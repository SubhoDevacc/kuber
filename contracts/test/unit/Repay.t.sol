// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleErrors, IKuberCircleEvents, Lane, Loan, LoanStatus, Member} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev Repayment (04-03), own-part loans. Contribution 100e6, installFineBps 300, ownRate 300, cooldownEpochs 1,
/// APY 0, settlements at the exact start of the next epoch. Loan L: S6, m0 prepays epoch 3 and requests 270e6 over
/// 2 epochs (id 1), funded Line at settle(3): saverInterest 8_100_000, installments 139_050_000 (135e6 principal +
/// 4_050_000 saver part) due in epochs 5 and 6. Token movements are balance changes.
contract RepayTest is LoanTestBase {
    uint256 private constant MAX = type(uint256).max;

    function test_D15_installmentsAndSaverPot() public {
        (KuberCircle c, address m0) = _loanL();
        assertEq(c.getLoan(1).saverInterest, 8_100_000);
        // settle(4): contribution only; installment 0 is due in 5.
        _settleAt(c, 5);
        uint256 bal = usdc.balanceOf(m0);

        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 139_050_000);
        c.settle(MAX);
        // Contribution 5 + installment 0.
        assertEq(bal - usdc.balanceOf(m0), 239_050_000);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.principalRepaid, 135e6);
        assertEq(loan.installmentsPaid, 1);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.outstandingPrincipal, 135e6);
        assertEq(p.saverPot, 4_050_000);

        bal = usdc.balanceOf(m0);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 139_050_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, true);
        c.settle(MAX);
        assertEq(bal - usdc.balanceOf(m0), 239_050_000);
        loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Repaid));
        assertEq(loan.principalRepaid, 270e6);
        assertEq(loan.missedCount, 0);
        p = c.getPublicSummary();
        assertEq(p.outstandingPrincipal, 0);
        assertEq(p.saverPot, 8_100_000);
        Member memory b = c.getMember(m0);
        assertEq(b.activeLoanId, 0);
        // Closed by settle(6): k 6 + cooldownEpochs 1.
        assertEq(b.cooldownUntil, 7);
        assertEq(registry.memberStats(m0).repaidOnTime, 1);
        assertEq(registry.memberStats(m0).lateInstallments, 0);
    }

    function test_ownPartCycle_payouts() public {
        (KuberCircle c, address m0) = _loanL();
        address[] memory ms = c.members();
        vm.prank(m0);
        c.claim();
        _settleAt(c, 5);
        _settleAt(c, 6);
        _settleAt(c, 7);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));

        // 6 members × 2_800e6 weight; m0 borrowed, so W_saver is m1..m5.
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(0, 16_800e6, 14_000e6, 8_100_000, 4_200e6);
        c.settle(MAX);
        // 42 contributions + the loan's 8_100_000 interest.
        assertEq(usdc.balanceOf(address(c)), 4_208_100_000);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.sTotal, 4_200e6);
        assertEq(p.yieldPot, 0);
        assertEq(p.wActive, 16_800e6);
        assertEq(p.wSaver, 14_000e6);
        assertEq(p.saverPot, 8_100_000);

        uint256 sum;
        for (uint256 i; i < ms.length; ++i) {
            uint256 bal = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            uint256 paid = usdc.balanceOf(ms[i]) - bal;
            // The borrower gets no saver share; each saver gets 700e6 + 8_100_000 × 2_800 / 14_000.
            assertEq(paid, i == 0 ? 700_000_000 : 701_620_000);
            sum += paid;
        }
        assertEq(sum, 4_208_100_000);
        // Dust 0.
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    function test_T_RP_1_splitExactOwnPart() public {
        // The voucher and agreer parts are T-RP-1's M5 half (DECISIONS P-6).
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        uint256 snap = vm.snapshotState();

        // (i) Line: saverInterest floor(100_000_001 × 3%) = 3_000_000 (1_000_000 a part); principal parts
        // 33_333_333, 33_333_333, 33_333_335.
        _request(c, m0, 100_000_001, 3, 0);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).lane), uint256(Lane.Line));
        assertEq(c.getLoan(1).saverInterest, 3_000_000);
        // All three due in the future (5, 6, 7): no fines.
        assertEq(_repayAll3(c, m0, 34_333_333, 34_333_333, 34_333_335), 103_000_001);
        _assertCleared(c, 100_000_001, 3_000_000);

        // (ii) Fast (the only extra payer; budget 720e6 × 30% = 216e6): saverInterest 3_000_000 + floor(100_000_001 ×
        // 1%) = 4_000_000, saver parts 1_333_333, 1_333_333, 1_333_334; both components carry a remainder.
        vm.revertToState(snap);
        _request(c, m0, 100_000_001, 3, 100);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).lane), uint256(Lane.Fast));
        assertEq(c.getLoan(1).saverInterest, 4_000_000);
        assertEq(_repayAll3(c, m0, 34_666_666, 34_666_666, 34_666_669), 104_000_001);
        _assertCleared(c, 100_000_001, 4_000_000);
    }

    function test_T_RP_2_repayAllCooldownRegistry() public {
        // Also T-LN-1's InCooldown reason; pledge release is M5 (DECISIONS P-6).
        (KuberCircle c, address[] memory ms) = _startLoans(6, 10, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        address m0 = ms[0];
        _fundL(c, m0);
        vm.prank(m0);
        c.claim();

        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, true);
        vm.prank(m0);
        c.repayAll();
        assertEq(bal - usdc.balanceOf(m0), 278_100_000);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.outstandingPrincipal, 0);
        assertEq(p.saverPot, 8_100_000);
        Member memory b = c.getMember(m0);
        assertEq(b.activeLoanId, 0);
        // Clock 4 + cooldownEpochs 1.
        assertEq(b.cooldownUntil, 5);
        assertEq(registry.memberStats(m0).repaidOnTime, 1);
        assertEq(registry.memberStats(m0).loansTaken, 1);
        assertEq(registry.memberStats(m0).lateInstallments, 0);

        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 5);
        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);
        // Epoch 6 > cooldownUntil 5; 6 + 1 + 1 <= 10.
        _settleAt(c, 6);
        vm.prank(m0);
        assertEq(c.requestLoan(10e6, 1, 0, 0), 2);
    }

    function test_T_PAY_4_finesOwnPart() public {
        // The backer-fine path is M5 (DECISIONS P-6).
        (KuberCircle c, address m0) = _loanLPrime();
        // settle(5) with allowance 100e6: contribution 5 fits, installment 0 does not (139_050_000 × 3% = 4_171_500).
        vm.prank(m0);
        usdc.approve(address(c), 100e6);
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 5, 100e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        c.settle(MAX);
        assertEq(c.getLoan(1).missedCount, 1);
        assertEq(registry.memberStats(m0).lateInstallments, 1);
        assertEq(c.getPublicSummary().saverPot, 0);

        // settle(6), allowance 100e6: installment 0 fined again (not missed again), installment 1 missed and fined.
        vm.prank(m0);
        usdc.approve(address(c), 100e6);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 6, 100e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        c.settle(MAX);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.missedCount, 2);
        assertEq(loan.installmentsPaid, 0);
        assertEq(loan.lastCollectEpoch, 6);
        assertEq(registry.memberStats(m0).lateInstallments, 2);

        // Epoch 7: installment 0 was found unpaid by settle(5) and settle(6): 2 fines = 6% = 8_343_000.
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 147_393_000);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 139_050_000 + 8_343_000);
        // Installment 1, found unpaid by settle(6) only: 1 fine = 3%.
        bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 143_221_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 139_050_000 + 4_171_500);

        // No backers: both fines land in the savers' pot (8_100_000 + 8_343_000 + 4_171_500).
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 20_614_500);
        assertEq(p.outstandingPrincipal, 0);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));
        assertEq(c.getMember(m0).cooldownUntil, 8);
        assertEq(registry.memberStats(m0).repaidOnTime, 0);
        vm.expectRevert(IKuberCircleErrors.NothingDue.selector);
        vm.prank(m0);
        c.payArrears(1);
        vm.expectRevert(IKuberCircleErrors.NoActiveLoan.selector);
        vm.prank(m0);
        c.repayAll();
    }

    function test_D12_payNowInDueEpochThenSettleSkips() public {
        (KuberCircle c, address m0) = _loanL();
        _settleAt(c, 5);
        // Epoch 5, settle(5) not run: lastCollectEpoch 4, so installment 0 (due 5) carries no fine.
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 139_050_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 5, 100e6);
        vm.prank(m0);
        c.payNow();
        assertEq(bal - usdc.balanceOf(m0), 100e6 + 139_050_000);

        // settle(5) pulls nothing from m0 and records no miss.
        bal = usdc.balanceOf(m0);
        _settleAt(c, 6);
        assertEq(usdc.balanceOf(m0), bal);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.installmentsPaid, 1);
        assertEq(loan.missedCount, 0);
        assertEq(loan.lastCollectEpoch, 5);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 139_050_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, true);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 6, 100e6);
        vm.prank(m0);
        c.payNow();
        assertEq(bal - usdc.balanceOf(m0), 100e6 + 139_050_000);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));
        // Repaid at clock 6.
        assertEq(c.getMember(m0).cooldownUntil, 7);
        assertEq(c.getMember(m0).activeLoanId, 0);
        vm.expectRevert(IKuberCircleErrors.AlreadyPaid.selector);
        vm.prank(m0);
        c.payNow();
    }

    function test_A1_noFineWhileSettlePending() public {
        (KuberCircle c, address m0) = _loanLPrime();
        assertEq(c.getLoan(1).lastCollectEpoch, 4);
        // Start of epoch 6, settle(5) pending.
        _warpTo(c, 6, false);
        assertEq(c.getCircleState().settledEpoch, 4);
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 139_050_000);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 139_050_000);

        bal = usdc.balanceOf(m0);
        vm.recordLogs();
        c.settle(MAX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c)) continue;
            assertTrue(logs[i].topics[0] != IKuberCircleEvents.InstallmentMissed.selector, "missed");
            assertTrue(logs[i].topics[0] != IKuberCircleEvents.FineCharged.selector, "fined");
        }
        // Contribution 5 only.
        assertEq(bal - usdc.balanceOf(m0), 100e6);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.missedCount, 0);
        assertEq(loan.lastCollectEpoch, 5);
        assertEq(c.getPublicSummary().saverPot, 4_050_000);
    }

    function test_A1_oneFineThenTwo() public {
        (KuberCircle c, address m0) = _loanLPrime();
        uint256 snap = vm.snapshotState();

        // (b) settle(5) with allowance 0: contribution 5 and installment 0 missed; then one fine.
        _settleAt(c, 6);
        assertEq(c.getLoan(1).missedCount, 1);
        assertEq(c.getLoan(1).lastCollectEpoch, 5);
        assertEq(c.getMember(m0).missedBitmap, 1 << 5);
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 143_221_500);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 143_221_500);

        // (c) settle(5) and settle(6) with allowance 0: two fines on installment 0, one on installment 1.
        vm.revertToState(snap);
        _settleAt(c, 6);
        _settleAt(c, 7);
        assertEq(c.getLoan(1).missedCount, 2);
        assertEq(c.getLoan(1).lastCollectEpoch, 6);
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 147_393_000);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 147_393_000);
        bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 143_221_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 143_221_500);
    }

    function test_A1_selfSettleEqualsHandPay() public {
        (KuberCircle c, address m0) = _loanLPrime();
        _warpTo(c, 6, false);
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        uint256 snap = vm.snapshotState();

        // Route 1: m0 runs settle(5) itself; the auto-debit sees lastCollectEpoch 4, so installment 0 has no fine.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 139_050_000);
        vm.prank(m0);
        c.settle(MAX);
        assertEq(bal - usdc.balanceOf(m0), 239_050_000);
        assertEq(c.getLoan(1).missedCount, 0);
        bytes32 route1 = _stateHash(c, m0);

        // Route 2: m0 pays by hand while settle(5) is pending, then anyone settles (contribution 5 only).
        vm.revertToState(snap);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 139_050_000);
        c.settle(MAX);
        assertEq(bal - usdc.balanceOf(m0), 239_050_000);
        assertEq(c.getLoan(1).missedCount, 0);
        assertEq(_stateHash(c, m0), route1);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 4_050_000);
        assertEq(p.outstandingPrincipal, 135e6);
    }

    function test_A1_paymentBetweenBatches() public {
        (KuberCircle c, address m0) = _loanLPrime();
        // m0 created the circle, so it is memberList[0] and alone in a batch of one.
        assertEq(c.members()[0], m0);
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 0);
        c.settle(1);
        assertEq(c.getCircleState().cursor, 1);
        assertEq(c.getCircleState().settledEpoch, 4);
        assertEq(c.getLoan(1).lastCollectEpoch, 5);

        // m0's batch already ran: one fine, although settle(5) has not finished.
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 143_221_500);
        vm.prank(m0);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m0), 143_221_500);

        bal = usdc.balanceOf(m0);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 5);
        assertEq(usdc.balanceOf(m0), bal);
        assertEq(c.getLoan(1).missedCount, 1);
        assertEq(c.getLoan(1).installmentsPaid, 1);
    }

    function test_D12_repayAllWithLateInstallments() public {
        (KuberCircle c, address m0) = _loanL();
        // Allowance for contributions 4 and 5 only: installment 0 misses at settle(5).
        vm.prank(m0);
        usdc.approve(address(c), 200e6);
        _settleAt(c, 5);
        _settleAt(c, 6);
        assertEq(c.getLoan(1).missedCount, 1);
        assertEq(c.getLoan(1).lastCollectEpoch, 5);

        // Epoch 6: installment 0 found unpaid once; installment 1 (due 6) not yet checked by any settlement.
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 143_221_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 139_050_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.prank(m0);
        c.repayAll();
        assertEq(bal - usdc.balanceOf(m0), 282_271_500);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid));
        assertEq(c.getMember(m0).cooldownUntil, 7);
        assertEq(registry.memberStats(m0).repaidOnTime, 0);
        assertEq(registry.memberStats(m0).lateInstallments, 1);
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
    }

    function test_D13_collectStopsAtFirstUnpullable() public {
        (KuberCircle c, address m0) = _loanL();
        vm.prank(m0);
        usdc.approve(address(c), 200e6);
        _settleAt(c, 5);
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        c.settle(MAX);

        // Exactly contribution 6 + installment 0 with one fine (stored lastCollectEpoch 5: 5 − 5 + 1).
        vm.prank(m0);
        usdc.approve(address(c), 243_221_500);
        uint256 bal = usdc.balanceOf(m0);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 6, 100e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 143_221_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        c.settle(MAX);
        assertEq(bal - usdc.balanceOf(m0), 243_221_500);
        Loan memory loan = c.getLoan(1);
        assertEq(loan.installmentsPaid, 1);
        assertEq(loan.missedCount, 2);
        assertEq(usdc.allowance(m0, address(c)), 0);
    }

    function test_D13_installmentWithoutItsFineIsNotPulled() public {
        (KuberCircle c, address m0) = _loanL();
        vm.prank(m0);
        usdc.approve(address(c), 200e6);
        _settleAt(c, 5);
        _settleAt(c, 6);
        assertEq(c.getLoan(1).missedCount, 1);

        // One unit short of contribution 6 + installment 0 + its fine: the contribution comes off the budget, the
        // installment is not pulled without its fine, and the settlement does not revert (T-04-19).
        vm.prank(m0);
        usdc.approve(address(c), 100e6 + 143_221_500 - 1);
        uint256 bal = usdc.balanceOf(m0);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m0, 6, 100e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, m0, 4_171_500);
        c.settle(MAX);
        assertEq(bal - usdc.balanceOf(m0), 100e6);
        assertEq(c.getLoan(1).installmentsPaid, 0);
        assertEq(c.getLoan(1).missedCount, 2);
        assertEq(usdc.allowance(m0, address(c)), 143_221_500 - 1);
    }

    function test_D12_payNowAndArrearsPayOnlyWhatIsDue() public {
        (KuberCircle c, address m0) = _loanL();
        // Epoch 4: installment 0 is due in 5, so nothing is due yet.
        vm.expectRevert(IKuberCircleErrors.NothingDue.selector);
        vm.prank(m0);
        c.payArrears(3);
        uint256 bal = usdc.balanceOf(m0);
        vm.prank(m0);
        c.payNow();
        assertEq(bal - usdc.balanceOf(m0), 100e6);
        assertEq(c.getLoan(1).installmentsPaid, 0);

        // Allowance for contribution 5 only: settle(4) takes nothing (prepaid), settle(5) misses installment 0.
        vm.prank(m0);
        usdc.approve(address(c), 100e6);
        _settleAt(c, 5);
        _settleAt(c, 6);
        assertEq(c.getLoan(1).missedCount, 1);

        // Epoch 6: both installments are due; payNow pays contribution 6 and only the oldest, with its one fine.
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        bal = usdc.balanceOf(m0);
        vm.prank(m0);
        c.payNow();
        assertEq(bal - usdc.balanceOf(m0), 100e6 + 143_221_500);
        assertEq(c.getLoan(1).installmentsPaid, 1);
        // Contribution 6 already paid: payNow still pays the next due installment (not yet checked: no fine).
        bal = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.prank(m0);
        c.payNow();
        assertEq(bal - usdc.balanceOf(m0), 139_050_000);
        vm.expectRevert(IKuberCircleErrors.AlreadyPaid.selector);
        vm.prank(m0);
        c.payNow();
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
    }

    function test_T_END_2_wSaverZeroMergesSaverPot() public {
        // The clause DECISIONS P-6 moved to M4; Phase 3 tests the negative-yield part.
        (KuberCircle c, address[] memory ms) = _startLoans(5, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, ms);
        for (uint256 i; i < 5; ++i) {
            _request(c, ms[i], 100e6, 1, 0);
        }
        // settle(3): V 1_500e6, bucket 600e6, max 300e6: all five Line (500e6).
        _settleAt(c, 4);
        for (uint256 i; i < 5; ++i) {
            assertEq(uint256(c.getLoan(i + 1).lane), uint256(Lane.Line));
            vm.prank(ms[i]);
            c.claim();
        }
        assertEq(_h(c).wSaverAt(3), 0);
        _settleAt(c, 5);
        // settle(5): each member's contribution 5 and its 103e6 installment.
        _settleAt(c, 6);
        assertEq(c.getPublicSummary().saverPot, 15e6);
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
        _settleAt(c, 7);

        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(15e6, 14_000e6, 0, 0, 3_500e6);
        c.settle(MAX);
        for (uint256 i; i < 5; ++i) {
            uint256 bal = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            // 700e6 + 15e6 × 2_800 / 14_000.
            assertEq(usdc.balanceOf(ms[i]) - bal, 703e6);
        }
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    function test_repayBeforeClaim_proceedsStayClaimable() public {
        (KuberCircle c, address m0) = _loanL();
        assertEq(c.getLoan(1).unclaimed, 270e6);
        vm.prank(m0);
        c.repayAll();
        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Repaid));
        // The marker is cleared at full repayment; the proceeds stay as ordinary claimable.
        assertEq(loan.unclaimed, 0);
        assertEq(c.getMember(m0).claimable, 270e6);
        assertEq(c.getPublicSummary().reservedClaims, 270e6);

        uint256 bal = usdc.balanceOf(m0);
        vm.recordLogs();
        vm.prank(m0);
        c.claim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool claimed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c)) continue;
            assertTrue(logs[i].topics[0] != IKuberCircleEvents.LoanClaimed.selector, "LoanClaimed");
            if (logs[i].topics[0] == IKuberCircleEvents.Claimed.selector) {
                claimed = true;
                assertEq(abi.decode(logs[i].data, (uint256)), 270e6);
            }
        }
        assertTrue(claimed, "Claimed");
        assertEq(usdc.balanceOf(m0) - bal, 270e6);
        assertEq(c.getMember(m0).claimable, 0);
        assertEq(c.getPublicSummary().reservedClaims, 0);
        assertEq(c.getLoan(1).unclaimed, 0);
    }

    function _s6() private returns (KuberCircle c, address[] memory ms) {
        return _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
    }

    /// @dev Loan L on c, funded at settle(3); clock: start of epoch 4.
    function _fundL(KuberCircle c, address m0) private {
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 270e6, 2, 0);
        _settleAt(c, 4);
    }

    /// @dev Loan L on S6.
    function _loanL() private returns (KuberCircle c, address m0) {
        address[] memory ms;
        (c, ms) = _s6();
        m0 = ms[0];
        _fundL(c, m0);
    }

    /// @dev Loan L′: loan L, m0 claims in epoch 4 and approves exactly 100e6, settle(4) pulls contribution 4.
    /// Clock: start of epoch 5; allowance 0; lastCollectEpoch 4.
    function _loanLPrime() private returns (KuberCircle c, address m0) {
        (c, m0) = _loanL();
        vm.startPrank(m0);
        c.claim();
        usdc.approve(address(c), 100e6);
        vm.stopPrank();
        _settleAt(c, 5);
        assertEq(usdc.allowance(m0, address(c)), 0);
    }

    /// @dev repayAll of loan 1 with three installments; asserts the events in order; returns the amount paid.
    function _repayAll3(KuberCircle c, address who, uint256 a0, uint256 a1, uint256 a2) private returns (uint256) {
        uint256 bal = usdc.balanceOf(who);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, a0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, a1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 2, a2);
        vm.prank(who);
        c.repayAll();
        return bal - usdc.balanceOf(who);
    }

    function _assertCleared(KuberCircle c, uint256 amount, uint256 saverPot) private view {
        assertEq(c.getLoan(1).principalRepaid, amount);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.outstandingPrincipal, 0);
        assertEq(p.saverPot, saverPot);
    }

    /// @dev m0, loan 1, and the public summary with cash and vaults summed (the split is a rebalance detail).
    function _stateHash(KuberCircle c, address m0) private view returns (bytes32) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        return keccak256(
            abi.encode(
                c.getMember(m0),
                c.getLoan(1),
                p.cash + p.aaveValue + p.lpValue,
                p.saverPot,
                p.outstandingPrincipal,
                p.reservedClaims,
                p.sTotal,
                p.wActive,
                p.wSaver
            )
        );
    }
}
