// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdMath} from "forge-std/StdMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Alloc,
    BPS,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    RuleParams
} from "../../src/lib/CircleTypes.sol";

/// @dev c = 100e6, 6 members, all auto-debited, settlements at the exact start of each epoch. Allocation 4_000 loan,
/// 3_000 Aave, 2_000 LP, 1_000 cash unless stated. Values are read from the token, the vaults, and the harness.
abstract contract InvestBase is CircleTestBase {
    uint256 internal constant MAX = type(uint256).max;

    function _alloc() internal pure returns (Alloc memory) {
        return Alloc({loan: 4_000, aave: 3_000, lp: 2_000, cash: 1_000});
    }

    /// @dev `_start(6)` with the allocation replaced.
    function _startWith(Alloc memory a) internal returns (KuberCircle c, address[] memory ms) {
        ms = _newMembers(6);
        RuleParams memory r = _rules();
        r.alloc = a;
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("circle", f, r, inv));
        _join(c, inv);
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
    }

    /// @dev V, both targets, and the floor from public state with the D-05 formulas, independent of Invest.
    function _expected(KuberCircle c) internal view returns (uint256 aaveT, uint256 lpT, uint256 floor) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        Alloc memory a = c.getCircleState().rules.alloc;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 v = assets > liabilities ? assets - liabilities : 0;
        aaveT = v * a.aave / BPS;
        lpT = v * a.lp / BPS;
        uint256 bucket = v * a.loan / BPS;
        uint256 idle = bucket > p.outstandingPrincipal ? bucket - p.outstandingPrincipal : 0;
        floor = idle + v * a.cash / BPS + liabilities;
    }

    function _aaveValue(KuberCircle c) internal view returns (uint256) {
        return aave.previewRedeem(aave.balanceOf(address(c)));
    }

    function _lpValue(KuberCircle c) internal view returns (uint256) {
        return lp.previewRedeem(lp.balanceOf(address(c)));
    }

    /// @dev Exact cash and vault values from the token and the vaults; the summary view agrees.
    function _assertSplit(KuberCircle c, uint256 cash, uint256 aaveV, uint256 lpV) internal view {
        assertEq(usdc.balanceOf(address(c)), cash, "cash");
        assertEq(_aaveValue(c), aaveV, "aave value");
        assertEq(_lpValue(c), lpV, "lp value");
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, cash, "summary cash");
        assertEq(p.aaveValue, aaveV, "summary aave");
        assertEq(p.lpValue, lpV, "summary lp");
    }

    function _assertNoAllowance(KuberCircle c) internal view {
        assertEq(usdc.allowance(address(c), address(aave)), 0, "aave allowance");
        assertEq(usdc.allowance(address(c), address(lp)), 0, "lp allowance");
    }

    /// @dev T-INV-1 general checks: both vaults within 1 unit of target, cash at least the floor, no allowance.
    function _assertOnTarget(KuberCircle c) internal view {
        (uint256 aaveT, uint256 lpT, uint256 floor) = _expected(c);
        assertApproxEqAbs(_aaveValue(c), aaveT, 1, "aave target");
        assertApproxEqAbs(_lpValue(c), lpT, 1, "lp target");
        assertGe(usdc.balanceOf(address(c)), floor, "cash floor");
        _assertNoAllowance(c);
    }

    function _settleAt(KuberCircle c, uint256 epoch) internal {
        _warpTo(c, epoch, false);
        c.settle(MAX);
        _assertNoAllowance(c);
    }
}

