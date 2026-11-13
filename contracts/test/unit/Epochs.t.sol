// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    CircleStatus,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Member,
    Window
} from "../../src/lib/CircleTypes.sol";

contract EpochsTest is CircleTestBase {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant C = 100e6;

    function _s(KuberCircle c) internal view returns (uint256) {
        return c.getCircleState().fixedParams.startTime;
    }

    function _pay(KuberCircle c, address m) internal {
        vm.prank(m);
        c.payNow();
    }

    function test_T_EP_1_epochMapping() public {
        KuberCircle c = _create(_newMembers(5));
        uint256 s = _s(c);
        vm.warp(s - 1);
        assertEq(c.currentEpoch(), 0);
        vm.warp(s);
        assertEq(c.currentEpoch(), 1);
        vm.warp(s + 59);
        assertEq(c.currentEpoch(), 1);
        vm.warp(s + 60);
        assertEq(c.currentEpoch(), 2);
        vm.warp(s + 419);
        assertEq(c.currentEpoch(), 7);
        vm.warp(s + 420);
        assertEq(c.currentEpoch(), 8);
    }

    function test_T_EP_1_windowsFollowLockBps() public {
        KuberCircle c = _create(_newMembers(5));
        address[] memory ms = _newMembers(5);
        FixedParams memory f = _fixed();
        f.lockBps = 4_000;
        vm.prank(ms[0]);
        KuberCircle c40 = KuberCircle(factory.createCircle("circle40", f, _rules(), _tail(ms)));
        uint256 s = _s(c);
        assertEq(_s(c40), s);

        // lockBps 2_000 over 60 s: OPEN is the first 48 s.
        vm.warp(s);
        assertEq(uint8(c.currentWindow()), uint8(Window.Open));
        vm.warp(s + 47);
        assertEq(uint8(c.currentWindow()), uint8(Window.Open));
        vm.warp(s + 48);
        assertEq(uint8(c.currentWindow()), uint8(Window.Lock));
        vm.warp(s + 59);
        assertEq(uint8(c.currentWindow()), uint8(Window.Lock));
        vm.warp(s + 60);
        assertEq(uint8(c.currentWindow()), uint8(Window.Open));

        // lockBps 4_000: OPEN is the first 36 s.
        vm.warp(s + 35);
        assertEq(uint8(c40.currentWindow()), uint8(Window.Open));
        vm.warp(s + 36);
        assertEq(uint8(c40.currentWindow()), uint8(Window.Lock));
    }

    function test_T_EP_2_payWorksInLock() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        _warpTo(c, 1, true);
        assertEq(uint8(c.currentWindow()), uint8(Window.Lock));
        uint256 bal = usdc.balanceOf(ms[1]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ContributionPaid(ms[1], 1, C);
        _pay(c, ms[1]);
        assertEq(usdc.balanceOf(ms[1]), bal - C);
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        _h(c).probeAction();
        _h(c).probeVote();

        _warpTo(c, 1, false);
        _h(c).probeAction();
    }

    function test_T_EP_3_settleBeforeEpochEndsReverts() public {
        (KuberCircle c,) = _start(6);
        uint256 s = _s(c);
        vm.warp(s);
        vm.expectRevert(IKuberCircleErrors.EpochNotEnded.selector);
        c.settle(50);
        vm.warp(s + 59);
        vm.expectRevert(IKuberCircleErrors.EpochNotEnded.selector);
        c.settle(50);
    }

    function test_T_EP_3_skippedEpochsCatchUpOnePerCall() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        _warpTo(c, 4, false);
        for (uint256 k = 1; k <= 3; ++k) {
            vm.expectEmit(address(c));
            emit IKuberCircleEvents.EpochSettled(k);
            c.settle(MAX);
            assertEq(c.getCircleState().settledEpoch, k);
        }
        vm.expectRevert(IKuberCircleErrors.EpochNotEnded.selector);
        c.settle(MAX);
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            assertEq(m.paidBitmap, 14);
            assertEq(m.savings, 300e6);
        }
    }

    function test_T_EP_4_actionsWaitForSettlement() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        _warpTo(c, 2, false);
        vm.expectRevert(IKuberCircleErrors.SettlementPending.selector);
        _h(c).probeAction();
        vm.expectRevert(IKuberCircleErrors.SettlementPending.selector);
        _h(c).probeVote();
        _pay(c, ms[1]);

        c.settle(50);
        _h(c).probeAction();
        _h(c).probeVote();

        _warpTo(c, 2, true);
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        _h(c).probeAction();
        _h(c).probeVote();
    }

    function test_T_EP_5_twoBatchesSameAsOne() public {
        (KuberCircle c, address[] memory ms) = _start(8);
        _pay(c, ms[1]);
        vm.prank(ms[2]);
        usdc.approve(address(c), 0);
        _warpTo(c, 2, false);
        _pay(c, ms[3]);
        uint256 snap = vm.snapshotState();

        c.settle(MAX);
        _pay(c, ms[5]);
        bytes32 one = _stateHash(c, ms);

        vm.revertToState(snap);
        c.settle(3);
        assertEq(c.getCircleState().cursor, 3);
        assertEq(c.getCircleState().settledEpoch, 0);
        vm.expectRevert(IKuberCircleErrors.SettlementPending.selector);
        _h(c).probeAction();
        _pay(c, ms[5]);
        c.settle(MAX);
        assertEq(_stateHash(c, ms), one);
        assertEq(c.getCircleState().settledEpoch, 1);
    }

    /// @dev D-23(b) and A-7 (weights half): join order and every batch split are random; payments land between
    /// batches in B and after settlement in A. The withdraw comparison is added in 02-03 with finalize.
    function test_T_EP_5_fuzzAnyOrderAnySplit(uint256 seed, uint256 splitSeed) public {
        address[] memory ms = _newMembers(8);
        KuberCircle a = _create(ms);
        KuberCircle b = _create(ms);
        _join(a, _tail(ms));
        address[] memory perm = _tail(ms);
        for (uint256 i = perm.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (perm[i], perm[j]) = (perm[j], perm[i]);
        }
        _join(b, perm);
        assertEq(_s(a), _s(b));
        vm.warp(_s(a));
        a.activate();
        b.activate();

        vm.startPrank(ms[2]);
        usdc.approve(address(a), 0);
        usdc.approve(address(b), 0);
        vm.stopPrank();
        _pay(a, ms[1]);
        _pay(b, ms[1]);
        _warpTo(a, 2, false);
        _pay(a, ms[3]);
        _pay(b, ms[3]);

        // Settle epoch 1: A in one call; B split with ms[4] paying epoch 2 between the batches.
        a.settle(MAX);
        b.settle(1 + splitSeed % 7);
        assertEq(b.getCircleState().settledEpoch, 0);
        _pay(b, ms[4]);
        b.settle(MAX);
        _pay(a, ms[4]);

        vm.startPrank(ms[2]);
        usdc.approve(address(a), 710e6);
        usdc.approve(address(b), 710e6);
        vm.stopPrank();

        // Settle epoch 2 in epoch 3: ms[2] catches up epoch 1 after A's settle and between B's batches.
        _warpTo(a, 3, false);
        a.settle(MAX);
        vm.prank(ms[2]);
        a.catchUp(1);
        b.settle(1 + (splitSeed >> 8) % 7);
        vm.prank(ms[2]);
        b.catchUp(1);
        b.settle(MAX);

        _assertSame(a, b, ms);
        _assertSums(a, ms, 3);
        _assertSums(b, ms, 3);
        Member memory m2 = a.getMember(ms[2]);
        assertEq(m2.savings, 200e6);
        assertEq(m2.weight, 100e6);
        assertEq(m2.paidCount, 2);
        assertEq(m2.missedBitmap & 2, 2);
        assertEq(a.getPublicSummary().saverPot, 2e6);
        assertEq(b.getPublicSummary().saverPot, 2e6);

        // A-7: run both to the last epoch, a random split at every settlement and a pre-pay between B's batches.
        for (uint256 k = 3; k <= 7; ++k) {
            _warpTo(a, k + 1, false);
            address payer = ms[uint256(keccak256(abi.encode(seed, k))) % 8];
            b.settle(1 + uint256(keccak256(abi.encode(splitSeed, k))) % 7);
            if (k < 7) _pay(b, payer);
            b.settle(MAX);
            a.settle(MAX);
            if (k < 7) _pay(a, payer);
        }
        assertEq(a.getCircleState().settledEpoch, 7);
        assertEq(b.getCircleState().settledEpoch, 7);
        _assertSame(a, b, ms);
        _assertSums(a, ms, 7);
        _assertSums(b, ms, 7);
        // Everyone paid 1..7 with x = k (28c); ms[2] has x = 2..7 plus the catch-up at x = 3 (26c).
        for (uint256 i; i < 8; ++i) {
            Member memory m = a.getMember(ms[i]);
            assertEq(m.savings, 700e6);
            assertEq(m.weight, i == 2 ? 2_600e6 : 2_800e6);
        }
        KuberCircle.PublicSummary memory p = a.getPublicSummary();
        assertEq(p.wActive, 22_200e6);
        assertEq(p.sTotal, 5_600e6);
        assertEq(p.cash, 5_602e6);
        assertEq(p.yieldPot, 0);

        // A-7 (payout half): settle(7) finalized both; each withdraw pays the same in A and B, whatever the
        // order (A in index order, B in reverse). Payout = 700e6 + floor(2e6 × w / 22_200e6).
        uint256[] memory pb = new uint256[](8);
        for (uint256 i = 8; i > 0; --i) {
            pb[i - 1] = _withdraw(b, ms[i - 1]);
        }
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            uint256 pa = _withdraw(a, ms[i]);
            assertEq(pa, pb[i], "payout A != B");
            assertEq(pa, i == 2 ? 700_234_234 : 700_252_252, "payout");
            sum += pa;
        }
        assertEq(sum, 5_601_999_998);
        assertEq(usdc.balanceOf(address(a)), 2);
        assertEq(usdc.balanceOf(address(b)), 2);
    }

    function _withdraw(KuberCircle c, address m) internal returns (uint256) {
        uint256 before = usdc.balanceOf(m);
        vm.prank(m);
        c.withdraw();
        return usdc.balanceOf(m) - before;
    }

    /// @dev EPOCH-02: the settlement of epoch totalEpochs finalizes, also when its collect pass is split.
    function test_T_EP_6_finalSettleFinalizes() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        for (uint256 e = 2; e <= 7; ++e) {
            _warpTo(c, e, false);
            c.settle(MAX);
        }
        _warpTo(c, 8, false);
        c.settle(4);
        KuberCircle.CircleState memory s = c.getCircleState();
        assertEq(uint8(s.status), uint8(CircleStatus.Active));
        assertEq(s.cursor, 4);
        assertEq(s.settledEpoch, 6);
        for (uint256 i; i < ms.length; ++i) {
            assertEq(registry.activeMemberships(ms[i]), 1);
        }

        // The nested Settle -> ShareOut delegatecall logs from the circle.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.EpochSettled(7);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(0, 16_800e6, 16_800e6, 0, 4_200e6);
        c.settle(MAX);
        s = c.getCircleState();
        assertEq(uint8(s.status), uint8(CircleStatus.Ended));
        assertEq(s.settledEpoch, 7);
        assertEq(s.cursor, 0);

        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        c.settle(MAX);
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        c.payNow();
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        c.catchUp(1);
        for (uint256 i; i < ms.length; ++i) {
            assertEq(registry.activeMemberships(ms[i]), 0);
            assertEq(registry.memberStats(ms[i]).circlesCompleted, 1);
        }
    }

    function test_settle_zeroBatchReverts() public {
        (KuberCircle c,) = _start(6);
        _warpTo(c, 2, false);
        vm.expectRevert(IKuberCircleErrors.ZeroBatch.selector);
        c.settle(0);
    }

    function test_settle_beforeActivationReverts() public {
        KuberCircle c = _create(_newMembers(5));
        vm.warp(_s(c) + 120);
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        c.settle(50);
    }

    function test_settle_maxBatchNoOverflow() public {
        (KuberCircle c,) = _start(6);
        _warpTo(c, 3, false);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 1);
        // With the cursor at 2, a naive cursor + maxMembers would overflow.
        c.settle(2);
        assertEq(c.getCircleState().cursor, 2);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 2);
        assertEq(c.getCircleState().cursor, 0);
    }

    function _stateHash(KuberCircle c, address[] memory ms) internal view returns (bytes32 h) {
        for (uint256 i; i < ms.length; ++i) {
            h = keccak256(abi.encode(h, c.getMember(ms[i])));
        }
        KuberCircle.CircleState memory s = c.getCircleState();
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        // The cash/vault split depends on when a payment lands relative to the rebalance; total assets do not.
        (p.cash, p.aaveValue, p.lpValue) = (p.cash + p.aaveValue + p.lpValue, 0, 0);
        h = keccak256(abi.encode(h, p, s.settledEpoch, s.cursor, _h(c).wActiveAt(7), _h(c).wSaverAt(7)));
    }

    function _assertSame(KuberCircle a, KuberCircle b, address[] memory ms) internal view {
        for (uint256 i; i < ms.length; ++i) {
            Member memory x = a.getMember(ms[i]);
            Member memory y = b.getMember(ms[i]);
            assertEq(x.savings, y.savings, "savings");
            assertEq(x.weight, y.weight, "weight");
            assertEq(x.lastAccrual, y.lastAccrual, "lastAccrual");
            assertEq(x.paidBitmap, y.paidBitmap, "paidBitmap");
            assertEq(x.missedBitmap, y.missedBitmap, "missedBitmap");
            assertEq(x.paidCount, y.paidCount, "paidCount");
        }
        KuberCircle.PublicSummary memory p = a.getPublicSummary();
        KuberCircle.PublicSummary memory q = b.getPublicSummary();
        assertEq(p.sTotal, q.sTotal, "sTotal");
        assertEq(p.saverPot, q.saverPot, "saverPot");
        assertEq(p.wActive, q.wActive, "wActive");
        assertEq(p.wSaver, q.wSaver, "wSaver");
    }

    function _assertSums(KuberCircle c, address[] memory ms, uint256 e) internal view {
        uint256 sum;
        for (uint256 i; i < ms.length; ++i) {
            sum += _h(c).weightAt(ms[i], e);
        }
        assertEq(_h(c).wActiveAt(e), sum, "sum w != W_active");
        assertEq(_h(c).wSaverAt(e), sum, "sum w != W_saver");
    }
}

