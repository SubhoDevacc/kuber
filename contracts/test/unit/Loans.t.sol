// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleErrors, IKuberCircleEvents, Lane, Loan, LoanStatus, Window} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev Loan requests (04-01): who may request, the locked terms, the pending list, expiry, and the catch-up rule.
/// Every settled request here is backed (backedNeed > 0, never eligible in M4) or expires, so 04-02's funding
/// leaves these numbers unchanged.
contract LoansTest is LoanTestBase {
    uint256 private constant MAX = type(uint256).max;

    /// @dev S6: 6 members, totalEpochs 7, allocation 40/30/20/10, per-loan max 50%.
    function _s6() private returns (KuberCircle c, address[] memory ms) {
        return _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
    }

    function test_T_LN_1_requestBlockedEachReason() public {
        // The existing-loan reason (HasActiveLoan) is tested in Queue.t.sol (04-02), the cooldown (InCooldown) in
        // Repay.t.sol (04-03).
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        address m0 = ms[0];

        address outsider = _newMembers(1)[0];
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        vm.prank(outsider);
        c.requestLoan(10e6, 1, 0, 0);

        // paidCount 2 < minSaveEpochs 3.
        assertEq(c.getMember(m0).paidCount, 2);
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);

        _payNowAs(c, m0);
        assertEq(c.getMember(m0).paidCount, 3);
        vm.expectRevert(IKuberCircleErrors.InvalidRepayEpochs.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 0, 0, 0);
        // maxRepayEpochs 3.
        vm.expectRevert(IKuberCircleErrors.InvalidRepayEpochs.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 4, 0, 0);
        vm.expectRevert(IKuberCircleErrors.InvalidOfferedRate.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 3_001, 0);
        vm.expectRevert(IKuberCircleErrors.InvalidExtra.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 1_001);
        vm.expectRevert(IKuberCircleErrors.ZeroAmount.selector);
        vm.prank(m0);
        c.requestLoan(0, 1, 0, 0);

        _h(c).setLeavePending(m0, true);
        vm.expectRevert(IKuberCircleErrors.LeavePending.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);
        _h(c).setLeavePending(m0, false);

        _payNowAs(c, ms[4]);
        _debt(ms[4]);
        vm.expectRevert(IKuberCircleErrors.HasOpenDebt.selector);
        vm.prank(ms[4]);
        c.requestLoan(10e6, 1, 0, 0);

        // No revert above left anything behind.
        assertEq(_h(c).loanCount(), 0);
        assertEq(c.getQueue().length, 0);
        assertEq(c.getMember(m0).pendingRequestId, 0);

        assertEq(_request(c, m0, 10e6, 1, 0), 1);
        vm.expectRevert(IKuberCircleErrors.HasPendingRequest.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);
        assertEq(_h(c).loanCount(), 1);

        // Start of epoch 4, settle(3) not run yet.
        _warpTo(c, 4, false);
        vm.expectRevert(IKuberCircleErrors.SettlementPending.selector);
        vm.prank(ms[2]);
        c.requestLoan(10e6, 1, 0, 0);

        c.settle(MAX);
        _settleAt(c, 5);
        assertEq(c.getMember(ms[2]).paidCount, 4);
        // 5 + 1 + 2 = 8 > totalEpochs 7.
        vm.expectRevert(IKuberCircleErrors.RepayPastEnd.selector);
        vm.prank(ms[2]);
        c.requestLoan(10e6, 2, 0, 0);

        address[] memory others = _newMembers(5);
        KuberCircle forming = _create(others);
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        vm.prank(others[0]);
        forming.requestLoan(10e6, 1, 0, 0);
    }

    function test_T_LN_3_ownPartAndLockedTerms() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[1]);
        assertEq(c.getMember(ms[1]).savings, 300e6);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRequested(1, ms[1], 350e6, 2, 800, 0);
        vm.prank(ms[1]);
        assertEq(c.requestLoan(350e6, 2, 800, 0), 1);

        Loan memory loan = c.getLoan(1);
        assertEq(loan.borrower, ms[1]);
        assertEq(loan.amount, 350e6);
        // min(350e6, 300e6 × 9_000 / 10_000) = 270e6; the rest needs backers.
        assertEq(loan.ownPart, 270e6);
        assertEq(loan.backedNeed, 80e6);
        assertEq(loan.ownLtvBps, 9_000);
        assertEq(loan.ownRateBps, 300);
        assertEq(loan.penaltyBps, 1_000);
        assertEq(loan.installFineBps, 300);
        assertEq(loan.offeredRateBps, 800);
        assertEq(loan.extraBps, 0);
        assertEq(loan.repayEpochs, 2);
        assertEq(loan.requestedEpoch, 3);
        assertEq(loan.age, 0);
        assertEq(uint256(loan.status), uint256(LoanStatus.Pending));
        assertEq(uint256(loan.lane), uint256(Lane.None));
        assertEq(c.getMember(ms[1]).pendingRequestId, 1);
        uint32[] memory q = c.getQueue();
        assertEq(q.length, 1);
        assertEq(q[0], 1);

        _payNowAs(c, ms[0]);
        assertEq(_request(c, ms[0], 200e6, 1, 0), 2);
        loan = c.getLoan(2);
        assertEq(loan.ownPart, 200e6);
        assertEq(loan.backedNeed, 0);
        assertEq(c.getMember(ms[0]).pendingRequestId, 2);
        q = c.getQueue();
        assertEq(q.length, 2);
        assertEq(q[0], 1);
        assertEq(q[1], 2);
    }

    function test_T_EP_2_requestActionsRevertInLock() public {
        // The backing and proposal LOCK cases are M5 and M6 (DECISIONS P-6).
        (KuberCircle c, address[] memory ms) = _s6();
        address[] memory payers = new address[](2);
        payers[0] = ms[0];
        payers[1] = ms[1];
        _openEpoch3(c, payers);
        assertEq(_request(c, ms[0], 10e6, 1, 0), 1);

        _warpTo(c, 3, true);
        assertEq(uint256(c.currentWindow()), uint256(Window.Lock));
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        vm.prank(ms[1]);
        c.requestLoan(10e6, 1, 0, 0);
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        vm.prank(ms[0]);
        c.raiseExtra(1, 100);
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        vm.prank(ms[0]);
        c.cancelRequest(1);

        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(1).extraBps, 0);
        assertEq(c.getQueue().length, 1);
    }

    function test_raiseExtraAndCancelRequest() public {
        // No settlement here: 04-02 would fund these small own-part requests.
        (KuberCircle c, address[] memory ms) = _s6();
        address[] memory payers = new address[](3);
        payers[0] = ms[1];
        payers[1] = ms[2];
        payers[2] = ms[3];
        _openEpoch3(c, payers);
        assertEq(_request(c, ms[1], 10e6, 1, 0), 1);
        assertEq(_request(c, ms[2], 10e6, 1, 0), 2);
        assertEq(_request(c, ms[3], 10e6, 1, 0), 3);

        vm.expectRevert(IKuberCircleErrors.NotBorrower.selector);
        vm.prank(ms[1]);
        c.cancelRequest(2);

        vm.prank(ms[2]);
        c.cancelRequest(2);
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Cancelled));
        assertEq(c.getMember(ms[2]).pendingRequestId, 0);
        uint32[] memory q = c.getQueue();
        assertEq(q.length, 2);
        assertEq(q[0], 1);
        assertEq(q[1], 3);

        vm.expectRevert(IKuberCircleErrors.NotPending.selector);
        vm.prank(ms[2]);
        c.cancelRequest(2);

        // Ids are never reused.
        assertEq(_request(c, ms[2], 10e6, 1, 0), 4);
        assertEq(c.getMember(ms[2]).pendingRequestId, 4);
        q = c.getQueue();
        assertEq(q.length, 3);
        assertEq(q[0], 1);
        assertEq(q[1], 3);
        assertEq(q[2], 4);

        vm.prank(ms[1]);
        c.raiseExtra(1, 300);
        assertEq(c.getLoan(1).extraBps, 300);
        vm.expectRevert(IKuberCircleErrors.InvalidExtra.selector);
        vm.prank(ms[1]);
        c.raiseExtra(1, 300);
        vm.expectRevert(IKuberCircleErrors.InvalidExtra.selector);
        vm.prank(ms[1]);
        c.raiseExtra(1, 1_001);
        vm.expectRevert(IKuberCircleErrors.NotBorrower.selector);
        vm.prank(ms[2]);
        c.raiseExtra(1, 500);
        vm.expectRevert(IKuberCircleErrors.NotPending.selector);
        vm.prank(ms[2]);
        c.raiseExtra(2, 500);
        // MAX_EXTRA itself is allowed.
        vm.prank(ms[1]);
        c.raiseExtra(1, 1_000);
        assertEq(c.getLoan(1).extraBps, 1_000);

        // Removing the first and the last id keeps the rest in order.
        vm.prank(ms[1]);
        c.cancelRequest(1);
        q = c.getQueue();
        assertEq(q.length, 2);
        assertEq(q[0], 3);
        assertEq(q[1], 4);
        vm.prank(ms[2]);
        c.cancelRequest(4);
        q = c.getQueue();
        assertEq(q.length, 1);
        assertEq(q[0], 3);
        assertEq(c.getMember(ms[1]).pendingRequestId, 0);
        assertEq(c.getMember(ms[2]).pendingRequestId, 0);
    }

    function test_T_Q_5_requestExpiresAtSettlement() public {
        // Pledge release on expiry is tested in M5 (DECISIONS P-6).
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[1]);
        // 3 + 1 + 3 = 7 ≤ 7; backedNeed 80e6 with no pledges, so never funded.
        assertEq(_request(c, ms[1], 350e6, 3, 0), 1);

        // settle(3): 3 + 1 + 3 = 7 ≤ 7, still pending.
        _settleAt(c, 4);
        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Pending));
        assertEq(loan.age, 1);
        assertEq(c.getQueue().length, 1);

        // settle(4): 4 + 1 + 3 = 8 > 7, expires.
        _warpTo(c, 5, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.RequestExpired(1);
        c.settle(MAX);
        loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Expired));
        assertEq(loan.age, 1);
        assertEq(c.getMember(ms[1]).pendingRequestId, 0);
        assertEq(c.getQueue().length, 0);

        // 5 + 1 + 1 = 7.
        assertEq(_request(c, ms[1], 10e6, 1, 0), 2);
        assertEq(c.getMember(ms[1]).pendingRequestId, 2);
        uint32[] memory q = c.getQueue();
        assertEq(q.length, 1);
        assertEq(q[0], 2);
    }

    function test_D05_catchUpSkipsExpiryAndAgeing() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[1]);
        _payNowAs(c, ms[2]);
        // Both backed (backedNeed 80e6), so never funded. Id 1: 3 + 1 + 1 = 5. Id 2: 3 + 1 + 3 = 7.
        assertEq(_request(c, ms[1], 350e6, 1, 0), 1);
        assertEq(_request(c, ms[2], 350e6, 3, 0), 2);

        // Nobody settles until the start of epoch 6.
        _warpTo(c, 6, false);
        // settle(3): clock 6 > 4, skipped.
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 3);
        _assertPending(c, 1, 0);
        _assertPending(c, 2, 0);
        // settle(4): clock 6 > 5, skipped; id 2 would expire here (4 + 1 + 3 = 8 > 7) if funding ran.
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 4);
        _assertPending(c, 1, 0);
        _assertPending(c, 2, 0);
        assertEq(c.getQueue().length, 2);
        // settle(5): clock 6 = 6, runs. Id 1: 5 + 1 + 1 = 7 ≤ 7, ages. Id 2: 5 + 1 + 3 = 9 > 7, expires.
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 5);
        _assertPending(c, 1, 1);
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Expired));
        assertEq(c.getLoan(2).age, 0);
        assertEq(c.getMember(ms[2]).pendingRequestId, 0);
        uint32[] memory q = c.getQueue();
        assertEq(q.length, 1);
        assertEq(q[0], 1);

        // settle(6) at the start of epoch 7: runs; 6 + 1 + 1 = 8 > 7, expires.
        _settleAt(c, 7);
        assertEq(c.getCircleState().settledEpoch, 6);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Expired));
        assertEq(c.getLoan(1).age, 1);
        assertEq(c.getMember(ms[1]).pendingRequestId, 0);
        assertEq(c.getQueue().length, 0);
    }

    function _assertPending(KuberCircle c, uint256 id, uint256 age) private view {
        Loan memory loan = c.getLoan(id);
        assertEq(uint256(loan.status), uint256(LoanStatus.Pending));
        assertEq(loan.age, age);
    }
}
