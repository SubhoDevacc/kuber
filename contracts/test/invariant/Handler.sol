// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {MockAaveVault} from "../../src/MockAaveVault.sol";
import {MockLPVault} from "../../src/MockLPVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {
    Alloc,
    BPS,
    CircleStatus,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus,
    ProposalKind,
    Window
} from "../../src/lib/CircleTypes.sol";

/// @dev Independent reads shared by the handler, the invariants, and the properties: token balances, vault
/// conversions, and member-by-member and loan-by-loan sums, never a total the circle keeps.
library Reads {
    /// @dev Σ savings and Σ rewards over the member list; Σ claimable over the member list plus `extra`.
    function sums(KuberCircle c, address[] memory extra)
        internal
        view
        returns (uint256 sav, uint256 claim, uint256 rew)
    {
        address[] memory ms = c.members();
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            sav += m.savings;
            claim += m.claimable;
            rew += m.rewards;
        }
        for (uint256 i; i < extra.length; ++i) {
            claim += c.getMember(extra[i]).claimable;
        }
    }

    /// @dev Unpaid principal of every funded loan, read loan by loan.
    function principal(KuberCircle c) internal view returns (uint256 sum) {
        uint256 n = c.getCircleState().loanCount;
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            if (l.status == LoanStatus.Funded) sum += l.amount - l.principalRepaid;
        }
    }

    /// @dev The circle's Aave and LP positions at the vaults' own conversion rate.
    function vaults(address c, MockAaveVault aave, MockLPVault lp) internal view returns (uint256) {
        return aave.convertToAssets(aave.balanceOf(c)) + lp.convertToAssets(lp.balanceOf(c));
    }
}

