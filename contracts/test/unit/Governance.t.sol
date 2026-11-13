// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    MemberStatus,
    Proposal,
    ProposalKind,
    ProposalStatus
} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev Governance (06-01..06-03): T-GOV-1, T-GOV-2 (rule, allocation, kick, and join thresholds), T-GOV-3,
/// T-INV-2 (by vote), T-INV-3, T-LN-2, T-EP-2 (proposals). Contribution 100e6, vault APY 0, settlements at the exact
/// start of the next epoch.
contract GovernanceTest is GovTestBase {
    /// @dev totalEpochs 7, default allocation 5/50/35/10.
    function _defaultGov(uint256 n) private returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startGov(n, 7, 50, _alloc(500, 5_000, 3_500, 1_000));
    }

    function _ruleReverts(KuberCircle c, address who, uint8 field, uint256 value, bytes4 sel) private {
        vm.expectRevert(sel);
        _ruleAs(c, who, field, value);
    }

    function _allocReverts(KuberCircle c, address who, uint16 l, uint16 a, uint16 p, uint16 h, bytes4 sel) private {
        vm.expectRevert(sel);
        _allocAs(c, who, l, a, p, h);
    }

    function _status(KuberCircle c, uint256 id) private view returns (ProposalStatus) {
        return c.getProposal(id).status;
    }

    function test_T_GOV_1_proposerMustBeActiveWithMinSave() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(6);
        _settleAt(c, 2);
        _settleAt(c, 3);
        // paidCount 2 < minSaveEpochs 3.
        _ruleReverts(c, ms[0], 1, 500, IKuberCircleErrors.NotEnoughSaved.selector);
        _ruleReverts(c, makeAddr("stranger"), 1, 500, IKuberCircleErrors.NotMember.selector);
        _payNowAs(c, ms[0]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalCreated(1, ProposalKind.Rule, ms[0], abi.encode(uint8(1), uint256(500)));
        assertEq(_ruleAs(c, ms[0], 1, 500), 1);
        Proposal memory p = c.getProposal(1);
        assertEq(uint256(p.status), uint256(ProposalStatus.Open));
        assertEq(uint256(p.kind), uint256(ProposalKind.Rule));
        assertEq(p.epoch, 3);
        assertEq(p.field, 1);
        assertEq(p.value, 500);
        assertEq(p.proposer, ms[0]);
    }

    function test_T_GOV_1_boundsCheckedWhenProposing() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(10);
        _openEpoch3(c, ms);
        address m0 = ms[0];
        // A reverted call does not use the member's round slot.
        _ruleReverts(c, m0, 0, 10_001, IKuberCircleErrors.InvalidOwnLtv.selector);
        _ruleReverts(c, m0, 1, 2_001, IKuberCircleErrors.InvalidOwnRate.selector);
        _ruleReverts(c, m0, 2, 999, IKuberCircleErrors.InvalidPerLoanMax.selector);
        _ruleReverts(c, m0, 2, 10_001, IKuberCircleErrors.InvalidPerLoanMax.selector);
        _ruleReverts(c, m0, 3, 5_001, IKuberCircleErrors.InvalidFastLane.selector);
        _ruleReverts(c, m0, 4, 5_001, IKuberCircleErrors.InvalidPenalty.selector);
        _ruleReverts(c, m0, 5, 1_001, IKuberCircleErrors.InvalidContribFine.selector);
        _ruleReverts(c, m0, 6, 2_001, IKuberCircleErrors.InvalidInstallFine.selector);
        _ruleReverts(c, m0, 7, 2_001, IKuberCircleErrors.InvalidExitFee.selector);
        _ruleReverts(c, m0, 8, 1_001, IKuberCircleErrors.InvalidManagerFee.selector);
        _ruleReverts(c, m0, 9, 1, IKuberCircleErrors.InvalidRuleField.selector);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, 70_000));
        _ruleAs(c, m0, 1, 70_000);
        // Join proposals come only from sponsor (06-03).
        vm.expectRevert(IKuberCircleErrors.InvalidProposal.selector);
        vm.prank(m0);
        c.propose(ProposalKind.Join, abi.encode(ms[1]));

        uint16[9] memory edge = [10_000, 2_000, 10_000, 5_000, 5_000, 1_000, 2_000, 2_000, 1_000];
        for (uint256 f; f < 9; ++f) {
            assertEq(_ruleAs(c, ms[f], uint8(f), edge[f]), f + 1);
        }
        assertEq(c.openProposals().length, 9);
    }

    function test_T_INV_2_allocationOutOfBoundsByVoteReverts() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(10);
        _openEpoch3(c, ms);
        bytes4 bad = IKuberCircleErrors.InvalidAllocation.selector;
        _allocReverts(c, ms[0], 4_100, 2_900, 2_000, 1_000, bad); // loan > 40%
        _allocReverts(c, ms[0], 1_000, 3_400, 5_100, 500, bad); // LP > 50%
        _allocReverts(c, ms[0], 1_000, 4_600, 4_000, 400, bad); // cash < 5%
        _allocReverts(c, ms[0], 1_000, 4_500, 3_500, 999, bad); // sum 9_999
        assertEq(_allocAs(c, ms[0], 4_000, 0, 5_000, 1_000), 1);
        assertEq(c.getProposal(1).alloc.lp, 5_000);
    }

    function test_T_GOV_1_oneOpenPerFieldAndKind() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(10);
        _openEpoch3(c, ms);
        _ruleAs(c, ms[0], 1, 500);
        _ruleReverts(c, ms[1], 1, 600, IKuberCircleErrors.ProposalOpen.selector);
        assertEq(_ruleAs(c, ms[2], 2, 2_500), 2);
        assertEq(_allocAs(c, ms[3], 1_000, 4_500, 3_500, 1_000), 3);
        _allocReverts(c, ms[4], 1_000, 4_000, 4_000, 1_000, IKuberCircleErrors.ProposalOpen.selector);
        // No votes: every proposal fails at settle(3) and every slot frees.
        _settleAt(c, 4);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed));
        }
        assertEq(c.openProposals().length, 0);
        assertEq(_ruleAs(c, ms[1], 1, 600), 4);
        assertEq(_allocAs(c, ms[4], 1_000, 4_000, 4_000, 1_000), 5);
    }

    function test_RJ2_oneProposalPerMemberPerRound() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(10);
        _openEpoch3(c, ms);
        _ruleAs(c, ms[0], 1, 500);
        _allocReverts(c, ms[0], 1_000, 4_500, 3_500, 1_000, IKuberCircleErrors.AlreadyProposed.selector);
        _ruleReverts(c, ms[0], 2, 2_500, IKuberCircleErrors.AlreadyProposed.selector);
        assertEq(_ruleAs(c, ms[1], 2, 2_500), 2);
        _settleAt(c, 4);
        // A new round.
        assertEq(_ruleAs(c, ms[0], 2, 2_500), 3);
    }

    function test_T_GOV_1_votingClosesAtEpochEnd() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(6);
        _openEpoch3(c, ms);
        _ruleAs(c, ms[0], 1, 500);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Voted(1, ms[1], true);
        vm.prank(ms[1]);
        c.vote(1, true);
        vm.expectRevert(IKuberCircleErrors.AlreadyVoted.selector);
        vm.prank(ms[1]);
        c.vote(1, false);
        address stranger = makeAddr("stranger");
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        vm.prank(stranger);
        c.vote(1, true);
        vm.expectRevert(IKuberCircleErrors.VotingClosed.selector);
        vm.prank(ms[2]);
        c.vote(99, true);
        // Epoch 3 is over: settle(3) pending, then the proposal is closed.
        _warpTo(c, 4, false);
        vm.expectRevert(IKuberCircleErrors.SettlementPending.selector);
        vm.prank(ms[2]);
        c.vote(1, true);
        c.settle(type(uint256).max);
        vm.expectRevert(IKuberCircleErrors.VotingClosed.selector);
        vm.prank(ms[2]);
        c.vote(1, true);
        assertEq(c.getProposal(1).yes, 1);
    }

    function test_T_EP_2_proposeRevertsInLockVoteWorks() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(6);
        _openEpoch3(c, ms);
        _ruleAs(c, ms[0], 1, 500);
        _warpTo(c, 3, true);
        _ruleReverts(c, ms[1], 2, 2_500, IKuberCircleErrors.LockWindow.selector);
        vm.prank(ms[1]);
        c.vote(1, true);
        assertEq(c.getProposal(1).yes, 1);
    }

    function test_T_GOV_2_ruleSixteenOfThirtyPasses() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(30);
        _openEpoch3(c, ms);
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        _votes(c, id, ms, 0, 16, true);
        _votes(c, id, ms, 16, 14, false);
        // GOV-03: nothing changes before the settlement.
        assertEq(c.getCircleState().rules.ownRateBps, 300);
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalPassed(id);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalApplied(id);
        c.settle(type(uint256).max);
        assertEq(c.getCircleState().rules.ownRateBps, 500);
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Applied));
        assertEq(c.openProposals().length, 0);
    }

    function test_T_GOV_2_ruleFifteenOfThirtyFails() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(30);
        _openEpoch3(c, ms);
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        _votes(c, id, ms, 0, 15, true);
        _votes(c, id, ms, 15, 15, false);
        _settleAt(c, 4);
        // Exactly half is not more than half.
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed));
        assertEq(c.getCircleState().rules.ownRateBps, 300);
    }

    function test_T_GOV_3_pausedVoterVoteDropped() public {
        (KuberCircle c, address[] memory ms) = _pausedAtSeven();
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        _votes(c, id, ms, 0, 4, true);
        _votes(c, id, ms, 9, 1, true);
        assertEq(c.getProposal(id).yes, 5);
        _settleAt(c, 8);
        // Fines 3 × floor(10_300_000 × 300 / 10_000); the penalty was paid from savings.
        assertEq(uint256(c.getMember(ms[9]).status), uint256(MemberStatus.Suspended));
        assertEq(c.debtOf(ms[9]), 927_000);
        // Kills "the paused vote still counts": 5 × 2 > 9 would pass, 4 × 2 > 9 does not.
        assertEq(c.getProposal(id).yes, 4);
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed));
        assertEq(c.getCircleState().rules.ownRateBps, 300);
        uint256 next = _ruleAs(c, ms[0], 2, 2_500);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        vm.prank(ms[9]);
        c.vote(next, true);
        _ruleReverts(c, ms[9], 3, 2_000, IKuberCircleErrors.NotMember.selector);
    }

    function test_T_GOV_3_pausedMemberLeavesDenominator() public {
        (KuberCircle c, address[] memory ms) = _pausedAtSeven();
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        _votes(c, id, ms, 0, 5, true);
        _votes(c, id, ms, 9, 1, false);
        assertEq(c.getProposal(id).no, 1);
        _settleAt(c, 8);
        // Kills "the denominator still counts the paused member": 5 × 2 > 10 would fail, 5 × 2 > 9 passes.
        assertEq(c.getProposal(id).no, 0);
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Applied));
        assertEq(c.getCircleState().rules.ownRateBps, 500);
    }

    function test_T_INV_3_allocationAppliesBeforeFunding() public {
        (KuberCircle c,) = _demoRound3(true, 16);
        _settleAt(c, 4);
        // Funding saw the new plan: bucket 900e6, per-loan max 450e6 >= 350e6.
        _assertFunded(c.getLoan(1));
        _assertFunded(c.getLoan(2));
        _assertAlloc(c, 1_000, 4_500, 3_500, 1_000);
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.outstandingPrincipal, 700e6);
        assertEq(s.aaveValue, 4_050e6);
        assertEq(s.lpValue, 3_150e6);
        // Idle reserve 200e6 + 10% buffer 900e6 + unclaimed proceeds 700e6.
        assertEq(s.cash, 1_800e6);
        Loan memory a = c.getLoan(1);
        assertEq(a.saverInterest, 8_100_000);
        assertEq(a.vouchers[0].interest, 6_400_000);
        Loan memory d = c.getLoan(2);
        assertEq(d.saverInterest, 8_100_000);
        assertEq(d.vouchers[0].interest, 2_400_000);
        assertEq(d.agreers[0].interest, 2_000_000);
    }

    function test_T_INV_3_withoutTheVoteNeitherIsFunded() public {
        (KuberCircle c,) = _demoRound3(false, 0);
        _settleAt(c, 4);
        // Bucket 450e6, per-loan max 225e6 < 350e6.
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Pending));
        _assertAlloc(c, 500, 5_000, 3_500, 1_000);
        assertEq(c.getQueue().length, 2);
    }

    function test_T_GOV_2_allocationFifteenOfThirtyFails() public {
        (KuberCircle c,) = _demoRound3(true, 15);
        assertEq(c.getProposal(1).yes, 15);
        assertEq(c.getProposal(1).no, 15);
        _settleAt(c, 4);
        assertEq(uint256(_status(c, 1)), uint256(ProposalStatus.Failed));
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending));
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Pending));
        _assertAlloc(c, 500, 5_000, 3_500, 1_000);
    }

    function test_T_LN_2_ruleChangeBeforeFundingKeepsLockedTerms() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(300e6, 2, 0, 0);
        assertEq(c.getLoan(1).ownPart, 270e6);
        assertEq(c.getLoan(1).backedNeed, 30e6);
        _vouchAs(c, ms[1], 1, 30e6);
        // One proposal per member per round (R-J2): ownLtv, ownRate, penalty, installFine.
        _ruleAs(c, ms[2], 0, 5_000);
        _ruleAs(c, ms[3], 1, 1_000);
        _ruleAs(c, ms[4], 4, 5_000);
        _ruleAs(c, ms[5], 6, 2_000);
        for (uint256 id = 1; id <= 4; ++id) {
            _votes(c, id, ms, 0, 6, true);
        }
        _settleAt(c, 4);
        KuberCircle.CircleState memory st = c.getCircleState();
        assertEq(st.rules.ownLtvBps, 5_000);
        assertEq(st.rules.ownRateBps, 1_000);
        assertEq(st.rules.penaltyBps, 5_000);
        assertEq(st.rules.installFineBps, 2_000);
        // Funded on its locked LTV: under the new 5_000 the 270e6 own part would exceed 300e6 × 50%.
        Loan memory l1 = c.getLoan(1);
        assertEq(uint256(l1.status), uint256(LoanStatus.Funded));
        assertEq(l1.ownLtvBps, 9_000);
        assertEq(l1.ownRateBps, 300);
        assertEq(l1.penaltyBps, 1_000);
        assertEq(l1.installFineBps, 300);
        assertEq(l1.ownPart, 270e6);
        assertEq(l1.saverInterest, 8_100_000);
        // A request made after the change locks the new values: own min(100e6, 400e6 × 50%).
        _payNowAs(c, ms[2]);
        vm.prank(ms[2]);
        assertEq(c.requestLoan(100e6, 1, 0, 0), 2);
        Loan memory l2 = c.getLoan(2);
        assertEq(l2.ownLtvBps, 5_000);
        assertEq(l2.ownRateBps, 1_000);
        assertEq(l2.penaltyBps, 5_000);
        assertEq(l2.installFineBps, 2_000);
        assertEq(l2.ownPart, 100e6);
    }

    function _assertFunded(Loan memory loan) private pure {
        assertEq(uint256(loan.status), uint256(LoanStatus.Funded));
        assertEq(uint256(loan.lane), uint256(Lane.Line));
        assertEq(loan.fundedEpoch, 3);
    }

    function _assertAlloc(KuberCircle c, uint16 loan, uint16 aaveBps, uint16 lpBps, uint16 cash) private view {
        KuberCircle.CircleState memory st = c.getCircleState();
        assertEq(st.rules.alloc.loan, loan);
        assertEq(st.rules.alloc.aave, aaveBps);
        assertEq(st.rules.alloc.lp, lpBps);
        assertEq(st.rules.alloc.cash, cash);
    }

    // ---------------------------------------------------------------- T-GOV-2 kick, D-07, R-J2 (06-02)

    function test_T_GOV_2_kickExactlyTwoThirdsPasses() public {
        // 7 Active, the target excluded: 6 eligible, two-thirds = 4 (4 x 3 + 2 >= 14; 3 x 3 + 2 < 14).
        (ProposalStatus st, MemberStatus t) = _kickRun(7, 4);
        assertEq(uint256(st), uint256(ProposalStatus.Applied), "4 of 6 applied");
        assertEq(uint256(t), uint256(MemberStatus.Kicked), "target kicked");
        (st, t) = _kickRun(7, 3);
        assertEq(uint256(st), uint256(ProposalStatus.Failed), "3 of 6 fails");
        assertEq(uint256(t), uint256(MemberStatus.Active), "target stays");
    }

    function test_T_GOV_2_kickWithSixActive() public {
        // 5 eligible: 4 >= 3.33 passes, 3 fails.
        (ProposalStatus st, MemberStatus t) = _kickRun(6, 4);
        assertEq(uint256(st), uint256(ProposalStatus.Applied), "4 of 5 applied");
        assertEq(uint256(t), uint256(MemberStatus.Kicked), "target kicked");
        (st, t) = _kickRun(6, 3);
        assertEq(uint256(st), uint256(ProposalStatus.Failed), "3 of 5 fails");
        assertEq(uint256(t), uint256(MemberStatus.Active), "target stays");
    }

    function test_T_GOV_2_kickWithThirtyActive() public {
        // 29 eligible: 20 x 3 = 60 >= 58 passes; 19 x 3 = 57 < 58 fails.
        (ProposalStatus st, MemberStatus t) = _kickRun(30, 20);
        assertEq(uint256(st), uint256(ProposalStatus.Applied), "20 of 29 applied");
        assertEq(uint256(t), uint256(MemberStatus.Kicked), "target kicked");
        (st, t) = _kickRun(30, 19);
        assertEq(uint256(st), uint256(ProposalStatus.Failed), "19 of 29 fails");
        assertEq(uint256(t), uint256(MemberStatus.Active), "target stays");
    }

    function test_T_GOV_2_kickTargetCannotVote() public {
        (KuberCircle c, address[] memory ms) = _defaultGov(6);
        _openEpoch3(c, ms);
        uint256 id = _kickAs(c, ms[0], ms[5]);
        vm.prank(ms[5]);
        vm.expectRevert(IKuberCircleErrors.TargetCannotVote.selector);
        c.vote(id, false);
        vm.prank(ms[1]);
        c.vote(id, false);
        assertEq(c.getProposal(id).no, 1, "others vote");
    }

    function test_T_GOV_2_kickTargetChecks() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(300e6, 2, 0, 0);
        _vouchAs(c, ms[1], 1, 30e6);
        _kickReverts(c, ms[3], ms[0], IKuberCircleErrors.HasPendingRequest.selector);
        _kickReverts(c, ms[3], ms[1], IKuberCircleErrors.HasPledges.selector);
        _kickReverts(c, ms[3], ms[3], IKuberCircleErrors.InvalidTarget.selector);
        _kickReverts(c, ms[3], makeAddr("stranger"), IKuberCircleErrors.InvalidTarget.selector);
        uint256 id = _kickAs(c, ms[3], ms[2]);
        _kickReverts(c, ms[4], ms[5], IKuberCircleErrors.ProposalOpen.selector);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "loan 1 funded");
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed), "no votes, failed");
        assertEq(uint256(c.getMember(ms[2]).status), uint256(MemberStatus.Active), "m2 stays");
        _kickReverts(c, ms[3], ms[0], IKuberCircleErrors.HasActiveLoan.selector);
        // The pledge stays until the loan is repaid.
        _kickReverts(c, ms[3], ms[1], IKuberCircleErrors.HasPledges.selector);
        (KuberCircle p, address[] memory pm) = _pausedAtSeven();
        _settleAt(p, 8);
        assertEq(uint256(p.getMember(pm[9]).status), uint256(MemberStatus.Suspended), "m9 paused");
        _kickReverts(p, pm[0], pm[9], IKuberCircleErrors.InvalidTarget.selector);
    }

    function test_D07_kickTargetCannotRequestOrBack() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(400e6, 2, 0, 0);
        assertEq(c.getLoan(1).backedNeed, 130e6, "backed 130e6");
        uint256 id = _kickAs(c, ms[1], ms[3]);
        vm.startPrank(ms[3]);
        vm.expectRevert(IKuberCircleErrors.KickPending.selector);
        c.requestLoan(10e6, 1, 0, 0);
        vm.expectRevert(IKuberCircleErrors.KickPending.selector);
        c.vouch(1, 1e6);
        vm.expectRevert(IKuberCircleErrors.KickPending.selector);
        c.agree(1, 1e6);
        vm.stopPrank();
        _settleAt(c, 4);
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed), "kick failed");
        _payNowAs(c, ms[3]);
        vm.prank(ms[3]);
        c.requestLoan(10e6, 1, 0, 0);
        assertEq(c.getMember(ms[3]).pendingRequestId, 2, "kickTarget cleared");
    }

    function test_RJ2_failedKickCooldown() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        uint256 id = _kickAs(c, ms[0], ms[5]);
        _votes(c, id, ms, 0, 3, true);
        _settleAt(c, 4);
        assertEq(uint256(_status(c, id)), uint256(ProposalStatus.Failed), "3 x 3 + 2 < 12");
        _kickReverts(c, ms[1], ms[5], IKuberCircleErrors.KickCooldown.selector);
        uint256 snap = vm.snapshotState();
        vm.prank(ms[5]);
        c.requestLoan(10e6, 1, 0, 0);
        vm.revertToState(snap);
        _kickAs(c, ms[1], ms[4]);
        _settleAt(c, 5);
        _kickAs(c, ms[2], ms[5]);
        assertEq(c.openProposals().length, 1, "a Kick on m5 again a round later");
    }

    /// @dev n members (totalEpochs 7, default allocation), epoch 3 OPEN: ms[0] kicks ms[n - 1], ms[0 .. yes - 1]
    /// vote yes; settle(3). Returns the proposal status and the target's status.
    function _kickRun(uint256 n, uint256 yes) private returns (ProposalStatus, MemberStatus) {
        (KuberCircle c, address[] memory ms) = _defaultGov(n);
        _openEpoch3(c, ms);
        uint256 id = _kickAs(c, ms[0], ms[n - 1]);
        _votes(c, id, ms, 0, yes, true);
        _settleAt(c, 4);
        return (_status(c, id), c.getMember(ms[n - 1]).status);
    }

    function _kickReverts(KuberCircle c, address who, address target, bytes4 sel) private {
        vm.prank(who);
        vm.expectRevert(sel);
        c.propose(ProposalKind.Kick, abi.encode(target));
    }

    // ---------------------------------------------------------------- T-GOV-2 join (06-03)

    /// @dev Lazy consensus with 30 Active: passes with yes × 2 > 30 or no × 3 < 30. One applicant sponsored by ms[0];
    /// ms[0 .. yes − 1] vote yes, the next `no` members vote no. A failed Join returns the applicant to "applied".
    function test_T_GOV_2_joinLazyConsensus() public {
        (KuberCircle c, address[] memory ms) = _startGov(30, 7, 31, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address ap = _newMembers(1)[0];
        vm.prank(ap);
        c.applyToJoin();
        vm.prank(ms[0]);
        uint256 id = c.sponsor(ap);
        uint256[5] memory yes = [uint256(0), 0, 0, 15, 16];
        uint256[5] memory no = [uint256(0), 9, 10, 10, 14];
        bool[5] memory passes = [true, true, false, false, true];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 5; ++i) {
            string memory label = string.concat("yes ", vm.toString(yes[i]), ", no ", vm.toString(no[i]));
            _votes(c, id, ms, 0, yes[i], true);
            _votes(c, id, ms, yes[i], no[i], false);
            _settleAt(c, 4);
            Proposal memory p = c.getProposal(id);
            assertEq(uint256(p.status), uint256(passes[i] ? ProposalStatus.Applied : ProposalStatus.Failed), label);
            assertEq(
                uint256(c.getMember(ap).status), uint256(passes[i] ? MemberStatus.Active : MemberStatus.None), label
            );
            if (!passes[i]) {
                vm.prank(ms[1]);
                assertEq(c.sponsor(ap), id + 1, "a failed applicant can be sponsored again");
            }
            vm.revertToState(snap);
        }
    }
}