/// @dev Adapted from the plan checker's random-sequence fuzz: payNow, catchUp, allowance and balance changes,
/// and batched settles in random order, each predicted by an independent model (who is collected, who misses,
/// fines, balances), with every weight compared to the brute-force sum of c × (T − x + 1). From 02-03: one donation
/// or loss lands before finalize, the run ends at the finalizing settlement, and the frozen numbers and every
/// withdraw are checked against the model (sum of payouts ≤ balance, dust < 2 per member).
contract SettleRandomTest is CircleTestBase {
    uint256 internal constant C = 100e6;
    address[] internal ms;
    KuberCircle internal c;
    uint256 internal T;
    uint256 internal fines;
    mapping(address => uint256[]) internal xs;
    int16 internal potShift;
    uint256 internal shiftAt;
    bool internal shifted;
    int256 internal shift;

    function testFuzz_randomSequenceMatchesModel(uint256 seed, uint8 nRaw, uint8 tRaw, int16 potShift_) public {
        uint256 n = 5 + nRaw % 6;
        T = 6 + tRaw % 10;
        potShift = potShift_;
        shiftAt = seed % T;
        address[] memory m0 = _newMembers(n);
        for (uint256 i; i < n; ++i) {
            ms.push(m0[i]);
            usdc.mint(m0[i], 90_000e6);
        }
        FixedParams memory f = _fixed();
        f.totalEpochs = uint8(T);
        vm.prank(m0[0]);
        c = KuberCircle(factory.createCircle("rand", f, _rules(), _tail(m0)));
        for (uint256 i; i < n; ++i) {
            if (i > 0) {
                vm.prank(m0[i]);
                c.join();
            }
            vm.prank(m0[i]);
            usdc.approve(address(c), 1_000_000e6);
        }
        vm.warp(f.startTime);
        c.activate();

        for (uint256 step; step < 400; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = r % 12;
            address who = ms[(r >> 16) % n];
            if (action <= 2) {
                vm.warp(vm.getBlockTimestamp() + 1 + (r >> 8) % 40);
            } else if (action <= 4) {
                _payNow(who);
            } else if (action == 5) {
                _catchUp(who, 1 + (r >> 24) % T);
            } else if (action == 6) {
                vm.prank(who);
                usdc.approve(address(c), (r >> 40) % 3 == 0 ? 0 : 1_000_000e6);
            } else if (action == 7) {
                uint256 bal = usdc.balanceOf(who);
                if ((r >> 40) % 2 == 0 && bal > 50e6) {
                    vm.prank(who);
                    assertTrue(usdc.transfer(address(0x5111c), bal - 50e6));
                } else {
                    usdc.mint(who, 100_000e6);
                }
            } else {
                _settle((r >> 32) % 5 == 4 ? type(uint256).max : 1 + (r >> 32) % 4);
            }
        }
        while (c.getCircleState().status != CircleStatus.Ended) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _settle(type(uint256).max);
        }
        _checkEnd();
    }

    // Once, before a settlement of an epoch after `shiftAt`: mint to the circle, or drain it (a stand-in for an
    // investment loss; `drain` pulls from the vaults first). The loss is capped only by what the circle holds; a
    // loss above all savings cuts the savers' pot at the freeze (R-U).
    function _shiftPot() internal {
        shifted = true;
        uint256 amt = uint256(potShift < 0 ? -int256(potShift) : int256(potShift)) * 1e5;
        if (potShift > 0) {
            usdc.mint(address(c), amt);
            shift += int256(amt);
        } else {
            KuberCircle.PublicSummary memory p = c.getPublicSummary();
            uint256 held = p.cash + p.aaveValue + p.lpValue;
            amt = amt > held ? held : amt;
            _h(c).drain(address(0xdead), amt);
            shift -= int256(amt);
        }
    }

    function _payNow(address who) internal {
        uint256 e = c.currentEpoch();
        Member memory m = c.getMember(who);
        bool ok = _active() && e <= T && (m.paidBitmap >> e) & 1 == 0 && _canPull(who, C);
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        if (!ok) {
            vm.expectRevert();
            c.payNow();
            return;
        }
        c.payNow();
        assertEq(usdc.balanceOf(who), bal - C, "payNow pull");
        xs[who].push(e);
    }

    function _catchUp(address who, uint256 k) internal {
        uint256 e = c.currentEpoch();
        Member memory m = c.getMember(who);
        uint256 fine = C * 100 * (e > k ? e - k : 0) / 10_000;
        bool ok = _active() && (m.missedBitmap >> k) & 1 == 1 && (m.paidBitmap >> k) & 1 == 0 && _canPull(who, C + fine);
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        if (!ok) {
            vm.expectRevert();
            c.catchUp(k);
            return;
        }
        c.catchUp(k);
        assertEq(usdc.balanceOf(who), bal - C - fine, "catchUp pull");
        fines += fine;
        xs[who].push(e);
    }

    function _active() internal view returns (bool) {
        return c.getCircleState().status == CircleStatus.Active;
    }

    function _canPull(address who, uint256 amt) internal view returns (bool) {
        return usdc.balanceOf(who) >= amt && usdc.allowance(who, address(c)) >= amt;
    }

    // Predicts the collect pass from the cursor, then checks bitmaps, balances, the cursor, and the sum invariant.
    function _settle(uint256 batch) internal {
        KuberCircle.CircleState memory st = c.getCircleState();
        if (st.status == CircleStatus.Ended) {
            vm.expectRevert(IKuberCircleErrors.NotActive.selector);
            c.settle(batch);
            return;
        }
        if (potShift != 0 && !shifted && st.settledEpoch >= shiftAt) _shiftPot();
        uint256 k = st.settledEpoch + 1;
        if (c.currentEpoch() <= k) {
            vm.expectRevert(IKuberCircleErrors.EpochNotEnded.selector);
            c.settle(batch);
            return;
        }
        uint256 n = ms.length;
        uint256 end = batch >= n - st.cursor ? n : st.cursor + batch;
        Member[] memory before = new Member[](n);
        uint256[] memory bal = new uint256[](n);
        bool[] memory pull = new bool[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = c.getMember(ms[i]);
            bal[i] = usdc.balanceOf(ms[i]);
            pull[i] = i >= st.cursor && i < end && (before[i].paidBitmap >> k) & 1 == 0 && _canPull(ms[i], C);
        }
        c.settle(batch);
        for (uint256 i; i < n; ++i) {
            Member memory m = c.getMember(ms[i]);
            bool inBatch = i >= st.cursor && i < end && (before[i].paidBitmap >> k) & 1 == 0;
            uint64 bit = uint64(1 << k);
            if (pull[i]) {
                assertEq(m.paidBitmap, before[i].paidBitmap | bit, "collected bit");
                assertEq(m.missedBitmap, before[i].missedBitmap, "no miss on collect");
                assertEq(usdc.balanceOf(ms[i]), bal[i] - C, "collect pull");
                xs[ms[i]].push(k);
            } else {
                assertEq(m.paidBitmap, before[i].paidBitmap, "paid unchanged");
                assertEq(m.missedBitmap, inBatch ? before[i].missedBitmap | bit : before[i].missedBitmap, "miss");
                assertEq(usdc.balanceOf(ms[i]), bal[i], "no pull");
            }
        }
        KuberCircle.CircleState memory after_ = c.getCircleState();
        assertEq(after_.cursor, end < n ? end : 0, "cursor");
        assertEq(after_.settledEpoch, end < n ? k - 1 : k, "settledEpoch");
        // Only the completed settlement of epoch T finalizes (D-16).
        CircleStatus want = end == n && k == T ? CircleStatus.Ended : CircleStatus.Active;
        assertEq(uint8(after_.status), uint8(want), "status");
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += _h(c).weightAt(ms[i], T);
        }
        assertEq(sum, _h(c).wActiveAt(T), "sum w != W_active");
        assertEq(sum, _h(c).wSaverAt(T), "sum w != W_saver");
    }

    function _checkEnd() internal {
        uint256 n = ms.length;
        uint256[] memory w = new uint256[](n);
        uint256 sumW;
        uint256 sumS;
        for (uint256 i; i < n; ++i) {
            address who = ms[i];
            for (uint256 j; j < xs[who].length; ++j) {
                uint256 x = xs[who][j] > T + 1 ? T + 1 : xs[who][j];
                w[i] += C * (T + 1 - x);
            }
            Member memory m = c.getMember(who);
            assertEq(m.weight, w[i], "weight != brute force");
            assertEq(m.savings, C * xs[who].length, "savings");
            assertEq(m.paidCount, xs[who].length, "paidCount");
            // Every epoch is paid or missed (or both, after a catch-up).
            for (uint256 k = 1; k <= T; ++k) {
                assertTrue((m.paidBitmap | m.missedBitmap) >> k & 1 == 1, "epoch neither paid nor missed");
            }
            sumW += w[i];
            sumS += m.savings;
        }
        // Model of the freeze: cash = savings + fines + shift; the savers' pot is cut to the cash (R-U); yieldPot =
        // cash − pool − savings; no savers left -> pot takes the pool. The single drain rarely reaches the R-U path;
        // test_RU_lossAboveSavingsCutsSaverPot covers it.
        uint256 cash = uint256(int256(sumS + fines) + shift);
        uint256 pool = cash < fines ? cash : fines;
        int256 pot = int256(cash) - int256(pool) - int256(sumS);
        if (sumW == 0) {
            pot += int256(pool);
            pool = 0;
        }
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.wActive, sumW, "sumW != W_active");
        assertEq(p.wSaver, sumW, "sumW != W_saver");
        assertEq(p.sTotal, sumS, "sumS != sTotal");
        assertEq(p.saverPot, pool, "saverPot");
        assertEq(p.cash, cash, "cash");
        assertEq(p.yieldPot, pot, "yieldPot");

        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 want = _modelPayout(C * xs[ms[i]].length, w[i], pot, pool, sumW, sumS);
            uint256 before = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            assertEq(usdc.balanceOf(ms[i]) - before, want, "payout != model");
            paid += want;
        }
        assertLe(paid, cash, "overpaid");
        assertLt(cash - paid, 2 * n, "dust");
        assertEq(usdc.balanceOf(address(c)), cash - paid, "dust stays");
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.AlreadyWithdrawn.selector);
        c.withdraw();
    }

    // Plain-arithmetic share-out (not the contract's mulDiv): gains floor by weight, a loss ceils by savings.
    function _modelPayout(uint256 s, uint256 w, int256 pot, uint256 pool, uint256 sumW, uint256 sumS)
        internal
        pure
        returns (uint256 a)
    {
        if (pot > 0) {
            a = s + (sumW == 0 ? 0 : uint256(pot) * w / sumW);
        } else if (pot < 0) {
            uint256 loss = s == 0 ? 0 : (uint256(-pot) * s + sumS - 1) / sumS;
            a = loss >= s ? 0 : s - loss;
        } else {
            a = s;
        }
        if (sumW > 0) a += pool * w / sumW;
    }
}