contract InvestTest is InvestBase {
    /// @dev N1 (APY 0), N2 (Aave 5%, LP 10%, one year per epoch), N3 (LP −10% before settle(3)).
    function test_T_INV_1_targetsAfterSettleYieldAndShock() public {
        (KuberCircle c,) = _startWith(_alloc());
        _warpTo(c, 2, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Rebalanced(180e6, 120e6, 300e6);
        c.settle(MAX);
        // V 600e6: targets 180e6 / 120e6, floor 240e6 + 60e6.
        _assertSplit(c, 300e6, 180e6, 120e6);
        assertEq(_h(c).vaultValueAfterRebalance(), 300e6);
        _assertOnTarget(c);

        // After settle(1), not before: the seed would otherwise earn yield during epoch 1.
        aave.setApy(500, uint64(block.timestamp));
        lp.setApy(1_000, uint64(block.timestamp));
        aave.setSpeedup(525_600);
        lp.setSpeedup(525_600);
        _settleAt(c, 3);
        // V 1_220_999_998: deposits 177_300_000 and 112_200_000.
        _assertSplit(c, 610_500_000, 366_299_999, 244_199_999);
        assertEq(_h(c).vaultValueAfterRebalance(), 610_499_998);
        _assertOnTarget(c);

        _warpTo(c, 4, false);
        lp.shock(-1000);
        assertEq(_lpValue(c), 241_757_999);
        c.settle(MAX);
        // V 1_836_872_998: deposits 166_446_900 and 125_616_600.
        _assertSplit(c, 918_436_500, 551_061_899, 367_374_599);
        assertEq(_h(c).vaultValueAfterRebalance(), 918_436_498);
        _assertOnTarget(c);
    }

    /// @dev N4: no inflow, LP −10%. Aave is 3_600_000 over target and is withdrawn; the LP deficit equals the
    /// spare cash, so cash lands exactly on the floor.
    function test_T_INV_1_shockWithoutInflowWithdrawsAndDeposits() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        _settleAt(c, 2);
        for (uint256 i; i < 6; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 0);
        }
        _warpTo(c, 3, false);
        lp.shock(-1000);
        assertEq(_lpValue(c), 108e6);
        c.settle(MAX);
        _assertSplit(c, 294_000_000, 176_400_000, 117_600_000);
        (,, uint256 floor) = _expected(c);
        assertEq(floor, 294_000_000);
        _assertOnTarget(c);
    }

    /// @dev N6: right after N1 (cash 300e6, Aave 180e6, LP 120e6), each amount from the same state.
    function test_T_INV_2_payoutDrawsCashThenAaveThenLp() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        _settleAt(c, 2);
        _claimCase(c, ms[1], 250e6, 50e6, 180e6, 120e6);
        _claimCase(c, ms[1], 400e6, 0, 80e6, 120e6);
        _claimCase(c, ms[1], 550e6, 0, 0, 50e6);

        _h(c).creditClaimable(ms[1], 600e6 + 1);
        vm.expectRevert(IKuberCircleErrors.InsufficientLiquidity.selector);
        vm.prank(ms[1]);
        c.claim();
    }

    /// @dev Share price is exactly 1 here (APY 0, seed deposited 1:1), so shares equal values.
    function _claimCase(KuberCircle c, address m, uint256 x, uint256 cash, uint256 aaveV, uint256 lpV) internal {
        uint256 snap = vm.snapshotState();
        _h(c).creditClaimable(m, x);
        uint256 before = usdc.balanceOf(m);
        vm.prank(m);
        c.claim();
        assertEq(usdc.balanceOf(m) - before, x, "paid");
        _assertSplit(c, cash, aaveV, lpV);
        assertEq(aave.balanceOf(address(c)), aaveV, "aave shares");
        assertEq(lp.balanceOf(address(c)), lpV, "lp shares");
        vm.revertToState(snap);
    }

    /// @dev D-13 through `createCircle`, a fresh verified creator per case (the 5-circle cap).
    function test_T_INV_2_allocationOutOfBoundsReverts() public {
        _expectAllocRevert(Alloc(4_001, 3_999, 1_000, 1_000));
        _expectAllocRevert(Alloc(0, 3_999, 5_001, 1_000));
        _expectAllocRevert(Alloc(500, 5_001, 4_000, 499));
        _expectAllocRevert(Alloc(4_000, 3_000, 2_000, 999));
        _expectAllocRevert(Alloc(4_000, 3_000, 2_000, 1_001));
        _expectAllocRevert(Alloc(4_000, 1_000, 5_000, 0));
        _assertAllocAccepted(Alloc(4_000, 0, 5_000, 1_000));
        _assertAllocAccepted(Alloc(0, 9_500, 0, 500));
    }

    function _expectAllocRevert(Alloc memory a) internal {
        address[] memory ms = _newMembers(5);
        RuleParams memory r = _rules();
        r.alloc = a;
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(ms);
        uint256 before = factory.circleCount();
        vm.expectRevert(IKuberCircleErrors.InvalidAllocation.selector);
        vm.prank(ms[0]);
        factory.createCircle("circle", f, r, inv);
        assertEq(factory.circleCount(), before);
    }

    function _assertAllocAccepted(Alloc memory a) internal {
        address[] memory ms = _newMembers(5);
        RuleParams memory r = _rules();
        r.alloc = a;
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("circle", f, r, inv));
        assertEq(abi.encode(c.getCircleState().rules.alloc), abi.encode(a));
    }

    /// @dev N5: LP −10% right after N1, then a rebalance at the same timestamp.
    function test_D07_vaultValueBeforeAndAfterRebalance() public {
        (KuberCircle c,) = _startWith(_alloc());
        _settleAt(c, 2);
        assertEq(_h(c).vaultValueAfterRebalance(), 300_000_000);
        lp.shock(-1000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Rebalanced(176_400_000, 117_600_000, 294_000_000);
        (uint256 before, uint256 pulled) = _h(c).rebalanceNow();
        assertEq(before, 288_000_000);
        assertEq(pulled, 0);
        assertEq(_h(c).vaultValueAfterRebalance(), 294_000_000);
        _assertNoAllowance(c);
    }

    /// @dev N8 (A-1): a 400e6 claim pays 300e6 of cash and pulls 100e6 from Aave; the next period result is 0.
    function test_A1_payoutIsNotNegativeYield() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        _settleAt(c, 2);
        uint256 base = _h(c).vaultValueAfterRebalance();
        assertEq(base, 300e6);
        _h(c).creditClaimable(ms[1], 400e6);
        vm.prank(ms[1]);
        c.claim();
        assertEq(_h(c).vaultPulledSinceRebalance(), 100e6);
        (uint256 before, uint256 pulled) = _h(c).rebalanceNow();
        assertEq(before, 200e6);
        assertEq(pulled, 100e6);
        assertEq(int256(before + pulled) - int256(base), 0);
        assertEq(_h(c).vaultPulledSinceRebalance(), 0);
    }

    /// @dev N7: V = 0 on a fresh circle, then liabilities above all assets (V floors to 0, floor 700e6).
    function test_rebalance_zeroValueAndEmptyVaults() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Rebalanced(0, 0, 0);
        (uint256 before, uint256 pulled) = _h(c).rebalanceNow();
        assertEq(before, 0);
        assertEq(pulled, 0);
        assertEq(aave.totalSupply(), 1e6);
        assertEq(lp.totalSupply(), 1e6);
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        _assertNoAllowance(c);

        _settleAt(c, 2);
        _h(c).creditClaimable(ms[1], 700e6);
        (uint256 aaveT, uint256 lpT, uint256 floor) = _expected(c);
        assertEq(aaveT, 0);
        assertEq(lpT, 0);
        assertEq(floor, 700e6);
        (before, pulled) = _h(c).rebalanceNow();
        assertEq(before, 300e6);
        assertEq(pulled, 0);
        assertEq(usdc.balanceOf(address(c)), 600e6);
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        assertEq(_h(c).vaultValueAfterRebalance(), 0);
        _assertNoAllowance(c);
    }

    /// @dev N9 seeded: deposit 1 unit and donate 1_000e6 to the seeded LP vault before settle(1), then a full cycle
    /// with everyone paying. The circle loses 2_164 units in total; the attacker loses almost everything.
    function test_inflationDonationOnSeededVaultLoses() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        address att = makeAddr("attacker");
        usdc.mint(att, 2_000e6);
        vm.startPrank(att);
        usdc.approve(address(lp), 1);
        lp.deposit(1, att);
        assertTrue(usdc.transfer(address(lp), 1_000e6));
        vm.stopPrank();

        for (uint256 e = 2; e <= 8; ++e) {
            _settleAt(c, e);
        }
        assertEq(c.getPublicSummary().yieldPot, -2_164);
        uint256 b0 = usdc.balanceOf(att);
        vm.prank(att);
        lp.redeem(1, att, att);
        assertEq(usdc.balanceOf(att) - b0, 1_001);
        // Spent 1 + 1_000e6 = 1_000_000_001, got back 1_001.
        assertEq(2_000e6 - usdc.balanceOf(att), 999_999_000);

        uint256 bal = usdc.balanceOf(address(c));
        uint256 paid;
        for (uint256 i; i < 6; ++i) {
            uint256 before = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            paid += usdc.balanceOf(ms[i]) - before;
        }
        assertLe(paid, bal);
        assertEq(usdc.balanceOf(address(c)), bal - paid);
    }

    // Per DECISIONS P-6 the "W_saver = 0" clause of T-END-2 is tested in M4.
    /// @dev Allocation 0/4_500/5_000/500, APY 0. P (ms[4]) misses epoch 1; ms[3] misses epoch 2 and catches up in
    /// epoch 3 (fine 1e6); H (ms[5]) stops paying after epoch 3. LP −20% at the start of epoch 8: yieldPot −320e6.
    function test_T_END_2_negativeYieldSharedBySavings() public {
        (KuberCircle c, address[] memory ms) = _startWith(Alloc({loan: 0, aave: 4_500, lp: 5_000, cash: 500}));
        vm.prank(ms[4]);
        usdc.approve(address(c), 0);
        _settleAt(c, 2);
        vm.prank(ms[4]);
        usdc.approve(address(c), 700e6);
        vm.prank(ms[3]);
        usdc.approve(address(c), 0);
        _settleAt(c, 3);
        vm.startPrank(ms[3]);
        usdc.approve(address(c), 700e6);
        c.catchUp(2);
        vm.stopPrank();
        _settleAt(c, 4);
        vm.prank(ms[5]);
        usdc.approve(address(c), 0);
        for (uint256 e = 5; e <= 7; ++e) {
            _settleAt(c, e);
        }
        // V 3_200e6 (the savers' pot is a liability): targets 1_440e6 / 1_600e6, floor 160e6 + 1e6.
        _assertSplit(c, 161e6, 1_440e6, 1_600e6);

        _warpTo(c, 8, false);
        lp.shock(-2000);
        assertEq(_lpValue(c), 1_280e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(-320e6, 15_000e6, 15_000e6, 1e6, 3_700e6);
        c.settle(MAX);
        // 161e6 + 500e6 collected + 1_440e6 + 1_280e6 redeemed.
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.yieldPot, -320e6);
        assertEq(p.cash, 3_381e6);
        assertEq(p.aaveValue, 0);
        assertEq(p.lpValue, 0);
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);

        uint256[6] memory savings = [uint256(700e6), 700e6, 700e6, 700e6, 600e6, 300e6];
        uint256[6] memory weights = [uint256(2_800e6), 2_800e6, 2_800e6, 2_700e6, 2_100e6, 1_800e6];
        uint256[6] memory payouts =
            [uint256(639_646_125), 639_646_125, 639_646_125, 639_639_459, 548_248_108, 274_174_054];
        uint256[6] memory got;
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            assertEq(c.getMember(ms[i]).savings, savings[i], "savings");
            assertEq(c.getMember(ms[i]).weight, weights[i], "weight");
            uint256 before = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            got[i] = usdc.balanceOf(ms[i]) - before;
            uint256 saverShare = Math.mulDiv(1e6, weights[i], 15_000e6);
            assertEq(got[i], payouts[i], "payout");
            assertEq(
                got[i], savings[i] - Math.mulDiv(320e6, savings[i], 3_700e6, Math.Rounding.Ceil) + saverShare, "formula"
            );
            assertLe(got[i], savings[i] + saverShare);
            assertGt(got[i], 0);
            sum += got[i];
        }
        assertEq(sum, 3_380_999_996);
        assertLe(sum, p.cash);
        assertEq(usdc.balanceOf(address(c)), 4);
        // R-A: P has twice H's savings and bears exactly twice H's loss, though P's weight is not twice H's.
        assertEq(600e6 + 140_000 - got[4], 2 * (300e6 + 120_000 - got[5]));
        uint256 wP = c.getMember(ms[4]).weight;
        uint256 wH = c.getMember(ms[5]).weight;
        assertTrue(wP != 2 * wH);
    }

    /// @dev D-16 on seeded vaults. The tolerance is one unit plus one share's value per vault: the dead-share seed is
    /// another holder, so each vault operation can lose up to one share's value to it, which shifts both targets.
    function test_D16_fuzzRebalanceAndShareOut(
        uint256 loanBps,
        uint256 lpBps,
        uint256 cashBps,
        uint256 aaveApy,
        uint256 lpApy,
        uint256 speedup,
        int256 shockBps,
        uint256 shockEpoch
    ) public {
        uint256 loan = bound(loanBps, 0, 4_000);
        uint256 lpA = bound(lpBps, 0, 5_000);
        uint256 cash = bound(cashBps, 500, BPS - loan - lpA);
        (KuberCircle c, address[] memory ms) =
            _startWith(Alloc(uint16(loan), uint16(BPS - loan - lpA - cash), uint16(lpA), uint16(cash)));
        aave.setApy(uint16(bound(aaveApy, 0, 10_000)), uint64(block.timestamp));
        lp.setApy(uint16(bound(lpApy, 0, 10_000)), uint64(block.timestamp));
        speedup = bound(speedup, 1, 1_000_000);
        aave.setSpeedup(uint32(speedup));
        lp.setSpeedup(uint32(speedup));
        int256 shock = bound(shockBps, -9_998, 4_999);
        shockEpoch = bound(shockEpoch, 2, 8);
        for (uint256 e = 2; e <= 8; ++e) {
            _warpTo(c, e, false);
            if (e == shockEpoch) lp.shock(int16(shock));
            c.settle(MAX);
            if (e <= 7) _assertWithinTolerance(c);
        }
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        uint256 bal = usdc.balanceOf(address(c));
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 before = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            sum += usdc.balanceOf(ms[i]) - before;
        }
        assertLe(sum, bal);
        // At most two floor roundings per member.
        assertLe(bal - sum, 12);
    }

    /// @dev D-16 invariants after a non-final settlement: on target within `tol` or cash-constrained, floor held or
    /// both vaults empty, no allowance left.
    function _assertWithinTolerance(KuberCircle c) internal view {
        (uint256 aaveT, uint256 lpT, uint256 floor) = _expected(c);
        uint256 cash = usdc.balanceOf(address(c));
        uint256 aaveV = _aaveValue(c);
        uint256 lpV = _lpValue(c);
        uint256 tol = Math.ceilDiv(aave.totalAssets() + 1, aave.totalSupply() + 1)
            + Math.ceilDiv(lp.totalAssets() + 1, lp.totalSupply() + 1) + 1;
        bool constrained = cash <= floor + 1;
        assertTrue(stdMath.delta(aaveV, aaveT) <= tol || (aaveV < aaveT && constrained), "aave off target");
        assertTrue(stdMath.delta(lpV, lpT) <= tol || (lpV < lpT && constrained), "lp off target");
        assertTrue(cash >= floor || (aaveV == 0 && lpV == 0), "floor");
        _assertNoAllowance(c);
    }
}

/// @dev Vaults without the dead-share seed: the zero-share guard alone keeps the circle's cash.
contract InvestUnseededTest is InvestBase {
    function _seedVaults() internal override {}

    /// @dev N9 unseeded: after the attacker's 1-unit deposit and 1_000e6 donation, 120e6 would mint 0 LP shares.
    function test_inflationDonationCannotZeroDeposits() public {
        (KuberCircle c,) = _startWith(_alloc());
        address att = makeAddr("attacker");
        usdc.mint(att, 2_000e6);
        vm.startPrank(att);
        usdc.approve(address(lp), 1);
        lp.deposit(1, att);
        assertTrue(usdc.transfer(address(lp), 1_000e6));
        vm.stopPrank();

        _warpTo(c, 2, false);
        assertEq(lp.previewDeposit(120e6), 0);
        c.settle(MAX);
        assertEq(lp.balanceOf(address(c)), 0);
        assertEq(usdc.balanceOf(address(c)), 420e6);
        assertEq(_aaveValue(c), 180e6);
        assertEq(lp.totalAssets(), 1_000_000_001);
        _assertNoAllowance(c);
    }
}
