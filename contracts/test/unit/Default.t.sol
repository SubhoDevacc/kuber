// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    CircleStatus,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev 05-02: pause trigger (T-DF-1), waterfall (T-DF-2), penalty and debt (T-DF-3), paused members (T-DF-4),
/// R-N2 zero debt, D-06 final-settlement expiry, T-EP-5 backers before the borrower. Vault APYs 0.
contract DefaultTest is BackingTestBase {
    uint256 private constant MAX = type(uint256).max;

    // ---------- T-DF-1: the pause rule (own-part loan of m0, 270e6; installments 92_700_000; one fine 2_781_000)

    function test_T_DF_1_missOneThenPayTwoStaysActive() public {
        (KuberCircle c, address[] memory m) = _ownLoan(10, 3);
        _next(c, m, 5, 100e6);
        _active(c, m[0], "after settle(4)");
        _next(c, m, 6, 100e6);
        _active(c, m[0], "after settle(5)");
        assertEq(c.getLoan(1).missedCount, 1, "installment 0 missed");
        _approve(c, m[0], 1_000e6);
        assertEq(_paid(c, m[0], 2), 92_700_000 + 2_781_000 + 92_700_000, "paid");
        assertEq(uint256(92_700_000 + 2_781_000 + 92_700_000), 188_181_000);
        _next(c, m, 7, 0);
        _active(c, m[0], "after settle(6)");
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        c.settle(MAX);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid), "repaid");
        _active(c, m[0], "after settle(7)");
    }

    function test_T_DF_1_missTwoThenPayOneStaysActive() public {
        (KuberCircle c, address[] memory m) = _ownLoan(10, 3);
        _next(c, m, 5, 100e6);
        _active(c, m[0], "after settle(4)");
        _next(c, m, 6, 100e6);
        _active(c, m[0], "after settle(5)");
        _next(c, m, 7, 100e6);
        _active(c, m[0], "after settle(6)");
        _approve(c, m[0], 1_000e6);
        // Installment 0 found unpaid at settle(5) and settle(6): two fines.
        assertEq(_paid(c, m[0], 1), 98_262_000, "92_700_000 + 5_562_000");
        _approve(c, m[0], 100e6);
        _next(c, m, 8, 0);
        // Installments 1 and 2 unpaid, oldest due 6 > 7 - 2.
        _active(c, m[0], "after settle(7)");
        _next(c, m, 9, 100e6);
        _suspended(c, m[0], "paused at settle(8)");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted), "defaulted");
    }

    function test_T_DF_1_threeUnpaidPauses() public {
        (KuberCircle c, address[] memory m) = _ownLoan(10, 3);
        _next(c, m, 5, 100e6);
        _active(c, m[0], "after settle(4)");
        _next(c, m, 6, 100e6);
        _active(c, m[0], "after settle(5)");
        _next(c, m, 7, 100e6);
        _active(c, m[0], "after settle(6)");
        _next(c, m, 8, 100e6);
        _suspended(c, m[0], "paused at settle(7)");
        assertEq(c.getLoan(1).installmentsPaid, 0, "3 unpaid");
    }

    function test_T_DF_1_oneInstallmentUnpaidThreeSettlementsPauses() public {
        (KuberCircle c, address[] memory m) = _ownLoan(10, 1);
        _next(c, m, 5, 100e6);
        _active(c, m[0], "after settle(4)");
        _next(c, m, 6, 100e6);
        _active(c, m[0], "after settle(5)");
        _next(c, m, 7, 100e6);
        _active(c, m[0], "after settle(6)");
        _next(c, m, 8, 100e6);
        // 1 unpaid (due 5), so only the d <= k - 2 trigger fires.
        _suspended(c, m[0], "paused at settle(7)");
        assertEq(c.getLoan(1).repayEpochs, 1);
        assertEq(c.getLoan(1).installmentsPaid, 0);
    }

    function test_T_DF_1_unpaidAtEndPausesBeforeFinalize() public {
        // 04-ADDENDUM A-3(a): the pause at settle(totalEpochs) runs before finalize.
        (KuberCircle c, address[] memory m) = _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        _settleAt(c, 4);
        _payAllBut(c, m, address(0));
        _settleAt(c, 5);
        _payAllBut(c, m, address(0));
        _request(c, m[0], 270e6, 1, 0);
        _settleAt(c, 6);
        vm.prank(m[0]);
        c.claim();
        _payAllBut(c, m, m[0]);
        _next(c, m, 7, 100e6);
        _active(c, m[0], "after settle(6)");
        _approve(c, m[0], 100e6);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 270e6, 270e6, 0, 0, 27e6, 8_343_000);
        c.settle(MAX);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "ended");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted), "defaulted");
        _suspended(c, m[0], "paused at settle(7)");
        assertEq(c.debtOf(m[0]), 8_343_000, "278_100_000 x 300 / 10_000");
        assertEq(c.getMember(m[0]).savings, 403e6, "700e6 - 270e6 - 27e6");
        assertEq(c.getPublicSummary().sTotal, 3_903e6, "5 x 700e6 + 403e6");
    }

    // ---------- T-DF-2: unclaimed proceeds, borrower, vouchers, agreers; the group loses 0

    function test_T_DF_2_waterfallOrderBorrowerVouchersAgreers() public {
        vm.recordLogs();
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        _expectSuspended(c, 1, 350e6, 300e6, 30e6, 20e6, 0, 106_749_998);
        Loan memory l = c.getLoan(1);
        assertEq(uint256(l.status), uint256(LoanStatus.Defaulted), "defaulted");
        assertEq(l.vouchers[0].loss, 10e6, "m1 loss: whole pledge");
        assertEq(l.vouchers[1].loss, 20e6, "m2 loss: whole pledge");
        assertEq(l.agreers[0].loss, 20e6, "m4 loss");
        assertEq(l.finesOwed, 21_749_998, "10_874_999 + 7_249_999 + 3_625_000");
        assertEq(uint256(10_874_999 + 7_249_999 + 3_625_000), 21_749_998);
        assertEq(l.penaltyOwed, 35e6, "penalty owed");
        assertEq(c.debtOf(m[3]), 106_749_998, "debt");
        Member memory b = c.getMember(m[3]);
        assertEq(b.savings, 0, "m3 savings");
        assertEq(uint256(b.status), uint256(MemberStatus.Suspended), "suspended");
        assertEq(b.activeLoanId, 0, "activeLoanId");
        assertEq(b.debtLoanId, 1, "debtLoanId");
        assertEq(c.getMember(m[1]).savings, 690e6, "m1 savings");
        assertEq(c.getMember(m[2]).savings, 680e6, "m2 savings");
        assertEq(c.getMember(m[4]).savings, 680e6, "m4 savings");
        for (uint256 i; i < 6; ++i) {
            assertEq(c.getMember(m[i]).pledgedOut, 0, "pledges released");
        }
        // Non-backers lose nothing: 300e6 + 4 contributions each.
        assertEq(c.getMember(m[0]).savings, 700e6, "m0 untouched");
        assertEq(c.getMember(m[5]).savings, 700e6, "m5 untouched");
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.outstandingPrincipal, 0, "outstandingPrincipal");
        assertEq(s.saverPot, 0, "saverPot");
        assertEq(registry.memberStats(m[3]).suspensions, 1, "registry suspensions");
        assertTrue(registry.hasOpenDebt(m[3]), "registry open debt");
        address[] memory dc = registry.debtCircles(m[3]);
        assertEq(dc.length, 1);
        assertEq(dc[0], address(c), "debt circle");
    }

    function test_T_DF_2_unclaimedProceedsCancelledFirst() public {
        vm.recordLogs();
        (KuberCircle c, address[] memory m) = _scenarioP(10, false, 4);
        _expectSuspended(c, 1, 0, 0, 0, 0, 0, 21_749_998);
        Loan memory l = c.getLoan(1);
        assertEq(l.principalRepaid, 350e6, "proceeds cancelled as repaid principal");
        assertEq(l.unclaimed, 0, "unclaimed");
        assertEq(l.vouchers[0].loss + l.vouchers[1].loss + l.agreers[0].loss, 0, "no backer loss");
        Member memory b = c.getMember(m[3]);
        assertEq(b.claimable, 0, "claimable");
        assertEq(b.savings, 300e6, "savings untouched");
        assertEq(uint256(b.status), uint256(MemberStatus.Suspended), "suspended");
        assertEq(c.debtOf(m[3]), 21_749_998, "debt is the fines");
        for (uint256 i; i < 6; ++i) {
            assertEq(c.getMember(m[i]).pledgedOut, 0, "pledges released");
        }
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.reservedClaims, 0, "reservedClaims");
        assertEq(s.outstandingPrincipal, 0, "outstandingPrincipal");
        vm.prank(m[3]);
        vm.expectRevert(IKuberCircleErrors.NothingToClaim.selector);
        c.claim();
    }

    function test_T_DF_2_repaidBeforeClaimExcessStaysClaimable() public {
        // D-07 capped at the unpaid principal (05-02 plan): the excess was repaid from the wallet and stays claimable.
        vm.recordLogs();
        (KuberCircle c, address[] memory m) = _scenarioP(7, false, 6);
        _expectSuspended(c, 1, 0, 0, 0, 0, 0, 10_874_999);
        assertEq(uint256(7_249_999 + 3_625_000), 10_874_999);
        Loan memory l = c.getLoan(1);
        assertEq(l.principalRepaid, 350e6, "116_666_666 paid + 233_333_334 cancelled");
        assertEq(l.installmentsPaid, 1, "installment 0 auto-debited");
        Member memory b = c.getMember(m[3]);
        assertEq(b.claimable, 116_666_666, "excess stays claimable");
        assertEq(b.savings, 500e6, "savings");
        assertEq(uint256(b.status), uint256(MemberStatus.Suspended), "suspended");
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.outstandingPrincipal, 0, "outstandingPrincipal");
        assertEq(s.reservedClaims, 116_666_666, "reservedClaims");
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "ended");
    }

    function test_T_DF_2_olderPledgeStaysAndTiersProRata() public {
        // R-N: only free savings pay; m3's older pledge on loan 1 (still Funded) stays pledged. Agreers split pro-rata.
        (KuberCircle c, address[] memory m) = _startLoans(6, 10, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        vm.prank(m[0]);
        c.requestLoan(280e6, 3, 800, 0);
        _vouchAs(c, m[3], 1, 10e6);
        // Own min(350e6, 290e6 x 0.9) = 261e6, backed 89e6.
        vm.prank(m[3]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[1], 2, 29e6);
        _agreeAs(c, m[4], 2, 30e6);
        _agreeAs(c, m[2], 2, 30e6);
        address[] memory payers = new address[](4);
        (payers[0], payers[1], payers[2], payers[3]) = (m[1], m[2], m[4], m[5]);
        for (uint256 e = 4; e <= 7; ++e) {
            _settleAt(c, e);
            if (e == 4) {
                vm.startPrank(m[3]);
                c.claim();
                usdc.approve(address(c), 0);
                vm.stopPrank();
            }
            _payAllBut(c, payers, address(0));
        }
        // m0 misses installment 2 at settle(7) without a pause, so loan 1 and m3's pledge stay open.
        _approve(c, m[0], 100e6);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        // Fines 10_876_499 + 7_250_999 + 3_625_500 (installments 120_849_999, 120_849_999, 120_850_002).
        emit IKuberCircleEvents.MemberSuspended(2, 350e6, 290e6, 29e6, 31e6, 0, 116_752_998);
        c.settle(MAX);
        Loan memory l = c.getLoan(2);
        assertEq(l.finesOwed, 21_752_998, "fines");
        assertEq(l.vouchers[0].loss, 29e6, "m1 whole pledge");
        assertEq(l.agreers[0].loss, 15_500_000, "m4 pro-rata");
        assertEq(l.agreers[1].loss, 15_500_000, "m2 pro-rata");
        assertEq(c.debtOf(m[3]), 116_752_998, "debt");
        Member memory b = c.getMember(m[3]);
        assertEq(b.savings, 10e6, "the pledged 10e6 is not taken");
        assertEq(b.pledgedOut, 10e6, "older pledge still open");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "loan 1 still funded");
        assertEq(c.getLoan(1).vouchers[0].loss, 0, "no loss on loan 1");
        assertEq(c.getMember(m[1]).savings, 671e6, "m1");
        assertEq(c.getMember(m[2]).savings, 684_500_000, "m2");
        assertEq(c.getMember(m[4]).savings, 684_500_000, "m4");
        assertEq(c.getMember(m[0]).savings, 700e6, "m0 untouched");
        assertEq(c.getMember(m[5]).savings, 700e6, "m5 untouched");
        for (uint256 i; i < 6; ++i) {
            Member memory x = c.getMember(m[i]);
            assertGe(x.savings, x.pledgedOut, "I1");
        }
        assertEq(c.getPublicSummary().outstandingPrincipal, 280e6 - c.getLoan(1).principalRepaid, "only loan 1 left");
    }

    // ---------- T-DF-3: penalty and debt

    function test_T_DF_3_penaltyPartlyPaidFromLeftover() public {
        (KuberCircle c, address[] memory m) = _startLoans(6, 10, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        vm.prank(m[3]);
        c.requestLoan(280e6, 3, 800, 0);
        _vouchAs(c, m[2], 1, 10e6);
        for (uint256 e = 4; e <= 7; ++e) {
            _settleAt(c, e);
            if (e == 4) {
                vm.startPrank(m[3]);
                c.claim();
                usdc.approve(address(c), 0);
                vm.stopPrank();
            }
            _payAllBut(c, m, m[3]);
        }
        _warpTo(c, 8, false);
        uint256 pot = c.getPublicSummary().saverPot;
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 280e6, 280e6, 0, 0, 20e6, 25_333_998);
        c.settle(MAX);
        Loan memory l = c.getLoan(1);
        assertEq(l.penaltyOwed, 8e6, "28e6 - 20e6");
        // Installments 96_299_999, 96_299_999, 96_300_002: 8_666_999 + 5_777_999 + 2_889_000.
        assertEq(l.finesOwed, 17_333_998, "fines");
        assertEq(l.vouchers[0].loss, 0, "m2 loss");
        assertEq(c.getPublicSummary().saverPot, pot + 20e6, "penalty paid to the savers' pot");
        assertEq(c.getMember(m[3]).savings, 0, "m3 savings");
        assertEq(c.getMember(m[2]).pledgedOut, 0, "pledge released");
        assertEq(c.debtOf(m[3]), 25_333_998, "debt");
    }

    function test_T_DF_3_penaltyUnpaidWithoutLeftover() public {
        vm.recordLogs();
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        _expectSuspended(c, 1, 350e6, 300e6, 30e6, 20e6, 0, 106_749_998);
        assertEq(c.getLoan(1).penaltyOwed, 35e6, "whole penalty owed");
        assertEq(c.getMember(m[3]).savings, 0, "no leftover");
        assertEq(c.getPublicSummary().saverPot, 0, "nothing paid to the savers' pot");
    }

    // ---------- R-N2: a default with debt 0 is not a suspension

    function test_RN2_zeroDebtDefaultStaysActive() public {
        address[] memory m = _newMembers(6);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        r.installFineBps = 0;
        KuberCircle c = _startPeople(m, 10, r);
        _activate(c);
        _openEpoch3(c, m);
        vm.prank(m[3]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[1], 1, 30e6);
        _agreeAs(c, m[4], 1, 50e6);
        _settleAt(c, 4);
        vm.prank(m[3]);
        c.claim();
        _payAllBut(c, m, m[3]);
        for (uint256 e = 5; e <= 7; ++e) {
            _next(c, m, e, 100e6);
            _active(c, m[3], "before the pause");
        }
        _approve(c, m[3], 100e6);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 350e6, 350e6, 0, 0, 35e6, 0);
        c.settle(MAX);
        Member memory b = c.getMember(m[3]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "stays Active");
        assertEq(b.savings, 315e6, "700e6 - 350e6 - 35e6");
        assertEq(b.activeLoanId, 0, "activeLoanId");
        assertEq(b.debtLoanId, 1, "debtLoanId");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted), "defaulted");
        assertEq(c.debtOf(m[3]), 0, "no debt");
        assertEq(c.getMember(m[1]).pledgedOut + c.getMember(m[4]).pledgedOut, 0, "pledges released");
        assertEq(registry.memberStats(m[3]).suspensions, 0, "no suspension");
        assertFalse(registry.hasOpenDebt(m[3]), "no debt entry");
        assertEq(_h(c).weightAt(m[3], 7), 2_415e6, "(100+200+300+400+500+600+315) x 1e6");
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += _h(c).weightAt(m[i], 7);
        }
        assertEq(sum, _h(c).wActiveAt(7), "weights match W_active");
    }

    // ---------- D-06: the final settlement expires every pending request, also in catch-up mode

    function test_D06_finalSettlementExpiresInCatchUp() public {
        (KuberCircle c, address[] memory m) = _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        _settleAt(c, 4);
        _payAllBut(c, m, address(0));
        _settleAt(c, 5);
        _payAllBut(c, m, address(0));
        // Own 450e6 (0.9 x 500e6), backed 50e6, pledged 10e6: never eligible.
        vm.prank(m[1]);
        c.requestLoan(500e6, 1, 800, 0);
        _vouchAs(c, m[2], 1, 10e6);
        _warpTo(c, 9, false);
        c.settle(MAX);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending), "settle(5) skipped");
        assertEq(c.getLoan(1).age, 0, "age after settle(5)");
        c.settle(MAX);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending), "settle(6) skipped although 6+1+1 > 7");
        assertEq(c.getLoan(1).age, 0, "age after settle(6)");
        assertEq(c.getMember(m[2]).pledgedOut, 10e6, "pledge still open");
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.RequestExpired(1);
        c.settle(MAX);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Expired), "expired");
        assertEq(c.getMember(m[2]).pledgedOut, 0, "pledge released");
        assertEq(c.getMember(m[1]).pendingRequestId, 0, "pendingRequestId");
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "ended");
    }

    // ---------- T-DF-4: a paused member is skipped and blocked

    function test_T_DF_4_pausedMemberSkippedAndBlocked() public {
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        address d = m[3];
        vm.startPrank(d);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.payNow();
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.catchUp(4);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.requestLoan(10e6, 1, 0, 0);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.payArrears(1);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.repayAll();
        vm.stopPrank();
        assertEq(_request(c, m[0], 10e6, 1, 0), 2, "id 2");
        vm.startPrank(d);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.vouch(2, 1e6);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.agree(2, 1e6);
        vm.stopPrank();
        _payAllBut(c, m, d);
        uint256 bal = usdc.balanceOf(d);
        _warpTo(c, 9, false);
        vm.recordLogs();
        c.settle(MAX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (logs[i].emitter != address(c)) continue;
            if (
                t == IKuberCircleEvents.ContributionPaid.selector || t == IKuberCircleEvents.ContributionMissed.selector
            ) {
                assertTrue(logs[i].topics[1] != bytes32(uint256(uint160(d))), "paused member collected");
            }
        }
        assertEq(usdc.balanceOf(d), bal, "nothing pulled");
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            if (i != 3) sum += _h(c).weightAt(m[i], 8);
        }
        assertEq(_h(c).wActiveAt(8), sum, "W_active == the five Active weights");
        // "Can't vote" and the sponsor's sponsoredSuspended are M6 (P-6, 06-CONTEXT D-05).
        assertEq(registry.memberStats(d).suspensions, 1, "suspensions");
        assertTrue(registry.hasOpenDebt(d), "open debt");
        address[] memory dc = registry.debtCircles(d);
        assertEq(dc.length, 1);
        assertEq(dc[0], address(c), "debt circle");
    }

    // ---------- T-EP-5: backers processed before the borrower; one batch or two; prepay order

    function test_T_EP_5_backersBeforeBorrowerBatchesMatch() public {
        // P-6 moved the default case of T-EP-5 to M5.
        (KuberCircle c, address[] memory p) = _s1Run(false, true);
        uint256 snap = vm.snapshotState();
        c.settle(3);
        KuberCircle.CircleState memory st = c.getCircleState();
        assertEq(uint256(st.status), uint256(CircleStatus.Active), "still Active after batch 1");
        assertEq(st.cursor, 3, "cursor after A, B, C");
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 350e6, 300e6, 30e6, 20e6, 0, 106_749_998);
        c.settle(3);
        assertEq(c.getLoan(2).finesOwed, 21_749_998, "fines");
        assertEq(c.getLoan(2).penaltyOwed, 35e6, "penalty owed");
        _s1End(c, p);
        _s1Payouts(c, p);
        vm.revertToState(snap);
        c.settle(MAX);
        _s1End(c, p);
        (c, p) = _s1Run(true, false);
        c.settle(MAX);
        _s1End(c, p);
        _s1Payouts(c, p);
    }

    // ---------- helpers

    /// @dev Own-part loan: m0 borrows 270e6 over `r` in epoch 3, funded at settle(3); the clock is then epoch 4.
    function _ownLoan(uint8 totalEpochs, uint256 r) private returns (KuberCircle c, address[] memory m) {
        (c, m) = _startLoans(6, totalEpochs, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        _request(c, m[0], 270e6, r, 0);
        _next(c, m, 4, 0);
    }

    /// @dev Loan 1's borrower sets allowance `allowance` (0: unchanged), settle(e − 1) runs at the start of e, then
    /// everyone else pays e.
    function _next(KuberCircle c, address[] memory m, uint256 e, uint256 allowance) private {
        address b = c.getLoan(1).borrower;
        if (allowance != 0) _approve(c, b, allowance);
        _settleAt(c, e);
        _payAllBut(c, m, b);
    }

    function _approve(KuberCircle c, address who, uint256 amount) private {
        vm.prank(who);
        usdc.approve(address(c), amount);
    }

    /// @dev payArrears(n) as `who`; returns what it pulled.
    function _paid(KuberCircle c, address who, uint256 n) private returns (uint256) {
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        c.payArrears(n);
        return bal - usdc.balanceOf(who);
    }

    function _active(KuberCircle c, address who, string memory why) private view {
        assertEq(uint256(c.getMember(who).status), uint256(MemberStatus.Active), why);
    }

    function _suspended(KuberCircle c, address who, string memory why) private view {
        assertEq(uint256(c.getMember(who).status), uint256(MemberStatus.Suspended), why);
    }

    /// @dev Exactly one MemberSuspended from `c` since vm.recordLogs(), with these fields.
    function _expectSuspended(
        KuberCircle c,
        uint256 id,
        uint256 owed,
        uint256 fromB,
        uint256 fromV,
        uint256 fromA,
        uint256 p1,
        uint256 debt
    ) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != IKuberCircleEvents.MemberSuspended.selector) {
                continue;
            }
            ++found;
            assertEq(uint256(logs[i].topics[1]), id, "loan id");
            assertEq(logs[i].data, abi.encode(owed, fromB, fromV, fromA, p1, debt), "MemberSuspended fields");
        }
        assertEq(found, 1, "one MemberSuspended");
    }

    /// @dev SPEC §4 end state after settle(7) (CONTEXT D-20).
    function _s1End(KuberCircle c, address[] memory p) private view {
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.cash, 3_524_500_000, "cash");
        assertEq(s.reservedClaims + s.totalRewardsOwed + s.saverPot, 14_500_000, "liabilities");
        assertEq(s.sTotal, 3_450e6, "sTotal");
        assertEq(s.yieldPot, 60e6, "yieldPot");
        assertEq(s.wActive, 13_950e6, "wActive");
        assertEq(s.wSaver, 11_150e6, "wSaver");
        assertEq(_h(c).weightAt(p[0], 7), 2_800e6, "A weight");
        assertEq(_h(c).weightAt(p[1], 7), 2_800e6, "B weight");
        assertEq(_h(c).weightAt(p[2], 7), 2_770e6, "C weight");
        assertEq(_h(c).weightAt(p[4], 7), 2_780e6, "E weight");
        assertEq(_h(c).weightAt(p[5], 7), 2_800e6, "F weight");
    }

    /// @dev The five Active members' final payouts (D's 0 payout is 05-03 / 05-04).
    function _s1Payouts(KuberCircle c, address[] memory p) private {
        uint256[6] memory want = [uint256(712_043_010), 720_477_090, 683_926_264, 0, 693_976_540, 714_077_090];
        for (uint256 i; i < 6; ++i) {
            if (i == 3) continue;
            uint256 bal = usdc.balanceOf(p[i]);
            vm.prank(p[i]);
            c.withdraw();
            assertEq(usdc.balanceOf(p[i]) - bal, want[i], "payout");
        }
    }
}
