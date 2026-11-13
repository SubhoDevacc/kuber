// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    Member,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev 05-04 decided points: the cooldown after reinstatement, R-N3 through a seizure below the pledge (both member
/// orders), the "borrower backs their own backer's debt loan" corner (unreachable), and the post-gate regression: a
/// member reinstated while settle(k) runs and then seized in it. Vault APYs 0.
contract RecoveryTest is BackingTestBase {
    uint256 private constant MAX = type(uint256).max;

    // ---------- reinstatement starts the normal cooldown: cooldownUntil = reinstatement epoch + cooldownEpochs

    function test_reinstatedMemberGetsCooldown() public {
        (KuberCircle c, address[] memory m) = _scenarioP(12, true, 4);
        address d = m[3];
        vm.startPrank(d);
        usdc.approve(address(c), 5_000e6);
        c.repayDebt(106_749_998);
        vm.stopPrank();
        Member memory b = c.getMember(d);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "reinstated");
        assertEq(b.reinstatedEpoch, 8, "reinstated in epoch 8");
        assertEq(b.cooldownUntil, 9, "8 + cooldownEpochs 1");
        _payAllBut(c, m, d);
        _settleAt(c, 9);
        assertEq(c.getMember(d).paidCount, 4, "epoch 8 collected");
        vm.prank(d);
        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 10);
        vm.prank(d);
        assertEq(c.requestLoan(10e6, 1, 0, 0), 2, "the epoch after the cooldown");
    }

    // ---------- R-N3 in _seize: a paused backer's pledge seized below its amount pays their own backers at once
    // m0 borrows 350e6 over 3 (own 270e6; M = m3 vouches 80e6). M then borrows 350e6 over 3 (own min(350e6, 220e6 x
    // 0.9) = 198e6; m1 vouches 52e6, m2 and m4 agree 50e6 each). Both claim in epoch 4 and revoke; both pause at
    // settle(7). Loan 2 installments 121_366_664, 121_366_664, 121_366_672: fines 10_922_999 + 7_281_999 + 3_641_000
    // = 21_845_998. Loan 1 installments 121_499_999, 121_499_999, 121_500_002: fines 10_934_999 + 7_289_999 +
    // 3_645_000 = 21_869_998.

    function test_RN3_pausedBackerSeizedBelowPledgePaysOwnBackers() public {
        // M first: paused with free 220e6 (80e6 pledged to loan 1); agreers lose 39e6 each.
        (KuberCircle c, address[] memory m) = _seizeFixture(true);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 350e6, 220e6, 52e6, 78e6, 0, 186_845_998);
        // Loan 1: m0 covers 300e6, M's pledge is seized for 50e6 < 80e6; the unseized 30e6 repays the agreers.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(m[3], 30e6, 156_845_998);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 350e6, 300e6, 50e6, 0, 0, 106_869_998);
        c.settle(MAX);
        _checkSeized(c, m);

        // m0 first: M is still Active when loan 1 takes 50e6, so M is paused with free 250e6. Same end state.
        (c, m) = _seizeFixture(false);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 350e6, 300e6, 50e6, 0, 0, 106_869_998);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 350e6, 250e6, 52e6, 48e6, 0, 156_845_998);
        c.settle(MAX);
        _checkSeized(c, m);
    }

    // ---------- 05-03's corner: L's borrower backs M's debt loan while M backs L. Unreachable: a backer needs no
    // pending request and no active loan, so whichever of the two pledges comes first, the other is blocked.

    function test_RN3_borrowerBackingOwnBackerCycleUnreachable() public {
        (KuberCircle c, address[] memory m) = _startLoans(6, 10, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        uint256 snap = vm.snapshotState();
        // L's borrower (m0) backs M's request, then requests L: M, pending, cannot back L.
        vm.prank(m[3]);
        uint256 lm = c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[0], lm, 10e6);
        vm.prank(m[0]);
        uint256 l = c.requestLoan(350e6, 3, 800, 0);
        vm.prank(m[3]);
        vm.expectRevert(IKuberCircleErrors.HasPendingRequest.selector);
        c.vouch(l, 10e6);
        vm.prank(m[3]);
        vm.expectRevert(IKuberCircleErrors.HasPendingRequest.selector);
        c.agree(l, 10e6);
        vm.revertToState(snap);
        // M backs L first, then requests: L's borrower, pending, cannot back M's request.
        vm.prank(m[0]);
        l = c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[3], l, 10e6);
        vm.prank(m[3]);
        lm = c.requestLoan(350e6, 3, 800, 0);
        vm.prank(m[0]);
        vm.expectRevert(IKuberCircleErrors.HasPendingRequest.selector);
        c.vouch(lm, 10e6);
        vm.prank(m[0]);
        vm.expectRevert(IKuberCircleErrors.HasPendingRequest.selector);
        c.agree(lm, 10e6);
        // Once both are funded, neither can back a later request either (and a paused M is not a member, T-DF-4).
        _vouchAs(c, m[1], l, 70e6);
        _vouchAs(c, m[2], lm, 39e6);
        _agreeAs(c, m[4], lm, 50e6);
        _settleAt(c, 4);
        assertEq(c.getMember(m[0]).activeLoanId, l, "L funded");
        assertEq(c.getMember(m[3]).activeLoanId, lm, "L_M funded");
        uint256 id = _request(c, m[5], 10e6, 1, 0);
        vm.prank(m[0]);
        vm.expectRevert(IKuberCircleErrors.HasActiveLoan.selector);
        c.vouch(id, 1e6);
        vm.prank(m[3]);
        vm.expectRevert(IKuberCircleErrors.HasActiveLoan.selector);
        c.vouch(id, 1e6);
    }

    // ---------- post-gate fix: a member reinstated while settle(7) runs is seized in that same settle(7). The seizure
    // (effective epoch 7) counts from the reinstatement epoch 8 for both the member and W_active; the old N-1 back-fill
    // took it from the discarded weight 0 and settle reverted with SafeCastOverflowedIntToUint(-20e6) for good.
    // B = m0 vouches 10e6 on X's loan 1 (280e6) and 50e6 on Y's loan 2 (320e6), then borrows 250e6 (own 216e6, m3
    // vouches 34e6). B, X, Y claim in epoch 4, revoke, and default in settle(7) in that order.

    function test_RN3_reinstatedInSettlementThenSeizedInSameSettlement() public {
        // Fines and penalty 0: B's debt is m3's 10e6 loss; X's default has debt 0 (R-N2) and frees B's 10e6 (R-N3).
        (KuberCircle c, address[] memory m) = _reinstateSeizeFixture(0, 0);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(3, 250e6, 240e6, 10e6, 0, 0, 10e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(m[0], 10e6, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberReinstated(m[0]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(1, 280e6, 280e6, 0, 0, 0, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 320e6, 300e6, 20e6, 0, 0, 20e6);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 7, "settle(7) done");
        Member memory b = c.getMember(m[0]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "B reinstated");
        assertEq(b.reinstatedEpoch, 8, "from epoch 8");
        assertEq(b.savings, 30e6, "60e6 - 10e6 (R-N3) - 20e6 seized");
        assertEq(b.pledgedOut, 0, "B's pledges released");
        assertEq(_h(c).weightAt(m[0], 7), 0, "B weight 0 through epoch 7");
        assertEq(_h(c).weightAt(m[0], 8), 30e6, "the seized 20e6 never counts");
        assertEq(uint256(c.getMember(m[1]).status), uint256(MemberStatus.Active), "X not paused (debt 0)");
        assertEq(c.debtOf(m[2]), 20e6, "Y owes B 20e6");
        assertEq(c.getMember(m[3]).savings, 700e6, "m3's 10e6 loss repaid");
        _checkWeightSums(c, m, 7);
        _checkWeightSums(c, m, 8);
    }

    function test_repayDebtBetweenSettleBatchesThenSeized() public {
        // Default fines and penalty: B is paused in the first batch, repays during epoch 8 (pay class, R-F), and is
        // reinstated from the clock epoch 8 before the next batch reaches X and Y.
        (KuberCircle c, address[] memory m) = _reinstateSeizeFixture(300, 1_000);
        _warpTo(c, 8, false);
        c.settle(1);
        assertEq(uint256(c.getMember(m[0]).status), uint256(MemberStatus.Suspended), "B paused");
        uint256 d = c.debtOf(m[0]);
        vm.startPrank(m[0]);
        usdc.approve(address(c), d);
        c.repayDebt(d);
        vm.stopPrank();
        assertEq(c.getMember(m[0]).reinstatedEpoch, 8, "reinstated from epoch 8");
        // Y's debt: B's 20e6 + penalty 32e6 + fines 9_962_999 + 6_641_999 + 3_321_000.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 320e6, 300e6, 20e6, 0, 0, 71_925_998);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 7, "settle(7) done");
        Member memory b = c.getMember(m[0]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "B still Active");
        assertEq(b.savings, 40e6, "60e6 - 20e6 seized");
        assertEq(_h(c).weightAt(m[0], 7), 0, "B weight 0 through epoch 7");
        assertEq(_h(c).weightAt(m[0], 8), 40e6, "the seized 20e6 never counts");
        _checkWeightSums(c, m, 7);
        _checkWeightSums(c, m, 8);
    }

    // ---------- helpers

    /// @dev 8 members, 10 epochs; the fixture above through epoch 7's payments (clock 7); settle(7) is left to the caller.
    function _reinstateSeizeFixture(uint16 fineBps, uint16 penaltyBps)
        private
        returns (KuberCircle c, address[] memory m)
    {
        m = _newMembers(8);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.installFineBps = fineBps;
        r.penaltyBps = penaltyBps;
        c = _startPeople(m, 10, r);
        _activate(c);
        _openEpoch3(c, m);
        vm.prank(m[1]);
        c.requestLoan(280e6, 3, 800, 0);
        _vouchAs(c, m[0], 1, 10e6);
        vm.prank(m[2]);
        c.requestLoan(320e6, 3, 800, 0);
        _vouchAs(c, m[0], 2, 50e6);
        vm.prank(m[0]);
        c.requestLoan(250e6, 3, 800, 0);
        _vouchAs(c, m[3], 3, 34e6);
        for (uint256 e = 4; e <= 7; ++e) {
            _settleAt(c, e);
            if (e == 4) {
                for (uint256 j; j < 3; ++j) {
                    assertEq(c.getMember(m[j]).activeLoanId, j == 0 ? 3 : j, "funded at settle(3)");
                    vm.startPrank(m[j]);
                    c.claim();
                    usdc.approve(address(c), 0);
                    vm.stopPrank();
                }
            }
            for (uint256 j = 3; j < 8; ++j) {
                _payNowAs(c, m[j]);
            }
        }
    }

    /// @dev Σ Active member weights == W_active and Σ never-borrowed Active weights == W_saver, at epoch e.
    function _checkWeightSums(KuberCircle c, address[] memory m, uint256 e) private view {
        uint256 wa;
        uint256 ws;
        for (uint256 i; i < m.length; ++i) {
            Member memory x = c.getMember(m[i]);
            if (x.status != MemberStatus.Active) continue;
            wa += _h(c).weightAt(m[i], e);
            if (!x.everBorrowed) ws += _h(c).weightAt(m[i], e);
        }
        assertEq(wa, _h(c).wActiveAt(e), "W_active");
        assertEq(ws, _h(c).wSaverAt(e), "W_saver");
    }

    /// @dev The R-N3 seizure fixture through epoch 7's payments (clock 7); settle(7) is left to the caller.
    function _seizeFixture(bool mFirst) private returns (KuberCircle c, address[] memory m) {
        m = _newMembers(6);
        address[] memory order = new address[](6);
        for (uint256 i; i < 6; ++i) {
            order[i] = m[i];
        }
        if (mFirst) (order[0], order[3]) = (m[3], m[0]);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        c = _startPeople(order, 10, r);
        _activate(c);
        _openEpoch3(c, m);
        vm.prank(m[0]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[3], 1, 80e6);
        vm.prank(m[3]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[1], 2, 52e6);
        _agreeAs(c, m[2], 2, 50e6);
        _agreeAs(c, m[4], 2, 50e6);
        address[] memory payers = new address[](4);
        (payers[0], payers[1], payers[2], payers[3]) = (m[1], m[2], m[4], m[5]);
        for (uint256 e = 4; e <= 7; ++e) {
            _settleAt(c, e);
            if (e == 4) {
                for (uint256 j; j < 4; j += 3) {
                    vm.startPrank(m[j]);
                    c.claim();
                    usdc.approve(address(c), 0);
                    vm.stopPrank();
                }
                assertEq(c.getLoan(2).ownPart, 198e6, "M's own part");
            }
            _payAllBut(c, payers, address(0));
        }
    }

    /// @dev The end state both member orders reach after settle(7).
    function _checkSeized(KuberCircle c, address[] memory m) private view {
        Member memory mm = c.getMember(m[3]);
        assertEq(mm.savings, 0, "M savings");
        assertEq(mm.pledgedOut, 0, "M pledge released");
        assertEq(uint256(mm.status), uint256(MemberStatus.Suspended), "M suspended");
        assertEq(c.debtOf(m[3]), 156_845_998, "M debt: 52e6 + 24e6 + 24e6 + 21_845_998 + 35e6");
        Loan memory l2 = c.getLoan(2);
        assertEq(l2.vouchers[0].loss, 52e6, "m1 loss");
        assertEq(l2.agreers[0].loss, 24e6, "m2 loss");
        assertEq(l2.agreers[1].loss, 24e6, "m4 loss");
        assertEq(l2.penaltyOwed, 35e6, "M penalty owed");
        assertEq(l2.finesOwed, 21_845_998, "M fines");
        assertEq(c.getLoan(1).vouchers[0].loss, 50e6, "M's loss on loan 1");
        assertEq(c.debtOf(m[0]), 106_869_998, "m0 debt: 50e6 + 35e6 + 21_869_998");
        assertEq(c.getMember(m[0]).savings, 0, "m0 savings");
        assertEq(c.getMember(m[1]).savings, 648e6, "m1");
        assertEq(c.getMember(m[2]).savings, 676e6, "m2");
        assertEq(c.getMember(m[4]).savings, 676e6, "m4");
        assertEq(c.getMember(m[5]).savings, 700e6, "m5 untouched");
        assertEq(_h(c).weightAt(m[2], 7), 2_776e6, "m2 weight: 2_100e6 + 676e6");
        assertEq(_h(c).weightAt(m[4], 7), 2_776e6, "m4 weight");
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.sTotal, 2_700e6, "sTotal");
        assertEq(s.saverPot, 0, "no penalty paid");
        assertEq(s.outstandingPrincipal, 0, "outstandingPrincipal");
        uint256 wa;
        uint256 ws;
        uint256 claims;
        for (uint256 i; i < 6; ++i) {
            Member memory x = c.getMember(m[i]);
            assertGe(x.savings, x.pledgedOut, "I1");
            claims += x.claimable;
            if (x.status != MemberStatus.Active) continue;
            wa += _h(c).weightAt(m[i], 7);
            if (!x.everBorrowed) ws += _h(c).weightAt(m[i], 7);
        }
        assertEq(s.reservedClaims, claims, "I3");
        assertEq(wa, _h(c).wActiveAt(7), "W_active");
        assertEq(ws, _h(c).wSaverAt(7), "W_saver");
    }
}
