// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";

contract KuberRegistryTest is Test {
    KuberRegistry internal registry;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal factory = makeAddr("factory");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal sponsor = makeAddr("sponsor");
    address internal manager = makeAddr("manager");
    address internal c1 = makeAddr("circle1");
    address internal c2 = makeAddr("circle2");
    address internal c3 = makeAddr("circle3");
    address internal c4 = makeAddr("circle4");
    address internal c5 = makeAddr("circle5");
    address internal c6 = makeAddr("circle6");

    function setUp() public {
        registry = new KuberRegistry(owner, treasury);
        vm.prank(owner);
        registry.setFactory(factory);
        vm.startPrank(factory);
        registry.authorizeCircle(c1);
        registry.authorizeCircle(c2);
        registry.authorizeCircle(c3);
        registry.authorizeCircle(c4);
        registry.authorizeCircle(c5);
        registry.authorizeCircle(c6);
        vm.stopPrank();
    }

    function _join(address circle, address person) internal {
        vm.prank(circle);
        registry.recordJoin(person);
    }

    function _joinFive(address person) internal {
        _join(c1, person);
        _join(c2, person);
        _join(c3, person);
        _join(c4, person);
        _join(c5, person);
    }

    // ---------- T-REG-1 ----------

    function test_T_REG_1_setVerifiedOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setVerified(alice, true);

        vm.expectEmit(true, false, false, true);
        emit KuberRegistry.VerifiedSet(alice, true);
        vm.prank(owner);
        registry.setVerified(alice, true);
        assertTrue(registry.verified(alice));

        vm.expectEmit(true, false, false, true);
        emit KuberRegistry.VerifiedSet(alice, false);
        vm.prank(owner);
        registry.setVerified(alice, false);
        assertFalse(registry.verified(alice));
    }

    function test_T_REG_1_unauthorizedHistoryWritesRevert() public {
        bytes memory notCircle = abi.encodeWithSelector(KuberRegistry.NotCircle.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(notCircle);
        registry.recordJoin(alice);
        vm.expectRevert(notCircle);
        registry.recordLeave(alice);
        vm.expectRevert(notCircle);
        registry.recordKick(alice);
        vm.expectRevert(notCircle);
        registry.recordComplete(alice);
        vm.expectRevert(notCircle);
        registry.recordLoan(alice);
        vm.expectRevert(notCircle);
        registry.recordRepaid(alice, true);
        vm.expectRevert(notCircle);
        registry.recordLateInstallment(alice);
        vm.expectRevert(notCircle);
        registry.recordSuspension(alice, sponsor);
        vm.expectRevert(notCircle);
        registry.recordSponsored(sponsor);
        vm.expectRevert(notCircle);
        registry.recordSponsoredCompleted(sponsor);
        vm.expectRevert(notCircle);
        registry.recordManagerEpoch(manager, 100);
        vm.expectRevert(notCircle);
        registry.addDebt(alice);
        vm.expectRevert(notCircle);
        registry.clearDebt(alice);
        vm.stopPrank();

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.NotCircle.selector, factory));
        registry.recordJoin(alice);
    }

    function test_T_REG_1_onlyFactoryAuthorizes() public {
        KuberRegistry fresh = new KuberRegistry(owner, treasury);
        address c = makeAddr("freshCircle");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.NotFactory.selector, stranger));
        fresh.authorizeCircle(c);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setFactory(factory);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.ZeroAddress.selector));
        fresh.setFactory(address(0));

        vm.expectEmit(true, false, false, true);
        emit KuberRegistry.FactorySet(factory);
        vm.prank(owner);
        fresh.setFactory(factory);
        assertEq(fresh.factory(), factory);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.FactoryAlreadySet.selector));
        fresh.setFactory(stranger);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.NotFactory.selector, owner));
        fresh.authorizeCircle(c);

        vm.expectEmit(true, false, false, true);
        emit KuberRegistry.CircleAuthorized(c);
        vm.prank(factory);
        fresh.authorizeCircle(c);
        assertTrue(fresh.isCircle(c));
    }

    function test_T_REG_1_authorizedCircleWritesHistory() public {
        vm.startPrank(c1);

        registry.recordLoan(alice);
        assertEq(registry.memberStats(alice).loansTaken, 1);

        registry.recordRepaid(alice, false);
        assertEq(registry.memberStats(alice).repaidOnTime, 0);
        registry.recordRepaid(alice, true);
        assertEq(registry.memberStats(alice).repaidOnTime, 1);

        registry.recordLateInstallment(alice);
        assertEq(registry.memberStats(alice).lateInstallments, 1);

        registry.recordSuspension(alice, address(0));
        assertEq(registry.memberStats(alice).suspensions, 1);
        assertEq(registry.sponsorStats(sponsor).sponsoredSuspended, 0);
        assertEq(registry.sponsorStats(address(0)).sponsoredSuspended, 0);

        registry.recordSuspension(alice, sponsor);
        assertEq(registry.memberStats(alice).suspensions, 2);
        assertEq(registry.sponsorStats(sponsor).sponsoredSuspended, 1);

        registry.recordSponsored(sponsor);
        assertEq(registry.sponsorStats(sponsor).sponsoredCount, 1);

        registry.recordSponsoredCompleted(sponsor);
        assertEq(registry.sponsorStats(sponsor).sponsoredCompleted, 1);

        registry.recordManagerEpoch(manager, 150);
        registry.recordManagerEpoch(manager, -200);
        assertEq(registry.managerStats(manager).managedEpochs, 2);
        assertEq(registry.managerStats(manager).managedYieldBpsSum, -50);

        vm.stopPrank();

        // Every writer touched only its own fields.
        KuberRegistry.MemberStats memory m = registry.memberStats(alice);
        assertEq(m.circlesJoined, 0);
        assertEq(m.circlesCompleted, 0);
        assertEq(m.loansTaken, 1);
        assertEq(m.repaidOnTime, 1);
        assertEq(m.lateInstallments, 1);
        assertEq(m.suspensions, 2);
        assertEq(m.kicks, 0);
        assertEq(registry.activeMemberships(alice), 0);
        assertEq(registry.sponsorStats(sponsor).sponsoredCount, 1);
        assertEq(registry.sponsorStats(sponsor).sponsoredCompleted, 1);
        assertEq(registry.sponsorStats(sponsor).sponsoredSuspended, 1);
        assertEq(registry.memberStats(sponsor).suspensions, 0);
        assertEq(registry.managerStats(alice).managedEpochs, 0);
    }

    // ---------- T-REG-2 ----------

    function test_T_REG_2_membershipCap() public {
        _joinFive(alice);
        assertEq(registry.activeMemberships(alice), 5);
        assertEq(registry.memberStats(alice).circlesJoined, 5);

        vm.prank(c6);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.MembershipCapReached.selector, alice));
        registry.recordJoin(alice);
        assertEq(registry.activeMemberships(alice), 5);
    }

    function test_T_REG_2_leaveKickCompleteFreeSlot() public {
        _joinFive(alice);

        vm.prank(c1);
        registry.recordLeave(alice);
        assertEq(registry.activeMemberships(alice), 4);
        _join(c6, alice);
        assertEq(registry.activeMemberships(alice), 5);
        assertEq(registry.memberStats(alice).circlesJoined, 6);

        vm.prank(c2);
        registry.recordKick(alice);
        assertEq(registry.activeMemberships(alice), 4);
        assertEq(registry.memberStats(alice).kicks, 1);

        vm.prank(c3);
        registry.recordComplete(alice);
        assertEq(registry.activeMemberships(alice), 3);
        assertEq(registry.memberStats(alice).circlesCompleted, 1);
    }

    function test_T_REG_2_decrementsFloorAtZero() public {
        vm.startPrank(c1);
        registry.recordLeave(alice);
        assertEq(registry.activeMemberships(alice), 0);
        registry.recordKick(alice);
        assertEq(registry.activeMemberships(alice), 0);
        registry.recordComplete(alice);
        assertEq(registry.activeMemberships(alice), 0);
        vm.stopPrank();

        assertEq(registry.memberStats(alice).kicks, 1);
        assertEq(registry.memberStats(alice).circlesCompleted, 1);
    }

    function test_T_REG_2_debtIndexNeverReverts() public {
        vm.expectEmit(true, true, false, true);
        emit KuberRegistry.DebtAdded(alice, c1);
        vm.prank(c1);
        registry.addDebt(alice);

        vm.recordLogs();
        vm.prank(c1);
        registry.addDebt(alice);
        assertEq(vm.getRecordedLogs().length, 0);

        address[] memory d = registry.debtCircles(alice);
        assertEq(d.length, 1);
        assertEq(d[0], c1);
        assertTrue(registry.hasOpenDebt(alice));

        vm.prank(c2);
        registry.addDebt(alice);
        assertEq(registry.debtCircles(alice).length, 2);

        vm.expectEmit(true, true, false, true);
        emit KuberRegistry.DebtCleared(alice, c1);
        vm.prank(c1);
        registry.clearDebt(alice);

        vm.recordLogs();
        vm.prank(c1);
        registry.clearDebt(alice);
        assertEq(vm.getRecordedLogs().length, 0);

        d = registry.debtCircles(alice);
        assertEq(d.length, 1);
        assertEq(d[0], c2);
        assertTrue(registry.hasOpenDebt(alice));

        vm.prank(c2);
        registry.clearDebt(alice);
        assertFalse(registry.hasOpenDebt(alice));
        assertEq(registry.debtCircles(alice).length, 0);

        vm.prank(c3);
        registry.clearDebt(alice);
        assertFalse(registry.hasOpenDebt(alice));
    }

    // ---------- T-REG-3 ----------

    function test_T_REG_3_protocolFeeBounds() public {
        assertEq(registry.protocolFeeBps(), 1_000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.FeeTooHigh.selector, uint16(2_001)));
        registry.setProtocolFeeBps(2_001);

        vm.expectEmit(false, false, false, true);
        emit KuberRegistry.ProtocolFeeSet(2_000);
        vm.prank(owner);
        registry.setProtocolFeeBps(2_000);
        assertEq(registry.protocolFeeBps(), 2_000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setProtocolFeeBps(500);
    }

    function test_T_REG_3_treasuryOwnerOnly() public {
        address t2 = makeAddr("treasury2");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setTreasury(t2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.ZeroAddress.selector));
        registry.setTreasury(address(0));

        vm.expectEmit(true, false, false, true);
        emit KuberRegistry.TreasurySet(t2);
        vm.prank(owner);
        registry.setTreasury(t2);
        assertEq(registry.treasury(), t2);

        vm.expectRevert(abi.encodeWithSelector(KuberRegistry.ZeroAddress.selector));
        new KuberRegistry(owner, address(0));
    }

    function test_T_REG_3_gasSettingsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setGasSettings(25_000_000, 100 gwei, 5_000_000);

        vm.expectEmit(false, false, false, true);
        emit KuberRegistry.GasSettingsSet(25_000_000, 100 gwei, 5_000_000);
        vm.prank(owner);
        registry.setGasSettings(25_000_000, 100 gwei, 5_000_000);
        assertEq(registry.avaxPriceUsd6(), 25_000_000);
        assertEq(registry.gasPriceCap(), 100 gwei);
        assertEq(registry.maxReimbursePerEpoch(), 5_000_000);

        bytes memory outOfBounds = abi.encodeWithSelector(KuberRegistry.GasSettingsOutOfBounds.selector);
        vm.startPrank(owner);
        vm.expectRevert(outOfBounds);
        registry.setGasSettings(1e12 + 1, 1e15, 1e12);
        vm.expectRevert(outOfBounds);
        registry.setGasSettings(1e12, 1e15 + 1, 1e12);
        vm.expectRevert(outOfBounds);
        registry.setGasSettings(1e12, 1e15, 1e12 + 1);

        registry.setGasSettings(1e12, 1e15, 1e12);
        vm.stopPrank();
        assertEq(registry.avaxPriceUsd6(), 1e12);
        assertEq(registry.gasPriceCap(), 1e15);
        assertEq(registry.maxReimbursePerEpoch(), 1e12);
    }

    function test_T_REG_3_constantsAndConstructor() public view {
        assertEq(registry.MAX_ACTIVE_CIRCLES(), 5);
        assertEq(registry.MAX_PROTOCOL_FEE_BPS(), 2_000);
        assertEq(registry.owner(), owner);
        assertEq(registry.treasury(), treasury);
    }
}
