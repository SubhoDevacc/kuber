// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {stdMath} from "forge-std/StdMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InvestBase} from "./Invest.t.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, BPS, FixedParams, RuleParams} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @notice 07 D-10b: the Phase 3 audit's test gaps (adapted from the auditor's Gaps.t.sol and RoundingBound.t.sol).
/// Allocation 4_000/3_000/2_000/1_000, APY 0, 6 members.
contract InvestGapsTest is InvestBase {
    /// (a) Mutant V5: a claim outstanding at a settlement; targets use V without the claim, the floor keeps it liquid.
    function test_D10b_a_outstandingClaimInV() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        _settleAt(c, 2); // cash 300e6, Aave 180e6, LP 120e6
        _h(c).creditClaimable(ms[1], 100e6);
        _settleAt(c, 3); // assets 1_200e6, V 1_100e6: Aave 330e6, LP 220e6, floor 440e6 + 110e6 + 100e6
        _assertSplit(c, 650e6, 330e6, 220e6);
        _assertOnTarget(c);
        uint256 b = usdc.balanceOf(ms[1]);
        vm.prank(ms[1]);
        c.claim();
        assertEq(usdc.balanceOf(ms[1]) - b, 100e6);
        _assertSplit(c, 550e6, 330e6, 220e6);
    }

    /// (b) Mutant E6. Two payouts that each pull from a vault before the next rebalance: the counter adds both.
    function test_D10b_b_pulledCounterAccumulates() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        _settleAt(c, 2);
        _h(c).creditClaimable(ms[1], 350e6);
        vm.prank(ms[1]);
        c.claim(); // cash 300e6 + 50e6 from Aave
        assertEq(_h(c).vaultPulledSinceRebalance(), 50e6);
        _h(c).creditClaimable(ms[2], 100e6);
        vm.prank(ms[2]);
        c.claim(); // 100e6 from Aave
        assertEq(_h(c).vaultPulledSinceRebalance(), 150e6);
        (uint256 before, uint256 pulled) = _h(c).rebalanceNow();
        assertEq(before, 150e6);
        assertEq(pulled, 150e6);
        assertEq(before + pulled, 300e6); // previous vaultValueAfterRebalance: no loss recorded
    }

    /// (c) Mutant D3: the LP price is raised by a donation so the circle's 120e6 LP deposit at settle(1) mints exactly one
    /// share (120e6 × (1e6 + 1) / 1e14 = 1.2); the deposit is made, not skipped as a donation.
    function test_D10b_c_oneShareDepositNotSkipped() public {
        (KuberCircle c,) = _startWith(_alloc());
        usdc.mint(address(lp), 100e12 - 1e6 - 1);
        assertEq(lp.previewDeposit(120e6), 1, "boundary: exactly one share");
        _settleAt(c, 2);
        assertEq(lp.balanceOf(address(c)), 1, "one share minted");
        assertEq(usdc.balanceOf(address(c)), 300e6, "600e6 - Aave 180e6 - LP 120e6");
        assertEq(_aaveValue(c), 180e6);
    }

    /// The M3 dead-share defence (seeded vaults): an attacker who matches the seed and donates 1e9 before the
    /// circle's first deposit loses money, and the circle still pays every member out of its own balance.
    function test_D10b_deadSharesBlockDonationInflation() public {
        (KuberCircle c, address[] memory ms) = _startWith(_alloc());
        address att = makeAddr("att");
        usdc.mint(att, 2_000e6);
        vm.startPrank(att);
        usdc.approve(address(lp), 1e6);
        lp.deposit(1e6, att);
        assertTrue(usdc.transfer(address(lp), 1_000e6));
        vm.stopPrank();
        for (uint256 e = 2; e <= 8; ++e) {
            _settleAt(c, e);
        }
        int256 pot = c.getPublicSummary().yieldPot;
        vm.startPrank(att);
        lp.redeem(lp.balanceOf(att), att, att);
        vm.stopPrank();
        emit log_named_int("circle yieldPot (rounding loss)", pot);
        emit log_named_int("attacker P&L", int256(usdc.balanceOf(att)) - int256(2_000e6));
        assertLt(int256(usdc.balanceOf(att)), int256(2_000e6));
        uint256 bal = usdc.balanceOf(address(c));
        uint256 paid;
        for (uint256 i; i < 6; ++i) {
            uint256 b = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            paid += usdc.balanceOf(ms[i]) - b;
        }
        assertLe(paid, bal);
    }
}

