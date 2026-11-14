// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Alloc,
    BPS,
    CircleStatus,
    FixedParams,
    LoanStatus,
    Member,
    MemberStatus,
    ProposalKind,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {Handler} from "../invariant/Handler.sol";
import {QueueFairnessBase} from "./QueueFairness.t.sol";

/// @dev The invariant handler, driven step by step: `act` runs one dispatcher action, the rest set up the guided
/// default and pay out through the handler so its ghosts see every transfer.
contract PropHandler is Handler {
    constructor(Config memory cfg) Handler(cfg) {}

    function act(uint256 r, uint256 s) external {
        _dispatch(r, s);
    }

    function setP4(bool on) external {
        p4On = on;
    }

    function setIgnored(address who) external {
        ignored[who] = true;
    }

    /// @dev `b` pays this epoch, requests its own limit + `need` over 3 epochs, and 2-4 others pledge the need.
    function forceLoan(address b, uint256 need, uint256 s) external returns (uint256 id) {
        vm.recordLogs();
        KuberCircle c = cs[0];
        if (c.getMember(b).paidBitmap & (uint64(1) << c.currentEpoch()) == 0) {
            _call(0, b, abi.encodeCall(KuberCircle.payNow, ()));
        }
        (,, uint256 own) = c.loanLimits(b);
        (bool ok_, bytes memory ret) = _call(0, b, abi.encodeCall(KuberCircle.requestLoan, (own + need, 3, 800, 0)));
        require(ok_, "request");
        id = abi.decode(ret, (uint256));
        require(_cover(0, id, need, s), "not pledged");
    }

    /// @dev `b` claims its proceeds and revokes its allowance.
    function forceStop(address b) external {
        vm.recordLogs();
        _call(0, b, abi.encodeCall(KuberCircle.claim, ()));
        vm.prank(b);
        usdc.approve(address(cs[0]), 0);
    }

    function take(address who, bool isWithdraw) external {
        vm.recordLogs();
        _take(
            0, who, isWithdraw ? abi.encodeCall(KuberCircle.withdraw, ()) : abi.encodeCall(KuberCircle.claim, ()), NEXT
        );
    }
}

