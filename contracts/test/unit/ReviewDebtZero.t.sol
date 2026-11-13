// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {CircleStatus, LoanStatus, Member, MemberStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev M5 review CR-01: a debt-0 default's savings drop is dated after everything already accrued, so it never
/// back-fills over epochs that late-dated savings (catch-ups at the clock epoch, or T + 1) were not counted in.
/// Reproductions from the review (.planning/reviews/m5-review-tests/ReviewDebtZero.t.sol), inverted: before the
/// fix each settle below reverted SafeCastOverflowedIntToUint on every retry.
contract ReviewDebtZeroTest is BackingTestBase {
    KuberCircle internal c;
    address[] internal p;
    address internal r;

    function _setup(uint8 total) internal {
        p = _newMembers(6);
        RuleParams memory rr = _rules();
        rr.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        rr.perLoanMaxBps = 10_000;
        rr.installFineBps = 0; // in bounds (0..2_000); every other rule is the default
        c = _startPeople(p, total, rr);
        r = p[5];
        vm.prank(r);
        usdc.approve(address(c), 0); // R misses rounds from the start
        _activate(c);
    }

    function _catchUp(uint256[] memory eps) internal {
        vm.startPrank(r);
        usdc.approve(address(c), 50_000e6);
        for (uint256 i; i < eps.length; ++i) {
            c.catchUp(eps[i]);
        }
        usdc.approve(address(c), 0);
        vm.stopPrank();
    }

    function _sumWeights(uint256 e) internal view returns (uint256 s) {
        for (uint256 i; i < p.length; ++i) {
            if (c.getMember(p[i]).status == MemberStatus.Active) s += _h(c).weightAt(p[i], e);
        }
    }

    /// settle(T): R catches up eight missed rounds at clock T + 1 (dated T + 1), then defaults with debt 0. The drop
    /// of 1_100e6 is dated T + 1, so R's weight through T stays 900e6 and the circle ends.
    function test_debtZeroDefaultAtFinalSettleDoesNotBackfill() public {
        _setup(12);
        for (uint256 e = 2; e <= 10; ++e) {
            _settleAt(c, e);
        }
        // Epoch 10: R qualifies (paidCount 3, savings 300e6 all dated 10) and borrows 1_000e6 over 1 epoch.
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (1, 2);
        _catchUp(two);
        vm.startPrank(r);
        usdc.approve(address(c), 100e6);
        c.payNow();
        usdc.approve(address(c), 0);
        c.requestLoan(1_000e6, 1, 0, 0);
        vm.stopPrank();
        assertEq(c.getLoan(1).ownPart, 270e6);
        _vouchAs(c, p[1], 1, 400e6);
        _vouchAs(c, p[2], 1, 330e6);
        _settleAt(c, 11); // settle(10) funds loan 1; installment due 12
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded));
        vm.prank(r);
        c.claim();
        _settleAt(c, 12); // settle(11): R misses round 11
        _warpTo(c, 13, false);
        uint256[] memory eight = new uint256[](8);
        for (uint256 i; i < 7; ++i) {
            eight[i] = 3 + i;
        }
        eight[7] = 11;
        _catchUp(eight);
        assertEq(c.getMember(r).savings, 1_100e6);
        assertEq(_h(c).weightAt(r, 12), 900e6, "R's dated weight through T");
        // O 1_000e6 + penalty 100e6 from free savings, fines 0: debt 0, R stays Active.
        c.settle(type(uint256).max);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "the circle ends");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted));
        Member memory m = c.getMember(r);
        assertEq(uint256(m.status), uint256(MemberStatus.Active), "debt 0: not paused");
        assertEq(m.savings, 0, "1_100e6 - 1_100e6");
        assertEq(c.debtOf(r), 0);
        // The drop counts from T + 1 (no epoch): R's weight through T is unchanged.
        assertEq(_h(c).weightAt(r, 12), 900e6, "no back-fill over epoch T");
        uint256 b0 = usdc.balanceOf(p[0]);
        vm.prank(p[0]);
        c.withdraw();
        assertGt(usdc.balanceOf(p[0]), b0, "members can withdraw");
    }

    /// The same at k < T in catch-up mode: settle(10) runs at clock 13 after R's catch-ups dated 13; the drop of
    /// 770e6 is dated 13 instead of being back-filled over epochs 10..12.
    function test_debtZeroDefaultInCatchUpSettleDoesNotBackfill() public {
        _setup(14);
        for (uint256 e = 2; e <= 6; ++e) {
            _settleAt(c, e);
        }
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (1, 2);
        _catchUp(two);
        vm.startPrank(r);
        usdc.approve(address(c), 100e6);
        c.payNow();
        usdc.approve(address(c), 0);
        c.requestLoan(700e6, 1, 0, 0);
        vm.stopPrank();
        _vouchAs(c, p[1], 1, 230e6);
        _vouchAs(c, p[2], 1, 200e6);
        _settleAt(c, 7); // settle(6) funds loan 1, due 8
        vm.prank(r);
        c.claim();
        _settleAt(c, 8);
        _settleAt(c, 9);
        _settleAt(c, 10);
        _warpTo(c, 13, false);
        uint256[] memory miss = new uint256[](6);
        (miss[0], miss[1], miss[2], miss[3], miss[4], miss[5]) = (3, 4, 5, 7, 8, 9);
        _catchUp(miss);
        assertEq(c.getMember(r).savings, 900e6);
        assertEq(_h(c).weightAt(r, 12), 2_100e6);
        // D = 700e6 + 70e6 = 770e6 <= free 900e6, fines 0: debt 0.
        c.settle(type(uint256).max);
        assertEq(c.getCircleState().settledEpoch, 10, "settle(10) completes");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted));
        assertEq(uint256(c.getMember(r).status), uint256(MemberStatus.Active), "debt 0: not paused");
        assertEq(c.getMember(r).savings, 130e6, "900e6 - 770e6");
        assertEq(_h(c).weightAt(r, 12), 2_100e6, "no back-fill over epochs 10..12");
        assertEq(_sumWeights(12), _h(c).wActiveAt(12), "member weights == W_active");
        // The rest of the cycle settles: 11 and 12 at clock 13, then 13 and 14.
        c.settle(type(uint256).max);
        c.settle(type(uint256).max);
        _settleAt(c, 14);
        _settleAt(c, 15);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended));
    }
}
