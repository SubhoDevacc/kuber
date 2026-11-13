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

/// @dev M5 review CR-02, DECISIONS R-N3 exception: a request expiring at settlement only releases a paused backer's
/// pledge; anyone's applyFreed(member) then applies that member's free savings to their backers' losses, then
/// penalty, at the clock epoch. T = 12, contribution 100e6, fines 0, penalty 1_000 bps.
contract ApplyFreedTest is BackingTestBase {
    KuberCircle internal c;
    address[] internal p;
    address internal s; // the paused member
    address internal anyone;

    /// p6 files an oversized request (never eligible, expires at settle(9): 9 + 1 + 3 > 12); S = p1 pledges `pledge`
    /// on it, borrows `amount` over 3 backed by p2, claims and stops paying, and is paused at settle(7).
    /// Returns at clock 10, right after settle(9).
    function _fixture(uint256 pledge, uint256 amount) internal {
        p = _newMembers(7);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 10_000;
        r.installFineBps = 0;
        c = _startPeople(p, 12, r);
        s = p[1];
        anyone = makeAddr("anyone");
        usdc.mint(anyone, 1_000e6);
        vm.prank(anyone);
        usdc.approve(address(c), 1_000e6);
        _activate(c);
        _settleAt(c, 2);
        _settleAt(c, 3);
        _payAllBut(c, p, address(0)); // everyone has 300e6
        vm.prank(p[6]);
        c.requestLoan(1_000_000e6, 3, 0, 0);
        _vouchAs(c, s, 1, pledge);
        vm.prank(s);
        c.requestLoan(amount, 3, 0, 0);
        _vouchAs(c, p[2], 2, c.getLoan(2).backedNeed);
        _settleAt(c, 4); // settle(3) funds loan 2, due 5, 6, 7
        vm.startPrank(s);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        for (uint256 e = 5; e <= 8; ++e) {
            _settleAt(c, e);
        }
        assertEq(uint256(c.getMember(s).status), uint256(MemberStatus.Suspended), "S paused at settle(7)");
        _settleAt(c, 9);
        _settleAt(c, 10); // settle(9) expires loan 1
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Expired));
    }

    function _sumWeights(uint256 e) internal view returns (uint256 sum) {
        for (uint256 i; i < p.length; ++i) {
            if (c.getMember(p[i]).status == MemberStatus.Active) sum += _h(c).weightAt(p[i], e);
        }
    }

    /// Pledge 50e6, loan 300e6: own 250e6 * 0.9 = 225e6, p2 vouches 75e6. At settle(7): O 300e6, fromB 250e6 (all
    /// free savings), fromV 50e6 (p2's loss), penalty 30e6 unpaid: debt 80e6. Expiry frees 50e6, which applyFreed
    /// pays to p2: debt 30e6 (penalty), S keeps 0 and stays paused.
    function test_applyFreed_paysBackersAfterExpiry_secondCallNoOp() public {
        _fixture(50e6, 300e6);
        assertEq(c.getLoan(2).ownPart, 225e6);
        Member memory m = c.getMember(s);
        assertEq(m.savings, 50e6, "300e6 - 250e6 taken at the default");
        assertEq(m.pledgedOut, 0, "released at expiry");
        assertEq(c.debtOf(s), 80e6, "expiry repaid nothing (R-N3 exception)");
        assertEq(c.getLoan(2).vouchers[0].loss, 50e6);
        uint256 p2Savings = c.getMember(p[2]).savings;
        uint256 pot = c.getPublicSummary().saverPot;
        uint256 bal = usdc.balanceOf(address(c));
        uint256 p0Savings = c.getMember(p[0]).savings;
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(s, 50e6, 30e6);
        vm.prank(anyone);
        c.applyFreed(s);
        assertEq(c.getMember(s).savings, 0, "S's free 50e6 applied");
        assertEq(uint256(c.getMember(s).status), uint256(MemberStatus.Suspended), "penalty still owed");
        assertEq(c.getMember(p[2]).savings - p2Savings, 50e6, "p2 repaid into savings");
        Loan memory l = c.getLoan(2);
        assertEq(l.vouchers[0].loss, 0);
        assertEq(l.penaltyOwed, 30e6);
        assertEq(c.debtOf(s), 30e6);
        assertEq(c.getPublicSummary().saverPot, pot, "no penalty paid: nothing was left");
        // Nobody else's money moves: no tokens, the caller pays nothing, other members unchanged.
        assertEq(usdc.balanceOf(address(c)), bal);
        assertEq(usdc.balanceOf(anyone), 1_000e6);
        assertEq(c.getMember(p[0]).savings, p0Savings);
        assertEq(_sumWeights(10), _h(c).wActiveAt(10), "member weights == W_active");
        // Second call: nothing free, so nothing changes and nothing is emitted.
        vm.recordLogs();
        vm.prank(anyone);
        c.applyFreed(s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no-op");
        assertEq(c.debtOf(s), 30e6);
        assertEq(c.getMember(p[2]).savings - p2Savings, 50e6);
        // Not on an Active member, nor on a non-member.
        vm.expectRevert(IKuberCircleErrors.NoDebt.selector);
        c.applyFreed(p[2]);
        vm.expectRevert(IKuberCircleErrors.NoDebt.selector);
        c.applyFreed(anyone);
    }

    /// Pledge 100e6, loan 220e6: own 200e6 * 0.9 = 180e6, p2 vouches 40e6. At settle(7): O 220e6, fromB 200e6,
    /// fromV 20e6, penalty 22e6 unpaid: debt 42e6. Expiry frees 100e6; applyFreed pays p2's 20e6 and the 22e6
    /// penalty to the savers' pot, S keeps 58e6 and is reinstated from the clock epoch 10.
    function test_applyFreed_paysLossesThenPenaltyAndReinstates() public {
        _fixture(100e6, 220e6);
        assertEq(c.getLoan(2).ownPart, 180e6);
        assertEq(c.getMember(s).savings, 100e6);
        assertEq(c.debtOf(s), 42e6);
        assertEq(c.getLoan(2).vouchers[0].loss, 20e6);
        uint256 p2Savings = c.getMember(p[2]).savings;
        uint256 pot = c.getPublicSummary().saverPot;
        vm.prank(anyone);
        c.applyFreed(s);
        Member memory m = c.getMember(s);
        assertEq(m.savings, 58e6, "100e6 - 20e6 - 22e6");
        assertEq(uint256(m.status), uint256(MemberStatus.Active), "reinstated at debt 0");
        assertEq(m.reinstatedEpoch, 10, "from the clock epoch");
        assertEq(c.debtOf(s), 0);
        assertFalse(registry.hasOpenDebt(s), "registry debt cleared");
        assertEq(c.getMember(p[2]).savings - p2Savings, 20e6, "p2 repaid");
        assertEq(c.getPublicSummary().saverPot - pot, 22e6, "penalty to the savers' pot");
        assertEq(_sumWeights(10), _h(c).wActiveAt(10), "member weights == W_active");
        // Second call: S is Active now, so it reverts and changes nothing.
        vm.expectRevert(IKuberCircleErrors.NoDebt.selector);
        c.applyFreed(s);
        assertEq(c.getMember(s).savings, 58e6);
        // The cycle ends and pays out within the balance.
        for (uint256 e = 11; e <= 13; ++e) {
            _settleAt(c, e);
        }
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended));
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        c.applyFreed(s);
        uint256 bal = usdc.balanceOf(address(c));
        uint256 paid;
        for (uint256 i; i < p.length; ++i) {
            uint256 b0 = usdc.balanceOf(p[i]);
            vm.prank(p[i]);
            c.withdraw();
            paid += usdc.balanceOf(p[i]) - b0;
        }
        assertLe(paid, bal);
    }
}
