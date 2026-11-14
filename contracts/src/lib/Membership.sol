// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    BPS,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    MAX_OPEN_JOINS,
    Member,
    MemberStatus,
    Proposal,
    ProposalKind,
    ProposalStatus
} from "./CircleTypes.sol";
import {Fees} from "./Fees.sol";
import {Governance} from "./Governance.sol";
import {Invest} from "./Invest.sol";
import {KuberRegistry} from "../KuberRegistry.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library: leave, kick, exit value, mid-cycle join, and the membership part of settlement step 2
/// (SPEC Membership changes; DECISIONS R-A, R-L, R-M, R-N).
library Membership {
    using SafeCast for uint256;

    /// @notice D-08. The caller already passed the action-class check. Locks the exit fee (R-E).
    function requestLeave(CircleStorage.Layout storage $) external {
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (m.leavePending) revert IKuberCircleErrors.LeavePending();
        if (m.activeLoanId != 0) revert IKuberCircleErrors.HasActiveLoan();
        if (m.pendingRequestId != 0) revert IKuberCircleErrors.HasPendingRequest();
        if (m.pledgedOut != 0) revert IKuberCircleErrors.HasPledges();
        m.leavePending = true;
        m.leaveExitFeeBps = $.rules.exitFeeBps;
        // One entry per member (a second request reverts, cancelLeave removes it): bounded by the member count.
        $.leaveQueue.push(msg.sender);
        emit IKuberCircleEvents.LeaveRequested(msg.sender);
    }

    /// @notice D-08. The caller already passed the action-class check.
    function cancelLeave(CircleStorage.Layout storage $) external {
        Member storage m = $.members[msg.sender];
        if (!m.leavePending) revert IKuberCircleErrors.NoLeavePending();
        m.leavePending = false;
        address[] storage q = $.leaveQueue;
        uint256 n = q.length;
        // Nothing to remove if the flag was set without a queue entry (the Phase 4 harness setter).
        for (uint256 i; i < n; ++i) {
            if (q[i] == msg.sender) {
                q[i] = q[n - 1];
                q.pop();
                return;
            }
        }
    }

    /// @notice D-11. The caller already passed the action-class check (circle Active, OPEN).
    function applyToJoin(CircleStorage.Layout storage $, uint256 e) external {
        if (e + 2 > $.fixedParams.totalEpochs) revert IKuberCircleErrors.JoinClosed();
        KuberRegistry reg = $.registry;
        if (!reg.verified(msg.sender)) revert IKuberCircleErrors.NotVerified();
        if (reg.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        if (reg.activeMemberships(msg.sender) >= reg.MAX_ACTIVE_CIRCLES()) revert IKuberCircleErrors.AtMembershipCap();
        // Left and Kicked block too: no rejoin this cycle (a Forming leaver's record was deleted, so they may apply).
        if ($.members[msg.sender].status != MemberStatus.None) revert IKuberCircleErrors.AlreadyMember();
        if ($.applicants[msg.sender] != 0) revert IKuberCircleErrors.AlreadyApplied();
        // memberList keeps Left, Kicked, and Suspended entries, so this also bounds every member loop (G1).
        if ($.memberList.length >= $.fixedParams.maxMembers) revert IKuberCircleErrors.CircleFull();
        $.applicants[msg.sender] = 1;
        emit IKuberCircleEvents.JoinApplied(msg.sender);
    }

    /// @notice D-12: the caller sponsors an applicant, which opens their Join proposal. The caller already passed the
    /// action-class check; Governance.open enforces R-J2 (the sponsorship is the caller's one proposal this round).
    function sponsor(CircleStorage.Layout storage $, address applicant, uint256 e) external returns (uint256 id) {
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (m.paidCount < $.fixedParams.minSaveEpochs) revert IKuberCircleErrors.NotEnoughSaved();
        if (m.leavePending) revert IKuberCircleErrors.LeavePending();
        if ($.hasSponsored[msg.sender]) revert IKuberCircleErrors.AlreadySponsored();
        if ($.registry.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        // Such a Join could never be admitted, and the sponsor would spend their one sponsorship.
        if (e + 2 > $.fixedParams.totalEpochs) revert IKuberCircleErrors.JoinClosed();
        uint8 st = $.applicants[applicant];
        if (st == 0) revert IKuberCircleErrors.NotApplicant();
        if (st == 2) revert IKuberCircleErrors.ProposalOpen();
        if ($.openJoins >= MAX_OPEN_JOINS) revert IKuberCircleErrors.TooManyJoins();
        $.openJoins += 1;
        $.applicants[applicant] = 2;
        $.hasSponsored[msg.sender] = true;
        id = Governance.open($, ProposalKind.Join, applicant, e);
        emit IKuberCircleEvents.ProposalCreated(id, ProposalKind.Join, msg.sender, abi.encode(applicant));
        emit IKuberCircleEvents.Sponsored(msg.sender, applicant, id);
        // Trusted registry fixed at init; cannot revert for an authorized circle.
        $.registry.recordSponsored(msg.sender);
    }

    /// @notice D-06 step 2 after the tally: the pending leaves (not at the final settlement, D-08), then the passed
    /// Kick `kickId` (0 if none), then at most one admission (D-13). Never reverts because of membership state.
    function applyStep(CircleStorage.Layout storage $, uint256 k, uint256 kickId) external {
        uint256 total = $.fixedParams.totalEpochs;
        uint256 fees = 0;
        if (k < total) {
            address[] storage q = $.leaveQueue;
            uint256 n = q.length;
            for (uint256 i; i < n; ++i) {
                address a = q[i];
                Member storage m = $.members[a];
                m.leavePending = false;
                if (_free(m)) fees += _exit($, a, k, m.leaveExitFeeBps, MemberStatus.Left, fees);
            }
            delete $.leaveQueue;
        }
        // Leaves run first, so a kick cannot dodge a pending leave's fee (the kick is then dropped).
        if (kickId != 0) {
            Proposal storage p = $.proposals[kickId];
            if (_free($.members[p.target])) {
                _exit($, p.target, k, 0, MemberStatus.Kicked, fees);
                p.status = ProposalStatus.Applied;
                emit IKuberCircleEvents.ProposalApplied(kickId);
            } else {
                p.status = ProposalStatus.Dropped;
            }
        }
        // R-J3: this settlement's exit fees join the savers' pot once, after every exit, so no leaver's share depends
        // on another leaver's fee or on the queue order.
        if (fees != 0) $.saverPot += fees;
        _admit($, k, total);
    }

    /// @notice D-10: what the member would be paid if they left at the next settlement with today's numbers, and
    /// the exit fee (their locked fee if a leave is pending), and the protocol and manager fee taken from their gross
    /// yield share. Zeros for a non-Active member.
    function exitValueOf(CircleStorage.Layout storage $, address member)
        external
        view
        returns (uint256 payout, uint256 fee, uint256 protocolFee, uint256 managerFee)
    {
        Member storage m = $.members[member];
        if (m.status != MemberStatus.Active) return (0, 0, 0, 0);
        // The quoted value is already net of the protocol and manager fee on a positive yield share (07 D-03).
        (uint256 value,, uint256 gain) = _quote($, member, uint256($.settledEpoch) + 1, 0);
        (protocolFee, managerFee) = Fees.quote($, gain);
        fee = Math.mulDiv(value, m.leavePending ? m.leaveExitFeeBps : $.rules.exitFeeBps, BPS, Math.Rounding.Ceil);
        payout = value - fee;
    }

    // D-13, R-L: admits the oldest approved applicant who still passes the checks; each one that fails before it is
    // dropped (back to "applied"), and from k > total - 2 the whole queue is. The queue holds one entry per distinct
    // sponsor (one sponsorship per member per circle), so it is bounded by maxMembers <= 50.
    function _admit(CircleStorage.Layout storage $, uint256 k, uint256 total) private {
        uint256 n = $.approvedJoins.length;
        uint256 i = $.joinHead;
        if (i == n) return;
        bool closed = k + 2 > total;
        KuberRegistry reg = $.registry;
        uint256 cap = reg.MAX_ACTIVE_CIRCLES();
        for (; i < n; ++i) {
            uint256 id = $.approvedJoins[i];
            Proposal storage p = $.proposals[id];
            address a = p.target;
            if (
                !closed && $.memberList.length < $.fixedParams.maxMembers && reg.verified(a) && !reg.hasOpenDebt(a)
                    && reg.activeMemberships(a) < cap
            ) {
                $.joinHead = i.toUint16() + 1;
                Member storage m = $.members[a];
                m.status = MemberStatus.Active;
                m.sponsor = p.proposer;
                // Zero savings and weight: the first contribution is for epoch k + 1, so W_active and W_saver gain
                // weight 0 and need no change; epochs <= k are neither paid nor missed.
                $.memberList.push(a);
                delete $.applicants[a];
                p.status = ProposalStatus.Applied;
                emit IKuberCircleEvents.ProposalApplied(id);
                emit IKuberCircleEvents.MemberAdmitted(a);
                // The cap was just checked, and that is recordJoin's only revert.
                reg.recordJoin(a);
                return;
            }
            p.status = ProposalStatus.Dropped;
            $.applicants[a] = 1;
        }
        $.joinHead = i.toUint16();
    }

    // D-09: the exit at settle(k); returns the fee, which applyStep adds to the savers' pot after every exit (R-J3).
    // The quote reads the weights before removeFromActive moves them, both at syncEpoch, so W_active and W_saver
    // stay equal to the sums over the remaining members. The protocol and manager fee on a positive yield share are
    // credited here, per leaver (07 D-03): payout and fees are both claimable liabilities, so the whole gross share
    // leaves V − sTotal and the next leaver's share is unchanged up to rounding (order-independent, R-J3), and
    // finalize never charges the same yield again. The manager in place after this settlement's tally receives them
    // (a manager paused in the collect pass was already cleared by Waterfall.suspend; a leaving manager is cleared
    // below, after its own exit's manager fee).
    function _exit(
        CircleStorage.Layout storage $,
        address a,
        uint256 k,
        uint256 feeBps,
        MemberStatus st,
        uint256 pendingFees
    ) private returns (uint256 fee) {
        (uint256 value, uint256 saverShare, uint256 gain) = _quote($, a, k, pendingFees);
        {
            (uint256 protocolFee, uint256 managerFee) = Fees.quote($, gain);
            Fees.credit($, protocolFee, managerFee);
        }
        fee = Math.mulDiv(value, feeBps, BPS, Math.Rounding.Ceil);
        uint256 payout = value - fee;
        Member storage m = $.members[a];
        Weights.removeFromActive($, a, k, st);
        uint256 s = m.savings;
        // The member is already out of both accumulators, so only savings and sTotal drop (changeSavings would
        // back-fill and underflow for a member who pre-paid a later epoch).
        if (s != 0) Weights.debitSuspended($, a, s);
        uint256 rw = m.rewards;
        if (rw != 0) {
            m.rewards = 0;
            $.totalRewardsOwed -= rw;
        }
        // saverShare <= saverPot because the member's weight <= W_saver.
        $.saverPot -= saverShare;
        // The lien applies when it is claimed (Waterfall.payOut).
        Weights.creditClaimable($, a, payout);
        Governance.clearManager($, a);
        if (st == MemberStatus.Left) {
            emit IKuberCircleEvents.MemberLeft(a, payout);
            // Trusted registry fixed at init; cannot revert for an authorized circle.
            $.registry.recordLeave(a);
        } else {
            emit IKuberCircleEvents.MemberKicked(a, payout);
            $.registry.recordKick(a);
        }
    }

    // D-09 exit value at settlement k (before the exit fee, net of the protocol and manager fee), the saver share
    // inside it, and the gross positive yield share `gain` those fees are taken from. `pendingFees` are this
    // settlement's exit fees not yet in the savers' pot (R-J3).
    function _quote(CircleStorage.Layout storage $, address a, uint256 k, uint256 pendingFees)
        private
        view
        returns (uint256 value, uint256 saverShare, uint256 gain)
    {
        Member storage m = $.members[a];
        uint256 e = Weights.syncEpoch($, m, k);
        uint256 w = Weights.accrued(m.weight, m.savings, m.lastAccrual, e);
        // Only V is needed here; the cash and vault split is for the rebalance.
        // slither-disable-next-line unused-return
        (int256 v,,,) = Invest.valuation($);
        // R-J3: earlier exits' fees in this settlement are cash, not yet a liability, so a later leaver must not take
        // them as yield.
        v -= pendingFees.toInt256();
        (value, gain) = _savingsPart($, m.savings, w, e, v);
        // R-J3: with V <= 0 the savers' bonus absorbs the loss first (as in R-U), so the leaver takes no saver share.
        if (!m.everBorrowed && v > 0) {
            uint256 wS = Weights.accrued($.wSaver, $.sSaver, $.wSaverLast, e);
            if (wS != 0) saverShare = Math.mulDiv($.saverPot, w, wS);
        }
        value += saverShare + m.rewards;
    }

    // Savings plus the yield share of pot = v − sTotal: a gain `gain` by weight, floored, added net of the protocol and
    // manager fee; a loss by savings (sTotal includes paused members' savings, R-N), rounded against the member (R-A),
    // never below 0 (same floor as ShareOut.payout), and no fee.
    function _savingsPart(CircleStorage.Layout storage $, uint256 s, uint256 w, uint256 e, int256 v)
        private
        view
        returns (uint256 value, uint256 gain)
    {
        int256 pot = v - $.sTotal.toInt256();
        value = s;
        if (pot > 0) {
            uint256 wA = Weights.accrued($.wActive, $.sActive, $.wActiveLast, e);
            gain = wA == 0 ? 0 : Math.mulDiv(uint256(pot), w, wA);
            value += Fees.net($, gain);
        } else if (pot < 0 && s != 0) {
            uint256 loss = Math.mulDiv(uint256(-pot), s, $.sTotal, Math.Rounding.Ceil);
            value = loss >= s ? 0 : s - loss;
        }
    }

    // R-M: a stale leave or kick (a loan, request, or pledge since, or no longer Active) is dropped, never reverted.
    function _free(Member storage m) private view returns (bool) {
        return m.status == MemberStatus.Active && m.activeLoanId == 0 && m.pendingRequestId == 0 && m.pledgedOut == 0;
    }
}
