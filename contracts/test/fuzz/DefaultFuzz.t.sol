// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Backing as Pledge,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev D-22 (P4, I1, the no-loss promise), biased toward seizure: 12 members in a seeded order, members 0..2 pure
/// savers, large backed requests with several backers per tier, older pledges held by later borrowers (R-N3), claims,
/// revoked allowances, repayDebt, pre-payments before settlement, and settlement in random batch sizes with pay calls
/// between batches. `settle` and the final `withdraw`s are never wrapped, so any revert (GroupLoss included) fails.
contract DefaultFuzzTest is BackingTestBase {
    uint256 private constant N = 12;
    uint8 private constant T = 10;
    bytes32 private constant SUSPENDED =
        keccak256("MemberSuspended(uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    // Members that ever vouched, agreed, or requested a loan; everyone else must lose nothing.
    mapping(address => bool) private touched;
    // Coverage: suspensions, voucher seizures, agreer seizures, multi-backer tiers seized, R-N3 DebtRepaid in settle.
    uint256[5] private cov;

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (30 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_D22_seizureInvariants(uint256 seed) public {
        _run(seed, 9_000, 300, 1_000);
    }

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (28 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_D22_ownLtvFull(uint256 seed) public {
        _run(seed, 10_000, 300, 1_000);
    }

    /// @dev Debt-0 defaults: the borrower stays Active and loses savings at effective epoch k.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: full.fuzz.runs = 10000
    /// forge-config: coverage.fuzz.runs = 64
    /// 256 runs in the default profile (28 ms per run, forge test -j 1); the full profile still runs 10,000 (inline settings for default carry over to the other profiles).
    function testFuzz_D22_zeroFinesAndPenalty(uint256 seed) public {
        _run(seed, 9_000, 0, 0);
    }

    function test_D22_seizureCoverage() public {
        uint256[5] memory tot;
        for (uint256 seed; seed < 15; ++seed) {
            uint256 snap = vm.snapshotState();
            _run(seed, 9_000, 300, 1_000);
            for (uint256 j; j < 5; ++j) {
                tot[j] += cov[j];
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("suspensions", tot[0]);
        emit log_named_uint("voucher seizures", tot[1]);
        emit log_named_uint("agreer seizures", tot[2]);
        emit log_named_uint("multi-backer tiers", tot[3]);
        emit log_named_uint("R-N3 DebtRepaid in settlement", tot[4]);
        assertGt(tot[0], 0, "no suspension");
        assertGt(tot[1], 0, "no voucher seizure");
        assertGt(tot[2], 0, "no agreer seizure");
        assertGt(tot[3], 0, "no multi-backer tier");
    }

    function _run(uint256 seed, uint16 ltv, uint16 fineBps, uint16 penaltyBps) private {
        address[] memory m = _newMembers(N);
        address[] memory order = new address[](N);
        for (uint256 i; i < N; ++i) {
            usdc.mint(m[i], 90_000e6);
            order[i] = m[i];
        }
        for (uint256 i = N - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, "perm", i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 10_000;
        r.ownLtvBps = ltv;
        r.installFineBps = fineBps;
        r.penaltyBps = penaltyBps;
        KuberCircle c = _startPeople(order, T, r);
        for (uint256 i; i < N; ++i) {
            vm.prank(m[i]);
            usdc.approve(address(c), 50_000e6);
        }
        _activate(c);
        _payAllBut(c, m, address(0));
        _settleAt(c, 2);
        _payAllBut(c, m, address(0));
        _settleAt(c, 3);
        _payAllBut(c, m, address(0));
        for (uint256 e = 3; e <= T; ++e) {
            _act(c, m, seed, e);
            _back(c, m, seed, e);
            _settle(c, m, seed, e);
            _check(c, m);
        }
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

    function _act(KuberCircle c, address[] memory m, uint256 seed, uint256 e) private {
        for (uint256 i; i < 3; ++i) {
            vm.prank(m[i]);
            try c.payNow() {} catch {}
        }
        for (uint256 i = 3; i < N; ++i) {
            address a = m[i];
            uint256 s = uint256(keccak256(abi.encode(seed, e, i)));
            vm.startPrank(a);
            if (s % 4 != 0) {
                try c.payNow() {} catch {}
            }
            if (s % 3 == 0) {
                try c.claim() {} catch {}
            }
            if (s % 7 == 1) {
                try c.repayAll() {} catch {}
            } else if (s % 7 == 2) {
                try c.payArrears(1) {} catch {}
            }
            // Borrowers who claimed often revoke (2 in 3), which drives defaults.
            if (s % 5 == 2) usdc.approve(address(c), (s >> 8) % 3 == 0 ? 50_000e6 : 0);
            if (s % 3 == 1) {
                try c.requestLoan(50e6 + (s >> 16) % 700e6, 1 + (s >> 48) % 3, (s >> 120) % 2_000, 0) {
                    touched[a] = true;
                } catch {}
            }
            if (c.debtOf(a) != 0 && (s >> 180) % 4 == 0) {
                usdc.approve(address(c), 50_000e6);
                try c.repayDebt(1 + (s >> 190) % 200e6) {} catch {}
            }
            if ((s >> 200) % 9 == 0) {
                uint32[] memory q = c.getQueue();
                if (q.length != 0) {
                    try c.unback(q[(s >> 210) % q.length]) {} catch {}
                }
            }
            vm.stopPrank();
        }
    }

    /// @dev Up to 6 tries per pending request to fill its backed need, members 3..11 only.
    function _back(KuberCircle c, address[] memory m, uint256 seed, uint256 e) private {
        uint32[] memory q = c.getQueue();
        for (uint256 j; j < q.length; ++j) {
            Loan memory l = c.getLoan(q[j]);
            uint256 need = l.backedNeed - _sum(l.vouchers) - _sum(l.agreers);
            for (uint256 t; t < 6 && need != 0; ++t) {
                uint256 s = uint256(keccak256(abi.encode(seed, e, q[j], t, "back")));
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

    /// @dev Pre-payments, then settle(e) in batches of a random size with pay-class calls between batches.
    function _settle(KuberCircle c, address[] memory m, uint256 seed, uint256 e) private {
        _warpTo(c, e + 1, false);
        for (uint256 i; i < N; ++i) {
            if (uint256(keccak256(abi.encode(seed, e, i, "pre"))) % 3 != 0) continue;
            vm.prank(m[i]);
            try c.payNow() {} catch {}
        }
        vm.recordLogs();
        uint256 bs = 1 + uint256(keccak256(abi.encode(seed, e, "batch"))) % 12;
        c.settle(bs);
        for (uint256 b; c.getCircleState().settledEpoch < e; ++b) {
            vm.startPrank(m[3 + uint256(keccak256(abi.encode(seed, e, b, "mid"))) % 9]);
            try c.payArrears(1) {} catch {}
            try c.claim() {} catch {}
            vm.stopPrank();
            c.settle(bs);
        }
    }

    /// @dev After each settlement: every seizure against its pledges and tier order; I1, the untouched-member promise,
    /// I3, I4, and both weight accumulators.
    function _check(KuberCircle c, address[] memory m) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 x; x < logs.length; ++x) {
            if (logs[x].emitter != address(c)) continue;
            if (logs[x].topics[0] == IKuberCircleEvents.DebtRepaid.selector) ++cov[4];
            if (logs[x].topics[0] != SUSPENDED) continue;
            Loan memory l = c.getLoan(uint256(logs[x].topics[1]));
            (uint256 owed, uint256 fromB, uint256 fromV, uint256 fromA,,) =
                abi.decode(logs[x].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(fromB + fromV + fromA, owed, "group share not 0");
            uint256 sv = _sum(l.vouchers);
            uint256 sa = _sum(l.agreers);
            assertLe(fromV, sv, "vouchers over their pledges");
            assertLe(fromA, sa, "agreers over their pledges");
            if (fromA != 0) assertEq(fromV, sv, "agreers before the vouchers are used up");
            ++cov[0];
            if (fromV != 0) ++cov[1];
            if (fromA != 0) ++cov[2];
            if ((fromV != 0 && l.vouchers.length > 1) || (fromA != 0 && l.agreers.length > 1)) ++cov[3];
        }
        uint256 k = c.getCircleState().settledEpoch;
        uint256 claims;
        uint256 wa;
        uint256 ws;
        for (uint256 i; i < N; ++i) {
            Member memory x = c.getMember(m[i]);
            assertGe(x.savings, x.pledgedOut, "I1");
            claims += x.claimable;
            if (!touched[m[i]]) {
                assertEq(x.savings, 100e6 * uint256(x.paidCount), "untouched member lost savings");
                assertEq(x.claimable, 0, "untouched member claimable");
                assertEq(x.rewards, 0, "untouched member rewards");
            }
            if (x.status != MemberStatus.Active) continue;
            wa += _h(c).weightAt(m[i], k);
            if (!x.everBorrowed) ws += _h(c).weightAt(m[i], k);
        }
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.reservedClaims, claims, "I3");
        uint256 unpaid;
        uint256 n = _h(c).loanCount();
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            if (l.status == LoanStatus.Funded) unpaid += l.amount - l.principalRepaid;
        }
        assertEq(p.outstandingPrincipal, unpaid, "I4");
        assertEq(wa, _h(c).wActiveAt(k), "W_active");
        assertEq(ws, _h(c).wSaverAt(k), "W_saver");
    }

    /// @dev Σ pledges of a tier; every recorded loss is within its pledge.
    function _sum(Pledge[] memory bs) private pure returns (uint256 s) {
        for (uint256 i; i < bs.length; ++i) {
            assertLe(bs[i].loss, bs[i].amount, "loss over pledge");
            s += bs[i].amount;
        }
    }
}
