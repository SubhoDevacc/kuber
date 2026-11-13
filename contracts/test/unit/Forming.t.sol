// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    CircleStatus,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    MemberStatus
} from "../../src/lib/CircleTypes.sol";

contract FormingTest is CircleTestBase {
    function _status(KuberCircle c) internal view returns (CircleStatus) {
        return c.getCircleState().status;
    }

    function _contains(address[] memory list, address who) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == who) return true;
        }
        return false;
    }

    function _expectJoinRevert(KuberCircle c, address who, bytes4 sel) internal {
        vm.expectRevert(sel);
        vm.prank(who);
        c.join();
    }

    function test_T_FRM_1_onlyInvitedVerifiedDebtFreeJoin() public {
        address[] memory ms = _newMembers(7); // creator, 4 clean invitees, then an unverified and an indebted one
        address unverified = ms[5];
        address indebted = ms[6];
        address outsider = _newMembers(1)[0];
        KuberCircle c = _create(ms);
        registry.setVerified(unverified, false);
        _debt(indebted);

        _expectJoinRevert(c, outsider, IKuberCircleErrors.NotInvited.selector);
        _expectJoinRevert(c, unverified, IKuberCircleErrors.NotVerified.selector);
        _expectJoinRevert(c, indebted, IKuberCircleErrors.HasOpenDebt.selector);
        assertEq(c.members().length, 1);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Joined(ms[1]);
        vm.prank(ms[1]);
        c.join();
        address[] memory mem = c.members();
        assertEq(mem.length, 2);
        assertEq(mem[1], ms[1]);
        assertEq(registry.activeMemberships(ms[1]), 1);
        assertEq(uint8(c.getMember(ms[1]).status), uint8(MemberStatus.Active));

        _expectJoinRevert(c, ms[1], IKuberCircleErrors.AlreadyMember.selector);
        // The creator is a member but never in the invite map (InvalidInvite), so the NotInvited check fires first.
        _expectJoinRevert(c, ms[0], IKuberCircleErrors.NotInvited.selector);
    }

    function test_T_FRM_1_requestToJoinThenInvite() public {
        address[] memory ms = _newMembers(5);
        address[] memory extra = _newMembers(3);
        (address outsider, address unverified, address indebted) = (extra[0], extra[1], extra[2]);
        KuberCircle c = _create(ms);
        registry.setVerified(unverified, false);
        _debt(indebted);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.JoinRequested(outsider);
        vm.prank(outsider);
        c.requestToJoin();
        _expectJoinRevert(c, outsider, IKuberCircleErrors.NotInvited.selector); // a request is not an invite

        vm.expectRevert(IKuberCircleErrors.NotVerified.selector);
        vm.prank(unverified);
        c.requestToJoin();
        vm.expectRevert(IKuberCircleErrors.HasOpenDebt.selector);
        vm.prank(indebted);
        c.requestToJoin();

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Invited(outsider);
        vm.prank(ms[0]);
        c.invite(outsider);
        vm.prank(outsider);
        c.join();
        assertTrue(_contains(c.members(), outsider));
        assertEq(registry.activeMemberships(outsider), 1);
    }

    // A-5: the AlreadyMember and NotForming paths of requestToJoin.
    function test_requestToJoinAlreadyMemberAndNotForming() public {
        (KuberCircle c, address[] memory ms) = _start(5);
        address outsider = _newMembers(1)[0];
        vm.expectRevert(IKuberCircleErrors.NotForming.selector);
        vm.prank(outsider);
        c.requestToJoin();

        ms = _newMembers(5);
        c = _create(ms);
        vm.prank(ms[1]);
        c.join();
        vm.expectRevert(IKuberCircleErrors.AlreadyMember.selector);
        vm.prank(ms[1]);
        c.requestToJoin();
        vm.expectRevert(IKuberCircleErrors.AlreadyMember.selector);
        vm.prank(ms[0]);
        c.requestToJoin();
    }

    function test_T_FRM_1_inviteRules() public {
        address[] memory ms = _newMembers(5);
        address[] memory extra = _newMembers(2);
        (address fresh, address indebted) = (extra[0], extra[1]);
        KuberCircle c = _create(ms);
        _debt(indebted);

        vm.expectRevert(IKuberCircleErrors.NotCreator.selector);
        vm.prank(ms[1]);
        c.invite(fresh);
        vm.expectRevert(IKuberCircleErrors.HasOpenDebt.selector);
        vm.prank(ms[0]);
        c.invite(indebted);
        vm.expectRevert(IKuberCircleErrors.InvalidInvite.selector);
        vm.prank(ms[0]);
        c.invite(address(0));

        _join(c, _tail(ms));
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
        vm.expectRevert(IKuberCircleErrors.NotForming.selector);
        vm.prank(ms[0]);
        c.invite(fresh);
    }

    function test_T_FRM_1_circleFull() public {
        address[] memory ms = _newMembers(6);
        FixedParams memory f = _fixed();
        f.maxMembers = 5;
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("circle", f, _rules(), inv));
        for (uint256 i = 1; i <= 4; ++i) {
            vm.prank(ms[i]);
            c.join();
        }
        assertEq(c.members().length, 5);
        _expectJoinRevert(c, ms[5], IKuberCircleErrors.CircleFull.selector);
        assertEq(registry.activeMemberships(ms[5]), 0);
    }

    function test_T_FRM_2_activateBeforeStartReverts() public {
        address[] memory ms = _newMembers(5);
        KuberCircle c = _create(ms);
        _join(c, _tail(ms));
        vm.warp(c.getCircleState().fixedParams.startTime - 1);
        vm.expectRevert(IKuberCircleErrors.TooEarly.selector);
        c.activate();
        assertEq(uint8(_status(c)), uint8(CircleStatus.Forming));
    }

    function test_T_FRM_2_activateWithEnoughMembersGoesActive() public {
        address[] memory ms = _newMembers(5);
        KuberCircle c = _create(ms);
        _join(c, _tail(ms));
        vm.warp(c.getCircleState().fixedParams.startTime);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Activated();
        vm.prank(makeAddr("keeper"));
        c.activate();
        assertEq(uint8(_status(c)), uint8(CircleStatus.Active));
        assertEq(c.currentEpoch(), 1);
        for (uint256 i; i < 5; ++i) {
            assertEq(registry.activeMemberships(ms[i]), 1);
        }

        vm.expectRevert(IKuberCircleErrors.NotForming.selector);
        c.activate();
    }

    function test_T_FRM_2_activateWithTooFewCancels() public {
        address[] memory ms = _newMembers(5);
        KuberCircle c = _create(ms);
        for (uint256 i = 1; i <= 3; ++i) {
            vm.prank(ms[i]);
            c.join();
        }
        vm.warp(c.getCircleState().fixedParams.startTime);

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Cancelled();
        c.activate();
        assertEq(uint8(_status(c)), uint8(CircleStatus.Cancelled));
        for (uint256 i; i < 4; ++i) {
            assertEq(registry.activeMemberships(ms[i]), 0);
        }
        _expectJoinRevert(c, ms[4], IKuberCircleErrors.NotForming.selector);
    }

    function test_T_FRM_3_noTokensMoveWhileForming() public {
        address[] memory ms = _newMembers(6);
        address outsider = _newMembers(1)[0];
        address[] memory everyone = new address[](7);
        uint256[] memory before = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            everyone[i] = i < 6 ? ms[i] : outsider;
            before[i] = usdc.balanceOf(everyone[i]);
        }
        uint256 factoryBefore = usdc.balanceOf(address(factory));
        uint256 supplyBefore = usdc.totalSupply();

        KuberCircle c = _create(ms);
        _join(c, _tail(ms)); // joins plus the R-G approvals
        vm.prank(outsider);
        c.requestToJoin();
        vm.prank(ms[0]);
        c.invite(outsider);
        vm.prank(outsider);
        c.join();
        vm.prank(ms[5]);
        c.leave();
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
        assertEq(uint8(_status(c)), uint8(CircleStatus.Active));

        for (uint256 i; i < 7; ++i) {
            assertEq(usdc.balanceOf(everyone[i]), before[i]);
        }
        assertEq(usdc.balanceOf(address(factory)), factoryBefore);
        assertEq(usdc.balanceOf(address(c)), 0);
        assertEq(usdc.totalSupply(), supplyBefore);
        assertEq(usdc.allowance(ms[1], address(c)), 700e6); // approval set, nothing pulled
    }

    function test_T_FRM_3_cancelIsCreatorOnly() public {
        address[] memory ms = _newMembers(5);
        KuberCircle c = _create(ms);
        _join(c, _tail(ms));

        vm.expectRevert(IKuberCircleErrors.NotCreator.selector);
        vm.prank(ms[1]);
        c.cancel();

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Cancelled();
        vm.prank(ms[0]);
        c.cancel();
        assertEq(uint8(_status(c)), uint8(CircleStatus.Cancelled));
        for (uint256 i; i < 5; ++i) {
            assertEq(registry.activeMemberships(ms[i]), 0);
        }

        vm.expectRevert(IKuberCircleErrors.NotForming.selector);
        vm.prank(ms[0]);
        c.cancel();
    }

    function test_leaveWhileForming() public {
        address[] memory ms = _newMembers(5);
        address outsider = _newMembers(1)[0];
        KuberCircle c = _create(ms);
        _join(c, _tail(ms));
        address leaver = ms[2];

        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberLeft(leaver, 0);
        vm.prank(leaver);
        c.leave();
        address[] memory mem = c.members();
        assertEq(mem.length, 4);
        assertFalse(_contains(mem, leaver));
        assertEq(uint8(c.getMember(leaver).status), uint8(MemberStatus.None));
        assertEq(registry.activeMemberships(leaver), 0);

        vm.prank(leaver);
        c.join(); // still invited
        assertTrue(_contains(c.members(), leaver));
        assertEq(registry.activeMemberships(leaver), 1);

        vm.expectRevert(IKuberCircleErrors.CreatorCannotLeave.selector);
        vm.prank(ms[0]);
        c.leave();
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        vm.prank(outsider);
        c.leave();

        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
        vm.expectRevert(IKuberCircleErrors.NotForming.selector);
        vm.prank(ms[1]);
        c.leave();
    }
}
