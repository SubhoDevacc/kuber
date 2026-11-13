// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Backing as Pledge,
    CircleStatus,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";
import {ReviewHarness} from "../utils/ReviewHarness.sol";

/// @dev M5 review IN-01 fuzz: the D-22 world plus catchUp, stalled settlements (catch-up mode, pay-class calls dated
/// after the epoch being settled), repayDebt / claim / payNow / applyFreed between and inside batches, and checks of
/// every running total, I1, both weight sums, and the yield pot never going negative (vault APY 0, no shocks: a
/// negative pot is a group loss). Any settle revert fails the run.
contract ReviewFuzzTest is BackingTestBase {
    uint256 private constant N = 12;
    uint8 private constant T = 12;

    mapping(address => bool) private touched;
    uint256 public settlesDone;
    // Share of members (out of 4) who start with no allowance, so they miss rounds and catch up later.
    uint256 private lateOf4 = 1;
    // suspensions(debt>0), debt-0 defaults, catchUps, reinstatements, catch-up settles, repayDebt ok, seizures,
    // applyFreed that repaid something
    uint256[8] public cov;

    function test_review_coverage() public {
        uint256[8] memory tot;
        // Four whole runs per call: more exceed the default memory and gas limits of one test.
        for (uint256 seed; seed < 4; ++seed) {
            uint256 snap = vm.snapshotState();
            if (seed % 2 == 0) _run(seed, 9_000, 0, 1_000);
            else _run(seed, 9_000, 300, 1_000);
            for (uint256 j; j < 8; ++j) {
                tot[j] += cov[j];
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("suspensions (debt > 0)", tot[0]);
        emit log_named_uint("debt-0 defaults", tot[1]);
        emit log_named_uint("catchUps", tot[2]);
        emit log_named_uint("reinstatements", tot[3]);
        emit log_named_uint("catch-up settles (funding skipped)", tot[4]);
        emit log_named_uint("repayDebt ok", tot[5]);
        emit log_named_uint("seizures (fromV+fromA>0)", tot[6]);
        emit log_named_uint("applyFreed repaid", tot[7]);
    }

    function _implementation() internal override returns (address) {
        return address(new ReviewHarness());
    }

    function testFuzz_review_fines(uint256 seed) public {
        _run(seed, 9_000, 300, 1_000);
    }

    function testFuzz_review_finesFullLtv(uint256 seed) public {
        _run(seed, 10_000, 2_000, 5_000);
    }

    function testFuzz_review_zeroFines(uint256 seed) public {
        _run(seed, 9_000, 0, 1_000);
    }

    function testFuzz_review_zeroFinesZeroPenalty(uint256 seed) public {
        _run(seed, 9_000, 0, 0);
    }

    /// CR-01's shape: fines 0 and three in four members start late, so qualifying rounds are often dated late.
    function testFuzz_review_zeroFinesLateSavers(uint256 seed) public {
        lateOf4 = 3;
        _run(seed, 9_000, 0, 1_000);
    }

    function _rnd(uint256 seed, bytes memory tag) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }

    function _run(uint256 seed, uint16 ltv, uint16 fineBps, uint16 penaltyBps) private {
        (KuberCircle c, address[] memory m) = _setupRun(seed, ltv, fineBps, penaltyBps);
        _loop(c, m, seed);
        _finish(c, m);
    }

    function _setupRun(uint256 seed, uint16 ltv, uint16 fineBps, uint16 penaltyBps)
        private
        returns (KuberCircle c, address[] memory m)
    {
        m = _newMembers(N);
        address[] memory order = new address[](N);
        for (uint256 i; i < N; ++i) {
            usdc.mint(m[i], 90_000e6);
            order[i] = m[i];
        }
        for (uint256 i = N - 1; i > 0; --i) {
            uint256 j = _rnd(seed, abi.encode("perm", i)) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 10_000;
        r.ownLtvBps = ltv;
        r.installFineBps = fineBps;
        r.penaltyBps = penaltyBps;
        c = _startPeople(order, T, r);
        for (uint256 i; i < N; ++i) {
            // Some members start with no allowance, so they miss rounds and later catch up.
            vm.prank(m[i]);
            usdc.approve(address(c), _rnd(seed, abi.encode("allow0", i)) % 4 < lateOf4 ? 0 : 50_000e6);
        }
        _activate(c);
    }

    function _loop(KuberCircle c, address[] memory m, uint256 seed) private {
        uint256 clock = 1;
        uint256 step;
        while (c.getCircleState().status == CircleStatus.Active) {
            ++step;
            uint256 s = _rnd(seed, abi.encode("step", step));
            // Action class only when nothing is pending and the window is OPEN (we sit at an epoch start).
            if (c.getCircleState().settledEpoch + 1 == clock && clock >= 3 && clock <= T) {
                _act(c, m, seed, step);
                _back(c, m, seed, step);
            }
            // Advance 1 epoch, sometimes 2-4 (catch-up mode).
            clock += s % 5 == 0 ? 2 + (s >> 8) % 3 : 1;
            _warpTo(c, clock, false);
            _pay(c, m, seed, step);
            _settleSome(c, m, seed, step, clock, s);
        }
    }

    function _settleSome(KuberCircle c, address[] memory m, uint256 seed, uint256 step, uint256 clock, uint256 s)
        private
    {
        // Settle pending epochs one by one; sometimes leave the last one pending for the next step.
        uint256 pending = clock - 1 - c.getCircleState().settledEpoch;
        uint256 todo = (s >> 20) % 3 == 0 && pending > 1 ? pending - 1 : pending;
        for (uint256 t; t < todo && c.getCircleState().status == CircleStatus.Active; ++t) {
            _settleOne(c, m, seed, step * 100 + t);
            _check(c, m);
        }
    }

    function _finish(KuberCircle c, address[] memory m) private {
        uint256 bal = usdc.balanceOf(address(c));
        uint256 paid;
        for (uint256 i; i < N; ++i) {
            uint256 b0 = usdc.balanceOf(m[i]);
            vm.prank(m[i]);
            c.withdraw();
            paid += usdc.balanceOf(m[i]) - b0;
        }
        assertLe(paid, bal, "paid out more than the balance");
    }

    function _act(KuberCircle c, address[] memory m, uint256 seed, uint256 step) private {
        for (uint256 i = 3; i < N; ++i) {
            address a = m[i];
            uint256 s = _rnd(seed, abi.encode("act", step, i));
            vm.startPrank(a);
            if (s % 3 == 1) {
                try c.requestLoan(
                    50e6 + (s >> 16) % 900e6, 1 + (s >> 48) % 3, (s >> 120) % 2_000, (s >> 140) % 2 == 0 ? 0 : 100
                ) {
                    touched[a] = true;
                } catch {}
            }
            if ((s >> 200) % 9 == 0) {
                uint32[] memory q = c.getQueue();
                if (q.length != 0) {
                    try c.unback(q[(s >> 210) % q.length]) {} catch {}
                }
            }
            if ((s >> 220) % 13 == 0 && c.getMember(a).pendingRequestId != 0) {
                try c.cancelRequest(c.getMember(a).pendingRequestId) {} catch {}
            }
            vm.stopPrank();
        }
    }

    /// Pay class in the clock epoch, pending settlements or not: payNow, catchUp, payArrears, repayAll, claim,
    /// repayDebt, allowance flips.
    function _pay(KuberCircle c, address[] memory m, uint256 seed, uint256 step) private {
        for (uint256 i; i < N; ++i) {
            address a = m[i];
            uint256 s = _rnd(seed, abi.encode("pay", step, i));
            vm.startPrank(a);
            if (i < 3 || s % 4 != 0) {
                try c.payNow() {} catch {}
            }
            if (s % 5 == 1) {
                Member memory x = c.getMember(a);
                for (uint256 ep = 1; ep <= T; ++ep) {
                    if (x.missedBitmap & (uint64(1 << ep)) != 0 && x.paidBitmap & (uint64(1 << ep)) == 0) {
                        try c.catchUp(ep) {
                            ++cov[2];
                        } catch {}
                    }
                }
            }
            if (i >= 3) {
                if (s % 3 == 0) {
                    try c.claim() {} catch {}
                }
                if (s % 7 == 1) {
                    try c.repayAll() {} catch {}
                } else if (s % 7 == 2) {
                    try c.payArrears(1) {} catch {}
                }
                Member memory y = c.getMember(a);
                if (y.activeLoanId != 0) {
                    // Borrowers often claim and revoke, which drives defaults (and later catch-ups).
                    if ((s >> 30) % 2 == 0) usdc.approve(address(c), 0);
                } else if (s % 5 == 2) {
                    usdc.approve(address(c), (s >> 8) % 3 == 0 ? 50_000e6 : 0);
                } else if (s % 5 == 3) {
                    usdc.approve(address(c), 50_000e6);
                }
                if ((s >> 60) % 3 == 0) _applyFreed(c, m[(s >> 64) % N]);
                uint256 d = c.debtOf(a);
                if (d != 0 && (s >> 180) % 2 == 0) {
                    usdc.approve(address(c), 50_000e6);
                    try c.repayDebt((s >> 190) % 2 == 0 ? d : 1 + (s >> 192) % d) {
                        ++cov[5];
                    } catch {}
                }
            }
            vm.stopPrank();
        }
    }

    function _back(KuberCircle c, address[] memory m, uint256 seed, uint256 step) private {
        uint32[] memory q = c.getQueue();
        for (uint256 j; j < q.length; ++j) {
            Loan memory l = c.getLoan(q[j]);
            uint256 need = l.backedNeed - _sum(l.vouchers) - _sum(l.agreers);
            for (uint256 t; t < 6 && need != 0; ++t) {
                uint256 s = _rnd(seed, abi.encode("back", step, q[j], t));
                address a = m[3 + s % 9];
                bool agree = (s >> 8) % 2 == 0;
                uint256 amt = t == 5 || (s >> 9) % 3 == 0 ? need : 1 + (s >> 16) % need;
                if (agree && amt > 100e6) amt = 100e6;
                Member memory x = c.getMember(a);
                if (amt > x.savings - x.pledgedOut) amt = x.savings - x.pledgedOut;
                if (amt == 0) continue;
                vm.prank(a);
                if (agree) {
                    try c.agree(q[j], amt) {
                        need -= amt;
                        touched[a] = true;
                    } catch {}
                } else {
                    try c.vouch(q[j], amt) {
                        need -= amt;
                        touched[a] = true;
                    } catch {}
                }
            }
        }
    }

    function _settleOne(KuberCircle c, address[] memory m, uint256 seed, uint256 tag) private {
        uint256 target = c.getCircleState().settledEpoch + 1;
        if (
            block.timestamp
                >= c.getCircleState().fixedParams.startTime + uint256(target + 1)
                    * c.getCircleState().fixedParams.epochDuration
        ) ++cov[4];
        vm.recordLogs();
        uint256 bs = 1 + _rnd(seed, abi.encode("batch", tag)) % 12;
        c.settle(bs);
        for (
            uint256 b;
            c.getCircleState().settledEpoch < target && c.getCircleState().status == CircleStatus.Active;
            ++b
        ) {
            address a = m[3 + _rnd(seed, abi.encode("mid", tag, b)) % 9];
            uint256 s = _rnd(seed, abi.encode("midop", tag, b));
            vm.startPrank(a);
            if (s % 4 == 0) {
                try c.payArrears(1) {} catch {}
            } else if (s % 4 == 1) {
                try c.claim() {} catch {}
            } else if (s % 4 == 2) {
                try c.payNow() {} catch {}
            } else if ((s >> 4) % 2 == 0) {
                _applyFreed(c, m[(s >> 12) % N]);
            } else if (c.debtOf(a) != 0) {
                usdc.approve(address(c), 50_000e6);
                try c.repayDebt(1 + (s >> 8) % 300e6) {} catch {}
            }
            vm.stopPrank();
            c.settle(bs);
        }
        ++settlesDone;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 x; x < logs.length; ++x) {
            if (logs[x].emitter != address(c)) continue;
            if (logs[x].topics[0] == IKuberCircleEvents.MemberReinstated.selector) ++cov[3];
            if (logs[x].topics[0] != IKuberCircleEvents.MemberSuspended.selector) continue;
            (,, uint256 fromV, uint256 fromA,, uint256 debt) =
                abi.decode(logs[x].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            if (debt == 0) ++cov[1];
            else ++cov[0];
            if (fromV + fromA != 0) ++cov[6];
        }
    }

    /// Pay class, anyone (R-N3 exception): reverts only for a member who is not paused.
    function _applyFreed(KuberCircle c, address t) private {
        uint256 d = c.debtOf(t);
        try c.applyFreed(t) {
            if (c.debtOf(t) < d) ++cov[7];
        } catch {
            assertTrue(c.getMember(t).status != MemberStatus.Suspended, "applyFreed reverted for a paused member");
        }
    }

    struct Sums {
        uint256 claims;
        uint256 wa;
        uint256 ws;
        uint256 st;
        uint256 sa;
        uint256 ss;
        uint256 rw;
        uint256 e;
    }

    function _check(KuberCircle c, address[] memory m) private view {
        if (c.getCircleState().status != CircleStatus.Active) return;
        ReviewHarness h = ReviewHarness(address(c));
        Sums memory z;
        {
            (uint256 la, uint256 ls) = h.lasts();
            z.e = la > ls ? la : ls;
            uint256 k = c.getCircleState().settledEpoch;
            if (k > z.e) z.e = k;
        }
        for (uint256 i; i < N; ++i) {
            _member(c, h, m[i], z);
        }
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        (uint256 sTotal, uint256 sActive, uint256 sSaver, uint256 rewardsOwed,) = h.totals();
        assertEq(p.reservedClaims, z.claims, "I3 reservedClaims");
        assertEq(sTotal, z.st, "sTotal");
        assertEq(sActive, z.sa, "sActive");
        assertEq(sSaver, z.ss, "sSaver");
        assertEq(rewardsOwed, z.rw, "totalRewardsOwed");
        uint256 unpaid;
        uint256 n = h.loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            if (l.status == LoanStatus.Funded) unpaid += l.amount - l.principalRepaid;
        }
        assertEq(p.outstandingPrincipal, unpaid, "I4");
        assertEq(z.wa, h.wActiveAt(z.e), "W_active");
        assertEq(z.ws, h.wSaverAt(z.e), "W_saver");
        // APY 0 and no shock: any negative pot beyond vault rounding dust is a group loss.
        assertGe(p.yieldPot, -int256(20), "yield pot negative (group loss)");
    }

    function _member(KuberCircle c, ReviewHarness h, address a, Sums memory z) private view {
        Member memory x = c.getMember(a);
        assertGe(x.savings, x.pledgedOut, "I1");
        z.claims += x.claimable;
        z.st += x.savings;
        z.rw += x.rewards;
        if (!touched[a]) {
            assertEq(x.savings, 100e6 * uint256(x.paidCount), "untouched member lost savings");
        }
        if (x.status != MemberStatus.Active) return;
        z.sa += x.savings;
        uint256 w = h.weightAt(a, z.e);
        z.wa += w;
        if (!x.everBorrowed) {
            z.ss += x.savings;
            z.ws += w;
        }
    }

    function _sum(Pledge[] memory bs) private pure returns (uint256 s) {
        for (uint256 i; i < bs.length; ++i) {
            assertLe(bs[i].loss, bs[i].amount, "loss over pledge");
            s += bs[i].amount;
        }
    }
}
