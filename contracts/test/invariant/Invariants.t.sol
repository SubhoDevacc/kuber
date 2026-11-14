// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, CircleStatus, FixedParams, Member, MemberStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircleHarness} from "../utils/KuberCircleHarness.sol";
import {Handler, Reads} from "./Handler.sol";

/// @dev TEST_PLAN §10 (I1-I7) and the 07 D-13 extras over two circles sharing four members: A (30 members, 12 epochs,
/// allocation 40/30/20/10, manager fee 5%) and B (8 members, 12 epochs, starting half an epoch later); 3 outsiders;
/// protocol fee 10%; gas reimbursement on (AVAX $30, cap 100 gwei, 1 USDC per epoch, every settle at 25 gwei); Aave
/// at 5% with a 200,000× speedup. Every check compares independent reads (balances, vault conversions, member and
/// loan sums, handler ghosts) with the totals the circle keeps. afterInvariant writes one reach line per run to
/// out/reach.txt (the campaign-level thresholds are checked over it) and the call counters to out/calls.txt.
contract InvariantsTest is CircleTestBase {
    Handler internal h;
    KuberCircle[2] internal cs;
    address[] internal people;
    // memberList is append-only: founders first, then members admitted mid-cycle (their first epoch is a ghost).
    uint256[2] internal founders;

    function setUp() public override {
        super.setUp();
        registry.setProtocolFeeBps(1_000);
        registry.setGasSettings(30e6, 100e9, 1e6);
        aave.setApy(500, 0);
        aave.setSpeedup(200_000);
        address[] memory a = _newMembers(30);
        address[] memory bOnly = _newMembers(4);
        address[] memory out = _newMembers(3);
        address[] memory b = new address[](8);
        address[] memory shared = new address[](4);
        for (uint256 i; i < 4; ++i) {
            (b[i], b[4 + i], shared[i]) = (bOnly[i], a[26 + i], a[26 + i]);
            usdc.mint(shared[i], 10_000e6);
        }
        FixedParams memory f = _fixed();
        f.totalEpochs = 12;
        f.maxMembers = 40;
        RuleParams memory r = _rules();
        r.alloc = Alloc({loan: 4_000, aave: 3_000, lp: 2_000, cash: 1_000});
        r.managerFeeBps = 500;
        vm.prank(a[0]);
        cs[0] = KuberCircle(factory.createCircle("A", f, r, _tail(a)));
        f.startTime += f.epochDuration / 2;
        vm.prank(b[0]);
        cs[1] = KuberCircle(factory.createCircle("B", f, r, _tail(b)));
        _enter(cs[0], a);
        _enter(cs[1], b);
        (founders[0], founders[1]) = (a.length, b.length);
        for (uint256 i; i < out.length; ++i) {
            for (uint256 ci; ci < 2; ++ci) {
                vm.prank(out[i]);
                usdc.approve(address(cs[ci]), type(uint256).max);
            }
            people.push(out[i]);
        }
        vm.warp(f.startTime);
        cs[0].activate();
        cs[1].activate();

        Handler.Config memory cfg;
        (cfg.a, cfg.b, cfg.usdc, cfg.aave, cfg.lp, cfg.reg) = (cs[0], cs[1], usdc, aave, lp, registry);
        (cfg.treasury, cfg.keeper, cfg.outsiders, cfg.shared) = (registry.treasury(), makeAddr("keeper"), out, shared);
        cfg.poolA = new address[](2);
        (cfg.poolA[0], cfg.poolA[1]) = (a[1], a[2]);
        cfg.poolB = new address[](1);
        cfg.poolB[0] = b[1];
        h = new Handler(cfg);
        usdc.setMinter(address(h), true);
        aave.transferOwnership(address(h));
        lp.transferOwnership(address(h));
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = Handler.step.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _enter(KuberCircle c, address[] memory ms) internal {
        for (uint256 i; i < ms.length; ++i) {
            if (i != 0) {
                vm.prank(ms[i]);
                c.join();
            }
            vm.prank(ms[i]);
            usdc.approve(address(c), type(uint256).max);
            if (c == cs[0] || i < 4) people.push(ms[i]);
        }
    }

    // ---------------------------------------------------------------- campaigns

    /// @dev I1-I4, the weight accumulators, and the paid/missed bitmaps.
    function invariant_ledger() public view {
        for (uint256 ci; ci < 2; ++ci) {
            _ledger(ci);
        }
    }

    /// @dev I5 (member savings the residual claim), the share-out once ended, P2 flows, fee and reimbursement
    /// conservation, I6, and the per-settlement fee and capacity checks the handler ran.
    function invariant_solvency() public view {
        for (uint256 ci; ci < 2; ++ci) {
            _assets(ci);
            _flows(ci);
            _fees(ci);
            _alloc(ci);
        }
        assertEq(h.feeOnNonPositivePot(), 0, h.firstBreach());
        assertEq(h.feeAboveBound(), 0, h.firstBreach());
        assertEq(h.exitFeeMissing(), 0, h.firstBreach());
        assertEq(h.capacityBreaches(), 0, h.firstBreach());
    }

    /// @dev I7, the manager rule (R-K), the waterfall's group loss, and no settle revert in a reachable state.
    function invariant_governanceAndDebt() public view {
        _debtIndex();
        for (uint256 ci; ci < 2; ++ci) {
            address mgr = cs[ci].getCircleState().manager;
            if (mgr != address(0)) {
                assertEq(uint8(cs[ci].getMember(mgr).status), uint8(MemberStatus.Active), "manager");
            }
        }
        assertEq(h.groupLossEvents(), 0, "group loss");
        assertEq(h.settleReverts(), 0, vm.toString(h.settleRevertData()));
    }

    function afterInvariant() public {
        vm.writeLine(
            "out/reach.txt",
            string.concat(
                string.concat(
                    "defaultsWithSeizure=",
                    vm.toString(h.defaultsWithSeizure()),
                    " exits=",
                    vm.toString(h.exits()),
                    " passedVotes=",
                    vm.toString(h.passedVotes()),
                    " liensPaid=",
                    vm.toString(h.liensPaid()),
                    " finalizedA=",
                    h.finalized(0) ? "1" : "0",
                    " finalizedB=",
                    h.finalized(1) ? "1" : "0"
                ),
                string.concat(
                    " defaults=",
                    vm.toString(h.defaults()),
                    " backedFunded=",
                    vm.toString(h.backedFunded()),
                    " admitted=",
                    vm.toString(h.admitted()),
                    " managerFees=",
                    vm.toString(h.managerFees()),
                    " caughtUps=",
                    vm.toString(h.caughtUps()),
                    " reinstated=",
                    vm.toString(h.reinstated()),
                    " maxSettledA=",
                    vm.toString(h.maxSettled(0)),
                    " maxSettledB=",
                    vm.toString(h.maxSettled(1)),
                    " potA=",
                    vm.toString(h.finalPot(0)),
                    " potB=",
                    vm.toString(h.finalPot(1))
                )
            )
        );
        string memory line = "calls";
        for (uint256 i; i < h.N_ACT(); ++i) {
            line = string.concat(
                line, " ", vm.toString(h.ok(i)), "/", vm.toString(h.reverted(i)), "/", vm.toString(h.noop(i))
            );
        }
        vm.writeLine("out/calls.txt", line);
        console.log(line);
    }

    // ---------------------------------------------------------------- ledger

    // One pass over the members. I1 savings >= pledgedOut; I2 sTotal, sActive, sSaver, totalRewardsOwed equal the
    // member sums; I3 reservedClaims equals Σ claimable over every credited address; I4 outstandingPrincipal equals
    // the loan-by-loan sum. N-1: accrued to one epoch E at or after every `last` (min(clock - 1, totalEpochs)),
    // Σ Active weights == W_active and Σ never-borrowed Active weights == W_saver.
    function _ledger(uint256 ci) internal view {
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        uint256 e = st.currentEpoch - 1;
        if (e > st.fixedParams.totalEpochs || st.status != CircleStatus.Active) e = st.fixedParams.totalEpochs;
        address[] memory ms = c.members();
        // sTotal, sActive, sSaver, rewards, claimable, W_active, W_saver
        uint256[7] memory s;
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            assertGe(m.savings, m.pledgedOut, "I1");
            if (m.status == MemberStatus.Active || m.status == MemberStatus.Suspended) s[0] += m.savings;
            else assertEq(m.savings, 0, "exited member keeps savings");
            s[3] += m.rewards;
            s[4] += m.claimable;
            if (m.status != MemberStatus.Active) continue;
            uint256 w = m.weight + (e > m.lastAccrual ? uint256(m.savings) * (e - m.lastAccrual) : 0);
            s[1] += m.savings;
            s[5] += w;
            if (!m.everBorrowed) (s[2], s[6]) = (s[2] + m.savings, s[6] + w);
            _bitmap(ci, ms[i], m, i < founders[ci] ? 1 : h.firstEpoch(ci, ms[i]), st.settledEpoch);
        }
        address[] memory ex = h.extras();
        for (uint256 i; i < ex.length; ++i) {
            s[4] += c.getMember(ex[i]).claimable;
        }
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        KuberCircleHarness hc = KuberCircleHarness(address(c));
        assertEq(p.sTotal, s[0], "I2 sTotal");
        assertEq(hc.sActive(), s[1], "I2 sActive");
        assertEq(hc.sSaver(), s[2], "I2 sSaver");
        assertEq(p.totalRewardsOwed, s[3], "I2 totalRewardsOwed");
        assertEq(p.reservedClaims, s[4], "I3");
        assertEq(p.outstandingPrincipal, Reads.principal(c), "I4");
        assertEq(s[5], hc.wActiveAt(e), "weights: W_active");
        assertEq(s[6], hc.wSaverAt(e), "weights: W_saver");
    }

    // N-2: for an Active member and every settled epoch from its first epoch (and from a reinstatement), the paid or
    // the missed bit is set, and both only for an epoch it caught up.
    function _bitmap(uint256 ci, address a, Member memory m, uint256 first, uint256 se) internal view {
        uint256 lo = m.reinstatedEpoch > first ? m.reinstatedEpoch : first;
        for (uint256 e = lo; e <= se; ++e) {
            uint64 bit = uint64(1) << e;
            bool paid = m.paidBitmap & bit != 0;
            assertTrue(paid || m.missedBitmap & bit != 0, "bitmap: settled epoch neither paid nor missed");
            if (paid && m.missedBitmap & bit != 0) {
                assertTrue(h.caughtUp(ci, a) & bit != 0, "bitmap: paid and missed without a catch-up");
            }
        }
    }

    // ---------------------------------------------------------------- solvency

    function _assets(uint256 ci) internal view {
        KuberCircle c = cs[ci];
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 bal = usdc.balanceOf(address(c));
        uint256 av = aave.convertToAssets(aave.balanceOf(address(c)));
        uint256 lv = lp.convertToAssets(lp.balanceOf(address(c)));
        assertEq(p.cash, bal, "cash");
        assertEq(p.aaveValue, av, "aave value");
        assertEq(p.lpValue, lv, "lp value");
        (uint256 sav, uint256 claim, uint256 rew) = Reads.sums(c, h.extras());
        if (c.getCircleState().status != CircleStatus.Active) return _ended(c, p, bal, claim);
        uint256 assets = bal + av + lv + Reads.principal(c);
        // Every pot decrease is a shock, a reimbursement, or a vault call's rounding: exits take at most their yield
        // share, defaults move savings, fees come only from a positive pot.
        uint256 losses = h.shockLoss(ci) + h.reimbClaimed(ci) + c.getMember(h.keeper()).claimable + 2 * h.vaultOps(ci);
        assertGe(assets + losses + 2, sav + claim + rew + p.saverPot, "I5: pot below -(shocks + expenses)");
        assertGe(assets, p.reservedClaims + p.totalRewardsOwed + p.saverPot, "I5: V < 0");
    }

    // Ended: every share-out still owed, rebuilt from the frozen numbers, plus every claimable fits the balance.
    function _ended(KuberCircle c, KuberCircle.PublicSummary memory p, uint256 bal, uint256 owed) internal view {
        address[] memory ms = c.members();
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            bool listed = m.status == MemberStatus.Active || m.status == MemberStatus.Suspended;
            if (!listed || m.withdrawn) continue;
            uint256 s = m.savings;
            uint256 part = s;
            if (p.yieldPot > 0 && m.status == MemberStatus.Active && p.wActive != 0) {
                part += Math.mulDiv(uint256(p.yieldPot), m.weight, p.wActive);
            } else if (p.yieldPot < 0 && s != 0) {
                uint256 loss = Math.mulDiv(uint256(-p.yieldPot), s, p.sTotal, Math.Rounding.Ceil);
                part = loss >= s ? 0 : s - loss;
            }
            if (!m.everBorrowed && p.wSaver != 0) part += Math.mulDiv(p.saverPot, m.weight, p.wSaver);
            owed += part + m.rewards;
        }
        assertLe(owed, bal, "Ended: share-outs and claims exceed the balance");
    }

    // P2: what left the circle never exceeds what came in plus yield; and the token ghost balances (inflow + yield -
    // shocks - outflow equals what the circle holds) up to the vault calls' rounding.
    function _flows(uint256 ci) internal view {
        address c = address(cs[ci]);
        uint256 tol = 2 * (h.vaultOps(0) + h.vaultOps(1)) + 2;
        uint256 inPlus = h.inflow(ci) + h.yieldIn(ci);
        assertLe(h.outflow(ci), inPlus + tol, "P2: outflow above inflow + yield");
        uint256 held = usdc.balanceOf(c) + Reads.vaults(c, aave, lp);
        int256 gap = int256(inPlus) - int256(h.shockLoss(ci) + h.outflow(ci)) - int256(held);
        assertLe(gap < 0 ? uint256(-gap) : uint256(gap), tol, "P2: token ghost does not balance");
    }

    // Fees charged == fees credited (the treasury's and the pool's claimable plus what they took out); expenses ==
    // the keeper's reimbursement likewise.
    function _fees(uint256 ci) internal view {
        KuberCircle c = cs[ci];
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 credited = h.feesClaimed(ci) + c.getMember(h.treasury()).claimable;
        address[] memory pool = h.poolOf(ci);
        for (uint256 i; i < pool.length; ++i) {
            credited += c.getMember(pool[i]).claimable;
        }
        assertEq(p.feesCharged, credited, "fees charged != fees credited");
        assertEq(p.expenses, h.reimbClaimed(ci) + c.getMember(h.keeper()).claimable, "expenses != reimbursed");
    }

    // I6.
    function _alloc(uint256 ci) internal view {
        Alloc memory a = cs[ci].getCircleState().rules.alloc;
        assertEq(uint256(a.loan) + a.aave + a.lp + a.cash, 10_000, "I6 sum");
        assertLe(a.loan, 4_000, "I6 loan");
        assertLe(a.lp, 5_000, "I6 lp");
        assertGe(a.cash, 500, "I6 cash");
    }

    // ---------------------------------------------------------------- debt index

    // I7: each person's registry debt list has at most 5 entries and is exactly the circles where debtOf > 0.
    function _debtIndex() internal view {
        for (uint256 i; i < people.length; ++i) {
            address[] memory list = registry.debtCircles(people[i]);
            assertLe(list.length, 5, "I7: more than 5 debts");
            uint256 expected;
            for (uint256 ci; ci < 2; ++ci) {
                bool owes = cs[ci].debtOf(people[i]) != 0;
                bool listed;
                for (uint256 j; j < list.length; ++j) {
                    if (list[j] == address(cs[ci])) listed = true;
                }
                assertEq(listed, owes, "I7: registry index != debtOf");
                if (owes) ++expected;
            }
            assertEq(list.length, expected, "I7: unknown circle listed");
        }
    }
}
