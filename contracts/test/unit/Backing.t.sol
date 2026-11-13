// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    BackingTier,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev Backing (05-01): vouch, agree, unback, pledge release, and the backed loan paths M4 left to M5 (DECISIONS
/// P-6). Contribution 100e6, APY 0, settlements at the exact start of the next epoch. S6: 6 members, totalEpochs 7,
/// allocation 40/30/20/10, per-loan max 50%; at settle(3) with epoch 3 paid by all: V 1_800e6, bucket 720e6, max
/// 360e6.
contract BackingTest is BackingTestBase {
    uint256 private constant MAX = type(uint256).max;

    function test_T_BK_1_backingBlockedEachReason() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m0, address m1, address m2, address m3, address m4, address m5) =
            (ms[0], ms[1], ms[2], ms[3], ms[4], ms[5]);
        // Own min(400e6, 300e6 × 90%) = 270e6, backed 130e6.
        vm.prank(m1);
        assertEq(c.requestLoan(400e6, 2, 800, 0), 1);
        assertEq(c.getLoan(1).backedNeed, 130e6);
        assertEq(_request(c, m0, 10e6, 1, 0), 2);

        // The borrower (its pending request is this one), then a member with another pending request.
        _vouchReverts(c, m1, 1, 10e6, IKuberCircleErrors.HasPendingRequest.selector);
        _vouchReverts(c, m0, 1, 10e6, IKuberCircleErrors.HasPendingRequest.selector);
        _vouchReverts(c, _newMembers(1)[0], 1, 10e6, IKuberCircleErrors.NotMember.selector);
        _vouchReverts(c, m2, 1, 0, IKuberCircleErrors.ZeroAmount.selector);
        _vouchReverts(c, m2, 1, 300e6 + 1, IKuberCircleErrors.ExceedsFreeSavings.selector);
        _vouchReverts(c, m2, 1, 131e6, IKuberCircleErrors.OverPledged.selector);
        _agreeReverts(c, m4, 1, 100e6 + 1, IKuberCircleErrors.AgreeCapExceeded.selector);

        // The agree cap is cumulative (R-D): 60e6 + 41e6 > 100e6; 60e6 + 40e6 fits, as one entry.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Backed(1, m4, BackingTier.Agree, 60e6);
        _agreeAs(c, m4, 1, 60e6);
        _agreeReverts(c, m4, 1, 41e6, IKuberCircleErrors.AgreeCapExceeded.selector);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Backed(1, m4, BackingTier.Agree, 40e6);
        _agreeAs(c, m4, 1, 40e6);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.agreers.length, 1);
        assertEq(loan.agreers[0].backer, m4);
        assertEq(loan.agreers[0].amount, 100e6);
        assertEq(c.getMember(m4).pledgedOut, 100e6);
        _vouchReverts(c, m4, 1, 1e6, IKuberCircleErrors.OtherTier.selector);

        // Same-tier top-up adds to the one entry.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Backed(1, m2, BackingTier.Vouch, 10e6);
        _vouchAs(c, m2, 1, 10e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Backed(1, m2, BackingTier.Vouch, 5e6);
        _vouchAs(c, m2, 1, 5e6);
        loan = c.getLoan(1);
        assertEq(loan.vouchers.length, 1);
        assertEq(loan.vouchers[0].backer, m2);
        assertEq(loan.vouchers[0].amount, 15e6);
        assertEq(c.getMember(m2).pledgedOut, 15e6);
        _agreeReverts(c, m2, 1, 1e6, IKuberCircleErrors.OtherTier.selector);
        // Both tiers count toward backedNeed: 115e6 + 15_000_001 > 130e6.
        _vouchReverts(c, m3, 1, 15e6 + 1, IKuberCircleErrors.OverPledged.selector);

        _h(c).setLeavePending(m5, true);
        _vouchReverts(c, m5, 1, 1e6, IKuberCircleErrors.LeavePending.selector);
        _h(c).setLeavePending(m5, false);
        _debt(m5);
        _vouchReverts(c, m5, 1, 1e6, IKuberCircleErrors.HasOpenDebt.selector);
        _agreeReverts(c, m5, 1, 1e6, IKuberCircleErrors.HasOpenDebt.selector);
        _vouchReverts(c, m3, 99, 1e6, IKuberCircleErrors.NotPending.selector);

        // No revert above left a pledge behind.
        assertEq(c.getMember(m3).pledgedOut, 0);
        assertEq(c.getMember(m5).pledgedOut, 0);

        // Start of epoch 4, settle(3) not run yet.
        _warpTo(c, 4, false);
        _vouchReverts(c, m2, 1, 1e6, IKuberCircleErrors.SettlementPending.selector);

        // settle(3): id 2 (no backed part) is funded; id 1 is not (Σ 115e6 ≠ 130e6).
        c.settle(MAX);
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Funded));
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        _vouchReverts(c, m0, 1, 1e6, IKuberCircleErrors.HasActiveLoan.selector);
        _vouchReverts(c, m3, 2, 1e6, IKuberCircleErrors.NotPending.selector);
        assertEq(c.getMember(m2).pledgedOut, 15e6);
        assertEq(c.getMember(m4).pledgedOut, 100e6);
    }

    function test_T_BK_1_pledgedSavingsAreNotFree() public {
        // Free savings are savings − pledgedOut: savings already pledged elsewhere cannot back another loan (I1).
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        address m2 = ms[2];
        // m1, m3, m4 each request 400e6 (ids 1, 2, 3), each backed 130e6.
        address[3] memory borrowers = [ms[1], ms[3], ms[4]];
        for (uint256 i; i < 3; ++i) {
            vm.prank(borrowers[i]);
            assertEq(c.requestLoan(400e6, 2, 800, 0), i + 1);
        }
        _vouchAs(c, m2, 1, 130e6);
        _vouchAs(c, m2, 2, 130e6);
        // Savings 300e6, pledged 260e6: 40e6 is free although 40_000_001 ≤ savings and ≤ the 130e6 still needed.
        _vouchReverts(c, m2, 3, 40e6 + 1, IKuberCircleErrors.ExceedsFreeSavings.selector);
        _agreeReverts(c, m2, 3, 40e6 + 1, IKuberCircleErrors.ExceedsFreeSavings.selector);
        _vouchAs(c, m2, 3, 40e6);
        assertEq(c.getMember(m2).pledgedOut, 300e6);
        assertEq(c.getMember(m2).savings, 300e6);
        _vouchReverts(c, m2, 3, 1, IKuberCircleErrors.ExceedsFreeSavings.selector);
    }

    function test_T_BK_1_atMostTenDistinctVouchers() public {
        (KuberCircle c, address[] memory ms) = _startLoans(13, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        assertEq(c.requestLoan(400e6, 2, 800, 0), 1);
        assertEq(c.getLoan(1).backedNeed, 130e6);
        for (uint256 i = 1; i <= 10; ++i) {
            _vouchAs(c, ms[i], 1, 1e6);
        }
        _vouchReverts(c, ms[11], 1, 1e6, IKuberCircleErrors.TooManyBackers.selector);
        // An existing voucher adds to its entry; the count stays 10.
        _vouchAs(c, ms[1], 1, 1e6);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.vouchers.length, 10);
        assertEq(loan.vouchers[0].amount, 2e6);
        assertEq(c.getMember(ms[1]).pledgedOut, 2e6);
        // The agree tier counts separately.
        _agreeAs(c, ms[11], 1, 1e6);
        assertEq(c.getLoan(1).agreers.length, 1);
        assertEq(c.getMember(ms[11]).pledgedOut, 1e6);
    }

    function test_T_BK_1_atMostTenDistinctAgreers() public {
        // The agree-tier half of R-D's distinct-address cap.
        (KuberCircle c, address[] memory ms) = _startLoans(12, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        assertEq(c.requestLoan(400e6, 2, 800, 0), 1);
        for (uint256 i = 1; i <= 10; ++i) {
            _agreeAs(c, ms[i], 1, 1e6);
        }
        _agreeReverts(c, ms[11], 1, 1e6, IKuberCircleErrors.TooManyBackers.selector);
        _agreeAs(c, ms[10], 1, 1e6);
        assertEq(c.getLoan(1).agreers.length, 10);
        assertEq(c.getLoan(1).agreers[9].amount, 2e6);
        _vouchAs(c, ms[11], 1, 1e6);
        assertEq(c.getLoan(1).vouchers.length, 1);
    }

    function test_T_BK_2_unbackReleasesInOpenKeepsOrder() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m0, address m2, address m3, address m4, address m5) = (ms[0], ms[2], ms[3], ms[4], ms[5]);
        _backed80(c, ms);
        _vouchAs(c, m2, 1, 10e6);
        _vouchAs(c, m4, 1, 20e6);
        _vouchAs(c, m5, 1, 30e6);
        assertEq(c.getMember(m4).pledgedOut, 20e6);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Unbacked(1, m4, 20e6);
        vm.prank(m4);
        c.unback(1);
        assertEq(c.getMember(m4).pledgedOut, 0);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.vouchers.length, 2);
        assertEq(loan.vouchers[0].backer, m2);
        assertEq(loan.vouchers[0].amount, 10e6);
        assertEq(loan.vouchers[1].backer, m5);
        assertEq(loan.vouchers[1].amount, 30e6);
        _unbackReverts(c, m4, 1, IKuberCircleErrors.NotBacker.selector);
        _unbackReverts(c, m0, 1, IKuberCircleErrors.NotBacker.selector);

        // The role is freed: m4 may now agree.
        _agreeAs(c, m4, 1, 20e6);
        assertEq(c.getLoan(1).agreers[0].backer, m4);
        assertEq(c.getMember(m4).pledgedOut, 20e6);

        // An agreer unbacks too.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Unbacked(1, m4, 20e6);
        vm.prank(m4);
        c.unback(1);
        assertEq(c.getLoan(1).agreers.length, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);

        // Removing the first of three keeps the rest in order ([m5, m3], where swap-and-pop would give [m3, m5]).
        _vouchAs(c, m3, 1, 5e6);
        vm.prank(m2);
        c.unback(1);
        loan = c.getLoan(1);
        assertEq(loan.vouchers.length, 2);
        assertEq(loan.vouchers[0].backer, m5);
        assertEq(loan.vouchers[1].backer, m3);
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m5).pledgedOut, 30e6);
        assertEq(c.getMember(m3).pledgedOut, 5e6);
    }

    function test_T_EP_2_backingRevertsInLock() public {
        // DECISIONS P-6 moved this backing case of T-EP-2 to M5.
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m2, address m3) = (ms[2], ms[3]);
        _backed80(c, ms);
        _vouchAs(c, m2, 1, 10e6);
        _vouchAs(c, ms[4], 1, 20e6);
        _vouchAs(c, ms[5], 1, 30e6);

        _warpTo(c, 3, true);
        _unbackReverts(c, m2, 1, IKuberCircleErrors.LockWindow.selector);
        _vouchReverts(c, m3, 1, 1e6, IKuberCircleErrors.LockWindow.selector);
        _agreeReverts(c, m3, 1, 1e6, IKuberCircleErrors.LockWindow.selector);

        // Start of epoch 4, settle(3) not run yet.
        _warpTo(c, 4, false);
        _vouchReverts(c, m3, 1, 1e6, IKuberCircleErrors.SettlementPending.selector);
        _agreeReverts(c, m3, 1, 1e6, IKuberCircleErrors.SettlementPending.selector);
        _unbackReverts(c, m2, 1, IKuberCircleErrors.SettlementPending.selector);
        assertEq(c.getMember(m2).pledgedOut, 10e6);
        assertEq(c.getMember(m3).pledgedOut, 0);
    }

    function test_T_BK_2_unbackAfterFundingReverts() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        address m2 = ms[2];
        _backed80(c, ms);
        _vouchAs(c, m2, 1, 10e6);
        _vouchAs(c, ms[4], 1, 20e6);
        _vouchAs(c, ms[5], 1, 30e6);
        _vouchAs(c, ms[0], 1, 20e6);

        // Σ 80e6 == backedNeed: funded at settle(3).
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Line);
        c.settle(MAX);
        _unbackReverts(c, m2, 1, IKuberCircleErrors.NotPending.selector);
        // The pledge stays locked for the loan's life (T-05-01).
        assertEq(c.getMember(m2).pledgedOut, 10e6);
        assertEq(c.getLoan(1).vouchers.length, 4);
    }

    function test_T_Q_5_expiryReleasesPledges() public {
        // The expiry itself was tested in M4; DECISIONS P-6 moved the pledge release here.
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m1, address m2, address m4) = (ms[1], ms[2], ms[4]);
        // 3 + 1 + 3 = 7 ≤ 7; backed 80e6.
        vm.prank(m1);
        assertEq(c.requestLoan(350e6, 3, 800, 0), 1);
        _vouchAs(c, m2, 1, 30e6);
        _agreeAs(c, m4, 1, 20e6);

        // Σ 50e6 ≠ 80e6: never eligible.
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(1).age, 1);
        assertEq(c.getMember(m2).pledgedOut, 30e6);
        assertEq(c.getMember(m4).pledgedOut, 20e6);

        // settle(4): 4 + 1 + 3 > 7.
        _warpTo(c, 5, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.RequestExpired(1);
        c.settle(MAX);
        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Expired));
        assertEq(c.getMember(m1).pendingRequestId, 0);
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);
        // History kept.
        assertEq(loan.vouchers[0].amount, 30e6);
        assertEq(loan.agreers[0].amount, 20e6);
    }

    function test_cancelRequestReleasesPledges() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m1, address m2, address m4) = (ms[1], ms[2], ms[4]);
        _backed80(c, ms);
        _vouchAs(c, m2, 1, 30e6);
        _agreeAs(c, m4, 1, 50e6);
        vm.prank(m1);
        c.cancelRequest(1);
        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Cancelled));
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);
        assertEq(loan.vouchers[0].amount, 30e6);
        assertEq(loan.agreers[0].amount, 50e6);
        // A released pledge cannot be freed a second time (T-05-04).
        _unbackReverts(c, m2, 1, IKuberCircleErrors.NotPending.selector);
    }

    function test_T_RP_1_backedSplitExact() public {
        // The voucher and agreer parts are T-RP-1's M5 half (DECISIONS P-6); the 3-installment parts do not divide
        // evenly.
        (KuberCircle c, address[] memory ms) = _s6();
        (address m2, address m3, address m4) = (ms[2], ms[3], ms[4]);
        _loanL3(c, ms);
        vm.prank(m3);
        c.claim();
        assertEq(c.getMember(m2).pledgedOut, 30e6);
        assertEq(c.getMember(m4).pledgedOut, 50e6);

        // Epoch 4: nothing due yet, so no fines. Principal parts 116_666_666 ×2 + 116_666_668, saver 2_700_000,
        // voucher 800_000, agreer 666_666 ×2 + 666_668.
        uint256 bal = usdc.balanceOf(m3);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 120_833_332);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 120_833_332);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 2, 120_833_336);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, true);
        vm.prank(m3);
        c.repayAll();
        assertEq(bal - usdc.balanceOf(m3), 362_500_000);

        assertEq(c.getMember(m2).rewards, 2_400_000);
        assertEq(c.getMember(m4).rewards, 2_000_000);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.vouchers[0].interestPaid, 2_400_000);
        assertEq(loan.agreers[0].interestPaid, 2_000_000);
        assertEq(loan.principalRepaid, 350e6);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.totalRewardsOwed, 4_400_000);
        assertEq(p.saverPot, 8_100_000);
        assertEq(p.outstandingPrincipal, 0);
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);
    }

    function test_T_PAY_4_backerFinesProRata() public {
        // The backer-fine path DECISIONS P-6 moved to M5; it replaces M4's test_D11_backerPartsViaHarness.
        (KuberCircle c, address[] memory ms) = _s6();
        (address m2, address m3, address m4) = (ms[2], ms[3], ms[4]);
        _loanL3(c, ms);
        // settle(4) pulls contribution 4 only; installment 0 is due in 5.
        vm.startPrank(m3);
        c.claim();
        usdc.approve(address(c), 100e6);
        vm.stopPrank();
        _settleAt(c, 5);
        assertEq(usdc.allowance(m3, address(c)), 0);

        // settle(5): contribution 5 fits the 100e6 allowance, installment 0 does not.
        vm.prank(m3);
        usdc.approve(address(c), 100e6);
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m3, 5, 100e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m3, 3_624_999);
        c.settle(MAX);
        assertEq(c.getLoan(1).missedCount, 1);

        // Epoch 6: installment 0 found unpaid by settle(5) only: one fine floor(120_833_332 × 3%) = 3_624_999, split
        // m2 floor(× 30e6 / 80e6) = 1_359_374 and m4 (last) the rest, 2_265_625.
        vm.prank(m3);
        usdc.approve(address(c), 10_000e6);
        uint256 bal = usdc.balanceOf(m3);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 124_458_331);
        vm.prank(m3);
        c.payArrears(1);
        uint256 paid = bal - usdc.balanceOf(m3);
        assertEq(paid, 124_458_331);
        assertEq(c.getMember(m2).rewards, 800_000 + 1_359_374);
        assertEq(c.getMember(m4).rewards, 666_666 + 2_265_625);
        assertEq(c.getPublicSummary().saverPot, 2_700_000);

        // Installment 1 due now (not yet checked by a settlement) and 2 in the future: no fines.
        bal = usdc.balanceOf(m3);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 120_833_332);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 2, 120_833_336);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.prank(m3);
        c.repayAll();
        paid += bal - usdc.balanceOf(m3);
        assertEq(paid, 362_500_000 + 3_624_999);

        assertEq(c.getMember(m2).rewards, 3_759_374);
        assertEq(c.getMember(m4).rewards, 4_265_625);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 8_100_000);
        assertEq(p.totalRewardsOwed, 8_024_999);
        assertEq(p.outstandingPrincipal, 0);
        // Every unit the borrower paid is principal, the savers' pot, or a backer reward.
        assertEq(paid, c.getLoan(1).principalRepaid + p.saverPot + 3_759_374 + 4_265_625);
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);
    }

    function test_T_RP_2_repayAllReleasesPledges() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, ms);
        (address m2, address m3, address m4) = (ms[2], ms[3], ms[4]);
        vm.prank(m3);
        assertEq(c.requestLoan(350e6, 3, 800, 0), 1);
        _vouchAs(c, m2, 1, 30e6);
        _agreeAs(c, m4, 1, 50e6);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded));
        vm.prank(m3);
        c.claim();

        assertEq(c.getMember(m2).pledgedOut, 30e6);
        assertEq(c.getMember(m4).pledgedOut, 50e6);
        uint256 bal = usdc.balanceOf(m3);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, true);
        vm.prank(m3);
        c.repayAll();
        assertEq(bal - usdc.balanceOf(m3), 362_500_000);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));
        assertEq(c.getMember(m2).pledgedOut, 0);
        assertEq(c.getMember(m4).pledgedOut, 0);
        assertEq(c.getMember(m2).rewards, 2_400_000);
        assertEq(c.getMember(m4).rewards, 2_000_000);
        // Clock 4 + cooldownEpochs 1.
        assertEq(c.getMember(m3).cooldownUntil, 5);
        assertEq(c.getMember(m3).activeLoanId, 0);
        assertEq(registry.memberStats(m3).repaidOnTime, 1);
    }

    function test_T_Q_7_agedBackedRequestBeatsFastLane() public {
        // 10 members, totalEpochs 10, allocation 20/30/40/10, per-loan max 100%; every member pays each epoch right
        // after its settlement (a borrower's payNow also pays its due installment).
        (KuberCircle c, address[] memory ms) = _startLoans(10, 10, _alloc(2_000, 3_000, 4_000, 1_000), 10_000);
        _openEpoch3(c, ms);
        // id 1: own 270e6, backed 330e6 by m5 and m6.
        vm.prank(ms[4]);
        assertEq(c.requestLoan(600e6, 3, 0, 0), 1);
        assertEq(c.getLoan(1).backedNeed, 330e6);
        _vouchAs(c, ms[5], 1, 180e6);
        _vouchAs(c, ms[6], 1, 150e6);
        assertEq(_request(c, ms[1], 180e6, 1, 500), 2);

        // settle(3): V 3_000e6, capacity 600e6, fast budget 180e6: id 2 Fast, 420e6 left < 600e6.
        _settleAt(c, 4);
        _assertLoan(c, 1, LoanStatus.Pending, Lane.None, 1, 0);
        _assertLoan(c, 2, LoanStatus.Funded, Lane.Fast, 0, 3);
        _payAllBut(c, ms, address(0));
        assertEq(_request(c, ms[2], 180e6, 1, 500), 3);

        // settle(4): V 4_000e6, capacity 800e6 − 180e6 = 620e6, fast budget 186e6: id 3 Fast, 440e6 left < 600e6.
        _settleAt(c, 5);
        _assertLoan(c, 1, LoanStatus.Pending, Lane.None, 2, 0);
        _assertLoan(c, 2, LoanStatus.Funded, Lane.Fast, 0, 3);
        _assertLoan(c, 3, LoanStatus.Funded, Lane.Fast, 0, 4);
        // m1's payNow repays id 2: 180e6 + 5_400_000 + 9_000_000.
        uint256 bal = usdc.balanceOf(ms[1]);
        _payAllBut(c, ms, address(0));
        assertEq(bal - usdc.balanceOf(ms[1]), 100e6 + 194_400_000);
        assertEq(_request(c, ms[3], 240e6, 1, 500), 4);

        // settle(5): V 5_000e6, capacity 1_000e6 − 180e6 = 820e6. Aged: id 1 → 220e6 left. Fast budget 66e6: id 4
        // skipped; spill back 240e6 > 220e6 skipped. Without the aged lane, id 4 (fast budget 246e6) would be funded
        // first and leave 580e6 < 600e6.
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Aged);
        c.settle(MAX);
        _assertLoan(c, 1, LoanStatus.Funded, Lane.Aged, 2, 5);
        _assertLoan(c, 2, LoanStatus.Repaid, Lane.Fast, 0, 3);
        _assertLoan(c, 3, LoanStatus.Funded, Lane.Fast, 0, 4);
        _assertLoan(c, 4, LoanStatus.Pending, Lane.None, 1, 0);
        // 270e6 × 3%; the aged lane charges no extra.
        assertEq(c.getLoan(1).saverInterest, 8_100_000);
        assertEq(c.getMember(ms[4]).activeLoanId, 1);
        assertEq(c.getQueue().length, 1);
        assertEq(c.getQueue()[0], 4);
        // id 3 180e6 + id 1 600e6.
        assertEq(c.getPublicSummary().outstandingPrincipal, 780e6);
    }

    function _s6() private returns (KuberCircle c, address[] memory ms) {
        return _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
    }

    /// @dev ms[1] requests 350e6 over 2 epochs at 8% (id 1): own 270e6, backed 80e6.
    function _backed80(KuberCircle c, address[] memory ms) private {
        vm.prank(ms[1]);
        assertEq(c.requestLoan(350e6, 2, 800, 0), 1);
        assertEq(c.getLoan(1).backedNeed, 80e6);
    }

    /// @dev Loan L3 on S6: only m3 pre-pays epoch 3 (savings 300e6, the others 200e6 until settle(3)); m3 requests
    /// 350e6 over 3 epochs at 8% (own 270e6, backed 80e6); m2 vouches 30e6, m4 agrees 50e6; funded Line at settle(3)
    /// (V 1_800e6). Clock: start of epoch 4.
    function _loanL3(KuberCircle c, address[] memory ms) private {
        (address m2, address m3, address m4) = (ms[2], ms[3], ms[4]);
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m3);
        vm.prank(m3);
        assertEq(c.requestLoan(350e6, 3, 800, 0), 1);
        assertEq(c.getLoan(1).backedNeed, 80e6);
        _vouchAs(c, m2, 1, 30e6);
        _agreeAs(c, m4, 1, 50e6);
        _settleAt(c, 4);
        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Funded));
        assertEq(uint256(loan.lane), uint256(Lane.Line));
        assertEq(loan.saverInterest, 8_100_000);
        // 30e6 × 800 / 10_000 and 50e6 × 800 / 20_000 (R-C).
        assertEq(loan.vouchers[0].interest, 2_400_000);
        assertEq(loan.agreers[0].interest, 2_000_000);
    }

    function _assertLoan(KuberCircle c, uint256 id, LoanStatus status, Lane lane, uint256 age, uint256 fundedEpoch)
        private
        view
    {
        Loan memory loan = c.getLoan(id);
        assertEq(uint256(loan.status), uint256(status), "status");
        assertEq(uint256(loan.lane), uint256(lane), "lane");
        assertEq(loan.age, age, "age");
        assertEq(loan.fundedEpoch, fundedEpoch, "fundedEpoch");
    }

    function _vouchReverts(KuberCircle c, address who, uint256 id, uint256 amt, bytes4 err) private {
        vm.expectRevert(err);
        vm.prank(who);
        c.vouch(id, amt);
    }

    function _agreeReverts(KuberCircle c, address who, uint256 id, uint256 amt, bytes4 err) private {
        vm.expectRevert(err);
        vm.prank(who);
        c.agree(id, amt);
    }

    function _unbackReverts(KuberCircle c, address who, uint256 id, bytes4 err) private {
        vm.expectRevert(err);
        vm.prank(who);
        c.unback(id);
    }
}
