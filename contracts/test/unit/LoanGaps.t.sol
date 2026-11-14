// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    Member,
    MemberStatus
} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev Verifier probes for paths the phase tests do not exercise.
contract LoanGapsTest is GovTestBase {
    uint256 private constant MAX = type(uint256).max;

    function _s6() private returns (KuberCircle c, address[] memory ms) {
        return _startLoans(6, 9, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
    }

    /// @dev Three installments (B-style 100e6 over 3 at 3%: 34_333_333, 34_333_333, 34_333_334). Installment 0 misses
    /// at settle(5); in epoch 6 payNow pays contribution 6 + installment 0 (oldest, one fine), so contribution 6 is
    /// pre-paid when settle(6) runs while installment 1 (due 6) is unpaid. settle(6) must still pull or record it.
    function test_prepaidContributionWithInstallmentDueStillCollected() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 100e6, 3, 0);
        _settleAt(c, 4);
        vm.prank(m0);
        usdc.approve(address(c), 200e6); // contributions 4 and 5 only
        _settleAt(c, 5);
        _settleAt(c, 6);
        assertEq(c.getLoan(1).missedCount, 1);
        // Epoch 6: payNow = contribution 6 + installment 0 (34_333_333 + one fine 1_029_999).
        vm.prank(m0);
        usdc.approve(address(c), 100e6 + 34_333_333 + 1_029_999);
        _payNowAs(c, m0);
        assertEq(c.getLoan(1).installmentsPaid, 1);
        assertEq(usdc.allowance(m0, address(c)), 0);
        // (a) no allowance: settle(6) must record installment 1 as missed and set lastCollectEpoch 6.
        uint256 snap = vm.snapshotState();
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 1);
        c.settle(MAX);
        assertEq(c.getLoan(1).missedCount, 2);
        assertEq(c.getLoan(1).lastCollectEpoch, 6);
        // (b) with allowance: settle(6) pulls installment 1 although the contribution was pre-paid.
        vm.revertToState(snap);
        vm.prank(m0);
        usdc.approve(address(c), 34_333_333);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 34_333_333);
        c.settle(MAX);
        assertEq(c.getLoan(1).installmentsPaid, 2);
        assertEq(c.getLoan(1).missedCount, 1);
    }

    /// @dev A-4: when the contribution pull misses, an installment that fits the remaining budget is still pulled.
    function test_contributionMissesInstallmentStillPulled() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 100e6, 3, 0); // installments 34_333_333, 34_333_333, 34_333_334 due 5, 6, 7
        _settleAt(c, 4);
        _settleAt(c, 5);
        vm.prank(m0);
        usdc.approve(address(c), 50e6); // below the 100e6 contribution, above the installment
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionMissed(m0, 5);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 34_333_333);
        c.settle(MAX);
        assertEq(c.getLoan(1).missedCount, 0);
        assertEq(usdc.allowance(m0, address(c)), 50e6 - 34_333_333);
    }

    /// @dev Batched settle(k) finished after the clock moved to k + 2: funding is skipped (catch-up), the request is
    /// funded at settle(k + 1) with a fresh schedule.
    function test_batchedSettleFinishedLateSkipsFunding() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m1 = ms[1];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m1);
        _request(c, m1, 100e6, 1, 0);
        _warpTo(c, 4, false);
        c.settle(2); // first batch at clock 4
        _warpTo(c, 5, false);
        c.settle(MAX); // finishes settle(3) at clock 5: catching up, no funding
        assertEq(c.getCircleState().settledEpoch, 3);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(1).age, 0);
        c.settle(MAX); // settle(4) at clock 5: funds
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded));
        assertEq(c.getLoan(1).fundedEpoch, 4);
    }

    /// @dev A-3 (d), other half: a hand payment between two batches, before the borrower's batch ran, costs no fine
    /// and records no miss.
    function test_paymentBetweenBatchesBeforeOwnBatch() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m5 = ms[5]; // last in memberList
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m5);
        _request(c, m5, 270e6, 2, 0);
        _settleAt(c, 4);
        vm.prank(m5);
        usdc.approve(address(c), 100e6);
        _settleAt(c, 5);
        // settle(5): first batch processes m0..m4 only.
        _warpTo(c, 6, false);
        c.settle(5);
        assertEq(c.getCircleState().cursor, 5);
        vm.prank(m5);
        usdc.approve(address(c), 1_000e6);
        uint256 bal = usdc.balanceOf(m5);
        vm.prank(m5);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(m5), 139_050_000); // no fine
        vm.recordLogs();
        c.settle(MAX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c)) continue;
            assertTrue(logs[i].topics[0] != IKuberCircleEvents.InstallmentMissed.selector, "missed");
        }
        assertEq(c.getLoan(1).missedCount, 0);
    }

    /// @dev W_saver after a first loan for a borrower who pre-paid the next epoch before the funding settlement ran:
    /// W_saver equals the sum of the savers' weights (N-1).
    function test_removeFromSaverAfterPrepayOfNextEpoch() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 100e6, 1, 0);
        // Start of epoch 4: m0 pre-pays epoch 4 while settle(3) is pending, then settle(3) funds m0.
        _warpTo(c, 4, false);
        _payNowAs(c, m0);
        c.settle(MAX);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded));
        _settleAt(c, 5);
        _settleAt(c, 6);
        uint256 sum;
        for (uint256 i = 1; i < 6; ++i) {
            sum += _h(c).weightAt(ms[i], 5);
        }
        assertEq(_h(c).wSaverAt(5), sum);
        uint256 all = sum + _h(c).weightAt(m0, 5);
        assertEq(_h(c).wActiveAt(5), all);
    }

    /// @dev Very late repayAll (clock far past the cycle while the circle is still Active): the cooldown cap keeps
    /// the uint8 cast from reverting.
    function test_repayAllFarPastEnd() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 100e6, 1, 0);
        _settleAt(c, 4);
        vm.prank(m0);
        usdc.approve(address(c), 0);
        _warpTo(c, 300, false);
        vm.prank(m0);
        usdc.approve(address(c), 1_000e6);
        vm.prank(m0);
        c.repayAll();
        assertEq(c.getMember(m0).cooldownUntil, 10);
    }

    /// @dev Non-borrowers cannot touch someone else's request or loan.
    function test_nonBorrowerCannotTouchOthers() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[0]);
        _payNowAs(c, ms[1]);
        _request(c, ms[0], 100e6, 2, 0);
        vm.expectRevert(IKuberCircleErrors.NotBorrower.selector);
        vm.prank(ms[1]);
        c.cancelRequest(1);
        vm.expectRevert(IKuberCircleErrors.NotBorrower.selector);
        vm.prank(ms[1]);
        c.raiseExtra(1, 10);
        _settleAt(c, 4);
        vm.expectRevert(IKuberCircleErrors.NoActiveLoan.selector);
        vm.prank(ms[1]);
        c.repayAll();
        vm.expectRevert(IKuberCircleErrors.NothingDue.selector);
        vm.prank(ms[1]);
        c.payArrears(3);
        // ms[1]'s claim does not touch ms[0]'s proceeds.
        vm.expectRevert(IKuberCircleErrors.NothingToClaim.selector);
        vm.prank(ms[1]);
        c.claim();
        assertEq(c.getLoan(1).unclaimed, 100e6);
    }

    // ---- D-10c (c): one test per eligibility guard of the funding step (Queue._eligible, Queue._fundOne). Each
    // circle: 6 members, savings 300e6 each, epoch 3 OPEN; ms[1] requests in epoch 3, funding runs at settle(3).
    // Q08, Q11, Q44 guard states the public API cannot reach today (a member with a pending request cannot leave, be
    // kicked, back a loan, or be paused, and a seizure lowers pledgedOut by the whole pledge but savings by at most
    // it), so the harness forces them: the guards are defence in depth and these tests pin them.

    function _requested(uint256 amount) private returns (KuberCircle c, address[] memory ms, uint256 id) {
        (c, ms) = _s6();
        _openEpoch3(c, ms);
        id = _request(c, ms[1], amount, 3, 0);
    }

    function _assertSkipped(KuberCircle c, uint256 id) private {
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(id).status), uint256(LoanStatus.Pending), "skipped, keeps its place");
        assertEq(c.getQueue()[0], id);
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
    }

    /// Q08: a borrower who is no longer Active is skipped (paused, then left, each from a snapshot).
    function test_D10c_fundSkipsNonActiveBorrower() public {
        (KuberCircle c, address[] memory ms, uint256 id) = _requested(100e6);
        uint256 snap = vm.snapshotState();
        _h(c).forceMember(ms[1], MemberStatus.Suspended, 300e6, 0);
        _assertSkipped(c, id);
        vm.revertToState(snap);
        _h(c).forceMember(ms[1], MemberStatus.Left, 300e6, 0);
        _assertSkipped(c, id);
        vm.revertToState(snap);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(id).status), uint256(LoanStatus.Funded), "control: Active borrower funded");
    }

    /// Q11: ownPart 270e6 = 300e6 x 90% at the request; savings fall to 200e6 (180e6 at 90%) before funding.
    function test_D10c_fundRechecksLockedLtv() public {
        (KuberCircle c, address[] memory ms, uint256 id) = _requested(270e6);
        assertEq(c.getLoan(id).ownPart, 270e6);
        _h(c).forceMember(ms[1], MemberStatus.Active, 200e6, 0);
        _assertSkipped(c, id);
    }

    /// Q44: same request; 100e6 pledged out leaves 200e6 free (180e6 at 90%), though savings are still 300e6.
    function test_D10c_ownPartCountsPledgedOut() public {
        (KuberCircle c, address[] memory ms, uint256 id) = _requested(270e6);
        _h(c).forceMember(ms[1], MemberStatus.Active, 300e6, 100e6);
        _assertSkipped(c, id);
    }

    /// Q46: a vote raises ownRateBps 300 -> 1_000 in the request's epoch; the tally runs before funding, and the
    /// loan still charges the locked 3%: saverInterest 100e6 x 3% = 3e6 (10e6 at the live rate).
    function test_D10c_fundUsesLockedRate() public {
        (KuberCircle c, address[] memory ms, uint256 id) = _requested(100e6);
        uint256 pid = _ruleAs(c, ms[0], 1, 1_000);
        _votes(c, pid, ms, 0, 4, true);
        _settleAt(c, 4);
        assertEq(c.getCircleState().rules.ownRateBps, 1_000, "rule applied before funding");
        Loan memory l = c.getLoan(id);
        assertEq(uint256(l.status), uint256(LoanStatus.Funded));
        assertEq(l.ownRateBps, 300);
        assertEq(l.saverInterest, 3e6, "locked rate");
    }

    /// Q47: a vote lowers ownLtvBps 9_000 -> 5_000 in the request's epoch; the request locked at 90% (ownPart 270e6)
    /// is still eligible (150e6 at the live 50%).
    function test_D10c_eligibilityUsesLockedLtv() public {
        (KuberCircle c, address[] memory ms, uint256 id) = _requested(270e6);
        uint256 pid = _ruleAs(c, ms[0], 0, 5_000);
        _votes(c, pid, ms, 0, 4, true);
        _settleAt(c, 4);
        assertEq(c.getCircleState().rules.ownLtvBps, 5_000, "rule applied before funding");
        assertEq(uint256(c.getLoan(id).status), uint256(LoanStatus.Funded), "locked LTV");
        assertEq(c.getPublicSummary().outstandingPrincipal, 270e6);
    }
}
