// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {CircleStatus, FixedParams, IKuberCircleErrors} from "../../src/lib/CircleTypes.sol";

/// @dev A full savings-only cycle with 50 members on the production contract (not the harness), the real
/// registry, and two `settle(25)` batches per epoch. Runs in Forge's EVM (the engine Anvil uses).
contract SavingsCycleTest is CircleTestBase {
    function _implementation() internal override returns (address) {
        return address(new KuberCircle());
    }

    /// @dev Member i pays in OPEN when i % 5 == 1 and in LOCK when i % 5 == 2; when i % 10 == 3 it misses epoch 2
    /// (allowance 0 after settle(1)) and catches it up in epoch 3 (fine 1e6); everyone else is auto-debited.
    function test_S50_savingsOnlyCycle() public {
        address[] memory ms = _newMembers(50);
        FixedParams memory f = _fixed();
        f.maxMembers = 50;
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("fifty", f, _rules(), _tail(ms)));
        _join(c, _tail(ms)); // all 49 join; all 50 approve 700e6
        assertEq(c.members().length, 50);
        vm.warp(f.startTime);
        c.activate();

        uint256 maxGas;
        for (uint256 e = 1; e <= 8; ++e) {
            _warpTo(c, e, false);
            if (e >= 2) {
                for (uint256 b; b < 2; ++b) {
                    uint256 g = gasleft();
                    c.settle(25);
                    g -= gasleft();
                    if (g > maxGas) maxGas = g;
                }
                assertEq(c.getCircleState().settledEpoch, e - 1);
            }
            for (uint256 i = 3; i < 50; i += 10) {
                vm.startPrank(ms[i]);
                if (e == 2) usdc.approve(address(c), 0);
                if (e == 3) {
                    usdc.approve(address(c), 700e6);
                    c.catchUp(2);
                }
                vm.stopPrank();
            }
            if (e > 7) continue;
            for (uint256 i = 1; i < 50; i += 5) {
                vm.prank(ms[i]);
                c.payNow();
            }
            _warpTo(c, e, true);
            for (uint256 i = 2; i < 50; i += 5) {
                vm.prank(ms[i]);
                c.payNow();
            }
        }
        emit log_named_uint("max settle(25) gas", maxGas);
        assertLt(maxGas, 8_000_000);

        assertEq(uint8(c.getCircleState().status), uint8(CircleStatus.Ended));
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 35_005e6);
        assertEq(p.sTotal, 35_000e6);
        assertEq(p.saverPot, 5e6);
        assertEq(p.yieldPot, 0);
        assertEq(p.wActive, 139_500e6);
        assertEq(p.wSaver, 139_500e6);

        // 700e6 + floor(5e6 × w / 139_500e6): w = 2_800e6 -> 100_358; w = 2_700e6 (catch-up at x = 3) -> 96_774.
        uint256 sum;
        for (uint256 i; i < 50; ++i) {
            bool late = i % 10 == 3;
            assertEq(c.getMember(ms[i]).weight, late ? 2_700e6 : 2_800e6);
            uint256 savings = c.getMember(ms[i]).savings;
            assertEq(savings, 700e6);
            uint256 before = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            uint256 got = usdc.balanceOf(ms[i]) - before;
            assertEq(got, late ? 700_096_774 : 700_100_358);
            assertGe(got, savings, "R-S P1");
            sum += got;
        }
        for (uint256 i; i < 50; ++i) {
            vm.prank(ms[i]);
            vm.expectRevert(IKuberCircleErrors.AlreadyWithdrawn.selector);
            c.withdraw();
            assertEq(registry.activeMemberships(ms[i]), 0);
            assertEq(registry.memberStats(ms[i]).circlesCompleted, 1);
        }
        assertEq(sum, 35_004_999_980);
        assertEq(usdc.balanceOf(address(c)), 20);
    }
}
