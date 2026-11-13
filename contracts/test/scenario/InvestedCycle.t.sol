// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {InvestBase} from "../unit/Invest.t.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {CircleStatus, FixedParams, IKuberCircleErrors} from "../../src/lib/CircleTypes.sol";

/// @dev D-15: `test_S50_savingsOnlyCycle` with money in the vaults. Production contract, real registry, seeded
/// vaults, demo allocation 500/5_000/3_500/1_000, Aave 0.5% and LP 1% per 60 s epoch.
contract InvestedCycleTest is InvestBase {
    function _implementation() internal override returns (address) {
        return address(new KuberCircle());
    }

    /// @dev Member behaviour as in `test_S50_savingsOnlyCycle`: i % 5 == 1 pays in OPEN, i % 5 == 2 in LOCK,
    /// i % 10 == 3 misses epoch 2 and catches it up in epoch 3 (fine 1e6); everyone else is auto-debited.
    function test_S50_investedCycle() public {
        address[] memory ms = _newMembers(50);
        FixedParams memory f = _fixed();
        f.maxMembers = 50;
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("fifty", f, _rules(), _tail(ms)));
        _join(c, _tail(ms)); // all 49 join; all 50 approve 700e6
        assertEq(c.members().length, 50);
        vm.warp(f.startTime);
        c.activate();
        aave.setApy(500, uint64(block.timestamp));
        lp.setApy(1_000, uint64(block.timestamp));
        aave.setSpeedup(52_560);
        lp.setSpeedup(52_560);

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
                if (e <= 7) _assertOnTarget(c);
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
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 35_638_265_280);
        assertEq(p.sTotal, 35_000e6);
        assertEq(p.saverPot, 5e6);
        assertEq(p.yieldPot, 633_265_280);
        assertEq(p.wActive, 139_500e6);
        assertEq(p.wSaver, 139_500e6);

        // 700e6 + floor(633_265_280 × w / 139_500e6) + floor(5e6 × w / 139_500e6):
        // w = 2_800e6 -> 12_710_700 + 100_358; w = 2_700e6 (catch-up) -> 12_256_747 + 96_774.
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
            assertEq(got, late ? 712_353_521 : 712_811_058);
            assertGe(got, savings, "R-S P1");
            sum += got;
        }
        for (uint256 i; i < 50; ++i) {
            vm.prank(ms[i]);
            vm.expectRevert(IKuberCircleErrors.AlreadyWithdrawn.selector);
            c.withdraw();
            assertEq(registry.activeMemberships(ms[i]), 0);
        }
        assertEq(sum, 35_638_265_215);
        assertEq(usdc.balanceOf(address(c)), 65);
    }
}
