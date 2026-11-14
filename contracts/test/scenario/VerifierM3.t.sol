// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {InvestBase} from "../unit/Invest.t.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, FixedParams, IKuberCircleEvents, RuleParams} from "../../src/lib/CircleTypes.sol";

/// @dev Verifier scenario. Numbers come from an independent integer model (scenario/model.py), checked by hand.
/// 5 members, c = 100e6, alloc 1_000/4_000/4_000/1_000. Aave APY 10% x52_560 (1% per epoch) from activation.
/// m4 misses epochs 2 and 3, catches up epoch 3 in epoch 5 (fine 2e6). LP -30% at epoch 4 start, +15% at epoch 6
/// start. In epoch 5 a harness credit of 1_100e6 to m1 is claimed: cash, then all of Aave, then part of LP.
contract VerifierM3Test is InvestBase {
    bytes32 internal constant WITHDRAW_SIG = keccak256("Withdraw(address,address,address,uint256,uint256)");

    function _start5() internal returns (KuberCircle c, address[] memory ms) {
        ms = _newMembers(5);
        RuleParams memory r = _rules();
        r.alloc = Alloc({loan: 1_000, aave: 4_000, lp: 4_000, cash: 1_000});
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("verifier", f, r, inv));
        _join(c, inv);
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
    }

    function _check(KuberCircle c, uint256 cash, uint256 aaveV, uint256 lpV, uint256 vaultAfter) internal view {
        _assertSplit(c, cash, aaveV, lpV);
        assertEq(_h(c).vaultValueAfterRebalance(), vaultAfter, "vaultValueAfterRebalance");
        _assertOnTarget(c); // |value - target| <= 1 for both vaults, cash >= floor, allowances 0
    }

    function test_verifier_unequalSavingsShocksBigClaim() public {
        (KuberCircle c, address[] memory ms) = _start5();
        aave.setApy(1_000, uint64(block.timestamp));
        aave.setSpeedup(52_560);

        _settleAt(c, 2); // settle(1): 5 pay
        _check(c, 100_000_000, 199_999_999, 200_000_000, 399_999_999);
        vm.prank(ms[4]);
        usdc.approve(address(c), 0);

        _settleAt(c, 3); // settle(2): m4 misses
        _check(c, 180_400_001, 360_799_999, 360_799_999, 721_599_998);

        _settleAt(c, 4); // settle(3): m4 misses
        _check(c, 261_121_601, 522_243_199, 522_243_199, 1_044_486_398);
        lp.shock(-3000);
        assertEq(_lpValue(c), 365_570_240, "lp after -30%");
        vm.prank(ms[4]);
        usdc.approve(address(c), 700e6);

        _settleAt(c, 5); // settle(4): 5 pay
        _check(c, 330_831_496, 661_662_988, 661_662_988, 1_323_325_976);

        // Claim larger than cash: cash 330_831_496, then all 661_662_988 of Aave, then 107_505_516 of LP.
        _claimAndCheckOrder(c, ms[1]);

        vm.startPrank(ms[4]);
        c.catchUp(3); // fine 100e6 x 1% x 2 epochs
        vm.stopPrank();
        assertEq(c.getPublicSummary().saverPot, 2e6);

        // R-K: vault value before settle(5) + pulled - previous after-value = 0 (the payout is not a loss).
        assertEq(_aaveValue(c) + _lpValue(c) + _h(c).vaultPulledSinceRebalance(), 1_323_325_976);
        _settleAt(c, 6); // settle(5): LP above target is pulled, Aave refilled
        _check(c, 232_831_496, 461_662_987, 461_662_988, 923_325_975);
        assertEq(_h(c).vaultPulledSinceRebalance(), 0);
        lp.shock(1500);
        assertEq(_lpValue(c), 530_912_436, "lp after +15%");

        _settleAt(c, 7); // settle(6)
        _check(c, 347_604_710, 691_209_419, 691_209_419, 1_382_418_838);

        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(-1_165_064_358, 13_200e6, 13_200e6, 2e6, 3_400e6);
        c.settle(MAX);
        _assertNoAllowance(c);
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 2_236_935_642, "balance after redeem");
        assertEq(p.yieldPot, -1_165_064_358, "yield pot");

        _withdrawAll(c, ms);
    }

    function _claimAndCheckOrder(KuberCircle c, address m1) internal {
        _h(c).creditClaimable(m1, 1_100e6);
        uint256 b1 = usdc.balanceOf(m1);
        vm.recordLogs();
        vm.prank(m1);
        c.claim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[2] memory from;
        uint256[2] memory assets;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != WITHDRAW_SIG) continue;
            require(n < 2, "more than two vault withdrawals");
            from[n] = logs[i].emitter;
            (assets[n],) = abi.decode(logs[i].data, (uint256, uint256));
            ++n;
        }
        assertEq(n, 2, "two vault withdrawals");
        assertEq(from[0], address(aave), "aave first");
        assertEq(assets[0], 661_662_988);
        assertEq(from[1], address(lp), "lp second");
        assertEq(assets[1], 107_505_516);
        assertEq(usdc.balanceOf(m1) - b1, 1_100e6, "claim paid");
        _assertSplit(c, 0, 0, 554_157_472);
        assertEq(aave.balanceOf(address(c)), 0, "aave shares");
        assertEq(_h(c).vaultPulledSinceRebalance(), 769_168_504, "pulled counter");
    }

    function _withdrawAll(KuberCircle c, address[] memory ms) internal {
        uint256[5] memory pay = [uint256(460_558_050), 460_558_050, 460_558_050, 460_558_050, 394_703_437];
        uint256[5] memory sav = [uint256(700e6), 700e6, 700e6, 700e6, 600e6];
        uint256[5] memory wt = [uint256(2_800e6), 2_800e6, 2_800e6, 2_800e6, 2_000e6];
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            assertEq(c.getMember(ms[i]).savings, sav[i], "savings");
            assertEq(c.getMember(ms[i]).weight, wt[i], "weight");
            uint256 b = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            uint256 got = usdc.balanceOf(ms[i]) - b;
            assertEq(got, pay[i], "payout");
            sum += got;
        }
        assertEq(sum, 2_236_935_637);
        assertEq(usdc.balanceOf(address(c)), 5, "dust");
        // R-A: loss follows savings (6:7), not weight (5:7).
        uint256 lossH = 700e6 + 424_242 - pay[0];
        uint256 lossP = 600e6 + 303_030 - pay[4];
        assertEq(lossH, 239_866_192);
        assertEq(lossP, 205_599_593);
        assertLe(stdMath.delta(lossP * 7, lossH * 6), 7);
    }
}
