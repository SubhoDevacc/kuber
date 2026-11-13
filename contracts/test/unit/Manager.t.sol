// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {
    IKuberCircleErrors,
    IKuberCircleEvents,
    MemberStatus,
    ProposalKind,
    ProposalStatus
} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev T-GOV-4 (appoint and fire the fund manager by vote; only the manager proposes allocations), D-14 (the manager
/// is cleared on leave, kick, or pause), R-J2 (the manager cannot squat the manager slots; firing has its own slot
/// and wins), and the R-K track record (pulled vault tokens are added back, so a payout is not a loss).
contract ManagerTest is GovTestBase {
    /// @dev 6 members, totalEpochs 10; m0 proposes Manager(m1) in epoch 3, m0..m3 vote yes, settle(3) appoints m1.
    /// Returns in epoch 4 OPEN.
    function _appointM1() internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        uint256 id = _managerAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 0, 4, true);
        _settleAt(c, 4);
        assertEq(c.getCircleState().manager, ms[1], "m1 appointed");
    }

    function _status(KuberCircle c, uint256 id) internal view returns (uint8) {
        return uint8(c.getProposal(id).status);
    }

    /// @dev The ManagerChanged logs in `logs` from `c`, in order.
    function _managerLogs(KuberCircle c, Vm.Log[] memory logs) internal pure returns (address[] memory out) {
        uint256 n;
        out = new address[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(c) && logs[i].topics[0] == IKuberCircleEvents.ManagerChanged.selector) {
                out[n++] = address(uint160(uint256(logs[i].topics[1])));
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function test_T_GOV_4_appointAndFireByVote() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256 id = _managerAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 0, 4, true);
        _warpTo(c, 4, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(ms[1]);
        c.settle(type(uint256).max);
        assertEq(c.getCircleState().manager, ms[1], "4 of 6 appoints");
        assertEq(_status(c, id), uint8(ProposalStatus.Applied));

        // Epoch 4: m2 proposes firing; four members other than the manager say yes.
        uint256 fire = _managerAs(c, ms[2], address(0));
        _votes(c, fire, ms, 2, 4, true);
        _warpTo(c, 5, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(address(0));
        c.settle(type(uint256).max);
        assertEq(c.getCircleState().manager, address(0), "fired");
        assertEq(_status(c, fire), uint8(ProposalStatus.Applied));

        // Epoch 5: with no manager anyone eligible proposes the money plan again.
        uint256 al = _allocAs(c, ms[0], 1_000, 4_500, 3_500, 1_000);
        assertEq(_status(c, al), uint8(ProposalStatus.Open));

        // 3 of 6 is not more than half.
        (KuberCircle c2, address[] memory ms2) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c2, ms2);
        uint256 id2 = _managerAs(c2, ms2[0], ms2[1]);
        _votes(c2, id2, ms2, 0, 3, true);
        _settleAt(c2, 4);
        assertEq(_status(c2, id2), uint8(ProposalStatus.Failed));
        assertEq(c2.getCircleState().manager, address(0), "3 of 6 fails");
    }

    function test_T_GOV_4_onlyManagerProposesAllocation() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        _votes(c, _managerAs(c, ms[0], ms[1]), ms, 0, 4, true);
        _settleAt(c, 4);
        assertEq(c.getCircleState().manager, ms[1]);

        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.OnlyManager.selector);
        c.propose(ProposalKind.Allocation, abi.encode(uint16(1_000), uint16(4_500), uint16(3_500), uint16(1_000)));

        // The manager's own allocation still needs more than half: 3 of 6 fails.
        uint256 id = _allocAs(c, ms[1], 1_000, 4_500, 3_500, 1_000);
        _votes(c, id, ms, 0, 3, true);
        _settleAt(c, 5);
        assertEq(_status(c, id), uint8(ProposalStatus.Failed));
        assertEq(c.getCircleState().rules.alloc.loan, 500, "unchanged");

        id = _allocAs(c, ms[1], 1_000, 4_500, 3_500, 1_000);
        _votes(c, id, ms, 0, 4, true);
        _settleAt(c, 6);
        assertEq(_status(c, id), uint8(ProposalStatus.Applied));
        assertEq(c.getCircleState().rules.alloc.loan, 1_000);
        assertEq(c.getCircleState().rules.alloc.aave, 4_500);
        assertEq(c.getCircleState().manager, ms[1], "still manager");
    }

    function test_T_GOV_1_managerTargetMustBeActive() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        address fresh = makeAddr("fresh");
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.InvalidTarget.selector);
        c.propose(ProposalKind.Manager, abi.encode(fresh));
        // Firing has its own slot (R-J2) and needs no Active target.
        uint256 fire = _managerAs(c, ms[0], address(0));
        assertEq(c.getProposal(fire).target, address(0));
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.ProposalOpen.selector);
        c.propose(ProposalKind.Manager, abi.encode(address(0)));
        // The appoint slot is separate.
        uint256 ap = _managerAs(c, ms[1], ms[2]);
        assertEq(c.getProposal(ap).target, ms[2]);
        vm.prank(ms[3]);
        vm.expectRevert(IKuberCircleErrors.ProposalOpen.selector);
        c.propose(ProposalKind.Manager, abi.encode(ms[4]));

        // A paused member cannot be a candidate.
        (KuberCircle c2, address[] memory ms2) = _pausedAtSeven();
        _settleAt(c2, 8);
        assertEq(uint8(c2.getMember(ms2[9]).status), uint8(MemberStatus.Suspended));
        vm.prank(ms2[0]);
        vm.expectRevert(IKuberCircleErrors.InvalidTarget.selector);
        c2.propose(ProposalKind.Manager, abi.encode(ms2[9]));
    }

    function test_RJ2_managerCannotSquatAndIsFired() public {
        (KuberCircle c, address[] memory ms) = _appointM1();
        _payAllBut(c, ms, address(0));
        vm.prank(ms[0]);
        c.requestLoan(400e6, 2, 0, 0);
        assertEq(c.getLoan(1).backedNeed, 40e6, "own 360e6, backed 40e6");
        _vouchAs(c, ms[1], 1, 1e6);
        // The sitting manager can hold neither manager slot.
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.IsManager.selector);
        c.propose(ProposalKind.Manager, abi.encode(address(0)));
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.IsManager.selector);
        c.propose(ProposalKind.Manager, abi.encode(ms[1]));
        // A pledge makes the manager unkickable.
        vm.prank(ms[2]);
        vm.expectRevert(IKuberCircleErrors.HasPledges.selector);
        c.propose(ProposalKind.Kick, abi.encode(ms[1]));
        // An ally squats the appoint slot; the manager takes its own round slot with an Allocation.
        uint256 squat = _managerAs(c, ms[3], ms[3]);
        _allocAs(c, ms[1], 4_000, 3_000, 2_000, 1_000);
        _settleAt(c, 5);
        assertEq(_status(c, squat), uint8(ProposalStatus.Failed));
        assertEq(c.getCircleState().manager, ms[1]);

        // Next round: the ally squats again, yet the firing has its own slot and passes.
        _payAllBut(c, ms, address(0));
        squat = _managerAs(c, ms[3], ms[3]);
        uint256 fire = _managerAs(c, ms[2], address(0));
        _votes(c, fire, ms, 2, 4, true);
        _settleAt(c, 6);
        assertEq(c.getCircleState().manager, address(0), "fired");
        assertEq(_status(c, fire), uint8(ProposalStatus.Applied));
        assertEq(_status(c, squat), uint8(ProposalStatus.Failed));
        assertEq(c.getMember(ms[1]).pledgedOut, 1e6, "still pledged");
    }

    function test_RJ2_fireWinsOverAppoint() public {
        for (uint256 order; order < 2; ++order) {
            (KuberCircle c, address[] memory ms) = _appointM1();
            uint256 ap;
            uint256 fire;
            if (order == 0) {
                ap = _managerAs(c, ms[2], ms[3]);
                fire = _managerAs(c, ms[4], address(0));
            } else {
                fire = _managerAs(c, ms[4], address(0));
                ap = _managerAs(c, ms[2], ms[3]);
            }
            _votes(c, ap, ms, 0, 6, true);
            _votes(c, fire, ms, 0, 6, true);
            vm.recordLogs();
            _settleAt(c, 5);
            address[] memory changed = _managerLogs(c, vm.getRecordedLogs());
            assertEq(changed.length, 1, "one ManagerChanged");
            assertEq(changed[0], address(0));
            assertEq(c.getCircleState().manager, address(0), "the firing wins");
            assertEq(_status(c, ap), uint8(ProposalStatus.Dropped));
            assertEq(_status(c, fire), uint8(ProposalStatus.Applied));
        }
    }

    function test_D14_trackRecordCountsPulledTokens() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        uint256 id = _managerAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 0, 4, true);
        _warpTo(c, 4, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(ms[1]);
        c.settle(type(uint256).max);
        assertEq(c.getCircleState().manager, ms[1]);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(uint256(p.yieldPot) + p.sTotal, 1_800e6, "V");
        assertEq(p.aaveValue, 900e6);
        assertEq(p.lpValue, 630e6);
        assertEq(p.cash, 270e6);
        assertEq(_h(c).vaultValueAfterRebalance(), 1_530e6);
        // The appointing settlement credits nobody: its period belonged to no manager.
        assertEq(registry.managerStats(ms[1]).managedEpochs, 0);

        // Epoch 4.
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.OnlyManager.selector);
        c.propose(ProposalKind.Allocation, abi.encode(uint16(1_000), uint16(4_500), uint16(3_500), uint16(1_000)));
        // A 300e6 payout: cash 270e6 first, then 30e6 from Aave.
        _h(c).drain(address(0xdead), 300e6);
        assertEq(_h(c).vaultPulledSinceRebalance(), 30e6);
        assertEq(c.getPublicSummary().aaveValue, 870e6);
        // LP +10%: 631e6 in the vault (incl. the 1e6 dead shares) x 1.1 = 694_100_000; the circle's 630e6 shares
        // redeem floor(630e6 x 694_100_001 / 631_000_001).
        lp.shock(1_000);
        assertEq(c.getPublicSummary().lpValue, 692_999_999);
        id = _allocAs(c, ms[1], 1_000, 4_500, 3_500, 1_000);
        _votes(c, id, ms, 0, 3, true);
        _settleAt(c, 5);
        assertEq(_status(c, id), uint8(ProposalStatus.Failed));
        // base 1_530_000_000; before the rebalance 870_000_000 + 692_999_999 = 1_562_999_999, plus 30_000_000
        // pulled = 1_592_999_999; 62_999_999 x 10_000 / 1_530_000_000 = 411 (411.76 truncated). Without the pulled
        // tokens it would read 32_999_999 x 10_000 / 1_530_000_000 = 215: counting them keeps a payout from
        // looking like a loss.
        assertEq(int256(62_999_999) * 10_000 / 1_530_000_000, 411);
        assertEq(int256(32_999_999) * 10_000 / 1_530_000_000, 215);
        KuberRegistry.ManagerStats memory s = registry.managerStats(ms[1]);
        assertEq(s.managedEpochs, 1);
        assertEq(s.managedYieldBpsSum, 411);
        assertEq(_h(c).vaultPulledSinceRebalance(), 0, "reset by the rebalance");

        // Settlements 5 and 6 (rebalanced, APY 0) and the final 7 (read from valuation before finalize) add 0 bps.
        _settleAt(c, 6);
        _settleAt(c, 7);
        _settleAt(c, 8);
        assertEq(uint8(c.getCircleState().status), 2, "Ended");
        s = registry.managerStats(ms[1]);
        assertEq(s.managedEpochs, 4);
        assertEq(s.managedYieldBpsSum, 411);
    }

    function test_D14_managerClearedOnPause() public {
        (KuberCircle c, address[] memory ms) = _startGov(10, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        _votes(c, _managerAs(c, ms[0], ms[9]), ms, 0, 6, true);
        vm.prank(ms[9]);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 4);
        assertEq(c.getCircleState().manager, ms[9]);
        vm.startPrank(ms[9]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _settleAt(c, 5);
        _settleAt(c, 6);
        _settleAt(c, 7);
        _warpTo(c, 8, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(address(0));
        c.settle(type(uint256).max);
        assertEq(uint8(c.getMember(ms[9]).status), uint8(MemberStatus.Suspended));
        assertEq(c.getCircleState().manager, address(0));
        // Settlements 4, 5, 6; the pausing settlement's period is not credited (cleared in the collect pass).
        assertEq(registry.managerStats(ms[9]).managedEpochs, 3);
    }

    function test_D14_managerClearedOnLeave() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        _votes(c, _managerAs(c, ms[0], ms[1]), ms, 0, 4, true);
        _settleAt(c, 4);
        vm.prank(ms[1]);
        c.requestLeave();
        _warpTo(c, 5, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(address(0));
        c.settle(type(uint256).max);
        assertEq(uint8(c.getMember(ms[1]).status), uint8(MemberStatus.Left));
        assertEq(c.getCircleState().manager, address(0));
        // The outgoing manager is credited for the period 3 -> 4.
        assertEq(registry.managerStats(ms[1]).managedEpochs, 1);
    }

    function test_D14_managerClearedOnKick() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        _votes(c, _managerAs(c, ms[0], ms[1]), ms, 0, 4, true);
        _settleAt(c, 4);
        uint256 k = _kickAs(c, ms[0], ms[1]);
        vm.prank(ms[0]);
        c.vote(k, true);
        _votes(c, k, ms, 2, 3, true);
        _warpTo(c, 5, false);
        vm.expectEmit(true, true, true, true, address(c));
        emit IKuberCircleEvents.ManagerChanged(address(0));
        c.settle(type(uint256).max);
        assertEq(uint8(c.getMember(ms[1]).status), uint8(MemberStatus.Kicked));
        assertEq(c.getCircleState().manager, address(0));
        assertEq(registry.managerStats(ms[1]).managedEpochs, 1);
        assertEq(registry.memberStats(ms[1]).kicks, 1);
    }

    function test_D06_pausedCandidateNotAppointed() public {
        (KuberCircle c, address[] memory ms) = _pausedAtSeven();
        uint256 id = _managerAs(c, ms[0], ms[9]);
        _votes(c, id, ms, 0, 9, true);
        vm.recordLogs();
        _settleAt(c, 8);
        assertEq(_managerLogs(c, vm.getRecordedLogs()).length, 0, "no ManagerChanged");
        assertEq(uint8(c.getMember(ms[9]).status), uint8(MemberStatus.Suspended));
        assertEq(_status(c, id), uint8(ProposalStatus.Dropped));
        assertEq(c.getCircleState().manager, address(0));
    }

    function test_D06_appointedThenLeavesSameSettlement() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256 id = _managerAs(c, ms[0], ms[2]);
        _votes(c, id, ms, 0, 4, true);
        vm.prank(ms[2]);
        c.requestLeave();
        vm.recordLogs();
        _settleAt(c, 4);
        // D-06 order: the manager is applied before the leaves.
        address[] memory changed = _managerLogs(c, vm.getRecordedLogs());
        assertEq(changed.length, 2);
        assertEq(changed[0], ms[2]);
        assertEq(changed[1], address(0));
        assertEq(_status(c, id), uint8(ProposalStatus.Applied));
        assertEq(uint8(c.getMember(ms[2]).status), uint8(MemberStatus.Left));
        assertEq(c.getCircleState().manager, address(0));
        assertEq(registry.managerStats(ms[2]).managedEpochs, 0);
    }
}