/// @dev One circle of 12-20 members (seeded), 10 epochs, allocation 40/30/20/10, manager fee 5%, protocol fee 10%,
/// reimbursement on, Aave at 5% with a 1,000,000x speedup (so most runs end with a positive pot); members 0-2 are the
/// manager pool (never borrow, back, leave, or get kicked).
abstract contract PropBase is CircleTestBase {
    PropHandler internal h;
    KuberCircle internal c;
    address[] internal ms;
    uint256 internal constant C = 100e6;

    function _system(uint256 seed) internal {
        registry.setProtocolFeeBps(1_000);
        registry.setGasSettings(30e6, 100e9, 1e6);
        aave.setApy(500, 0);
        aave.setSpeedup(1_000_000);
        ms = _newMembers(12 + seed % 9);
        address[] memory out = _newMembers(3);
        FixedParams memory f = _fixed();
        f.totalEpochs = 10;
        f.maxMembers = 40;
        RuleParams memory r = _rules();
        r.alloc = Alloc({loan: 4_000, aave: 3_000, lp: 2_000, cash: 1_000});
        r.managerFeeBps = 500;
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("P", f, r, _tail(ms)));
        for (uint256 i; i < ms.length; ++i) {
            if (i != 0) {
                vm.prank(ms[i]);
                c.join();
            }
            vm.prank(ms[i]);
            usdc.approve(address(c), type(uint256).max);
        }
        for (uint256 i; i < out.length; ++i) {
            vm.prank(out[i]);
            usdc.approve(address(c), type(uint256).max);
        }
        vm.warp(f.startTime);
        c.activate();
        Handler.Config memory cfg;
        (cfg.a, cfg.usdc, cfg.aave, cfg.lp, cfg.reg) = (c, usdc, aave, lp, registry);
        (cfg.treasury, cfg.keeper, cfg.outsiders) = (registry.treasury(), makeAddr("keeper"), out);
        cfg.poolA = new address[](3);
        (cfg.poolA[0], cfg.poolA[1], cfg.poolA[2]) = (ms[0], ms[1], ms[2]);
        h = new PropHandler(cfg);
        usdc.setMinter(address(h), true);
        aave.transferOwnership(address(h));
        lp.transferOwnership(address(h));
    }

    // To the next epoch start, settling everything (the dispatcher's nextEpoch with a full settle).
    function _next() internal {
        h.act(0, 5);
    }

    // Random dispatcher steps until the circle ends or `steps` ran.
    function _drive(uint256 seed, uint256 steps) internal {
        for (uint256 i; i < steps && c.getCircleState().status == CircleStatus.Active; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, "step", i)));
            h.act(s % 100, s / 100);
        }
    }

    function _finish() internal {
        for (uint256 i; i < 40 && c.getCircleState().status == CircleStatus.Active; ++i) {
            _next();
        }
        assertEq(uint8(c.getCircleState().status), uint8(CircleStatus.Ended), "not finalized");
        assertEq(h.settleReverts(), 0, vm.toString(h.settleRevertData()));
    }

    // Guided default with a seizure: at epoch 4 a non-pool member pays, borrows its own limit (90% of 400e6) + 2
    // contributions, funded at settle(4); it then claims and revokes, so settle(8) finds installment 1 unpaid for the
    // third time and seizes about 160e6 from the backers. The handler never acts for it again.
    function _guidedDefault(uint256 seed) internal returns (address b) {
        _next();
        _next();
        _next();
        b = ms[3 + seed % (ms.length - 3)];
        uint256 id = h.forceLoan(b, 2 * C, seed);
        _next();
        assertEq(uint8(c.getLoan(id).status), uint8(LoanStatus.Funded), "guided loan funded");
        h.forceStop(b);
        h.setIgnored(b);
    }

    function _warpNext() internal {
        FixedParams memory f = c.getCircleState().fixedParams;
        vm.warp(f.startTime + c.currentEpoch() * uint256(f.epochDuration));
    }

    function _settleAll() internal {
        _warpNext();
        vm.txGasPrice(25e9);
        c.settle(type(uint256).max);
    }
}

