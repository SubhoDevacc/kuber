// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {
    CircleStatus,
    CircleStorage,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    MAX_MEMBERS,
    MIN_INVITES,
    MemberStatus,
    RuleParams
} from "./CircleTypes.sol";
import {Params} from "./Params.sol";
import {KuberFactory} from "../KuberFactory.sol";

/// @notice Linked library (delegatecalled by KuberCircle): `msg.sender` is the circle's caller and
/// `address(this)` is the circle. No token moves here.
library Forming {
    /// @notice Validates params, stores config and invites, and makes the creator a member (R-B, I10).
    function init(
        CircleStorage.Layout storage $,
        address creator,
        string calldata name,
        FixedParams calldata fixedParams_,
        RuleParams calldata rules_,
        address[] calldata invites
    ) external {
        Params.validateFixed(fixedParams_);
        Params.validateRules(rules_);
        // Dependencies come from the calling factory; a clone initialized elsewhere is never authorized.
        KuberFactory factory = KuberFactory(msg.sender);
        $.registry = factory.REGISTRY();
        $.token = factory.TOKEN();
        $.aaveVault = factory.AAVE_VAULT();
        $.lpVault = factory.LP_VAULT();
        $.name = name;
        $.fixedParams = fixedParams_;
        $.rules = rules_;
        $.creator = creator;
        if (invites.length > MAX_MEMBERS) revert IKuberCircleErrors.TooManyInvites();
        uint256 distinct = 0;
        for (uint256 i; i < invites.length; ++i) {
            address who = invites[i];
            if (who == address(0) || who == creator) revert IKuberCircleErrors.InvalidInvite();
            if (!$.invited[who]) {
                $.invited[who] = true;
                ++distinct;
                emit IKuberCircleEvents.Invited(who);
            }
        }
        if (distinct < MIN_INVITES) revert IKuberCircleErrors.TooFewInvites();
        _addMember($, creator);
    }

    function invite(CircleStorage.Layout storage $, address who) external {
        if (msg.sender != $.creator) revert IKuberCircleErrors.NotCreator();
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        if (who == address(0)) revert IKuberCircleErrors.InvalidInvite();
        if ($.registry.hasOpenDebt(who)) revert IKuberCircleErrors.HasOpenDebt();
        $.invited[who] = true;
        emit IKuberCircleEvents.Invited(who);
    }

    function requestToJoin(CircleStorage.Layout storage $) external {
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        if (!$.registry.verified(msg.sender)) revert IKuberCircleErrors.NotVerified();
        if ($.registry.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        if ($.members[msg.sender].status != MemberStatus.None) revert IKuberCircleErrors.AlreadyMember();
        $.joinRequested[msg.sender] = true;
        emit IKuberCircleEvents.JoinRequested(msg.sender);
    }

    function join(CircleStorage.Layout storage $) external {
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        if (!$.invited[msg.sender]) revert IKuberCircleErrors.NotInvited();
        if ($.members[msg.sender].status != MemberStatus.None) revert IKuberCircleErrors.AlreadyMember();
        if (!$.registry.verified(msg.sender)) revert IKuberCircleErrors.NotVerified();
        if ($.registry.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        if ($.memberList.length >= $.fixedParams.maxMembers) revert IKuberCircleErrors.CircleFull();
        _addMember($, msg.sender);
    }

    /// @notice A non-creator member leaves while Forming; `invited` stays, so they may join again.
    function leave(CircleStorage.Layout storage $) external {
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        if ($.members[msg.sender].status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (msg.sender == $.creator) revert IKuberCircleErrors.CreatorCannotLeave();
        address[] storage list = $.memberList;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == msg.sender) {
                list[i] = list[n - 1];
                list.pop();
                break;
            }
        }
        delete $.members[msg.sender];
        emit IKuberCircleEvents.MemberLeft(msg.sender, 0);
        $.registry.recordLeave(msg.sender);
    }

    function cancel(CircleStorage.Layout storage $) external {
        if (msg.sender != $.creator) revert IKuberCircleErrors.NotCreator();
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        _cancel($);
    }

    /// @notice Anyone, at or after startTime: Active with at least minMembers, otherwise Cancelled.
    function activate(CircleStorage.Layout storage $) external {
        if ($.status != CircleStatus.Forming) revert IKuberCircleErrors.NotForming();
        if (block.timestamp < $.fixedParams.startTime) revert IKuberCircleErrors.TooEarly();
        if ($.memberList.length >= $.fixedParams.minMembers) {
            $.status = CircleStatus.Active;
            emit IKuberCircleEvents.Activated();
        } else {
            _cancel($);
        }
    }

    function _addMember(CircleStorage.Layout storage $, address who) private {
        $.members[who].status = MemberStatus.Active;
        $.memberList.push(who);
        emit IKuberCircleEvents.Joined(who);
        $.registry.recordJoin(who);
    }

    // Frees every member's registry slot (I19); the list is at most maxMembers <= 50 long.
    function _cancel(CircleStorage.Layout storage $) private {
        $.status = CircleStatus.Cancelled;
        emit IKuberCircleEvents.Cancelled();
        address[] storage list = $.memberList;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            $.registry.recordLeave(list[i]);
        }
    }
}