contract RoundingBoundTest is InvestBase {
    KuberCircle internal c;
    KuberCircle internal c2;
    address[] internal ms;
    bool internal hasSecond;
    int256 internal shockS;
    uint256 internal shockE;

    function _make(Alloc memory a) internal returns (KuberCircle cc, address[] memory mm) {
        mm = _newMembers(6);
        RuleParams memory r = _rules();
        r.alloc = a;
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(mm);
        vm.prank(mm[0]);
        cc = KuberCircle(factory.createCircle("c", f, r, inv));
        _join(cc, inv);
    }

    function _assets(KuberCircle c) internal view returns (uint256) {
        return usdc.balanceOf(address(c)) + _aaveValue(c) + _lpValue(c);
    }

    function _price(address v) internal view returns (uint256) {
        if (v == address(aave)) return Math.ceilDiv(aave.totalAssets() + 1, aave.totalSupply() + 1);
        return Math.ceilDiv(lp.totalAssets() + 1, lp.totalSupply() + 1);
    }

    function testFuzz_lossPerSettlementWithinBound(
        uint256 loanBps,
        uint256 lpBps,
        uint256 cashBps,
        uint256 aaveApy,
        uint256 lpApy,
        uint256 speedup,
        int256 shockBps,
        uint256 shockEpoch,
        uint256 donA,
        uint256 donL,
        bool second
    ) public {
        uint256 loan = bound(loanBps, 0, 4_000);
        uint256 lpA = bound(lpBps, 0, 5_000);
        uint256 cash = bound(cashBps, 500, BPS - loan - lpA);
        (c, ms) = _make(Alloc(uint16(loan), uint16(BPS - loan - lpA - cash), uint16(lpA), uint16(cash)));
        hasSecond = second;
        if (second) (c2,) = _make(Alloc(500, 5_000, 3_500, 1_000));
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
        if (second) c2.activate();
        aave.setApy(uint16(bound(aaveApy, 0, 10_000)), uint64(block.timestamp));
        lp.setApy(uint16(bound(lpApy, 0, 10_000)), uint64(block.timestamp));
        speedup = bound(speedup, 1, 1_000_000);
        aave.setSpeedup(uint32(speedup));
        lp.setSpeedup(uint32(speedup));
        // Third-party donations (no shares) before any circle deposit: share prices up to ~1e6.
        address att = makeAddr("donor");
        donA = bound(donA, 0, 1e12);
        donL = bound(donL, 0, 1e12);
        usdc.mint(att, donA + donL);
        vm.startPrank(att);
        assertTrue(usdc.transfer(address(aave), donA));
        assertTrue(usdc.transfer(address(lp), donL));
        vm.stopPrank();
        shockS = bound(shockBps, -9_998, 4_999);
        shockE = bound(shockEpoch, 2, 8);
        for (uint256 e = 2; e <= 8; ++e) {
            _epoch(e);
        }
        _end();
    }

    function _epoch(uint256 e) internal {
        {
            _warpTo(c, e, false);
            if (e == shockE) lp.shock(int16(shockS));
            if (hasSecond) c2.settle(MAX);
            uint256 before = _assets(c) + 600e6; // all six members are auto-debited
            uint256 pa = _price(address(aave));
            uint256 pl = _price(address(lp));
            c.settle(MAX);
            uint256 after_ = _assets(c);
            pa = Math.max(pa, _price(address(aave)));
            pl = Math.max(pl, _price(address(lp)));
            uint256 boundUnits = pa + pl + 1;
            uint256 loss = before > after_ ? before - after_ : 0;
            assertLe(loss, boundUnits, "rounding loss above bound");
            if (e <= 7) {
                (uint256 aT, uint256 lT, uint256 floor) = _expected(c);
                assertLe(stdMath.delta(_aaveValue(c), aT), boundUnits, "aave off target");
                assertLe(stdMath.delta(_lpValue(c), lT), boundUnits, "lp off target");
                assertGe(usdc.balanceOf(address(c)), floor, "cash below post-state floor");
                _assertNoAllowance(c);
            }
        }
    }

    function _end() internal {
        assertEq(aave.balanceOf(address(c)), 0);
        assertEq(lp.balanceOf(address(c)), 0);
        uint256 bal = usdc.balanceOf(address(c));
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 b = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            sum += usdc.balanceOf(ms[i]) - b;
        }
        assertLe(sum, bal);
    }
}