/// @dev TEST_PLAN §9 P1-P5 (DECISIONS R-S, 07 D-11, D-12) and fee conservation at an exit, over random sequences of
/// borrowing, backing, defaults, votes, kicks, leaves, joins, manager actions, shocks, and yield from the handler.
contract PropertiesTest is PropBase {
    /// @dev P1: a member who never backed, was never paused or defaulted (the R-N2 debt-0 default too), is Active at
    /// the end, and owes nothing anywhere withdraws at least its credited contributions whenever the frozen net pot is
    /// >= 0. Every run has the guided seizure and >= 3 subjects (the manager pool).
    function testFuzz_P1_nonBackerPaidAtLeastContributions(uint256 seed) public {
        _p1(seed);
    }

    /// @dev Non-vacuity: P1 binds only when the frozen pot is >= 0; over 16 seeds most runs must get there.
    function test_P1_potNonNegativeInMostRuns() public {
        uint256 binding;
        for (uint256 seed; seed < 16; ++seed) {
            uint256 snap = vm.snapshotState();
            if (_p1(seed)) ++binding;
            vm.revertToState(snap);
        }
        emit log_named_uint("P1 runs with a frozen pot >= 0 (of 16)", binding);
        assertGe(binding, 8, "P1 mostly vacuous");
    }

    function _p1(uint256 seed) internal returns (bool potNonNegative) {
        _system(seed);
        _guidedDefault(seed);
        _drive(seed, 30);
        _finish();
        assertGe(h.defaultsWithSeizure(), 1, "no seizure");
        potNonNegative = c.getPublicSummary().yieldPot >= 0;
        address[] memory list = c.members();
        uint256 subjects;
        for (uint256 i; i < list.length; ++i) {
            address a = list[i];
            Member memory m = c.getMember(a);
            if (m.status != MemberStatus.Active || h.everBacked(0, a) || h.everDefaulted(0, a)) continue;
            if (registry.hasOpenDebt(a)) continue;
            ++subjects;
            uint256 before = usdc.balanceOf(a);
            vm.prank(a);
            c.withdraw();
            if (potNonNegative) assertGe(usdc.balanceOf(a) - before, uint256(m.paidCount) * C, "P1");
        }
        assertGe(subjects, 3, "subjects");
    }

    /// @dev P2: after finalize and after every withdraw and claim (members, leavers, treasury, manager, keeper), what
    /// left the circle is at most what came in plus yield; once everything is paid only dust stays.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (141 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_P2_outflowsWithinInflows(uint256 seed) public {
        _system(seed);
        _guidedDefault(seed);
        _drive(seed, 30);
        _finish();
        _flowsWithin();
        address[] memory list = c.members();
        for (uint256 i; i < list.length; ++i) {
            Member memory m = c.getMember(list[i]);
            if ((m.status == MemberStatus.Active || m.status == MemberStatus.Suspended) && !m.withdrawn) {
                h.take(list[i], true);
                _flowsWithin();
            }
        }
        // Twice: a paused member's share-out repays its backers' losses into their claimable.
        address[] memory ex = h.extras();
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < list.length + ex.length; ++i) {
                address a = i < list.length ? list[i] : ex[i - list.length];
                if (c.getMember(a).claimable == 0) continue;
                h.take(a, false);
                _flowsWithin();
            }
        }
        assertLe(usdc.balanceOf(address(c)), 2 * list.length + 10, "P2: more than dust left");
    }

    function _flowsWithin() internal view {
        assertLe(h.outflow(0), h.inflow(0) + h.yieldIn(0) + 2 * h.vaultOps(0) + 2, "P2: outflow above inflow + yield");
    }

    /// @dev P3: the same member, in the same settlement, kicked or leaving: kick payout == leave payout + the leave's
    /// exit fee (the kick charges none).
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (77 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_P3_kickKeepsExitValue(uint256 seed) public {
        _system(seed);
        uint256 target = 4 + seed % 4;
        for (uint256 i; i < 200 && c.currentEpoch() < target; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, "p3", i)));
            h.act(s % 100, s / 100);
        }
        // A fresh epoch: everything settled, no leave pending, no proposal open.
        _next();
        (address a, address proposer) = _kickPair(seed);
        if (a == address(0)) return;
        uint256 snap = vm.snapshotState();

        uint256 before = c.getMember(a).claimable;
        vm.prank(proposer);
        uint256 id = c.propose(ProposalKind.Kick, abi.encode(a));
        _voteAllBut(id, a);
        _settleAll();
        assertEq(uint8(c.getMember(a).status), uint8(MemberStatus.Kicked), "kick passed");
        uint256 payK = c.getMember(a).claimable - before;

        vm.revertToState(snap);
        vm.prank(a);
        c.requestLeave();
        uint256 bps = c.getMember(a).leaveExitFeeBps;
        _settleAll();
        assertEq(uint8(c.getMember(a).status), uint8(MemberStatus.Left), "left");
        uint256 payL = c.getMember(a).claimable - before;
        assertEq(payK, payL + Math.mulDiv(payK, bps, BPS, Math.Rounding.Ceil), "P3");
    }

    // A free non-pool member and an eligible proposer whose Kick proposal on it goes through now.
    function _kickPair(uint256 seed) internal returns (address a, address proposer) {
        address[] memory list = c.members();
        uint256 minSave = c.getCircleState().fixedParams.minSaveEpochs;
        for (uint256 j; j < list.length; ++j) {
            address t = list[(seed % list.length + j) % list.length];
            Member memory m = c.getMember(t);
            if (h.isPool(t) || m.status != MemberStatus.Active || m.activeLoanId != 0) continue;
            if (m.pendingRequestId != 0 || m.pledgedOut != 0 || m.leavePending) continue;
            for (uint256 i; i < list.length; ++i) {
                Member memory p = c.getMember(list[i]);
                if (list[i] == t || p.status != MemberStatus.Active || p.paidCount < minSave) continue;
                uint256 snap = vm.snapshotState();
                vm.prank(list[i]);
                (bool ok,) = address(c).call(abi.encodeCall(KuberCircle.propose, (ProposalKind.Kick, abi.encode(t))));
                vm.revertToState(snap);
                if (ok) return (t, list[i]);
            }
        }
    }

    function _voteAllBut(uint256 id, address skip) internal {
        address[] memory list = c.members();
        uint256 minSave = c.getCircleState().fixedParams.minSaveEpochs;
        for (uint256 i; i < list.length; ++i) {
            Member memory m = c.getMember(list[i]);
            if (list[i] == skip || m.status != MemberStatus.Active) continue;
            if (m.sponsor != address(0) && m.paidCount < minSave) continue;
            vm.prank(list[i]);
            c.vote(id, true);
        }
    }

    /// @dev P4 (07 D-12): every MemberSuspended has O == fromBorrower + fromVouchers + fromAgreers, and around every
    /// settle call with a default a member not involved in any default keeps its savings except for its own
    /// contribution collected in that call (the handler's P4 ghost).
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (162 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_P4_groupLossZero(uint256 seed) public {
        _system(seed);
        h.setP4(true);
        _guidedDefault(seed);
        _drive(seed, 30);
        _finish();
        assertGe(h.defaultsWithSeizure(), 1, "no seizure");
        assertEq(h.groupLossEvents(), 0, "P4: O != fromBorrower + fromVouchers + fromAgreers");
        assertEq(h.p4Breaches(), 0, h.firstBreach());
    }

    /// @dev P5 (07 D-12): X and Y mirror each other (the same payments, misses, catch-ups, and claims; they never
    /// borrow or back) at random list positions under random batch sizes: their withdraw amounts are equal.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (159 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_P5_identicalMembersIdenticalPayouts(uint256 seed) public {
        _system(seed);
        uint256 n = ms.length;
        address x = ms[3 + seed % (n - 3)];
        address y = ms[3 + (seed / n + 1 + seed % (n - 3)) % (n - 3)];
        if (x == y) y = ms[x == ms[3] ? 4 : 3];
        h.setIgnored(x);
        h.setIgnored(y);
        for (uint256 i; i < 80 && c.getCircleState().status == CircleStatus.Active; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, "p5", i)));
            if (s % 4 == 0) _mirror(x, y, s >> 8);
            else h.act((s >> 8) % 100, s >> 16);
        }
        _finish();
        Member memory mx = c.getMember(x);
        Member memory my = c.getMember(y);
        assertEq(mx.savings, my.savings, "savings");
        assertEq(mx.weight, my.weight, "weight");
        uint256 bx = usdc.balanceOf(x);
        uint256 by = usdc.balanceOf(y);
        vm.prank(x);
        c.withdraw();
        vm.prank(y);
        c.withdraw();
        assertEq(usdc.balanceOf(x) - bx, usdc.balanceOf(y) - by, "P5");
    }

    // The same action for both; skipped while a settlement is part-way (X and Y may sit in different batches).
    function _mirror(address x, address y, uint256 s) internal {
        if (c.getCircleState().cursor != 0) return;
        uint256 k = s % 5;
        uint256 e = c.currentEpoch();
        address[2] memory pair = [x, y];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(pair[i]);
            if (k == 0) address(c).call(abi.encodeCall(KuberCircle.payNow, ()));
            else if (k == 1) usdc.approve(address(c), 0);
            else if (k == 2) usdc.approve(address(c), type(uint256).max);
            else if (k == 3) address(c).call(abi.encodeCall(KuberCircle.catchUp, (1 + (s >> 8) % (e == 0 ? 1 : e))));
            else address(c).call(abi.encodeCall(KuberCircle.claim, ()));
            vm.stopPrank();
        }
    }

    /// @dev 07 D-03: with a positive pot, a manager in place, and every member paid up for the exit epoch (so the
    /// collect pass changes nothing), exitValueOf's quote is exact: after the settlement the treasury's claimable rose
    /// by protocolFee, the manager's by managerFee, the leaver's by payout.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (80 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_feeConservationAtExit(uint256 seed) public {
        _system(seed);
        uint256 target = 4 + seed % 3;
        for (uint256 i; i < 200 && c.currentEpoch() < target; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, "fee", i)));
            h.act(s % 100, s / 100);
        }
        _next();
        address mgr = c.getCircleState().manager;
        if (mgr == address(0)) {
            address[] memory pool = h.poolOf(0);
            mgr = pool[seed % pool.length];
            vm.prank(_proposer(mgr));
            uint256 id = c.propose(ProposalKind.Manager, abi.encode(mgr));
            _voteAllBut(id, address(0));
            _next();
            assertEq(c.getCircleState().manager, mgr, "manager appointed");
        }
        int256 pot = c.getPublicSummary().yieldPot;
        usdc.mint(address(c), (pot < 0 ? uint256(-pot) : 0) + 500e6 + seed % 500e6);
        address a = _leaver(seed, mgr);
        if (a == address(0)) return;
        _payUpAll();
        vm.prank(a);
        c.requestLeave();
        // Quoted after the warp: the vault yield of the epoch is part of the settlement's pot.
        _warpNext();
        (uint256 payout,, uint256 pf, uint256 mf) = c.exitValueOf(a);
        assertGt(pf, 0, "positive share");
        address treasury = registry.treasury();
        uint256 t0 = c.getMember(treasury).claimable;
        uint256 m0 = c.getMember(mgr).claimable;
        uint256 l0 = c.getMember(a).claimable;
        vm.txGasPrice(25e9);
        c.settle(type(uint256).max);
        assertEq(uint8(c.getMember(a).status), uint8(MemberStatus.Left), "left");
        assertEq(c.getMember(treasury).claimable, t0 + pf, "treasury credited protocolFee");
        assertEq(c.getMember(mgr).claimable, m0 + mf, "manager credited managerFee");
        assertEq(c.getMember(a).claimable, l0 + payout, "leaver credited payout");
    }

    // An Active member with minSaveEpochs paid, other than `not` (a fresh epoch, so nobody proposed yet).
    function _proposer(address not) internal view returns (address) {
        address[] memory list = c.members();
        uint256 minSave = c.getCircleState().fixedParams.minSaveEpochs;
        for (uint256 i; i < list.length; ++i) {
            Member memory m = c.getMember(list[i]);
            if (list[i] != not && m.status == MemberStatus.Active && m.paidCount >= minSave) return list[i];
        }
        return address(0);
    }

    // A free member with savings who is not the manager or in the pool.
    function _leaver(uint256 seed, address mgr) internal view returns (address) {
        address[] memory list = c.members();
        for (uint256 j; j < list.length; ++j) {
            address t = list[(seed % list.length + j) % list.length];
            Member memory m = c.getMember(t);
            if (t == mgr || h.isPool(t) || m.status != MemberStatus.Active || m.savings == 0) continue;
            if (m.activeLoanId == 0 && m.pendingRequestId == 0 && m.pledgedOut == 0 && !m.leavePending) return t;
        }
        return address(0);
    }

    // Every Active member pays this epoch's contribution and every installment due, so the collect pass has nothing.
    function _payUpAll() internal {
        address[] memory list = c.members();
        uint64 bit = uint64(1) << c.currentEpoch();
        for (uint256 i; i < list.length; ++i) {
            Member memory m = c.getMember(list[i]);
            if (m.status != MemberStatus.Active) continue;
            vm.startPrank(list[i]);
            usdc.approve(address(c), type(uint256).max);
            if (m.paidBitmap & bit == 0) c.payNow();
            for (uint256 j; j < 4 && m.activeLoanId != 0; ++j) {
                (bool ok,) = address(c).call(abi.encodeCall(KuberCircle.payArrears, (3)));
                if (!ok) break;
            }
            vm.stopPrank();
        }
    }
}

/// @dev P6 (DECISIONS R-S): a fully backed request with no extra, the oldest aged request, whose amount fits total
/// capacity, is funded at its third funding settlement at the latest; 07-02's QueueFairness run with R's request
/// backed (a voucher and an agreer cover the part above its own limit).
contract PropertiesP6Test is QueueFairnessBase {
    function testFuzz_P6_backedOldestFundedByThirdPass(uint256 seed) public {
        _p6(seed, true);
    }
}
