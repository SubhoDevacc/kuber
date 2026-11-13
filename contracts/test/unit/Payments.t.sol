// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleErrors, IKuberCircleEvents, Member} from "../../src/lib/CircleTypes.sol";

contract PaymentsTest is CircleTestBase {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant C = 100e6;

    function _pay(KuberCircle c, address m) internal {
        vm.prank(m);
        c.payNow();
    }

    /// @dev Warp to the start of epoch k + 1 and settle epoch k in one call.
    function _settleEpoch(KuberCircle c, uint256 k) internal {
        _warpTo(c, k + 1, false);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, k);
    }

    function test_T_PAY_1_payNowOpenLockAndWhilePending() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        (address m1, address m2, address m3) = (ms[1], ms[2], ms[3]);

        uint256 bal = usdc.balanceOf(m1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m1, 1, C);
        _pay(c, m1);
        assertEq(usdc.balanceOf(m1), bal - C);
        _warpTo(c, 1, true);
        _pay(c, m2);
        vm.prank(m1);
        vm.expectRevert(IKuberCircleErrors.AlreadyPaid.selector);
        c.payNow();

        // Settlements 1 and 2 are pending.
        _warpTo(c, 3, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(m3, 3, C);
        _pay(c, m3);

        uint256 bal1 = usdc.balanceOf(m1);
        uint256 bal2 = usdc.balanceOf(m2);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 1);
        assertEq(usdc.balanceOf(m1), bal1, "m1 pulled twice");
        assertEq(usdc.balanceOf(m2), bal2, "m2 pulled twice");
        for (uint256 i = 1; i <= 2; ++i) {
            Member memory m = c.getMember(ms[i]);
            assertEq(m.savings, 100e6);
            assertEq(m.paidCount, 1);
        }
        assertEq(c.getMember(m3).savings, 200e6);

        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 2);
        Member memory p3 = c.getMember(m3);
        assertEq(p3.savings, 300e6);
        assertEq(p3.paidCount, 3);
        assertEq(p3.paidBitmap, 14);
        // A-8: x = 1 counts epochs 1..2, x = 2 counts epoch 2, x = 3 counts none yet: 2c + c = 300e6.
        assertEq(p3.weight, 300e6);
        assertEq(_h(c).weightAt(m3, 2), 300e6);

        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.payNow();

        _warpTo(c, 8, false);
        vm.prank(ms[4]);
        vm.expectRevert(IKuberCircleErrors.CycleOver.selector);
        c.payNow();

        address[] memory fm = _newMembers(5);
        KuberCircle forming = _create(fm);
        vm.prank(fm[0]);
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        forming.payNow();
    }

    function test_T_PAY_2_autoDebitAndShortfallRecordsMiss() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        (address m1, address m2) = (ms[1], ms[2]);
        uint256 away = usdc.balanceOf(m1) - 50e6;
        vm.prank(m1);
        assertTrue(usdc.transfer(makeAddr("sink"), away));
        vm.prank(m2);
        usdc.approve(address(c), 50e6);
        uint256 bal2 = usdc.balanceOf(m2);

        _warpTo(c, 2, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionMissed(m1, 1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionMissed(m2, 1);
        c.settle(MAX);

        assertEq(c.getCircleState().settledEpoch, 1);
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            bool short = i == 1 || i == 2;
            assertEq(m.missedBitmap, short ? 2 : 0);
            assertEq(m.paidBitmap, short ? 0 : 2);
            assertEq(m.savings, short ? 0 : 100e6);
            assertEq(m.paidCount, short ? 0 : 1);
        }
        assertEq(usdc.balanceOf(m1), 50e6);
        assertEq(usdc.balanceOf(m2), bal2);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        // settle(1) moved 85% into the vaults: cash 60e6, Aave 200e6, LP 140e6.
        assertEq(p.cash + p.aaveValue + p.lpValue, 400e6);
        assertEq(p.sTotal, 400e6);
    }

    function test_T_PAY_3_catchUpFineToSaversPot() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        address f = ms[5];

        _settleEpoch(c, 1);
        vm.prank(f);
        usdc.approve(address(c), 0);
        _warpTo(c, 3, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionMissed(f, 2);
        c.settle(MAX);
        vm.prank(f);
        usdc.approve(address(c), 700e6);
        _settleEpoch(c, 3);

        // Epoch 4: fine = 100e6 × 100 × (4 − 2) / 10_000 = 2e6.
        uint256 bal = usdc.balanceOf(f);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.CaughtUp(f, 2, 2e6);
        vm.prank(f);
        c.catchUp(2);
        assertEq(usdc.balanceOf(f), bal - 102e6);

        Member memory m = c.getMember(f);
        assertEq(m.savings, 300e6);
        assertEq(m.weight, 400e6);
        assertEq(m.lastAccrual, 3);
        assertEq(m.paidCount, 3);
        assertEq(m.paidBitmap, 14);
        assertEq(m.missedBitmap, 4);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 2e6);
        assertEq(p.sTotal, 1_800e6);

        vm.startPrank(f);
        vm.expectRevert(IKuberCircleErrors.AlreadyPaid.selector);
        c.catchUp(2);
        vm.expectRevert(IKuberCircleErrors.NotMissed.selector);
        c.catchUp(5);
        vm.expectRevert(IKuberCircleErrors.NotMissed.selector);
        c.catchUp(0);
        vm.expectRevert(IKuberCircleErrors.NotMissed.selector);
        c.catchUp(61);
        vm.stopPrank();
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.catchUp(2);
    }

    function test_T_PAY_5_advanceAllowanceThenRevoke() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        address who = ms[3];
        for (uint256 k = 1; k <= 3; ++k) {
            _settleEpoch(c, k);
        }
        assertEq(usdc.allowance(who, address(c)), 400e6);
        vm.prank(who);
        usdc.approve(address(c), 0);
        for (uint256 k = 4; k <= 6; ++k) {
            _warpTo(c, k + 1, false);
            vm.expectEmit(address(c));
            emit IKuberCircleEvents.ContributionMissed(who, k);
            c.settle(MAX);
        }
        Member memory m = c.getMember(who);
        assertEq(m.paidBitmap, 14);
        assertEq(m.missedBitmap, 112);
        for (uint256 i; i < ms.length; ++i) {
            if (i != 3) assertEq(c.getMember(ms[i]).paidBitmap, 126);
        }
        assertEq(c.getPublicSummary().sTotal, 3_300e6);
    }

    function test_D23a_prePayBeforeSettleSameWeight() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        (address x, address y) = (ms[4], ms[1]);
        _warpTo(c, 2, false);
        _pay(c, x);
        c.settle(3);
        assertEq(c.getCircleState().cursor, 3);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 1);
        _pay(c, y);

        address[2] memory xy = [x, y];
        for (uint256 i; i < 2; ++i) {
            Member memory m = c.getMember(xy[i]);
            assertEq(m.savings, 200e6);
            assertEq(m.weight, 100e6);
            assertEq(m.lastAccrual, 1);
        }

        for (uint256 k = 2; k <= 6; ++k) {
            _settleEpoch(c, k);
        }
        uint256 sum;
        for (uint256 i; i < ms.length; ++i) {
            assertEq(c.getMember(ms[i]).weight, 2_100e6);
            sum += _h(c).weightAt(ms[i], 6);
        }
        assertEq(_h(c).wActiveAt(6), 12_600e6);
        assertEq(sum, _h(c).wActiveAt(6));
    }

    // Boundary of the auto-debit check: exactly one contribution of balance and allowance is pulled; one unit less is a miss.
    function test_T_PAY_2_exactBalanceAndAllowanceArePulled() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        (address exact, address short) = (ms[1], ms[2]);
        vm.startPrank(exact);
        assertTrue(usdc.transfer(address(0xdead), usdc.balanceOf(exact) - C));
        usdc.approve(address(c), C);
        vm.stopPrank();
        vm.startPrank(short);
        assertTrue(usdc.transfer(address(0xdead), usdc.balanceOf(short) - (C - 1)));
        vm.stopPrank();
        _settleEpoch(c, 1);
        assertEq(c.getMember(exact).paidBitmap, 2);
        assertEq(usdc.balanceOf(exact), 0);
        assertEq(c.getMember(short).missedBitmap, 2);
        assertEq(usdc.balanceOf(short), C - 1);
    }
}
