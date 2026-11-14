// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    BPS,
    FixedParams,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    Member,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev TEST_PLAN P6 / DECISIONS R-S P6: a request with no extra that fits total capacity is funded by its third
/// funding pass while extra-paying requests keep arriving. 12 members, 10 epochs, allocation 10/40/40/10, per-loan
/// max 100%, fast lane 30%, ownRate 3%, APY 0. The helper is shared with 07-03's Properties (the backed variant).
abstract contract QueueFairnessBase is LoanTestBase {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant T = 10;

    function _start12() internal returns (KuberCircle c, address[] memory ms) {
        return _start12(3_000);
    }

    function _start12(uint16 fastBps) internal returns (KuberCircle c, address[] memory ms) {
        ms = _newMembers(12);
        FixedParams memory f = _fixed();
        f.totalEpochs = uint8(T);
        f.maxMembers = 50;
        RuleParams memory r = _rules();
        r.alloc = _alloc(1_000, 4_000, 4_000, 1_000);
        r.perLoanMaxBps = 10_000;
        r.fastLaneBps = fastBps;
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("p6", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < 12; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        vm.warp(f.startTime);
        c.activate();
        _openEpoch3(c, ms); // everyone prepays epoch 3: savings 300e6, paidCount 3
    }

    function _v(KuberCircle c) internal view returns (uint256) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        return assets > liabilities ? assets - liabilities : 0;
    }

    struct Run {
        KuberCircle c;
        address[] ms;
        uint256 seed;
        uint256 amount;
        uint256 passes;
    }

    /// @dev Outcome: 1 funded before pass 3, 3 funded at pass 3, 9 precondition (fits total capacity) failed at pass 3.
    /// With `backed`, R asks 280..360e6: its 270e6 own part plus a 10..90e6 need that m11 vouches and m10 agrees.
    function _p6(uint256 seed, bool backed) internal returns (uint256 outcome) {
        Run memory s;
        s.seed = seed;
        // Half the runs at the fast-lane bound (50%), where extra payers can push a line request out more often.
        (s.c, s.ms) = _start12(seed % 2 == 0 ? 5_000 : 3_000);
        s.amount = 200e6 + (seed >> 1) % 70_000_001; // 200..270e6, own part only (≤ 90% of 300e6)
        if (backed) s.amount = 280e6 + (seed >> 1) % 80_000_001;
        _request(s.c, s.ms[1], s.amount, 1, 0); // id 1, the oldest request for the whole run
        if (backed) {
            uint256 need = s.amount - 270e6;
            vm.prank(s.ms[11]);
            s.c.vouch(1, need / 2);
            vm.prank(s.ms[10]);
            s.c.agree(1, need - need / 2);
        }
        uint256 e = 3;
        while (true) {
            bool cu = uint256(keccak256(abi.encode(seed, e, "cu"))) % 3 == 0 && e + 2 <= T - 1;
            _arrivals(s, e, cu ? e + 1 : e);
            uint256 k;
            if (cu) {
                // A catch-up settlement in between: no funding, no age.
                uint256 age = s.c.getLoan(1).age;
                _warpTo(s.c, e + 2, false);
                s.c.settle(MAX);
                assertEq(uint256(s.c.getLoan(1).status), uint256(LoanStatus.Pending), "funded in catch-up");
                assertEq(s.c.getLoan(1).age, age, "aged in catch-up");
                k = e + 1;
            } else {
                _warpTo(s.c, e + 1, false);
                k = e;
            }
            s.c.settle(MAX);
            s.passes += 1;
            Loan memory r = s.c.getLoan(1);
            if (r.status == LoanStatus.Funded) {
                assertEq(r.fundedEpoch, k, "fundedEpoch");
                assertLe(s.passes, 3, "funded after pass 3");
                if (s.passes == 3) assertEq(uint256(r.lane), uint256(Lane.Aged), "pass 3 lane");
                return s.passes == 3 ? 3 : 1;
            }
            assertEq(r.age, s.passes, "age = funding passes");
            if (s.passes == 3) {
                // Not funded at pass 3: the P6 precondition must have failed (amount above the capacity at funding).
                assertGt(s.amount, _capAtFunding(s, k), "P6 violated");
                return 9;
            }
            e = k + 1;
            if (e + 1 + 1 > T) return 9;
        }
    }

    // Every epoch: one extra payer sized near the fast budget (90..200e6), plus 0 to 2 random extra payers
    // (1..270e6); random extras and terms.
    function _arrivals(Run memory s, uint256 e, uint256 kNext) internal {
        // A third of the runs: an adversary that exactly fills the next pass's fast budget (computed as if the aged
        // lane did not exist) with the maximum extra.
        bool adversary = s.seed % 3 == 0;
        uint256 nArr = 1 + uint256(keccak256(abi.encode(s.seed, e, "n"))) % 3;
        for (uint256 j; j < nArr; ++j) {
            uint256 r = uint256(keccak256(abi.encode(s.seed, e, j)));
            address who = s.ms[2 + r % 10];
            Member memory m = s.c.getMember(who);
            if (m.activeLoanId != 0 || m.pendingRequestId != 0) continue;
            uint256 rep = 1 + (r >> 8) % 3;
            if (e + 1 + rep > T) rep = T - e - 1;
            uint256 amt = j == 0 ? 90e6 + (r >> 16) % 110e6 : 1e6 + (r >> 16) % 270e6;
            uint256 extra = 1 + (r >> 40) % 1_000;
            if (j == 0 && adversary) {
                amt = _predictCap(s, kNext) * s.c.getCircleState().rules.fastLaneBps / BPS;
                extra = 1_000;
                if (amt == 0 || amt > 270e6) continue;
            }
            vm.prank(who);
            try s.c.requestLoan(amt, rep, 0, extra) {} catch {}
        }
    }

    // Capacity at the funding step of settle(k): V is unchanged by funding and the rebalance (APY 0), and the
    // outstanding principal before funding is the current one minus what this pass funded.
    function _capAtFunding(Run memory s, uint256 k) internal view returns (uint256) {
        uint256 funded;
        uint256 n = _h(s.c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = s.c.getLoan(id);
            if (l.lane != Lane.None && l.fundedEpoch == k) funded += l.amount;
        }
        uint256 bucket = _v(s.c) * 1_000 / BPS;
        uint256 before = s.c.getPublicSummary().outstandingPrincipal - funded;
        return bucket > before ? bucket - before : 0;
    }

    // Capacity the funding step of settle(k) will see: V = 1_200e6 × k (APY 0, every contribution auto-debited) and
    // the outstanding principal minus the principal parts the collect pass of k will pull.
    function _predictCap(Run memory s, uint256 k) internal view returns (uint256) {
        uint256 o = s.c.getPublicSummary().outstandingPrincipal;
        uint256 n = _h(s.c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = s.c.getLoan(id);
            if (l.status != LoanStatus.Funded) continue;
            for (uint256 i = l.installmentsPaid; i < l.repayEpochs && uint256(l.fundedEpoch) + 2 + i <= k; ++i) {
                o -= l.amount / l.repayEpochs + (i + 1 == l.repayEpochs ? l.amount % l.repayEpochs : 0);
            }
        }
        uint256 bucket = 1_200e6 * k * 1_000 / BPS;
        return bucket > o ? bucket - o : 0;
    }
}