/// @dev 07-03 stateful handler over one or two circles (B shares members with A, for the lien). `step(seed)` is the
/// only target selector, so the dispatcher's weights are exact. Guided actions make their own preconditions (settle
/// what is due, leave LOCK, set up a loan first). Nothing reverts out of `step`: every circle call is recorded as ok,
/// reverted, or noop (precondition not met, nothing called), and a revert of `settle` is stored as a finding.
contract Handler is Test {
    struct Config {
        KuberCircle a;
        // address(0): one circle.
        KuberCircle b;
        MockUSDC usdc;
        MockAaveVault aave;
        MockLPVault lp;
        KuberRegistry reg;
        address treasury;
        address keeper;
        address[] outsiders;
        // Manager candidates of A and of B: never borrow, back, leave, get kicked, or settle, so their claimable is
        // only manager fees.
        address[] poolA;
        address[] poolB;
        // Members of both circles.
        address[] shared;
        // Never acted for (P5's mirrored pair).
        address[] ignored;
    }

    struct Pre {
        int256 pot;
        uint256 mBps;
        // The largest protocol fee quoted for one pending leaver.
        uint256 quotedPf;
        uint256 treasury;
    }

    // Counter ids: guided and market actions, internal settle calls, then the 21 random member calls.
    uint256 internal constant NEXT = 0;
    uint256 internal constant BACKED = 1;
    uint256 internal constant STOP = 2;
    uint256 internal constant LEAVE = 3;
    uint256 internal constant JOIN = 4;
    uint256 internal constant VOTE = 5;
    uint256 internal constant LIEN = 6;
    uint256 internal constant MINT = 7;
    uint256 internal constant SHOCK = 8;
    uint256 internal constant APY = 9;
    uint256 internal constant SETTLE = 10;
    uint256 internal constant R0 = 11;
    uint256 public constant N_ACT = 32;

    MockUSDC internal usdc;
    MockAaveVault internal aave;
    MockLPVault internal lp;
    KuberRegistry internal reg;
    KuberCircle[2] internal cs;
    uint256 public nCircles;
    address public treasury;
    address public keeper;
    address[] internal outsiders;
    address[] internal shared;
    address[][2] internal pools;
    mapping(address => bool) public isPool;
    mapping(address => bool) public ignored;
    uint256 internal t0;
    uint256 internal dur;
    uint256 internal nonce;
    // Properties only: P4's per-call savings snapshot around each settle.
    bool public p4On;

    uint256[N_ACT] public ok;
    uint256[N_ACT] public reverted;
    uint256[N_ACT] public noop;

    // Per-circle token flows from the token's Transfer logs: in from people or the other circle, out to anyone but
    // the vaults; yield = mints to the circle + vault value gained across warps; shock = vault value lost to shocks.
    uint256[2] public inflow;
    uint256[2] public outflow;
    uint256[2] public yieldIn;
    uint256[2] public shockLoss;
    // Transfers between the circle and a vault: each can round the position down by a unit.
    uint256[2] public vaultOps;
    // Claimable the treasury and the pool took out (claim, or inside withdraw); the keeper's reimbursement likewise.
    uint256[2] public feesClaimed;
    uint256[2] public reimbClaimed;
    mapping(uint256 => mapping(address => uint64)) public caughtUp;
    // 0: a founder (first epoch 1); else the first epoch of a member admitted mid-cycle.
    mapping(uint256 => mapping(address => uint256)) public firstEpoch;
    mapping(uint256 => mapping(address => bool)) public everBacked;
    mapping(uint256 => mapping(address => bool)) public everDefaulted;

    // Reach (the whole EVM state, ghosts included, starts fresh every run).
    uint256 public defaults;
    uint256 public defaultsWithSeizure;
    uint256 public exits;
    uint256 public passedVotes;
    uint256 public liensPaid;
    uint256 public backedFunded;
    uint256 public admitted;
    uint256 public managerFees;
    uint256 public caughtUps;
    uint256 public reinstated;
    bool[2] public finalized;
    int256[2] public finalPot;
    uint256[2] public maxSettled;

    // Findings inside a step; the invariants assert each is zero.
    uint256 public settleReverts;
    bytes public settleRevertData;
    uint256 public feeOnNonPositivePot;
    uint256 public feeAboveBound;
    uint256 public exitFeeMissing;
    uint256 public capacityBreaches;
    uint256 public groupLossEvents;
    uint256 public p4Breaches;
    string public firstBreach;

    // Scratch for the settle call being checked.
    uint256 internal cFees;
    uint256 internal cFeeEvents;
    uint256 internal cReimb;
    uint256 internal cFunded;
    uint256 internal cDefaults;
    uint256 internal callId;
    mapping(uint256 => mapping(address => uint256)) internal cContrib;

    constructor(Config memory cfg) {
        cs[0] = cfg.a;
        cs[1] = cfg.b;
        nCircles = address(cfg.b) == address(0) ? 1 : 2;
        usdc = cfg.usdc;
        aave = cfg.aave;
        lp = cfg.lp;
        reg = cfg.reg;
        treasury = cfg.treasury;
        keeper = cfg.keeper;
        outsiders = cfg.outsiders;
        shared = cfg.shared;
        pools[0] = cfg.poolA;
        pools[1] = cfg.poolB;
        for (uint256 i; i < cfg.poolA.length; ++i) {
            isPool[cfg.poolA[i]] = true;
        }
        for (uint256 i; i < cfg.poolB.length; ++i) {
            isPool[cfg.poolB[i]] = true;
        }
        for (uint256 i; i < cfg.ignored.length; ++i) {
            ignored[cfg.ignored[i]] = true;
        }
        t0 = cfg.a.getCircleState().fixedParams.startTime;
        dur = cfg.a.getCircleState().fixedParams.epochDuration;
    }

    /// @dev The only target selector: a weighted dispatch on the hashed seed (hashed with a call counter, so the
    /// weights hold whatever values the fuzzer's dictionary repeats).
    function step(uint256 seed) external {
        uint256 s = uint256(keccak256(abi.encode(seed, ++nonce)));
        _dispatch(s % 100, s / 100);
    }

    function circle(uint256 ci) external view returns (KuberCircle) {
        return cs[ci];
    }

    function poolOf(uint256 ci) external view returns (address[] memory) {
        return pools[ci];
    }

    /// @dev Addresses credited outside the member list: the treasury (fees) and the keeper (reimbursement).
    function extras() public view returns (address[] memory e) {
        e = new address[](2);
        (e[0], e[1]) = (treasury, keeper);
    }

    function _dispatch(uint256 r, uint256 s) internal {
        vm.recordLogs();
        if (r < 25) _nextEpoch(s);
        else if (r < 35) _backedLoan(s);
        else if (r < 43) _stopPaying(s);
        else if (r < 49) _leave(s);
        else if (r < 54) _join(s);
        else if (r < 59) _vote(s);
        else if (r < 64) _lien(s);
        else if (r < 72) _market(s);
        else _random(s);
        _logs();
    }

    // ---------------------------------------------------------------- time and settlement

    // 0-24: to the next epoch start of either circle (B starts half an epoch after A, so they alternate and B lags A by
    // at most one epoch), settling everything due in batches of 1-60; a tenth leave the last due settlement part-way.
    // A fifth only move inside the epoch, so LOCK windows happen. Once both circles ended: withdraw and claim.
    function _nextEpoch(uint256 s) internal {
        if (!_live(0) && !_live(1)) return _payoutSweep(s);
        uint256 r = s % 10;
        if (r < 2) {
            uint256 nb = _nextBoundary();
            uint256 t = block.timestamp + 12 + (s >> 8) % 18;
            _warp(t < nb ? t : nb - 1);
        } else {
            _warp(_nextBoundary());
            for (uint256 x; x < nCircles; ++x) {
                _settleDue(x, uint256(keccak256(abi.encode(s, x))), r == 9 && x == (s >> 16) % nCircles);
            }
        }
        ++ok[NEXT];
    }

    function _nextBoundary() internal view returns (uint256) {
        uint256 half = nCircles == 2 ? dur / 2 : dur;
        if (block.timestamp < t0) return t0;
        return t0 + ((block.timestamp - t0) / half + 1) * half;
    }

    // Vault yield accrues with time: the value each circle's positions gain across the warp is yield in.
    function _warp(uint256 t) internal {
        uint256[2] memory v;
        for (uint256 x; x < nCircles; ++x) {
            v[x] = Reads.vaults(address(cs[x]), aave, lp);
        }
        vm.warp(t);
        for (uint256 x; x < nCircles; ++x) {
            uint256 w = Reads.vaults(address(cs[x]), aave, lp);
            if (w > v[x]) yieldIn[x] += w - v[x];
        }
    }

    function _settleDue(uint256 ci, uint256 s, bool stopShort) internal {
        KuberCircle c = cs[ci];
        for (uint256 j; j < 200; ++j) {
            KuberCircle.CircleState memory st = c.getCircleState();
            if (st.status != CircleStatus.Active || st.currentEpoch <= uint256(st.settledEpoch) + 1) return;
            uint256 batch = 1 + uint256(keccak256(abi.encode(s, j))) % 60;
            if (stopShort && st.currentEpoch == uint256(st.settledEpoch) + 2 && st.cursor + batch >= st.memberCount) {
                // Part-way: pay-class calls then run while the settlement is pending.
                if (st.memberCount - st.cursor > 1) _settleCall(ci, st.memberCount - st.cursor - 1);
                return;
            }
            if (!_settleCall(ci, batch)) return;
        }
    }

    // One settle call by the keeper at 25 gwei (reimbursement on). Around the completing call: the fee checks (none
    // on a pot <= 0 before and after; at most the fee rates of the pot before; the treasury credited for the
    // quoted exits) and the capacity check after funding. With p4On: P4's savings ghost.
    function _settleCall(uint256 ci, uint256 batch) internal returns (bool) {
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        bool completing = st.cursor + batch >= st.memberCount;
        Pre memory pre;
        if (completing) pre = _pre(ci, st);
        uint256[] memory sav;
        if (p4On) sav = _savings(ci);
        (cFees, cFeeEvents, cReimb, cFunded, cDefaults) = (0, 0, 0, 0, 0);
        ++callId;
        vm.txGasPrice(25e9);
        vm.prank(keeper);
        try c.settle(batch) {
            ++ok[SETTLE];
        } catch (bytes memory err) {
            ++reverted[SETTLE];
            ++settleReverts;
            if (settleRevertData.length == 0) settleRevertData = err;
            _logs();
            return false;
        }
        _logs();
        uint256 se = c.getCircleState().settledEpoch;
        if (se > maxSettled[ci]) maxSettled[ci] = se;
        if (completing) _post(ci, pre);
        if (p4On && cDefaults != 0) _p4(ci, sav);
        return true;
    }

    function _pre(uint256 ci, KuberCircle.CircleState memory st) internal view returns (Pre memory p) {
        KuberCircle c = cs[ci];
        p.pot = _pot(ci);
        p.mBps = st.rules.managerFeeBps;
        p.treasury = c.getMember(treasury).claimable;
        // Leaves run at settle(k) for k < totalEpochs; the quote is for exactly that settlement.
        if (uint256(st.settledEpoch) + 1 >= st.fixedParams.totalEpochs) return p;
        address[] memory ms = c.members();
        for (uint256 i; i < ms.length; ++i) {
            if (!c.getMember(ms[i]).leavePending) continue;
            (,, uint256 pf,) = c.exitValueOf(ms[i]);
            if (pf > p.quotedPf) p.quotedPf = pf;
        }
    }

    function _post(uint256 ci, Pre memory p) internal {
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        (uint256 assets, uint256 sav, uint256 nonMember) = _book(ci);
        int256 potAfter = int256(assets) - int256(nonMember) - int256(sav);
        uint256 rate = reg.protocolFeeBps() + (p.mBps > st.rules.managerFeeBps ? p.mBps : st.rules.managerFeeBps);
        if (cFees != 0 && p.pot <= 0 && potAfter <= 0) {
            ++feeOnNonPositivePot;
            _breach(string.concat("fee on a pot <= 0: circle ", vm.toString(ci), " pot ", vm.toString(p.pot)));
        }
        uint256 bound = p.pot > 0 ? uint256(p.pot) * rate / BPS : 0;
        if (cFees > bound + cFeeEvents) {
            ++feeAboveBound;
            _breach(string.concat("fees ", vm.toString(cFees), " above ", vm.toString(bound)));
        }
        // An exit with a positive yield share pays the protocol fee to the treasury (07 D-03). The collect pass leaves
        // the pot and the leaver's weight as they are but can raise W_active by up to one contribution per member
        // (n <= 50), so a leaver quoted >= 1,000 still pays >= 1,000 / 51 > 0 at its exit.
        if (p.quotedPf >= 1_000 && c.getMember(treasury).claimable == p.treasury) {
            ++exitFeeMissing;
            _breach(string.concat("exit protocol fee not credited: quoted ", vm.toString(p.quotedPf)));
        }
        if (cFunded != 0) {
            // V at funding = V after + this call's reimbursement + the rebalance's rounding (four vault calls).
            uint256 v = assets > nonMember ? assets - nonMember : 0;
            uint256 pr = Reads.principal(c);
            if (pr > (v + cReimb + 8) * st.rules.alloc.loan / BPS + 1) {
                ++capacityBreaches;
                _breach(string.concat("principal ", vm.toString(pr), " above the loan bucket of V ", vm.toString(v)));
            }
        }
    }

    // P4: a member not involved in any default (not the borrower or a backer of a defaulted loan, since R-N3 repays an
    // older default's backers in any settlement) keeps its savings except for its own contribution collected here.
    function _p4(uint256 ci, uint256[] memory before) internal {
        KuberCircle c = cs[ci];
        address[] memory ms = c.members();
        for (uint256 i; i < before.length; ++i) {
            if (before[i] == type(uint256).max || _involved(c, ms[i])) continue;
            Member memory m = c.getMember(ms[i]);
            if (m.status != MemberStatus.Active) continue;
            if (m.savings != before[i] + cContrib[callId][ms[i]]) {
                ++p4Breaches;
                _breach(string.concat("P4: uninvolved member's savings moved: ", vm.toString(ms[i])));
            }
        }
    }

    function _savings(uint256 ci) internal view returns (uint256[] memory s) {
        KuberCircle c = cs[ci];
        address[] memory ms = c.members();
        s = new uint256[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            s[i] = m.status == MemberStatus.Active ? m.savings : type(uint256).max;
        }
    }

    function _involved(KuberCircle c, address a) internal view returns (bool) {
        uint256 n = c.getCircleState().loanCount;
        for (uint256 id = 1; id <= n; ++id) {
            Loan memory l = c.getLoan(id);
            if (l.status != LoanStatus.Defaulted) continue;
            if (l.borrower == a) return true;
            for (uint256 j; j < l.vouchers.length; ++j) {
                if (l.vouchers[j].backer == a) return true;
            }
            for (uint256 j; j < l.agreers.length; ++j) {
                if (l.agreers[j].backer == a) return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- guided actions

    // 25-34: request own limit + a backed need (contribution/2 .. 2 × contribution) and have 2-4 others pledge it.
    function _backedLoan(uint256 s) internal {
        uint256 ci = _pick(s);
        address b = _prep(ci, s) ? _find(ci, s >> 8, 0) : address(0);
        // Pays this epoch first, so its own part counts it and later contributions cannot cover the backed part.
        if (b != address(0) && cs[ci].getMember(b).paidBitmap & (uint64(1) << cs[ci].currentEpoch()) == 0) {
            _call(ci, b, abi.encodeCall(KuberCircle.payNow, ()));
        }
        bytes memory data = b == address(0) ? bytes("") : _backedTerms(ci, b, s);
        if (data.length == 0) {
            ++noop[BACKED];
            return;
        }
        (bool okr, bytes memory ret) = _call(ci, b, data);
        if (!okr) {
            ++reverted[BACKED];
            return;
        }
        uint256 id = abi.decode(ret, (uint256));
        _count(BACKED, _cover(ci, id, cs[ci].getLoan(id).backedNeed, s));
    }

    // The requestLoan call: own limit + need, capped at the per-loan max; empty when no backed part fits.
    function _backedTerms(uint256 ci, address b, uint256 s) internal view returns (bytes memory data) {
        KuberCircle.CircleState memory st = cs[ci].getCircleState();
        if (st.currentEpoch + 2 > st.fixedParams.totalEpochs) return data;
        uint256 amount = _backedAmount(ci, b, st.fixedParams.contribution, s);
        if (amount == 0) return data;
        uint256 rep =
            1 + (s >> 16) % _min(st.fixedParams.totalEpochs - st.currentEpoch - 1, st.fixedParams.maxRepayEpochs);
        data = abi.encodeCall(
            KuberCircle.requestLoan,
            (amount, rep, 500 + (s >> 32) % 1_001, (s >> 40) % 4 == 0 ? 1 + (s >> 48) % 1_000 : 0)
        );
    }

    // 0 when the per-loan max leaves no room for a backed part at today's V.
    function _backedAmount(uint256 ci, address b, uint256 cb, uint256 s) internal view returns (uint256 amount) {
        (, uint256 perLoan, uint256 own) = cs[ci].loanLimits(b);
        amount = own + cb / 2 + (s >> 24) % (cb * 3 / 2 + 1);
        if (amount > perLoan) amount = perLoan;
        if (amount <= own) amount = 0;
    }

    function _cover(uint256 ci, uint256 id, uint256 need, uint256 s) internal returns (bool) {
        address[] memory ms = cs[ci].members();
        address borrower = cs[ci].getLoan(id).borrower;
        uint256 parts = 2 + (s >> 56) % 3;
        for (uint256 j; j < ms.length && need != 0; ++j) {
            address a = ms[((s >> 64) + j) % ms.length];
            uint256 amt = a == borrower ? 0 : _freeToBack(cs[ci], a);
            if (amt == 0) continue;
            if (parts > 1 && need / parts != 0 && need / parts < amt) amt = need / parts;
            if (amt > need) amt = need;
            if (!_pledge(ci, a, id, amt, (s >> (80 + j)) & 1 == 1)) continue;
            need -= amt;
            if (parts > 1) --parts;
        }
        return need == 0;
    }

    // An agree pledge is capped at one contribution (R-D).
    function _pledge(uint256 ci, address a, uint256 id, uint256 amt, bool agree) internal returns (bool success) {
        uint256 cb = cs[ci].getCircleState().fixedParams.contribution;
        if (agree && amt > cb) agree = false;
        (success,) = _call(
            ci, a, agree ? abi.encodeCall(KuberCircle.agree, (id, amt)) : abi.encodeCall(KuberCircle.vouch, (id, amt))
        );
    }

    // 35-42: the borrower of the most recently funded backed loan that still pays claims its proceeds and revokes its
    // allowance (its balance stays), so it defaults with a seizure three settlements later. With none, it sets one up.
    function _stopPaying(uint256 s) internal {
        (uint256 ci, address b) = _newestBacked(s);
        if (b == address(0)) {
            ++noop[STOP];
            _backedLoan(s);
            return;
        }
        if (cs[ci].getMember(b).claimable != 0) _call(ci, b, abi.encodeCall(KuberCircle.claim, ()));
        vm.prank(b);
        usdc.approve(address(cs[ci]), 0);
        ++ok[STOP];
    }

    function _newestBacked(uint256 s) internal view returns (uint256 ci, address b) {
        uint256 best = 0;
        for (uint256 x; x < nCircles; ++x) {
            KuberCircle c = cs[x];
            address[] memory ms = c.members();
            for (uint256 j; j < ms.length; ++j) {
                address a = ms[(s % ms.length + j) % ms.length];
                Member memory m = c.getMember(a);
                if (ignored[a] || m.status != MemberStatus.Active || m.activeLoanId == 0) continue;
                Loan memory l = c.getLoan(m.activeLoanId);
                if (l.backedNeed == 0 || l.fundedEpoch < best || usdc.allowance(a, address(c)) == 0) continue;
                (best, ci, b) = (uint256(l.fundedEpoch) + 1, x, a);
            }
        }
    }

    // 43-48: a free member requests a leave; in A, half the time a shared member with debt in B (its exit pays the
    // lien when claimed).
    function _leave(uint256 s) internal {
        uint256 ci = _pick(s);
        if (!_prep(ci, s)) {
            ++noop[LEAVE];
            return;
        }
        KuberCircle c = cs[ci];
        address who = address(0);
        if (ci == 0 && (s >> 8) % 2 == 0) {
            for (uint256 i; i < shared.length && who == address(0); ++i) {
                address a = shared[i];
                if (!ignored[a] && reg.hasOpenDebt(a) && _free(c.getMember(a))) who = a;
            }
        }
        if (who == address(0)) who = _find(ci, s >> 16, 1);
        if (who == address(0)) {
            ++noop[LEAVE];
            return;
        }
        (bool okl,) = _call(ci, who, abi.encodeCall(KuberCircle.requestLeave, ()));
        _count(LEAVE, okl);
    }

    // 49-53: an outsider applies, an eligible member sponsors, every eligible member votes yes.
    function _join(uint256 s) internal {
        uint256 ci = _pick(s);
        if (!_prep(ci, s) || outsiders.length == 0) {
            ++noop[JOIN];
            return;
        }
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        address o = address(0);
        for (uint256 i; i < outsiders.length && o == address(0); ++i) {
            address x = outsiders[(s % outsiders.length + i) % outsiders.length];
            if (
                c.getMember(x).status == MemberStatus.None && !reg.hasOpenDebt(x)
                    && reg.activeMemberships(x) < reg.MAX_ACTIVE_CIRCLES()
            ) o = x;
        }
        if (o == address(0) || st.currentEpoch + 2 > st.fixedParams.totalEpochs) {
            ++noop[JOIN];
            return;
        }
        // Already applied (no sponsor yet) is fine: the sponsorship below opens the proposal.
        _call(ci, o, abi.encodeCall(KuberCircle.applyToJoin, ()));
        address[] memory ms = c.members();
        uint256 pid = 0;
        uint256 tries = 0;
        for (uint256 j; j < ms.length && pid == 0 && tries < 8; ++j) {
            address a = ms[(s >> (8 + j)) % ms.length];
            Member memory m = c.getMember(a);
            if (ignored[a] || m.status != MemberStatus.Active || m.leavePending) continue;
            if (m.paidCount < st.fixedParams.minSaveEpochs || reg.hasOpenDebt(a)) continue;
            ++tries;
            (bool oks, bytes memory ret) = _call(ci, a, abi.encodeCall(KuberCircle.sponsor, (o)));
            if (oks) pid = abi.decode(ret, (uint256));
        }
        if (pid == 0) {
            ++reverted[JOIN];
            return;
        }
        _voteAll(ci, pid, s, true, address(0));
        ++ok[JOIN];
    }

    // 54-58: a Rule, Allocation, Manager appoint/fire, or Kick proposal from a distinct eligible proposer (R-J2), then
    // every eligible member votes yes (always for a Kick) or about three in four do.
    function _vote(uint256 s) internal {
        uint256 ci = nCircles == 2 && s % 4 == 0 ? 1 : 0;
        if (!_prep(ci, s)) {
            ++noop[VOTE];
            return;
        }
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        ProposalKind k = ProposalKind((s >> 8) % 4);
        address target = address(0);
        bytes memory data;
        if (k == ProposalKind.Rule) {
            (uint8 field, uint256 value) = _ruleChange(s >> 16);
            data = abi.encode(field, value);
        } else if (k == ProposalKind.Allocation) {
            data = abi.encode(_alloc(s >> 16));
        } else if (k == ProposalKind.Manager) {
            if (st.manager == address(0) || (s >> 16) % 2 == 0) target = _poolMember(ci, s >> 24, st.manager);
            if (st.manager == address(0) && target == address(0)) k = ProposalKind.Rule;
            data = k == ProposalKind.Rule ? abi.encode(uint8(7), uint256(300)) : abi.encode(target);
        } else {
            target = _find(ci, s >> 16, 1);
            if (target == address(0)) {
                ++noop[VOTE];
                return;
            }
            data = abi.encode(target);
        }
        uint256 pid = _proposeAny(ci, k, data, target, st.manager, s);
        if (pid == 0) {
            ++reverted[VOTE];
            return;
        }
        _voteAll(ci, pid, s, k == ProposalKind.Kick || (s >> 32) % 2 == 0, k == ProposalKind.Kick ? target : address(0));
        ++ok[VOTE];
    }

    function _proposeAny(uint256 ci, ProposalKind k, bytes memory data, address target, address mgr, uint256 s)
        internal
        returns (uint256 pid)
    {
        address[] memory ms = cs[ci].members();
        // R-K: with a manager in place only the manager proposes the money plan.
        bool mgrOnly = k == ProposalKind.Allocation && mgr != address(0);
        uint256 tries = 0;
        for (uint256 j; j < ms.length && pid == 0 && tries < 6; ++j) {
            address a = mgrOnly ? mgr : ms[(s >> (40 + j)) % ms.length];
            if (a == target || (k == ProposalKind.Manager && a == mgr) || !_canPropose(ci, a)) continue;
            ++tries;
            (bool okp, bytes memory ret) = _call(ci, a, abi.encodeCall(KuberCircle.propose, (k, data)));
            if (okp) pid = abi.decode(ret, (uint256));
            if (mgrOnly) break;
        }
    }

    function _canPropose(uint256 ci, address a) internal view returns (bool) {
        Member memory m = cs[ci].getMember(a);
        return !ignored[a] && m.status == MemberStatus.Active
            && m.paidCount >= cs[ci].getCircleState().fixedParams.minSaveEpochs;
    }

    function _voteAll(uint256 ci, uint256 pid, uint256 s, bool allYes, address skip) internal {
        KuberCircle c = cs[ci];
        address[] memory ms = c.members();
        uint256 minSave = c.getCircleState().fixedParams.minSaveEpochs;
        for (uint256 i; i < ms.length; ++i) {
            address a = ms[i];
            Member memory m = c.getMember(a);
            if (a == skip || ignored[a] || m.status != MemberStatus.Active) continue;
            if (m.sponsor != address(0) && m.paidCount < minSave) continue;
            bool yes = allYes || uint256(keccak256(abi.encode(s, i))) % 4 != 0;
            _call(ci, a, abi.encodeCall(KuberCircle.vote, (pid, yes)));
        }
    }

    // 59-63: a shared member stops paying a loan in B, so its exit payout or withdraw in A pays the lien to B. In order:
    // a shared member with debt in B claims what A owes it; one with a paying loan in B claims and revokes its B
    // allowance; else one requests an own-savings loan in B.
    function _lien(uint256 s) internal {
        if (nCircles < 2 || shared.length == 0) {
            ++noop[LIEN];
            return;
        }
        KuberCircle b = cs[1];
        uint256 n = shared.length;
        for (uint256 j; j < n; ++j) {
            address p = shared[(s % n + j) % n];
            if (!ignored[p] && b.debtOf(p) != 0 && cs[0].getMember(p).claimable != 0) {
                _take(0, p, abi.encodeCall(KuberCircle.claim, ()), LIEN);
                return;
            }
        }
        for (uint256 j; j < n; ++j) {
            address p = shared[(s % n + j) % n];
            Member memory m = b.getMember(p);
            if (ignored[p] || m.status != MemberStatus.Active || m.activeLoanId == 0) continue;
            if (usdc.allowance(p, address(b)) == 0) continue;
            if (m.claimable != 0) _call(1, p, abi.encodeCall(KuberCircle.claim, ()));
            vm.prank(p);
            usdc.approve(address(b), 0);
            ++ok[LIEN];
            return;
        }
        _lienLoan(s);
    }

    // An eligible shared member requests half to all of its own limit in B, unbacked: its default leaves fines as
    // debt in B.
    function _lienLoan(uint256 s) internal {
        if (!_prep(1, s)) {
            ++noop[LIEN];
            return;
        }
        KuberCircle b = cs[1];
        KuberCircle.CircleState memory st = b.getCircleState();
        uint256 total = st.fixedParams.totalEpochs;
        if (st.currentEpoch + 2 > total) {
            ++noop[LIEN];
            return;
        }
        uint256 rep = 1 + (s >> 16) % _min(total - st.currentEpoch - 1, st.fixedParams.maxRepayEpochs);
        for (uint256 j; j < shared.length; ++j) {
            address p = shared[(s % shared.length + j) % shared.length];
            if (!_canBorrow(b, p, st)) continue;
            (, uint256 per, uint256 own) = b.loanLimits(p);
            uint256 amt = _min(own / 2 + (s >> 8) % (own / 2 + 1), per);
            if (amt == 0) continue;
            (bool okr,) = _call(1, p, abi.encodeCall(KuberCircle.requestLoan, (amt, rep, 0, 0)));
            _count(LIEN, okr);
            return;
        }
        ++noop[LIEN];
    }

    // 64-71: yield minted to a running circle (<= 50e6), an LP shock (up to a 30% loss), or a new Aave APY.
    function _market(uint256 s) internal {
        uint256 r = s % 3;
        if (r == 0) {
            uint256 ci = _pick(s >> 8);
            if (!_live(ci)) {
                ++noop[MINT];
                return;
            }
            usdc.mint(address(cs[ci]), 1 + (s >> 16) % 50e6);
            ++ok[MINT];
        } else if (r == 1) {
            uint256[2] memory v;
            for (uint256 x; x < nCircles; ++x) {
                v[x] = lp.convertToAssets(lp.balanceOf(address(cs[x])));
            }
            lp.shock(-int16(int256(1 + (s >> 8) % 3_000)));
            for (uint256 x; x < nCircles; ++x) {
                uint256 w = lp.convertToAssets(lp.balanceOf(address(cs[x])));
                if (v[x] > w) shockLoss[x] += v[x] - w;
            }
            ++ok[SHOCK];
        } else {
            aave.setApy(uint16((s >> 8) % 1_001), 0);
            ++ok[APY];
        }
    }

    // 72-99: one random member-facing call with bounded arguments; most revert, which is the point.
    function _random(uint256 s) internal {
        uint256 kind = s % 21;
        uint256 id = R0 + kind;
        uint256 ci = _pick(s >> 8);
        KuberCircle c = cs[ci];
        address[] memory ms = c.members();
        address who = ms[(s >> 16) % ms.length];
        uint256 x = s >> 32;
        // Half the catch-up, arrears, payoff, and debt calls go to a member they apply to (a loan-free member with a
        // missed round; a borrower; a debtor here).
        if ((kind == 1 || kind == 2 || kind == 3 || kind == 11) && x % 2 == 0) {
            address t = _find(ci, x >> 8, kind == 1 ? 4 : kind == 11 ? 3 : 2);
            if (t != address(0)) who = t;
        }
        bool money = kind == 4 || kind == 7 || kind == 8 || kind == 14;
        if ((ignored[who] && kind != 16) || (isPool[who] && money)) {
            ++noop[id];
            return;
        }
        Member memory m = c.getMember(who);
        bytes memory data;
        if (kind == 0) {
            data = abi.encodeCall(KuberCircle.payNow, ());
        } else if (kind == 1) {
            uint256 k = _missed(m, c.currentEpoch());
            // A member who missed a round approves again to catch it up.
            if (k != 0 && usdc.allowance(who, address(c)) == 0) {
                vm.prank(who);
                usdc.approve(address(c), type(uint256).max);
            }
            data = abi.encodeCall(KuberCircle.catchUp, (k != 0 ? k : 1 + x % (c.currentEpoch() + 1)));
        } else if (kind == 2) {
            data = abi.encodeCall(KuberCircle.payArrears, (1 + x % 3));
        } else if (kind == 3) {
            data = abi.encodeCall(KuberCircle.repayAll, ());
        } else if (kind == 4) {
            uint256 own = m.savings > m.pledgedOut ? uint256(m.savings - m.pledgedOut) * 9 / 10 : 0;
            data = abi.encodeCall(
                KuberCircle.requestLoan,
                (
                    1 + x % (own * 3 / 2 + 1),
                    1 + (x >> 64) % 3,
                    (x >> 72) % 3_001,
                    (x >> 88) % 2 == 0 ? 0 : (x >> 96) % 1_001
                )
            );
        } else if (kind == 5) {
            data = abi.encodeCall(KuberCircle.raiseExtra, (m.pendingRequestId, 1 + x % 1_000));
        } else if (kind == 6) {
            data = abi.encodeCall(KuberCircle.cancelRequest, (m.pendingRequestId));
        } else if (kind == 7 || kind == 8 || kind == 9) {
            uint32[] memory q = c.getQueue();
            if (q.length == 0) {
                ++noop[id];
                return;
            }
            uint256 lid = q[x % q.length];
            uint256 amt = 1 + (x >> 64) % (uint256(m.savings > m.pledgedOut ? m.savings - m.pledgedOut : 0) + 1);
            if (kind == 7) data = abi.encodeCall(KuberCircle.vouch, (lid, amt));
            else if (kind == 8) data = abi.encodeCall(KuberCircle.agree, (lid, amt % 100e6 + 1));
            else data = abi.encodeCall(KuberCircle.unback, (lid));
        } else if (kind == 10) {
            _take(ci, x % 4 != 0 ? who : (x % 8 == 0 ? treasury : keeper), abi.encodeCall(KuberCircle.claim, ()), id);
            return;
        } else if (kind == 11) {
            uint256 d = c.debtOf(who);
            // A debtor who stopped paying approves again to repay.
            if (d != 0 && usdc.allowance(who, address(c)) == 0) {
                vm.prank(who);
                usdc.approve(address(c), type(uint256).max);
            }
            data = abi.encodeCall(KuberCircle.repayDebt, (1 + x % (d == 0 ? 1e6 : d)));
        } else if (kind == 12) {
            (uint8 field, uint256 value) = _ruleChange(x);
            data = abi.encodeCall(KuberCircle.propose, (ProposalKind.Rule, abi.encode(field, value)));
        } else if (kind == 13) {
            uint32[] memory open = c.openProposals();
            if (open.length == 0) {
                ++noop[id];
                return;
            }
            data = abi.encodeCall(KuberCircle.vote, (open[x % open.length], x % 3 != 0));
        } else if (kind == 14) {
            data = abi.encodeCall(KuberCircle.requestLeave, ());
        } else if (kind == 15) {
            data = abi.encodeCall(KuberCircle.cancelLeave, ());
        } else if (kind == 16) {
            who = outsiders[x % outsiders.length];
            data = abi.encodeCall(KuberCircle.applyToJoin, ());
        } else if (kind == 17) {
            data = abi.encodeCall(KuberCircle.sponsor, (outsiders[x % outsiders.length]));
        } else if (kind == 18) {
            _take(ci, who, abi.encodeCall(KuberCircle.withdraw, ()), id);
            return;
        } else if (kind == 19) {
            uint256 next = usdc.allowance(who, address(c)) == 0 ? type(uint256).max : 0;
            vm.prank(who);
            usdc.approve(address(c), next);
            ++ok[id];
            return;
        } else {
            data = abi.encodeCall(KuberCircle.applyFreed, (ms[x % ms.length]));
        }
        (bool okc,) = _call(ci, who, data);
        _count(id, okc);
    }

    // Once both circles ended: the next member still owed a share-out withdraws; then anyone owed claimable claims.
    function _payoutSweep(uint256 s) internal {
        uint256 ci = s % nCircles;
        KuberCircle c = cs[ci];
        address[] memory ms = c.members();
        uint256 n = ms.length;
        uint256 start = (s >> 8) % n;
        for (uint256 j; j < n; ++j) {
            address a = ms[(start + j) % n];
            Member memory m = c.getMember(a);
            bool owed = m.status == MemberStatus.Active || m.status == MemberStatus.Suspended;
            if (owed && !m.withdrawn && !ignored[a]) {
                _take(ci, a, abi.encodeCall(KuberCircle.withdraw, ()), NEXT);
                return;
            }
        }
        address[] memory ex = extras();
        for (uint256 j; j < n + 2; ++j) {
            address a = j < n ? ms[(start + j) % n] : ex[j - n];
            if (!ignored[a] && c.getMember(a).claimable != 0) {
                _take(ci, a, abi.encodeCall(KuberCircle.claim, ()), NEXT);
                return;
            }
        }
        ++noop[NEXT];
    }

    // ---------------------------------------------------------------- calls and logs

    function _call(uint256 ci, address who, bytes memory data) internal returns (bool success, bytes memory ret) {
        vm.prank(who);
        (success, ret) = address(cs[ci]).call(data);
        _logs();
    }

    // claim or withdraw; what the treasury and the pool take out is fee claimable, what the keeper takes out is
    // reimbursement (withdraw pays the claimable too).
    function _take(uint256 ci, address who, bytes memory data, uint256 id) internal {
        uint256 before = cs[ci].getMember(who).claimable;
        (bool success,) = _call(ci, who, data);
        if (success && (who == treasury || isPool[who])) feesClaimed[ci] += before;
        if (success && who == keeper) reimbClaimed[ci] += before;
        _count(id, success);
    }

    function _count(uint256 id, bool success) internal {
        if (success) ++ok[id];
        else ++reverted[id];
    }

    function _logs() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            if (l.emitter == address(usdc)) {
                if (l.topics[0] == IERC20.Transfer.selector) {
                    _transfer(_addr(l.topics[1]), _addr(l.topics[2]), abi.decode(l.data, (uint256)));
                }
                continue;
            }
            for (uint256 ci; ci < nCircles; ++ci) {
                if (l.emitter == address(cs[ci])) _event(ci, l);
            }
        }
    }

    function _transfer(address from, address to, uint256 v) internal {
        for (uint256 x; x < nCircles; ++x) {
            address c = address(cs[x]);
            bool fromVault = from == address(aave) || from == address(lp);
            bool toVault = to == address(aave) || to == address(lp);
            if (to == c) {
                if (fromVault) ++vaultOps[x];
                else if (from == address(0)) yieldIn[x] += v;
                else inflow[x] += v;
            }
            if (from == c) {
                if (toVault) ++vaultOps[x];
                else outflow[x] += v;
            }
        }
    }

    function _event(uint256 ci, Vm.Log memory l) internal {
        bytes32 t = l.topics[0];
        if (t == IKuberCircleEvents.MemberSuspended.selector) {
            (uint256 o, uint256 fb, uint256 fv, uint256 fa,,) =
                abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256, uint256));
            if (o != fb + fv + fa) ++groupLossEvents;
            ++defaults;
            ++cDefaults;
            if (fv + fa != 0) ++defaultsWithSeizure;
            everDefaulted[ci][cs[ci].getLoan(uint256(l.topics[1])).borrower] = true;
        } else if (t == IKuberCircleEvents.MemberLeft.selector || t == IKuberCircleEvents.MemberKicked.selector) {
            ++exits;
        } else if (t == IKuberCircleEvents.ProposalPassed.selector) {
            ++passedVotes;
        } else if (t == IKuberCircleEvents.LienPaid.selector) {
            ++liensPaid;
        } else if (t == IKuberCircleEvents.FeesCharged.selector) {
            (uint256 pf, uint256 mf) = abi.decode(l.data, (uint256, uint256));
            cFees += pf + mf;
            ++cFeeEvents;
            managerFees += mf;
        } else if (t == IKuberCircleEvents.GasReimbursed.selector) {
            cReimb += abi.decode(l.data, (uint256));
        } else if (t == IKuberCircleEvents.LoanFunded.selector) {
            ++cFunded;
            if (cs[ci].getLoan(uint256(l.topics[1])).backedNeed != 0) ++backedFunded;
        } else if (t == IKuberCircleEvents.Finalized.selector) {
            finalized[ci] = true;
            (finalPot[ci],,,,) = abi.decode(l.data, (int256, uint256, uint256, uint256, uint256));
        } else if (t == IKuberCircleEvents.CaughtUp.selector) {
            caughtUp[ci][_addr(l.topics[1])] |= uint64(1) << uint256(l.topics[2]);
            ++caughtUps;
        } else if (t == IKuberCircleEvents.MemberReinstated.selector) {
            ++reinstated;
        } else if (t == IKuberCircleEvents.MemberAdmitted.selector) {
            // Logged by the completing call of settle(k), which already set settledEpoch = k.
            firstEpoch[ci][_addr(l.topics[1])] = uint256(cs[ci].getCircleState().settledEpoch) + 1;
            ++admitted;
        } else if (t == IKuberCircleEvents.Backed.selector) {
            everBacked[ci][_addr(l.topics[2])] = true;
        } else if (p4On && t == IKuberCircleEvents.ContributionPaid.selector) {
            cContrib[callId][_addr(l.topics[1])] += abi.decode(l.data, (uint256));
        }
    }

    // ---------------------------------------------------------------- reads and picks

    // assets = cash + vault positions + loan-by-loan principal; nonMember = Σ claimable + Σ rewards + saverPot.
    function _book(uint256 ci) internal view returns (uint256 assets, uint256 sav, uint256 nonMember) {
        KuberCircle c = cs[ci];
        uint256 claim;
        uint256 rew;
        (sav, claim, rew) = Reads.sums(c, extras());
        assets = usdc.balanceOf(address(c)) + Reads.vaults(address(c), aave, lp) + Reads.principal(c);
        nonMember = claim + rew + c.getPublicSummary().saverPot;
    }

    /// @dev The yield pot V − S_total rebuilt from independent reads.
    function _pot(uint256 ci) internal view returns (int256) {
        (uint256 assets, uint256 sav, uint256 nonMember) = _book(ci);
        return int256(assets) - int256(nonMember) - int256(sav);
    }

    // Settles what is due and leaves LOCK for the next epoch start (both circles settled after the warp). True when
    // circle ci can take an action-class call now.
    function _prep(uint256 ci, uint256 s) internal returns (bool) {
        if (!_live(ci)) return false;
        KuberCircle c = cs[ci];
        if (c.currentWindow() == Window.Lock) _warp(_nextBoundary());
        for (uint256 x; x < nCircles; ++x) {
            _settleDue(x, uint256(keccak256(abi.encode(s, "prep", x))), false);
        }
        KuberCircle.CircleState memory st = c.getCircleState();
        return st.status == CircleStatus.Active && st.window == Window.Open
            && uint256(st.settledEpoch) + 1 == st.currentEpoch && st.currentEpoch <= st.fixedParams.totalEpochs;
    }

    function _live(uint256 ci) internal view returns (bool) {
        return ci < nCircles && cs[ci].getCircleState().status == CircleStatus.Active;
    }

    // B takes a third of the circle-picking actions.
    function _pick(uint256 s) internal view returns (uint256) {
        return nCircles == 2 && s % 3 == 0 ? 1 : 0;
    }

    // From a random start: mode 0, a member who can borrow; mode 1, a free member (no loan, request, pledge, or
    // pending leave); mode 2, a borrower; mode 3, a member with debt here; mode 4, a loan-free Active member with a
    // missed round. Never a pool or ignored member.
    function _find(uint256 ci, uint256 s, uint256 mode) internal view returns (address) {
        KuberCircle c = cs[ci];
        KuberCircle.CircleState memory st = c.getCircleState();
        address[] memory ms = c.members();
        uint256 start = s % ms.length;
        for (uint256 j; j < ms.length; ++j) {
            address a = ms[(start + j) % ms.length];
            if (isPool[a] || ignored[a]) continue;
            if (mode == 0 && _canBorrow(c, a, st)) return a;
            if (mode == 1 && _free(c.getMember(a))) return a;
            if (mode == 2 && c.getMember(a).activeLoanId != 0) return a;
            if (mode == 3 && c.debtOf(a) != 0) return a;
            if (mode == 4) {
                Member memory m = c.getMember(a);
                if (m.status == MemberStatus.Active && m.activeLoanId == 0 && _missed(m, st.currentEpoch) != 0) {
                    return a;
                }
            }
        }
        return address(0);
    }

    // The Queue.request checks the handler can read (an open Kick on the member is left to revert).
    function _canBorrow(KuberCircle c, address a, KuberCircle.CircleState memory st) internal view returns (bool) {
        if (isPool[a] || ignored[a]) return false;
        Member memory m = c.getMember(a);
        return m.status == MemberStatus.Active && m.activeLoanId == 0 && m.pendingRequestId == 0 && !m.leavePending
            && m.paidCount >= st.fixedParams.minSaveEpochs && st.currentEpoch > m.cooldownUntil
            && m.savings > m.pledgedOut && !reg.hasOpenDebt(a);
    }

    function _freeToBack(KuberCircle c, address a) internal view returns (uint256) {
        if (isPool[a] || ignored[a]) return 0;
        Member memory m = c.getMember(a);
        if (m.status != MemberStatus.Active || m.activeLoanId != 0 || m.pendingRequestId != 0 || m.leavePending) {
            return 0;
        }
        return reg.hasOpenDebt(a) ? 0 : m.savings - m.pledgedOut;
    }

    // The lowest epoch up to `e` the member missed and has not caught up; 0 if none.
    function _missed(Member memory m, uint256 e) internal pure returns (uint256) {
        for (uint256 k = 1; k <= e && k < 64; ++k) {
            uint64 bit = uint64(1) << k;
            if (m.missedBitmap & bit != 0 && m.paidBitmap & bit == 0) return k;
        }
        return 0;
    }

    function _free(Member memory m) internal pure returns (bool) {
        return m.status == MemberStatus.Active && m.activeLoanId == 0 && m.pendingRequestId == 0 && m.pledgedOut == 0
            && !m.leavePending;
    }

    function _poolMember(uint256 ci, uint256 s, address not) internal view returns (address) {
        address[] memory p = pools[ci];
        for (uint256 j; j < p.length; ++j) {
            address a = p[(s % p.length + j) % p.length];
            if (a != not && cs[ci].getMember(a).status == MemberStatus.Active) return a;
        }
        return address(0);
    }

    // A rule change inside Params.validateRules bounds (ownLtv and perLoanMax kept workable).
    function _ruleChange(uint256 r) internal pure returns (uint8 field, uint256 value) {
        field = uint8(r % 9);
        uint256 x = r >> 8;
        if (field == 0) value = 5_000 + x % 5_001;
        else if (field == 2) value = 2_000 + x % 8_001;
        else if (field == 3) value = x % 5_001;
        else if (field == 4) value = x % 3_001;
        else if (field == 1 || field == 6) value = x % 2_001;
        else value = x % 1_001;
    }

    function _alloc(uint256 r) internal pure returns (Alloc memory a) {
        a.loan = uint16(r % 4_001);
        a.cash = uint16(500 + (r >> 16) % 1_501);
        uint256 rest = BPS - a.loan - a.cash;
        a.lp = uint16((r >> 32) % ((rest < 5_000 ? rest : 5_000) + 1));
        a.aave = uint16(rest - a.lp);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _addr(bytes32 t) internal pure returns (address) {
        return address(uint160(uint256(t)));
    }

    function _breach(string memory what) internal {
        if (bytes(firstBreach).length == 0) firstBreach = what;
    }
}
