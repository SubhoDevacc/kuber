// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {BPS, IKuberCircleEvents, Lane, Loan, LoanStatus, Member} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev D-19 with the 04-ADDENDUM A-5 branches: random requests (many tiny, some large), raiseExtra, cancel and
/// re-request, claims, repayAll / payArrears, allowance changes, and random catch-up settlements on a 12-member,
/// 12-epoch circle (allocation 20/40/30/10, per-loan max 25%, APY 0). Besides the planned checks, a reference model
/// (from 04-02's scratch QModel) replays every funding pass, and the logs are checked against the R-H fine rule.
contract LoanFuzzTest is LoanTestBase {
    uint256 private constant MAX = type(uint256).max;
    uint256 private constant T = 12;

    // Per loan id: bit i set once installment i was paid / recorded missed (each run starts from fresh storage).
    mapping(uint256 => uint256) private paidBits;
    mapping(uint256 => uint256) private missedBits;

    struct S {
        KuberCircle c;
        address[] m;
        uint256 seed;
    }

    // A pending request just before a funding settlement.
    struct Snap {
        uint256 id;
        uint256 amount;
        uint256 own;
        uint256 extra;
        uint256 age;
        uint256 backed;
        uint256 r;
    }

    // The model's funding pass: per request 0 waiting, 1 eligible, 2 funded, 3 expired.
    struct M {
        uint8[] st;
        Lane[] lane;
        uint256 cap;
        uint256 cap0;
        uint256 maxLoan;
        uint256 oFund;
        uint256 k;
    }

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (40 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_D19_queueAndRepayInvariants(uint256 seed) public {
        S memory s;
        s.seed = seed;
        (s.c, s.m) = _startLoans(12, uint8(T), _alloc(2_000, 4_000, 3_000, 1_000), 2_500);
        _settleAt(s.c, 2);
        _settleAt(s.c, 3);
        _settleAt(s.c, 4);
        uint256 e = 4;
        vm.recordLogs();
        while (e <= 11) {
            _actions(s, e);
            _checkLogs(s.c, e - 1, 0);
            _ledger(s);
            uint32[] memory before = s.c.getQueue();
            Snap[] memory b = _snap(s.c, before);
            uint256 n0 = _h(s.c).loanCount();
            if (uint256(keccak256(abi.encode(seed, e, "b"))) % 4 == 0 && e + 2 <= T) {
                // settle(e) at clock e + 2 is catching up: it funds nothing and leaves the queue as it was.
                _warpTo(s.c, e + 2, false);
                s.c.settle(MAX);
                _checkLogs(s.c, e - 1, e);
                for (uint256 id = 1; id <= n0; ++id) {
                    Loan memory l = s.c.getLoan(id);
                    assertFalse(l.lane != Lane.None && l.fundedEpoch == e, "funded in catch-up");
                }
                _sameQueue(s.c, b, before);
                _ledger(s);
                _misses(s.c, e);
                _fundingSettle(s, before, b, e + 1);
                e += 2;
            } else {
                _warpTo(s.c, e + 1, false);
                _fundingSettle(s, before, b, e);
                e += 1;
            }
        }
    }

    function _actions(S memory s, uint256 e) private {
        for (uint256 i; i < s.m.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(s.seed, e, i)));
            Member memory mm = s.c.getMember(s.m[i]);
            vm.startPrank(s.m[i]);
            if (r % 7 == 2) usdc.approve(address(s.c), (r >> 8) % 2 == 0 ? 0 : 5_000e6);
            if (mm.pendingRequestId != 0 && r % 5 == 0) {
                try s.c.raiseExtra(mm.pendingRequestId, (r >> 8) % 1_001) {} catch {}
            } else if (mm.pendingRequestId != 0 && r % 11 == 1) {
                try s.c.cancelRequest(mm.pendingRequestId) {} catch {}
            } else if (mm.activeLoanId != 0 && r % 3 == 0) {
                if (mm.claimable != 0) s.c.claim();
                if ((r >> 4) % 2 == 0) {
                    try s.c.repayAll() {} catch {}
                } else {
                    try s.c.payArrears(1 + (r >> 100) % 3) {} catch {}
                }
            }
            // After a cancel this is the re-request.
            uint256 amount = r % 4 == 0 ? 1 + (r >> 20) % 5e6 : 1 + (r >> 20) % 300e6;
            uint256 extra = (r >> 40) % 3 == 0 ? 0 : ((r >> 48) % 4 == 0 ? 500 : (r >> 56) % 1_001);
            try s.c.requestLoan(amount, 1 + (r >> 64) % 3, 0, extra) {} catch {}
            vm.stopPrank();
        }
    }

    function _fundingSettle(S memory s, uint32[] memory before, Snap[] memory b, uint256 k) private {
        uint256 o0 = s.c.getPublicSummary().outstandingPrincipal;
        uint256 pr0 = _principalOff(s.c);
        s.c.settle(MAX);
        _checkLogs(s.c, k - 1, k);
        _check(s, before, k);
        _ledger(s);
        _misses(s.c, k);
        // The collect pass runs before funding, so the principal it repaid or defaulted is off the capacity already.
        _model(s.c, b, o0 - (_principalOff(s.c) - pr0), k);
    }

    /// @dev The planned checks after funding settlement k (D-19, A-5).
    function _check(S memory s, uint32[] memory before, uint256 k) private view {
        _subsequence(s.c.getQueue(), before);
        uint256 v = _v(s.c);
        bool any;
        uint256 n = _h(s.c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = s.c.getLoan(id);
            if (l.lane == Lane.None || l.fundedEpoch != k) continue;
            any = true;
            assertTrue(_has(before, id), "funded id was not pending");
            assertLe(l.amount, v * 2_000 * 2_500 / (BPS * BPS), "above per-loan max");
            uint256 si = uint256(l.ownPart) * l.ownRateBps / BPS;
            if (l.lane == Lane.Fast) {
                assertGt(l.extraBps, 0, "fast without extra");
                si += uint256(l.amount) * l.extraBps / BPS;
            } else if (l.lane == Lane.Line) {
                assertEq(l.extraBps, 0, "line with extra");
            } else {
                assertGe(l.age, 2, "aged lane age");
            }
            assertEq(l.saverInterest, si, "interest");
        }
        if (any) assertLe(s.c.getPublicSummary().outstandingPrincipal, v * 2_000 / BPS, "over capacity");
    }

    /// @dev I3, I4, principal repaid in installment order, and V == sTotal (APY 0, no losses: any token taken or paid
    /// without its ledger entry shows up here).
    function _ledger(S memory s) private view {
        KuberCircle.PublicSummary memory p = s.c.getPublicSummary();
        uint256 unpaid;
        uint256 n = _h(s.c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = s.c.getLoan(id);
            if (l.status == LoanStatus.Funded) unpaid += l.amount - l.principalRepaid;
            uint256 parts =
                l.installmentsPaid == l.repayEpochs ? l.amount : uint256(l.amount) / l.repayEpochs * l.installmentsPaid;
            // A default's step 0 cancels the unclaimed proceeds as repaid principal (M5 D-07).
            if (l.status == LoanStatus.Defaulted) {
                assertTrue(l.principalRepaid == parts || l.principalRepaid == l.amount, "defaulted principal");
            } else {
                assertEq(l.principalRepaid, parts, "principal parts");
            }
            assertEq(l.installmentsPaid == l.repayEpochs, l.status == LoanStatus.Repaid, "repaid iff all paid");
            uint256 mb = missedBits[id];
            assertEq(l.missedCount, (mb & 1) + (mb >> 1 & 1) + (mb >> 2 & 1), "missedCount");
        }
        assertEq(p.outstandingPrincipal, unpaid, "I4");
        uint256 claims;
        for (uint256 i; i < s.m.length; ++i) {
            claims += s.c.getMember(s.m[i]).claimable;
        }
        assertEq(p.reservedClaims, claims, "I3");
        assertEq(p.yieldPot, 0, "ledger");
    }

    /// @dev Every InstallmentPaid since the last call: paid once, oldest first, for the installment plus one fine per
    /// settlement that found it unpaid. All settlements here run in full, so a payment sees lastCollectEpoch ==
    /// `settled` (0 before the loan's first check, which gives the same zero fine). `k`: the emitting settlement, 0
    /// for member actions; a miss is recorded only by settle(due), once.
    function _checkLogs(KuberCircle c, uint256 settled, uint256 k) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 x; x < logs.length; ++x) {
            if (logs[x].emitter != address(c)) continue;
            bytes32 t = logs[x].topics[0];
            if (t == IKuberCircleEvents.InstallmentPaid.selector) {
                uint256 id = uint256(logs[x].topics[1]);
                (uint256 i, uint256 amount) = abi.decode(logs[x].data, (uint256, uint256));
                assertEq(paidBits[id], (1 << i) - 1, "paid once, oldest first");
                paidBits[id] |= 1 << i;
                Loan memory l = c.getLoan(id);
                uint256 a = _part(l.amount, l.repayEpochs, i) + _part(l.saverInterest, l.repayEpochs, i);
                uint256 due = uint256(l.fundedEpoch) + 2 + i;
                uint256 fine = settled + 1 > due ? a * l.installFineBps * (settled + 1 - due) / BPS : 0;
                assertEq(amount, a + fine, "installment + fines");
            } else if (t == IKuberCircleEvents.InstallmentMissed.selector) {
                uint256 id = uint256(logs[x].topics[1]);
                uint256 j = abi.decode(logs[x].data, (uint256));
                assertEq(uint256(c.getLoan(id).fundedEpoch) + 2 + j, k, "missed at settle(due)");
                assertEq(missedBits[id] >> j & 1, 0, "missed once");
                missedBits[id] |= 1 << j;
            }
        }
    }

    /// @dev After settle(k): every installment due in k and still unpaid was recorded as missed.
    function _misses(KuberCircle c, uint256 k) private view {
        uint256 n = _h(c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            if (l.status != LoanStatus.Funded || k < uint256(l.fundedEpoch) + 2) continue;
            uint256 j = k - l.fundedEpoch - 2;
            if (j < l.repayEpochs && j >= l.installmentsPaid) assertEq(missedBits[id] >> j & 1, 1, "miss recorded");
        }
    }

    function _snap(KuberCircle c, uint32[] memory q) private view returns (Snap[] memory b) {
        b = new Snap[](q.length);
        for (uint256 i; i < q.length; ++i) {
            Loan memory l = c.getLoan(q[i]);
            assertEq(uint256(l.status), uint256(LoanStatus.Pending), "queued not pending");
            b[i] = Snap(q[i], l.amount, l.ownPart, l.extraBps, l.age, l.backedNeed, l.repayEpochs);
        }
    }

    function _sameQueue(KuberCircle c, Snap[] memory b, uint32[] memory before) private view {
        uint32[] memory q = c.getQueue();
        assertEq(q.length, before.length, "catch-up changed the queue");
        for (uint256 i; i < q.length; ++i) {
            assertEq(q[i], before[i], "catch-up changed the queue");
            Loan memory l = c.getLoan(b[i].id);
            assertEq(uint256(l.status), uint256(LoanStatus.Pending), "catch-up status");
            assertEq(l.age, b[i].age, "catch-up age");
        }
    }

    function _subsequence(uint32[] memory q, uint32[] memory before) private pure {
        uint256 j;
        for (uint256 i; i < q.length; ++i) {
            while (j < before.length && before[j] != q[i]) {
                ++j;
            }
            assertLt(j, before.length, "queue not a subsequence");
            if (i > 0) assertGt(q[i], q[i - 1], "queue not ascending");
        }
    }

    function _has(uint32[] memory ids, uint256 id) private pure returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    /// @dev Principal no longer outstanding: repaid, or all of it once the loan defaulted (M5 waterfall).
    function _principalOff(KuberCircle c) private view returns (uint256 sum) {
        uint256 n = _h(c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            sum += l.status == LoanStatus.Defaulted ? l.amount : l.principalRepaid;
        }
    }

    /// @dev V from public state: cash + vaults + outstanding − liabilities, floored at 0.
    function _v(KuberCircle c) private view returns (uint256) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        return assets > liabilities ? assets - liabilities : 0;
    }

    function _part(uint256 total, uint256 n, uint256 i) private pure returns (uint256) {
        return total / n + (i + 1 == n ? total % n : 0);
    }

    // Reference model of one funding pass (D-06): an independent selection sort for the fast order.
    function _model(KuberCircle c, Snap[] memory b, uint256 oFund, uint256 k) private view {
        M memory x;
        x.oFund = oFund;
        x.k = k;
        _sim(c, b, x);
        _cmp(c, b, x);
    }

    function _sim(KuberCircle c, Snap[] memory b, M memory x) private view {
        uint256 v = _v(c);
        KuberCircle.CircleState memory s = c.getCircleState();
        uint256 bucket = v * s.rules.alloc.loan / BPS;
        x.cap = bucket > x.oFund ? bucket - x.oFund : 0;
        x.cap0 = x.cap;
        x.maxLoan = v * s.rules.alloc.loan * s.rules.perLoanMaxBps / (BPS * BPS);
        uint256 n = b.length;
        x.st = new uint8[](n);
        x.lane = new Lane[](n);
        for (uint256 i; i < n; ++i) {
            if (x.k + 1 + b[i].r > T) x.st[i] = 3;
            else if (b[i].backed == 0 && b[i].amount <= x.maxLoan) x.st[i] = 1;
        }
        for (uint256 i; i < n; ++i) {
            if (b[i].age >= 2) _fund(b, x, i, x.cap, Lane.Aged);
        }
        uint256[] memory ord = _order(b, x);
        uint256 budget = x.cap * s.rules.fastLaneBps / BPS;
        for (uint256 j; j < ord.length; ++j) {
            budget -= _fund(b, x, ord[j], budget, Lane.Fast);
        }
        for (uint256 i; i < n; ++i) {
            if (b[i].extra == 0) _fund(b, x, i, x.cap, Lane.Line);
        }
        for (uint256 j; j < ord.length; ++j) {
            _fund(b, x, ord[j], x.cap, Lane.Fast);
        }
    }

    function _fund(Snap[] memory b, M memory x, uint256 i, uint256 room, Lane lane) private pure returns (uint256) {
        if (x.st[i] != 1 || b[i].amount > room) return 0;
        x.st[i] = 2;
        x.lane[i] = lane;
        x.cap -= b[i].amount;
        return b[i].amount;
    }

    // Eligible extra payers by highest extra, then lowest index (oldest).
    function _order(Snap[] memory b, M memory x) private pure returns (uint256[] memory ord) {
        uint256 n = b.length;
        uint256[] memory tmp = new uint256[](n);
        bool[] memory used = new bool[](n);
        uint256 m;
        while (true) {
            uint256 best = MAX;
            for (uint256 i; i < n; ++i) {
                if (used[i] || x.st[i] != 1 || b[i].extra == 0) continue;
                if (best == MAX || b[i].extra > b[best].extra) best = i;
            }
            if (best == MAX) break;
            used[best] = true;
            tmp[m++] = best;
        }
        ord = new uint256[](m);
        for (uint256 j; j < m; ++j) {
            ord[j] = tmp[j];
        }
    }

    function _cmp(KuberCircle c, Snap[] memory b, M memory x) private view {
        uint256 funded;
        uint256 kept;
        uint32[] memory q = c.getQueue();
        for (uint256 i; i < b.length; ++i) {
            Loan memory l = c.getLoan(b[i].id);
            if (x.st[i] == 3) {
                assertEq(uint256(l.status), uint256(LoanStatus.Expired), "model: expired");
                assertEq(l.age, b[i].age, "model: expired age");
            } else if (x.st[i] == 2) {
                assertEq(uint256(l.status), uint256(LoanStatus.Funded), "model: funded");
                assertEq(uint256(l.lane), uint256(x.lane[i]), "model: lane");
                assertEq(l.fundedEpoch, x.k, "model: fundedEpoch");
                assertEq(l.age, b[i].age, "model: funded age");
                uint256 si = b[i].own * l.ownRateBps / BPS;
                if (x.lane[i] == Lane.Fast) si += b[i].amount * b[i].extra / BPS;
                assertEq(l.saverInterest, si, "model: saverInterest");
                assertEq(c.getMember(l.borrower).activeLoanId, b[i].id, "model: activeLoanId");
                funded += b[i].amount;
            } else {
                assertEq(uint256(l.status), uint256(LoanStatus.Pending), "model: pending");
                assertEq(l.age, b[i].age + 1, "model: pending age");
                assertEq(q[kept++], b[i].id, "model: queue order");
            }
        }
        assertEq(q.length, kept, "model: queue length");
        assertLe(funded, x.cap0, "model: over capacity");
        assertEq(c.getPublicSummary().outstandingPrincipal, x.oFund + funded, "model: principal");
    }
}
