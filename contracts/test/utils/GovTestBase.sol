// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, FixedParams, Member, MemberStatus, ProposalKind, RuleParams} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "./BackingTestBase.sol";

/// @dev Shared helpers for the Phase 6 tests (Governance, Membership, Manager).
abstract contract GovTestBase is BackingTestBase {
    /// @dev n members (ms[0] creates), custom totalEpochs, maxMembers, and allocation; default rules otherwise
    /// (perLoanMax 5_000). Everyone approves 5_000e6; warped to startTime and activated.
    function _startGov(uint256 n, uint8 totalEpochs, uint8 maxMembers, Alloc memory al)
        internal
        returns (KuberCircle c, address[] memory ms)
    {
        ms = _newMembers(n);
        FixedParams memory f = _fixed();
        f.totalEpochs = totalEpochs;
        f.maxMembers = maxMembers;
        RuleParams memory r = _rules();
        r.alloc = al;
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("gov", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < n; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        vm.warp(f.startTime);
        c.activate();
    }

    function _ruleAs(KuberCircle c, address who, uint8 field, uint256 value) internal returns (uint256) {
        vm.prank(who);
        return c.propose(ProposalKind.Rule, abi.encode(field, value));
    }

    function _allocAs(KuberCircle c, address who, uint16 loanBps, uint16 aaveBps, uint16 lpBps, uint16 cashBps)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return c.propose(ProposalKind.Allocation, abi.encode(loanBps, aaveBps, lpBps, cashBps));
    }

    function _kickAs(KuberCircle c, address who, address target) internal returns (uint256) {
        vm.prank(who);
        return c.propose(ProposalKind.Kick, abi.encode(target));
    }

    /// @dev Manager(target); address(0) proposes firing the manager.
    function _managerAs(KuberCircle c, address who, address target) internal returns (uint256) {
        vm.prank(who);
        return c.propose(ProposalKind.Manager, abi.encode(target));
    }

    function _applyAs(KuberCircle c, address who) internal {
        vm.prank(who);
        c.applyToJoin();
    }

    function _sponsorAs(KuberCircle c, address who, address applicant) internal returns (uint256) {
        vm.prank(who);
        return c.sponsor(applicant);
    }

    /// @dev `person` creates five Forming circles, so activeMemberships(person) == 5 (the registry cap).
    function _fiveCircles(address person) internal {
        for (uint256 i; i < 5; ++i) {
            // Before the prank: _newMembers makes owner-only registry calls a pending prank would take over.
            address[] memory invitees = _newMembers(4);
            vm.prank(person);
            factory.createCircle("x", _fixed(), _rules(), invitees);
        }
    }

    /// @dev 06-02 exit fixture: 6 members, totalEpochs 10, allocation 40/30/20/10. m0 borrows 300e6 over 1 at 10%
    /// (own 270e6, m1 vouches 30e6), funded at settle(3) and auto-repaid at settle(5) (m1 rewards 3e6, savers' pot
    /// 8_100_000). Returns in epoch 6 OPEN after 61e6 of yield arrives as cash and all six pre-pay: savings 600e6
    /// each, V 3_661e6, weights 2_100e6 each at 6.
    function _exitFixture() internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(300e6, 1, 1_000, 0);
        _vouchAs(c, ms[1], 1, 30e6);
        _settleAt(c, 4);
        vm.prank(ms[0]);
        c.claim();
        _settleAt(c, 5);
        _settleAt(c, 6);
        usdc.mint(address(c), 61e6);
        _payAllBut(c, ms, address(0));
    }

    /// @dev Σ weightAt(e) over the Active members (never borrowed too, when `saversOnly`).
    function _sumWeights(KuberCircle c, address[] memory ms, uint256 e, bool saversOnly)
        internal
        view
        returns (uint256 sum)
    {
        for (uint256 i; i < ms.length; ++i) {
            Member memory m = c.getMember(ms[i]);
            if (m.status != MemberStatus.Active || (saversOnly && m.everBorrowed)) continue;
            sum += _h(c).weightAt(ms[i], e);
        }
    }

    function _sumClaimable(KuberCircle c, address[] memory ms) internal view returns (uint256 sum) {
        for (uint256 i; i < ms.length; ++i) {
            sum += c.getMember(ms[i]).claimable;
        }
    }

    /// @dev ms[from .. from + count − 1] each vote `yes`.
    function _votes(KuberCircle c, uint256 id, address[] memory ms, uint256 from, uint256 count, bool yes) internal {
        for (uint256 i = from; i < from + count; ++i) {
            vm.prank(ms[i]);
            c.vote(id, yes);
        }
    }

    /// @dev 10 members, totalEpochs 10, allocation 40/30/20/10. m9 borrows 10e6 over 1 (funded at settle(3)), claims
    /// in epoch 4, then sets its allowance to 0. Returns in epoch 7 OPEN with m9 still Active; settle(7) pauses m9 (its
    /// only installment, due 5, found unpaid at settlements 5, 6, 7).
    function _pausedAtSeven() internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(10, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[9]);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 4);
        vm.startPrank(ms[9]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _settleAt(c, 5);
        _settleAt(c, 6);
        _settleAt(c, 7);
    }

    /// @dev PRD §7 round 3 (T-INV-3): 30 members, totalEpochs 7, allocation 5/50/35/10. In epoch 3 OPEN Alice (ms[0])
    /// and Dave (ms[2]) pre-pay; Alice requests 350e6 over 2 at 8% (Bob ms[1] vouches 80e6), Dave 350e6 over 3 at 8%
    /// (Frank ms[3] vouches 30e6, Erin ms[4] agrees 50e6). With `withVote` Alice proposes 10/45/35/10; the first
    /// `yesVotes` members vote yes (up to ten in OPEN, the rest in LOCK) and every other member votes no. Returns
    /// before settle(3).
    function _demoRound3(bool withVote, uint256 yesVotes) internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(30, 7, 50, _alloc(500, 5_000, 3_500, 1_000));
        address[] memory payers = new address[](2);
        (payers[0], payers[1]) = (ms[0], ms[2]);
        _openEpoch3(c, payers);
        vm.prank(ms[0]);
        c.requestLoan(350e6, 2, 800, 0);
        _vouchAs(c, ms[1], 1, 80e6);
        vm.prank(ms[2]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, ms[3], 2, 30e6);
        _agreeAs(c, ms[4], 2, 50e6);
        if (!withVote) return (c, ms);
        uint256 id = _allocAs(c, ms[0], 1_000, 4_500, 3_500, 1_000);
        uint256 inOpen = yesVotes < 10 ? yesVotes : 10;
        _votes(c, id, ms, 0, inOpen, true);
        _warpTo(c, 3, true);
        _votes(c, id, ms, inOpen, yesVotes - inOpen, true);
        _votes(c, id, ms, yesVotes, ms.length - yesVotes, false);
    }
}
