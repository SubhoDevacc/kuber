// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    Alloc,
    BPS,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Member,
    MemberStatus,
    Proposal,
    ProposalKind,
    ProposalStatus,
    RuleParams
} from "./CircleTypes.sol";
import {Params} from "./Params.sol";

/// @notice Linked library: proposals, votes, and the tally-and-apply part of settlement step 2 (SPEC Governance;
/// DECISIONS R-J, R-K).
library Governance {
    using SafeCast for uint256;

    uint16 private constant ALLOC_BIT = 1 << 9;
    uint16 private constant MANAGER_BIT = 1 << 10;
    uint16 private constant KICK_BIT = 1 << 11;
    uint16 private constant FIRE_BIT = 1 << 12;

    /// @notice D-02. The caller already passed the action-class check.
    function propose(CircleStorage.Layout storage $, ProposalKind kind, bytes calldata data, uint256 e)
        external
        returns (uint256 id)
    {
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (m.paidCount < $.fixedParams.minSaveEpochs) revert IKuberCircleErrors.NotEnoughSaved();
        RuleParams memory r = $.rules;
        (uint16 bit, address target, uint8 field, uint16 value) = _decode($, kind, data, r, e);
        if ($.openMask & bit != 0) revert IKuberCircleErrors.ProposalOpen();
        $.openMask |= bit;
        if (kind == ProposalKind.Kick) $.kickTarget = target;
        id = open($, kind, target, e);
        Proposal storage p = $.proposals[id];
        p.field = field;
        p.value = value;
        p.alloc = r.alloc;
        emit IKuberCircleEvents.ProposalCreated(id, kind, msg.sender, data);
    }

    /// @notice D-04. The caller already passed the vote-class check, so an Open proposal is one of this epoch.
    function vote(CircleStorage.Layout storage $, uint256 id, bool yes) external {
        Proposal storage p = $.proposals[id];
        if (p.status != ProposalStatus.Open) revert IKuberCircleErrors.VotingClosed();
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        // D-04: only members admitted mid-cycle have a sponsor; founders vote from the first epoch.
        if (m.sponsor != address(0) && m.paidCount < $.fixedParams.minSaveEpochs) {
            revert IKuberCircleErrors.NotEnoughSaved();
        }
        if (p.kind == ProposalKind.Kick && p.target == msg.sender) revert IKuberCircleErrors.TargetCannotVote();
        if ($.ballots[id][msg.sender] != 0) revert IKuberCircleErrors.AlreadyVoted();
        $.ballots[id][msg.sender] = yes ? 1 : 2;
        if (yes) p.yes += 1;
        else p.no += 1;
        emit IKuberCircleEvents.Voted(id, msg.sender, yes);
    }

    /// @notice D-05, D-06 (first half): tallies every open proposal against the Active count after the collect pass
    /// and applies passed rule, allocation, and then manager changes. Bounds were checked when proposing, so it cannot
    /// revert. Returns the passed Kick (at most one is open), 0 if none; Membership.applyStep executes it.
    function tally(CircleStorage.Layout storage $) external returns (uint256 kickId) {
        uint32[] memory ids = $.openIds;
        uint256 n = ids.length;
        if (n == 0) return 0;
        uint256 active = _activeCount($);
        uint256 appointId = 0;
        uint256 fireId = 0;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            Proposal storage p = $.proposals[id];
            ProposalKind kind = p.kind;
            if (!_passes(p, active)) {
                p.status = ProposalStatus.Failed;
                // R-J2: no new Kick on this member next round, so a Kick cannot pin them every round (0 means "never").
                if (kind == ProposalKind.Kick) $.kickBlockedEpoch[p.target] = p.epoch + 1;
                // A failed Join returns the applicant to "applied", so another member may sponsor them.
                else if (kind == ProposalKind.Join) $.applicants[p.target] = 1;
                continue;
            }
            emit IKuberCircleEvents.ProposalPassed(id);
            if (kind == ProposalKind.Kick || kind == ProposalKind.Join) {
                // Membership.applyStep executes the Kick and admits Joins, one per settlement, oldest approval first.
                p.status = ProposalStatus.Passed;
                if (kind == ProposalKind.Kick) kickId = id;
                else $.approvedJoins.push(id.toUint32());
                continue;
            }
            if (kind == ProposalKind.Manager) {
                // Applied after the loop, so a firing wins whatever the creation order (R-J2).
                if (p.target == address(0)) fireId = id;
                else appointId = id;
                continue;
            }
            if (kind == ProposalKind.Rule) {
                RuleParams memory r = $.rules;
                _setRule(r, p.field, p.value);
                $.rules = r;
            } else {
                $.rules.alloc = p.alloc;
            }
            p.status = ProposalStatus.Applied;
            emit IKuberCircleEvents.ProposalApplied(id);
        }
        _applyManager($, appointId, fireId);
        // Every open proposal belongs to the epoch being settled, so nothing carries over.
        delete $.openIds;
        $.openMask = 0;
        $.openJoins = 0;
        // The Kick is no longer open; a passed one executes in this transaction (D-07).
        $.kickTarget = address(0);
    }

    /// @notice A new Open proposal of the current epoch.
    function open(CircleStorage.Layout storage $, ProposalKind kind, address target, uint256 e)
        internal
        returns (uint256 id)
    {
        // R-J2: one open proposal per member per round, across all kinds (a sponsor's Join included); every proposal
        // closes at its epoch's settlement, so "per round" is "per epoch".
        if ($.lastProposedEpoch[msg.sender] == e) revert IKuberCircleErrors.AlreadyProposed();
        $.lastProposedEpoch[msg.sender] = e.toUint8();
        id = ++$.proposalCount;
        Proposal storage p = $.proposals[id];
        p.kind = kind;
        p.status = ProposalStatus.Open;
        p.epoch = e.toUint8();
        p.proposer = msg.sender;
        p.target = target;
        $.openIds.push(id.toUint32());
    }

    /// @notice D-05: a member paused in this settlement's collect pass loses their votes on every open proposal.
    function dropVotes(CircleStorage.Layout storage $, address member) internal {
        uint32[] storage ids = $.openIds;
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            uint8 b = $.ballots[id][member];
            if (b == 0) continue;
            $.ballots[id][member] = 0;
            if (b == 1) $.proposals[id].yes -= 1;
            else $.proposals[id].no -= 1;
        }
    }

    /// @notice D-14: the manager is cleared when they leave, are kicked, or are paused.
    function clearManager(CircleStorage.Layout storage $, address member) internal {
        if ($.manager != member) return;
        $.manager = address(0);
        emit IKuberCircleEvents.ManagerChanged(address(0));
    }

    /// @notice R-K: the manager's result for the period since the previous rebalance, in signed bps of `base` (the
    /// vault value after that rebalance); `valueNow` already adds back the tokens pulled for payouts.
    function recordManager(CircleStorage.Layout storage $, address mgr, uint256 base, uint256 valueNow) internal {
        int256 b = base.toInt256();
        // Signed: Solidity division truncates toward zero.
        int256 bps = b == 0 ? int256(0) : (valueNow.toInt256() - b) * BPS.toInt256() / b;
        // Trusted registry fixed at init; cannot revert for an authorized circle.
        $.registry.recordManagerEpoch(mgr, bps);
    }

    // D-06, R-J2: a passed firing wins over an appointment passed in the same settlement; an appointee no longer
    // Active (paused in this collect pass) is dropped.
    function _applyManager(CircleStorage.Layout storage $, uint256 appointId, uint256 fireId) private {
        if (fireId != 0) {
            if (appointId != 0) $.proposals[appointId].status = ProposalStatus.Dropped;
            $.proposals[fireId].status = ProposalStatus.Applied;
            emit IKuberCircleEvents.ProposalApplied(fireId);
            if ($.manager != address(0)) {
                $.manager = address(0);
                emit IKuberCircleEvents.ManagerChanged(address(0));
            }
            return;
        }
        if (appointId == 0) return;
        Proposal storage p = $.proposals[appointId];
        address t = p.target;
        if ($.members[t].status != MemberStatus.Active) {
            p.status = ProposalStatus.Dropped;
            return;
        }
        $.manager = t;
        p.status = ProposalStatus.Applied;
        emit IKuberCircleEvents.ManagerChanged(t);
        emit IKuberCircleEvents.ProposalApplied(appointId);
    }

    // D-02 per kind: decodes `data`, checks bounds on a candidate copy of the rules (Params), and returns the
    // proposal's open-slot bit.
    function _decode(
        CircleStorage.Layout storage $,
        ProposalKind kind,
        bytes calldata data,
        RuleParams memory r,
        uint256 e
    ) private view returns (uint16 bit, address target, uint8 field, uint16 value) {
        if (kind == ProposalKind.Rule) {
            uint256 v;
            (field, v) = abi.decode(data, (uint8, uint256));
            value = v.toUint16();
            _setRule(r, field, value);
            Params.validateRules(r);
            return (uint16(1) << field, address(0), field, value);
        }
        if (kind == ProposalKind.Allocation) {
            // R-K: while a manager is appointed only they may propose the money plan (still voted).
            address mgr = $.manager;
            if (mgr != address(0) && mgr != msg.sender) revert IKuberCircleErrors.OnlyManager();
            r.alloc = abi.decode(data, (Alloc));
            Params.validateRules(r);
            return (ALLOC_BIT, address(0), 0, 0);
        }
        if (kind == ProposalKind.Join) revert IKuberCircleErrors.InvalidProposal();
        target = abi.decode(data, (address));
        Member storage t = $.members[target];
        if (kind == ProposalKind.Manager) {
            // R-J2: the sitting manager cannot hold either manager slot; firing has its own slot, so squatting the
            // appoint slot cannot block it.
            if (msg.sender == $.manager) revert IKuberCircleErrors.IsManager();
            if (target == address(0)) return (FIRE_BIT, target, 0, 0);
            if (t.status != MemberStatus.Active) revert IKuberCircleErrors.InvalidTarget();
            return (MANAGER_BIT, target, 0, 0);
        }
        // Kick, the only kind left.
        if (target == msg.sender || t.status != MemberStatus.Active) revert IKuberCircleErrors.InvalidTarget();
        if ($.kickBlockedEpoch[target] == e) revert IKuberCircleErrors.KickCooldown();
        // D-04: no kick of a member with money at stake (R-M).
        if (t.activeLoanId != 0) revert IKuberCircleErrors.HasActiveLoan();
        if (t.pendingRequestId != 0) revert IKuberCircleErrors.HasPendingRequest();
        if (t.pledgedOut != 0) revert IKuberCircleErrors.HasPledges();
        return (KICK_BIT, target, 0, 0);
    }

    // D-05 thresholds: Rule and Allocation strictly more than half of the Active members; Kick
    // yes × 3 ≥ 2 × (active − 1), the target excluded, written without a subtraction and never with zero yes votes;
    // Join by lazy consensus, more than half yes or fewer than a third no.
    function _passes(Proposal storage p, uint256 active) private view returns (bool) {
        uint256 y = p.yes;
        ProposalKind kind = p.kind;
        if (kind == ProposalKind.Kick) return y != 0 && y * 3 + 2 >= 2 * active;
        if (kind == ProposalKind.Join) return y * 2 > active || uint256(p.no) * 3 < active;
        return y * 2 > active;
    }

    // R-J denominator: Active members after the collect pass (bounded by maxMembers <= 50).
    function _activeCount(CircleStorage.Layout storage $) private view returns (uint256 c) {
        address[] storage list = $.memberList;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if ($.members[list[i]].status == MemberStatus.Active) ++c;
        }
    }

    // D-03 field order is the RuleParams order.
    function _setRule(RuleParams memory r, uint256 field, uint16 v) private pure {
        if (field == 0) r.ownLtvBps = v;
        else if (field == 1) r.ownRateBps = v;
        else if (field == 2) r.perLoanMaxBps = v;
        else if (field == 3) r.fastLaneBps = v;
        else if (field == 4) r.penaltyBps = v;
        else if (field == 5) r.contribFineBps = v;
        else if (field == 6) r.installFineBps = v;
        else if (field == 7) r.exitFeeBps = v;
        else if (field == 8) r.managerFeeBps = v;
        else revert IKuberCircleErrors.InvalidRuleField();
    }
}
