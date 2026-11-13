// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, LoanStatus, Member, MemberStatus} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev G3 (TEST_PLAN §10): the governance part of settlement with every loop at its maximum, plus the multi-exit and
/// combined final-batch checks at scale (06-04). M7 may fold this into Gas.t.sol. All figures are measured inside one
/// test transaction, so storage slots touched earlier in the test are warm.
contract GovernanceGasTest is GovTestBase {
    /// @dev The completing settle(1) of epoch 3 after settle(n − 1) collected everyone else.
    function _finishGas(KuberCircle c, uint256 n) internal returns (uint256 g) {
        _warpTo(c, 4, false);
        c.settle(n - 1);
        g = gasleft();
        c.settle(1);
        g -= gasleft();
    }

    /// @dev The 18 proposals of the loop-bound table (one proposer each, R-J2): nine Rule fields by m0..m8 (value 100,
    /// field 2 = 2_500), Allocation by m9, Manager(m11) by m10, Kick(kickTarget) by m12, Manager(0) by m14, and five
    /// Joins sponsored by ms[sponsorFrom .. sponsorFrom + 4]. Every member votes yes on each; the kick target skips its
    /// own Kick.
    function _eighteen(KuberCircle c, address[] memory ms, Alloc memory al, address kickTarget, uint256 sponsorFrom)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](18);
        for (uint256 f; f < 9; ++f) {
            // forge-lint: disable-next-line(unsafe-typecast)
            ids[f] = _ruleAs(c, ms[f], uint8(f), f == 2 ? 2_500 : 100);
        }
        ids[9] = _allocAs(c, ms[9], al.loan, al.aave, al.lp, al.cash);
        ids[10] = _managerAs(c, ms[10], ms[11]);
        ids[11] = _kickAs(c, ms[12], kickTarget);
        ids[12] = _managerAs(c, ms[14], address(0));
        address[] memory aps = _newMembers(5);
        for (uint256 j; j < 5; ++j) {
            _applyAs(c, aps[j]);
            ids[13 + j] = _sponsorAs(c, ms[sponsorFrom + j], aps[j]);
        }
        for (uint256 i; i < ms.length; ++i) {
            for (uint256 j; j < 18; ++j) {
                if (j == 11 && ms[i] == kickTarget) continue;
                vm.prank(ms[i]);
                c.vote(ids[j], true);
            }
        }
    }

    function test_G3_applyStep49Members18Proposals() public {
        (KuberCircle c, address[] memory ms) = _startGov(49, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256 baseline = _finishGas(c, 49);

        (c, ms) = _startGov(49, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256[] memory ids = _eighteen(c, ms, _alloc(1_000, 4_500, 3_500, 1_000), ms[13], 20);
        assertEq(c.openProposals().length, 18);
        uint256 loaded = _finishGas(c, 49);

        emit log_named_uint("finishing settle(1), 49 members, no proposals", baseline);
        emit log_named_uint("finishing settle(1), 49 members, 18 voted proposals", loaded);
        emit log_named_uint("step-2 tally and apply (difference)", loaded - baseline);
        // G3 (TEST_PLAN §10).
        assertLt(loaded - baseline, 1_000_000, "G3");
        assertLt(loaded, 8_000_000);
        // What the apply did: the kick exit, one admission, the allocation, and the firing winning over the appointment.
        assertEq(uint8(c.getMember(ms[13]).status), uint8(MemberStatus.Kicked));
        assertEq(c.members().length, 50);
        assertEq(c.getCircleState().rules.alloc.loan, 1_000);
        assertEq(c.getCircleState().manager, address(0));
        assertEq(uint8(c.getProposal(ids[10]).status), 5, "appointment Dropped");
        assertEq(uint8(c.getProposal(ids[12]).status), 4, "firing Applied");
    }

    /// @dev One Join voted yes by all 49 members and admitted: the tally of one proposal plus one admission.
    function test_admissionGas() public {
        (KuberCircle c, address[] memory ms) = _startGov(49, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256 baseline = _finishGas(c, 49);

        (c, ms) = _startGov(49, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        address ap = _newMembers(1)[0];
        _applyAs(c, ap);
        _votes(c, _sponsorAs(c, ms[0], ap), ms, 0, 49, true);
        uint256 g = _finishGas(c, 49);
        assertEq(uint8(c.getMember(ap).status), uint8(MemberStatus.Active));

        // The same tally with a Rule proposal instead, to separate the admission.
        (c, ms) = _startGov(49, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        _votes(c, _ruleAs(c, ms[0], 1, 500), ms, 0, 49, true);
        uint256 rule = _finishGas(c, 49);
        emit log_named_uint("finishing settle(1), one Join tallied and admitted", g);
        emit log_named_uint("finishing settle(1), one Rule tallied and applied", rule);
        emit log_named_uint("one-proposal tally and apply over 49 members (rule - baseline)", rule - baseline);
        emit log_named_uint("one admission (join - rule)", g - rule);
        assertLt(g - baseline, 1_000_000);
    }

    function test_applyStep49Leaves() public {
        (KuberCircle c, address[] memory ms) = _startGov(50, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        uint256 baseline = _finishGas(c, 50);

        (c, ms) = _startGov(50, 10, 50, _rules().alloc);
        _openEpoch3(c, ms);
        for (uint256 i = 1; i < 50; ++i) {
            vm.prank(ms[i]);
            c.requestLeave();
        }
        uint256 g = _finishGas(c, 50);
        emit log_named_uint("finishing settle(1), 50 members, no exits", baseline);
        emit log_named_uint("finishing settle(1), 50 members, 49 leaves", g);
        emit log_named_uint("per exit", (g - baseline) / 49);
        assertLt(g, 8_000_000);
        assertEq(uint8(c.getMember(ms[49]).status), uint8(MemberStatus.Left));
        assertEq(uint8(c.getMember(ms[0]).status), uint8(MemberStatus.Active));
    }

    /// @dev W5: 49 members; m48 defaults at settle(7) (18 ballots dropped) in the same completing call as 23 leaves, a
    /// kick, 24 fundings, the 18 proposals, and one admission.
    function test_G1_combinedFinalBatch() public {
        (KuberCircle c, address[] memory ms) = _startGov(49, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[48]);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 4);
        vm.startPrank(ms[48]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _settleAt(c, 5);
        _settleAt(c, 6);
        _settleAt(c, 7);
        // Epoch 7.
        for (uint256 i = 1; i <= 23; ++i) {
            vm.prank(ms[i]);
            c.requestLeave();
        }
        vm.prank(ms[0]);
        c.requestLoan(10e6, 1, 0, 0);
        for (uint256 i = 25; i <= 47; ++i) {
            vm.prank(ms[i]);
            c.requestLoan(10e6, 1, 0, 0);
        }
        _eighteen(c, ms, _alloc(3_500, 3_500, 2_000, 1_000), ms[24], 30);
        _warpTo(c, 8, false);
        c.settle(25);
        uint256 g = gasleft();
        c.settle(24);
        g -= gasleft();
        emit log_named_uint("completing settle(24): 23 leaves, kick, 24 fundings, 18 proposals, default", g);
        assertLt(g, 8_000_000);

        assertEq(uint8(c.getMember(ms[48]).status), uint8(MemberStatus.Suspended));
        assertEq(uint8(c.getMember(ms[24]).status), uint8(MemberStatus.Kicked));
        assertEq(uint8(c.getMember(ms[1]).status), uint8(MemberStatus.Left));
        uint256 funded;
        for (uint256 id = 2; id <= 25; ++id) {
            if (c.getLoan(id).status == LoanStatus.Funded) ++funded;
        }
        assertEq(funded, 24);
        address[] memory all = c.members();
        assertEq(all.length, 50);
        assertEq(c.getCircleState().rules.alloc.loan, 3_500);
        assertEq(_sumWeights(c, all, 7, false), _h(c).wActiveAt(7), "W_active");
        assertEq(_sumWeights(c, all, 7, true), _h(c).wSaverAt(7), "W_saver");
        assertEq(c.getPublicSummary().reservedClaims, _sumClaimable(c, all), "reservedClaims");

        for (uint256 i; i < all.length; ++i) {
            vm.prank(all[i]);
            usdc.approve(address(c), 5_000e6);
        }
        _settleAt(c, 9);
        _settleAt(c, 10);
        _settleAt(c, 11);
        assertEq(uint8(c.getCircleState().status), 2, "Ended");
        for (uint256 i; i < all.length; ++i) {
            Member memory m = c.getMember(all[i]);
            vm.startPrank(all[i]);
            if (m.status == MemberStatus.Active || m.status == MemberStatus.Suspended) c.withdraw();
            if (c.getMember(all[i]).claimable != 0) c.claim();
            vm.stopPrank();
        }
    }
}