/// @notice 07 D-10b (d): the floor-binding branch. 6 members, 10 epochs, allocation 40/30/20/10; ms[5] borrows 200e6
/// over 3 epochs (funded at settle(3)); a vote moves the allocation to 0/45/35/20 at settle(4), so the outstanding
/// principal is above the loan bucket (0) and the cash floor caps the deposits.
contract InvestGapsOverBucketTest is GovTestBase {
    function _overBucket() internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(6, 10, 30, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        _request(c, ms[5], 200e6, 3, 0);
        _settleAt(c, 4);
        uint256 id = _allocAs(c, ms[0], 0, 4_500, 3_500, 2_000);
        _votes(c, id, ms, 0, 4, true);
        _settleAt(c, 5);
        assertEq(c.getCircleState().rules.alloc.loan, 0);
        assertEq(c.getPublicSummary().outstandingPrincipal, 200e6, "loans above the bucket");
    }

    /// Targets and floor from public state with the D-05 formulas, independent of Invest.
    function _expected(KuberCircle c) internal view returns (uint256 aT, uint256 lT, uint256 floor) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        Alloc memory a = c.getCircleState().rules.alloc;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 v = assets > liabilities ? assets - liabilities : 0;
        aT = v * a.aave / BPS;
        lT = v * a.lp / BPS;
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

    /// Cash ends exactly at the floor, with LP still below target (the floor, not the target, bound the deposit).
    function _assertAtFloor(KuberCircle c, string memory term) internal view {
        (, uint256 lT, uint256 floor) = _expected(c);
        uint256 cash = usdc.balanceOf(address(c));
        assertGe(cash, floor, term);
        assertApproxEqAbs(cash, floor, 1, term);
        assertLt(_lpValue(c), lT, "floor binding");
    }

    /// One assertion per floor term (mutants F2-F5); each fails when its term is dropped from the floor.
    function test_D10b_d_cashFloorEachTerm() public {
        (KuberCircle c, address[] memory ms) = _overBucket();
        // settle(4)'s own rebalance, no liabilities: only the cash share holds cash back.
        _assertAtFloor(c, "cash share");
        uint256 snap = vm.snapshotState();
        _h(c).creditClaimable(ms[1], 50e6);
        _h(c).rebalanceNow();
        _assertAtFloor(c, "reservedClaims");
        vm.revertToState(snap);
        _h(c).addLiabilities(ms[1], 50e6, 0);
        _h(c).rebalanceNow();
        _assertAtFloor(c, "totalRewardsOwed");
        vm.revertToState(snap);
        _h(c).addLiabilities(ms[1], 0, 50e6);
        _h(c).rebalanceNow();
        _assertAtFloor(c, "saverPot");
    }

    /// Mutants R4 (LP before Aave) and R5 (LP cap ignores the Aave deposit): 100e6 donated leaves 80e6 above the
    /// floor; Aave takes its whole 45e6 gap first, LP the remaining 35e6, cash ends at the floor.
    function test_D10b_d_depositOrderAaveFirst() public {
        (KuberCircle c,) = _overBucket();
        usdc.mint(address(c), 100e6);
        (uint256 aT,, uint256 floor) = _expected(c);
        uint256 room = usdc.balanceOf(address(c)) - floor;
        uint256 a0 = _aaveValue(c);
        uint256 l0 = _lpValue(c);
        assertGt(room, aT - a0, "spare cash covers the Aave gap");
        _h(c).rebalanceNow();
        assertApproxEqAbs(_aaveValue(c), aT, 1, "Aave filled first");
        assertApproxEqAbs(_lpValue(c), l0 + room - (aT - a0), 1, "LP gets the rest");
        assertEq(usdc.balanceOf(address(c)), floor, "cash at the floor");
    }

    /// Mutants R9 (Aave deposit uncapped) and R5: a 100e6 claim pulls Aave below target, then 50e6 donated leaves
    /// 40e6 above the floor against a 57.5e6 Aave gap; Aave takes exactly the 40e6, LP nothing.
    function test_D10b_d_depositCapsPerVault() public {
        (KuberCircle c, address[] memory ms) = _overBucket();
        _h(c).creditClaimable(ms[1], 100e6);
        _h(c).rebalanceNow();
        usdc.mint(address(c), 50e6);
        (uint256 aT,, uint256 floor) = _expected(c);
        uint256 room = usdc.balanceOf(address(c)) - floor;
        uint256 a0 = _aaveValue(c);
        uint256 l0 = _lpValue(c);
        assertLt(room, aT - a0, "Aave gap above the spare cash");
        _h(c).rebalanceNow();
        assertApproxEqAbs(_aaveValue(c), a0 + room, 1, "Aave capped at the spare cash");
        assertEq(_lpValue(c), l0, "nothing left for LP");
        assertEq(usdc.balanceOf(address(c)), floor, "cash at the floor");
    }
}
