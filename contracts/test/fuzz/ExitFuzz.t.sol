// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {Member, ProposalKind} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev D-16 (P3 and exit conservation): random member count, missed contributions (caught up with fines), an
/// optional loan, an LP shock of up to ±30%, and a cash gift. One random member then exits three ways from the same
/// snapshot: (A) a real leave through settle(5), (B) the same leave with settlement step 2's membership half run alone
/// (harness `applyMembership`), (C) a real kick. Step 2 is isolated for the exact V − sTotal identity because after an
/// LP shock the rebalance's ERC-4626 conversions round by ±1 unit, which is not part of the exit. `settle` is never
/// wrapped, so any revert fails the run.
contract ExitFuzzTest is GovTestBase {
    KuberCircle internal c;
    address[] internal ms;

    function testFuzz_D16_exitConservationAndP3(
        uint256 seed,
        uint8 nRaw,
        uint8 who,
        int16 shock,
        uint64 gift,
        bool loan
    ) public {
        _setup(seed, bound(nRaw, 6, 10), loan);
        int16 s = int16(bound(shock, -3_000, 3_000));
        if (s != 0) lp.shock(s);
        usdc.mint(address(c), bound(gift, 0, 300e6));
        address a = ms[bound(who, 1, ms.length - 1)];
        Member memory before = c.getMember(a);
        uint256 snap = vm.snapshotState();

        // Path A: a real leave.
        KuberCircle.PublicSummary memory p0 = c.getPublicSummary();
        vm.prank(a);
        c.requestLeave();
        (uint256 payL, uint256 feeL,,) = c.exitValueOf(a);
        _settleAt(c, 6);
        assertEq(c.getMember(a).claimable, before.claimable + payL, "leave credit == exitValueOf");
        _checkLedger(6);
        // With no shock the vault prices stay 1:1, so the rebalance is exact and the identity holds end to end.
        if (s == 0) _checkIdentity(p0, c.getPublicSummary(), before, payL, feeL);

        // Path B: the same leave, step 2 isolated.
        vm.revertToState(snap);
        vm.prank(a);
        c.requestLeave();
        _warpTo(c, 6, false);
        p0 = c.getPublicSummary();
        _h(c).applyMembership(5, 0);
        assertEq(c.getMember(a).claimable, before.claimable + payL, "isolated leave credit");
        _checkIdentity(p0, c.getPublicSummary(), before, payL, feeL);
        _checkLedger(5);

        // Path C: a real kick pays the leave payout plus the leave fee (P3).
        vm.revertToState(snap);
        uint256 id = _kickAs(c, ms[a == ms[1] ? 2 : 1], a);
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i] == a) continue;
            vm.prank(ms[i]);
            c.vote(id, true);
        }
        _settleAt(c, 6);
        assertEq(c.getMember(a).claimable, before.claimable + payL + feeL, "P3");
        _checkLedger(6);
    }

    /// @dev D-09: a member who ever borrowed takes no saver share on exit. The fuzz cannot see this (its leaver never
    /// borrowed, and the view and the exit share one quote). 06-02 exit fixture: m0 borrowed and repaid, has no rewards;
    /// value = 600e6 + 61e6 / 6 = 610_166_666; fee = ceil(610_166_666 x 300 / 10_000) = 18_305_000. A saver share would
    /// add 8_100_000 x 2_100e6 / 10_500e6 = 1_620_000.
    function test_D09_pastBorrowerExitHasNoSaverShare() public {
        (c, ms) = _exitFixture();
        assertTrue(c.getMember(ms[0]).everBorrowed);
        vm.prank(ms[0]);
        c.requestLeave();
        (uint256 pay, uint256 fee,,) = c.exitValueOf(ms[0]);
        assertEq(pay, 591_861_666);
        assertEq(fee, 18_305_000);
        _settleAt(c, 7);
        assertEq(c.getMember(ms[0]).claimable, 591_861_666);
        assertEq(c.getPublicSummary().saverPot, 8_100_000 + 18_305_000, "pot keeps its 8_100_000, gains the fee");
    }

    // Epochs 1-4 with random misses (and m0's optional 50e6 loan at e = 3); then everyone catches up 1-4 and
    // pre-pays epoch 5, so every member has paidCount 5 and can propose and vote. Returns in epoch 5 OPEN.
    function _setup(uint256 seed, uint256 n, bool loan) internal {
        (c, ms) = _startGov(n, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        for (uint256 e = 2; e <= 5; ++e) {
            for (uint256 i; i < n; ++i) {
                vm.prank(ms[i]);
                usdc.approve(address(c), uint256(keccak256(abi.encode(seed, e, i))) % 4 == 0 ? 0 : 5_000e6);
            }
            _settleAt(c, e);
            if (e == 3 && loan) {
                vm.startPrank(ms[0]);
                usdc.approve(address(c), 5_000e6);
                _catchUp(ms[0], 2);
                if (c.getMember(ms[0]).paidBitmap & (1 << 3) == 0) c.payNow();
                c.requestLoan(50e6, 1, 0, 0);
                vm.stopPrank();
            }
        }
        for (uint256 i; i < n; ++i) {
            vm.startPrank(ms[i]);
            usdc.approve(address(c), 5_000e6);
            _catchUp(ms[i], 4);
            c.payNow();
            if (c.getMember(ms[i]).activeLoanId != 0) c.claim();
            vm.stopPrank();
        }
    }

    // Under an active prank: catches up every missed, unpaid epoch among 1..last.
    function _catchUp(address m, uint256 last) internal {
        for (uint256 k = 1; k <= last; ++k) {
            Member memory x = c.getMember(m);
            if (x.missedBitmap & (1 << k) != 0 && x.paidBitmap & (1 << k) == 0) c.catchUp(k);
        }
    }

    // Δ(V − sTotal) is exactly minus the yield share paid (a loss share taken counts as a negative yield share).
    function _checkIdentity(
        KuberCircle.PublicSummary memory p0,
        KuberCircle.PublicSummary memory p1,
        Member memory before,
        uint256 payL,
        uint256 feeL
    ) internal pure {
        uint256 saverShare = feeL + p0.saverPot - p1.saverPot;
        int256 yieldPaid = int256(payL + feeL) - int256(uint256(before.savings)) - int256(saverShare)
            - int256(uint256(before.rewards));
        assertEq(p1.yieldPot - p0.yieldPot, -yieldPaid, "V - sTotal identity");
    }

    // Σ member weights equal both accumulators, and reservedClaims equals Σ claimable.
    function _checkLedger(uint256 e) internal view {
        assertEq(_sumWeights(c, ms, e, false), _h(c).wActiveAt(e), "W_active");
        assertEq(_sumWeights(c, ms, e, true), _h(c).wSaverAt(e), "W_saver");
        assertEq(c.getPublicSummary().reservedClaims, _sumClaimable(c, ms), "reservedClaims");
    }
}
