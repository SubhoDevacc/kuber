// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    BPS,
    CircleStatus,
    FixedParams,
    IKuberCircleErrors,
    MAX_EPOCHS,
    MAX_MEMBERS,
    LoanStatus,
    Member,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @notice 07 D-07 (contribution bound), D-08 (Forming closes at startTime), D-09 (the views the web app reads).
contract HardeningTest is GovTestBase {
    function test_D07_contributionAboveBoundReverts() public {
        assertEq(MAX_EPOCHS * MAX_MEMBERS, 60 * 50);
        assertLt(1e30 * MAX_EPOCHS * MAX_MEMBERS, type(uint128).max, "largest total savings fits uint128");
        address[] memory ms = _newMembers(5);
        FixedParams memory f = _fixed();
        f.contribution = 1e30 + 1;
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.InvalidContribution.selector);
        factory.createCircle("big", f, _rules(), _tail(ms));
        f.contribution = 1e30;
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("big", f, _rules(), _tail(ms)));
        assertEq(c.getCircleState().fixedParams.contribution, 1e30);
    }

    function test_D08_formingActionsCloseAtStart() public {
        address[] memory ms = _newMembers(6);
        KuberCircle c = _create(ms);
        for (uint256 i = 1; i < 5; ++i) {
            vm.prank(ms[i]);
            c.join();
        }
        address stranger = _newMembers(1)[0];
        uint64 start = c.getCircleState().fixedParams.startTime;

        vm.warp(start - 1);
        uint256 snap = vm.snapshotState();
        vm.prank(ms[5]);
        c.join();
        vm.revertToState(snap);
        vm.prank(stranger);
        c.requestToJoin();
        vm.revertToState(snap);
        vm.prank(ms[0]);
        c.invite(stranger);
        vm.revertToState(snap);
        vm.prank(ms[1]);
        c.leave();
        vm.revertToState(snap);
        vm.prank(ms[0]);
        c.cancel();
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Cancelled));
        vm.revertToState(snap);

        vm.warp(start);
        vm.prank(ms[5]);
        vm.expectRevert(IKuberCircleErrors.FormingClosed.selector);
        c.join();
        vm.prank(stranger);
        vm.expectRevert(IKuberCircleErrors.FormingClosed.selector);
        c.requestToJoin();
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.FormingClosed.selector);
        c.invite(stranger);
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.FormingClosed.selector);
        c.leave();
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.FormingClosed.selector);
        c.cancel();
        c.activate();
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Active));
        assertEq(c.getCircleState().memberCount, 5);
    }

    /// 5 members, 7 epochs, allocation 40% loans / 60% cash, managerFeeBps 500, protocol fee 1_000, reimbursement on.
    /// ms[4] borrows 10e6 (funded at settle(3)); ms[0] proposes ms[1] as manager, ms[0..2] vote yes, ms[3] no.
    function test_D09_viewsForWebApp() public {
        address[] memory ms = _newMembers(5);
        FixedParams memory f = _fixed();
        RuleParams memory r = _rules();
        r.managerFeeBps = 500;
        r.alloc = _alloc(4_000, 0, 0, 6_000);
        vm.prank(ms[0]);
        KuberCircle c = KuberCircle(factory.createCircle("views", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < 5; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        _readAll(c, ms[2]);
        vm.warp(f.startTime);
        c.activate();
        registry.setProtocolFeeBps(1_000);
        registry.setGasSettings(30e6, 100e9, 5e6);
        vm.txGasPrice(25 gwei);

        _openEpoch3(c, ms);
        _request(c, ms[4], 10e6, 1, 0);
        uint256 id = _managerAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 0, 3, true);
        _votes(c, id, ms, 3, 1, false);
        assertEq(c.ballotOf(id, ms[0]), 1, "yes");
        assertEq(c.ballotOf(id, ms[3]), 2, "no");
        assertEq(c.ballotOf(id, ms[4]), 0, "did not vote");
        _settleAt(c, 4);
        assertEq(c.getCircleState().manager, ms[1]);
        KuberCircle.CircleState memory s = c.getCircleState();
        assertEq(s.loanCount, 1);
        assertEq(s.proposalCount, 1);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "funded");
        _readAll(c, ms[2]);

        _checkLimits(c, ms[4]);
        usdc.mint(address(c), 50e6);
        _checkExitFees(c, ms[2]);

        for (uint256 e = 5; e <= f.totalEpochs + 1; ++e) {
            _settleAt(c, e);
        }
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended));
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertGt(p.feesCharged, 0);
        assertEq(p.feesCharged, c.getMember(registry.treasury()).claimable + c.getMember(ms[1]).claimable, "fees");
        assertGt(p.expenses, 0, "reimbursed");
        assertEq(p.expenses, c.getMember(address(this)).claimable, "reimbursement credited to the settler");
        _readAll(c, ms[2]);
    }

    /// 06-04 hand-off (D-10): a member who borrowed (and repaid) leaves with no share of the savers' pot. 5 members,
    /// ms[1] borrows 10e6 over 1 and repays at once; the savers' pot is then split among the 4 savers' quotes only.
    function test_D10_borrowerExitTakesNoSaverShare() public {
        (KuberCircle c, address[] memory ms) = _startGov(5, 7, 30, _alloc(4_000, 0, 0, 6_000));
        _openEpoch3(c, ms);
        _request(c, ms[1], 10e6, 1, 0);
        _settleAt(c, 4);
        vm.prank(ms[1]);
        c.repayAll();
        assertTrue(c.getMember(ms[1]).everBorrowed);
        assertEq(c.getMember(ms[1]).activeLoanId, 0, "free to leave");
        // A 5e6 savers' pot paid in cash, as fines are, and 10e6 of yield.
        usdc.mint(address(c), 15e6);
        _h(c).addLiabilities(ms[0], 0, 5e6);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertGt(p.yieldPot, 0);
        uint256 gain = uint256(p.yieldPot) / 5;
        (uint256 p1, uint256 f1,,) = c.exitValueOf(ms[1]);
        (uint256 p2, uint256 f2,,) = c.exitValueOf(ms[2]);
        assertEq(p1 + f1, 300e6 + gain, "borrower: savings + yield share, no saver share");
        assertEq(gain, 2e6);
        assertEq(p2 + f2, p1 + f1 + p.saverPot / 4, "saver: plus a quarter of the pot");
        assertGe(p.saverPot, 5e6);
    }

    function _checkLimits(KuberCircle c, address who) internal view {
        // loanLimits against the D-05 formulas from the public numbers.
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 value = uint256(p.yieldPot + int256(p.sTotal));
        uint256 bucket = value * 4_000 / BPS;
        Member memory m4 = c.getMember(who);
        (uint256 capacity, uint256 perLoanMax, uint256 ownLimit) = c.loanLimits(who);
        assertGt(p.outstandingPrincipal, 0);
        assertEq(capacity, bucket - p.outstandingPrincipal, "capacity");
        assertEq(perLoanMax, value * 4_000 * 5_000 / (BPS * BPS), "per-loan max");
        assertEq(ownLimit, (m4.savings - m4.pledgedOut) * 9_000 / BPS, "own limit");
    }

    function _checkExitFees(KuberCircle c, address who) internal view {
        // exitValueOf's fee parts are Fees.quote of the gross yield share (5 equal weights).
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 0);
        uint256 gain = uint256(p.yieldPot) / 5;
        (uint256 payout, uint256 fee, uint256 pf, uint256 mf) = c.exitValueOf(who);
        assertEq(pf, gain * 1_000 / BPS, "protocol fee");
        assertEq(mf, (gain - pf) * 500 / BPS, "manager fee");
        assertGt(mf, 0);
        assertEq(payout + fee, c.getMember(who).savings + gain - pf - mf, "value net of both fees");
    }

    /// Every view from an EOA, none reverting (Forming, Active, Ended).
    function _readAll(KuberCircle c, address who) internal {
        address eoa = makeAddr("reader");
        vm.startPrank(eoa, eoa);
        c.getCircleState();
        c.getPublicSummary();
        c.members();
        c.getMember(who);
        c.getLoan(1);
        c.getQueue();
        c.getProposal(1);
        c.openProposals();
        c.ballotOf(1, who);
        c.loanLimits(who);
        c.exitValueOf(who);
        c.debtOf(who);
        c.freedApplicable(who);
        c.currentEpoch();
        c.currentWindow();
        vm.stopPrank();
    }
}