contract QueueFairnessTest is QueueFairnessBase {
    /// @dev Deterministic: R (265e6, no extra) loses the line at passes 1 and 2 to extra payers and would lose pass
    /// 3 too without the aged lane (fast lane 113_370_000 would leave 264_530_000 < 265e6).
    function test_P6_noExtraRequestFundedAtThirdPassDespiteExtraPayers() public {
        (KuberCircle c, address[] memory ms) = _start12();
        address R = ms[1];
        _request(c, R, 265e6, 1, 0); // id 1
        _request(c, ms[2], 108e6, 3, 300); // id 2: X1
        _request(c, ms[3], 105e6, 3, 100); // id 3: X1b

        // Pass 1, settle(3): V 3_600e6, cap 360e6, fast 108e6 -> X1; line R 265e6 > 252e6 skipped; spill back X1b.
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(1).age, 1);
        assertEq(uint256(c.getLoan(2).lane), uint256(Lane.Fast));
        assertEq(uint256(c.getLoan(3).lane), uint256(Lane.Fast));
        assertEq(c.getPublicSummary().outstandingPrincipal, 213e6);

        // Pass 2, settle(4): cap 480e6 − 213e6 = 267e6 (R fits), fast 80_100_000 -> X2; line 186_900_000 < R.
        _request(c, ms[4], 80_100_000, 3, 1_000); // id 4: X2
        _settleAt(c, 5);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(1).age, 2);
        assertEq(uint256(c.getLoan(4).lane), uint256(Lane.Fast));
        assertEq(c.getPublicSummary().outstandingPrincipal, 293_100_000);

        // Pass 3, settle(5): collect repays 36e6 + 35e6; cap 600e6 − 222_100_000 = 377_900_000. Aged R first.
        _request(c, ms[5], 113_370_000, 3, 1_000); // id 5: X3
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Aged);
        c.settle(MAX);
        Loan memory r = c.getLoan(1);
        assertEq(uint256(r.lane), uint256(Lane.Aged));
        assertEq(r.fundedEpoch, 5);
        assertEq(r.saverInterest, 7_950_000);
        assertEq(uint256(c.getLoan(5).status), uint256(LoanStatus.Pending));
        assertEq(c.getPublicSummary().outstandingPrincipal, 487_100_000);
    }

    function testFuzz_P6_fundedByThirdPass(uint256 seed) public {
        _p6(seed, false);
    }

    /// @dev Non-vacuity: over 96 seeds, count the outcomes; some must reach pass 3 and be funded there (aged lane).
    function test_P6_outcomeCounts() public {
        uint256[10] memory cnt;
        for (uint256 seed; seed < 96; ++seed) {
            uint256 snap = vm.snapshotState();
            cnt[_p6(seed, false)] += 1;
            vm.revertToState(snap);
        }
        emit log_named_uint("funded before pass 3", cnt[1]);
        emit log_named_uint("funded at pass 3 (aged)", cnt[3]);
        emit log_named_uint("precondition failed at pass 3", cnt[9]);
        assertGt(cnt[3], 0, "no run reached pass 3");
    }
}
