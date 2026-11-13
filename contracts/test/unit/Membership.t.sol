// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {
    CircleStatus,
    IKuberCircleErrors,
    IKuberCircleEvents,
    LoanStatus,
    Member,
    MemberStatus,
    Proposal,
    ProposalKind,
    ProposalStatus
} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";

/// @dev 06-02: T-MEM-1, T-MEM-2, the MEM-02 kick payout, the GOV-05 exit fee, D-08/D-09/D-10, R-J3 (fees join the
/// savers' pot once), and the multi-exit and final-kick checks. 06-03: T-MEM-3, T-MEM-4, the D-11 apply and D-13
/// admission checks, R-J2 for sponsors, T-REG-2 (apply at the cap), T-DF-4 (sponsoredSuspended), T-DF-7 (apply and
/// sponsor), and N-1 for a joiner. Contribution 100e6, vault APY 0; settle(k) runs at the start of epoch k + 1.
contract MembershipTest is GovTestBase {
    // ---------------------------------------------------------------- T-MEM-1

    function test_T_MEM_1_leaveBlockedByLoanRequestPledges() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(300e6, 2, 0, 0);
        _vouchAs(c, ms[1], 1, 30e6);
        _leaveReverts(c, ms[0], IKuberCircleErrors.HasPendingRequest.selector);
        _leaveReverts(c, ms[1], IKuberCircleErrors.HasPledges.selector);
        _settleAt(c, 4);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "funded");
        _leaveReverts(c, ms[0], IKuberCircleErrors.HasActiveLoan.selector);
        _leaveReverts(c, ms[1], IKuberCircleErrors.HasPledges.selector);
        _leaveReverts(c, makeAddr("stranger"), IKuberCircleErrors.NotMember.selector);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LeaveRequested(ms[2]);
        vm.prank(ms[2]);
        c.requestLeave();
        _leaveReverts(c, ms[2], IKuberCircleErrors.LeavePending.selector);
        vm.prank(ms[3]);
        vm.expectRevert(IKuberCircleErrors.NoLeavePending.selector);
        c.cancelLeave();
        // D-08 with a real pending leave: no request, vouch, or agree.
        _payNowAs(c, ms[4]);
        vm.prank(ms[4]);
        c.requestLoan(400e6, 1, 0, 0);
        assertEq(c.getLoan(2).ownPart, 360e6, "own 360e6");
        assertEq(c.getLoan(2).backedNeed, 40e6, "backed 40e6");
        vm.startPrank(ms[2]);
        vm.expectRevert(IKuberCircleErrors.LeavePending.selector);
        c.vouch(2, 1e6);
        vm.expectRevert(IKuberCircleErrors.LeavePending.selector);
        c.agree(2, 1e6);
        vm.expectRevert(IKuberCircleErrors.LeavePending.selector);
        c.requestLoan(10e6, 1, 0, 0);
        vm.stopPrank();
        _warpTo(c, 4, true);
        _leaveReverts(c, ms[3], IKuberCircleErrors.LockWindow.selector);
        vm.prank(ms[2]);
        vm.expectRevert(IKuberCircleErrors.LockWindow.selector);
        c.cancelLeave();
    }

    function test_T_MEM_1_leavePaysExitValueMinusFee() public {
        (KuberCircle c, address[] memory ms) = _exitFixture();
        address m1 = ms[1];
        KuberCircle.PublicSummary memory p0 = c.getPublicSummary();
        assertEq(p0.yieldPot, 61e6, "yieldPot before");
        assertEq(p0.saverPot, 8_100_000, "saverPot before");
        assertEq(p0.sTotal, 3_600e6, "sTotal before");
        assertEq(_h(c).weightAt(m1, 6), 2_100e6, "m1 weight");
        assertEq(_h(c).wActiveAt(6), 12_600e6, "wActive");
        assertEq(_h(c).wSaverAt(6), 10_500e6, "wSaver (m0 borrowed)");
        assertEq(c.getMember(m1).rewards, 3e6, "m1 rewards");
        vm.prank(m1);
        c.requestLeave();
        // Yield floor(61e6 × 2_100 / 12_600) = 10_166_666; saver share 8_100_000 × 2_100 / 10_500 = 1_620_000;
        // exit value 600e6 + 10_166_666 + 1_620_000 + 3e6 = 614_786_666; fee ceil(18_443_599.98) = 18_443_600.
        (uint256 payout, uint256 fee) = c.exitValueOf(m1);
        assertEq(payout, 596_343_066, "view payout");
        assertEq(fee, 18_443_600, "view fee, rounded up");
        assertEq(payout + fee, 614_786_666, "exit value");
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberLeft(m1, 596_343_066);
        c.settle(type(uint256).max);
        KuberCircle.PublicSummary memory p1 = c.getPublicSummary();
        assertEq(c.getMember(m1).claimable, 596_343_066, "claimable == view");
        assertEq(p1.saverPot, 24_923_600, "8_100_000 - 1_620_000 + 18_443_600");
        assertEq(p1.yieldPot, 50_833_334, "61e6 - 10_166_666");
        assertEq(p1.yieldPot - p0.yieldPot, -10_166_666, "identity: yieldPot falls by the yield share");
        assertEq(int256(p1.saverPot) - int256(p0.saverPot), 18_443_600 - 1_620_000, "identity: fee - saver share");
        assertEq(p1.sTotal, 3_000e6, "sTotal");
        assertEq(_h(c).wActiveAt(6), 10_500e6, "wActive without m1");
        assertEq(_h(c).wSaverAt(6), 8_400e6, "wSaver without m1");
        assertEq(_sumWeights(c, ms, 6, false), _h(c).wActiveAt(6), "sum == wActive");
        assertEq(_sumWeights(c, ms, 6, true), _h(c).wSaverAt(6), "sum == wSaver");
        assertEq(p1.totalRewardsOwed, 0, "rewards paid out");
        assertEq(p1.reservedClaims, 596_343_066, "reservedClaims");
        assertEq(p1.reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
        assertEq(registry.activeMemberships(m1), 0, "registry recordLeave");
        Member memory m = c.getMember(m1);
        assertEq(uint256(m.status), uint256(MemberStatus.Left), "Left");
        assertFalse(m.leavePending, "flag cleared");
        assertEq(m.savings, 0, "savings");
        assertEq(m.rewards, 0, "rewards");
        vm.prank(m1);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.payNow();
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        vm.prank(m1);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.vote(id, true);
        uint256 bal = usdc.balanceOf(m1);
        vm.prank(m1);
        c.claim();
        assertEq(usdc.balanceOf(m1) - bal, 596_343_066, "claim pays the exit");
        (payout, fee) = c.exitValueOf(m1);
        assertEq(payout + fee, 0, "nothing after leaving");
    }

    function test_T_MEM_1_cancelLeaveKeepsMember() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        _openEpoch3(c, ms);
        vm.startPrank(ms[2]);
        c.requestLeave();
        c.cancelLeave();
        c.requestLeave();
        c.cancelLeave();
        vm.stopPrank();
        vm.recordLogs();
        _settleAt(c, 4);
        assertEq(_leftLogs(vm.getRecordedLogs(), ms[2]), 0, "no MemberLeft");
        assertEq(uint256(c.getMember(ms[2]).status), uint256(MemberStatus.Active), "still Active");
        assertEq(c.getMember(ms[2]).claimable, 0, "nothing credited");
        _payNowAs(c, ms[2]);
        vm.prank(ms[2]);
        c.requestLeave();
        vm.recordLogs();
        _settleAt(c, 5);
        assertEq(_leftLogs(vm.getRecordedLogs(), ms[2]), 1, "exactly one MemberLeft");
    }

    // ---------------------------------------------------------------- T-MEM-2

    function test_T_MEM_2_lpShockLossSharedBySavings() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _alloc(500, 5_000, 3_500, 1_000));
        _settleAt(c, 2);
        vm.prank(ms[5]);
        usdc.approve(address(c), 0);
        _settleAt(c, 3);
        vm.prank(ms[5]);
        usdc.approve(address(c), 5_000e6);
        _settleAt(c, 4);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.sTotal, 1_700e6, "m5 missed epoch 2");
        assertEq(p.yieldPot, 0, "V == sTotal");
        assertEq(p.aaveValue, 850e6, "aave");
        assertEq(p.lpValue, 595e6, "lp");
        assertEq(p.cash, 255e6, "cash");
        vm.prank(ms[2]);
        c.requestLeave();
        _payAllBut(c, ms, address(0));
        lp.shock(-1_000);
        KuberCircle.PublicSummary memory p0 = c.getPublicSummary();
        assertEq(p0.lpValue, 535_500_000, "LP loses 59_500_000");
        assertEq(p0.yieldPot, -59_500_000, "yieldPot");
        assertEq(p0.sTotal, 2_300e6, "sTotal");
        // Loss by savings: ceil(59_500_000 × 400e6 / 2_300e6) = 10_347_827; exit value 389_652_173 < savings 400e6;
        // fee ceil(11_689_565.19) = 11_689_566. By weight (m2 1_000e6 of 5_700e6) it would have been 10_438_597.
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[2]);
        assertEq(payout, 377_962_607, "view payout");
        assertEq(fee, 11_689_566, "view fee");
        assertEq(payout + fee, 400e6 - 10_347_827, "savings minus the loss share");
        _settleAt(c, 5);
        KuberCircle.PublicSummary memory p1 = c.getPublicSummary();
        assertEq(c.getMember(ms[2]).claimable, 377_962_607, "claimable");
        assertEq(p1.yieldPot, -49_152_173, "-59_500_000 + 10_347_827");
        assertEq(p1.saverPot, 11_689_566, "the fee; the pot held 0, so no saver share");
        assertEq(p1.sTotal, 1_900e6, "sTotal");
        assertEq(_sumWeights(c, ms, 4, false), _h(c).wActiveAt(4), "sum == wActive");
        assertEq(_sumWeights(c, ms, 4, true), _h(c).wSaverAt(4), "sum == wSaver");
        assertEq(p1.reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
    }

    function test_T_MEM_2_lossAboveSavingsFloorsAtZero() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        _settleAt(c, 2);
        _settleAt(c, 3);
        vm.prank(ms[2]);
        c.requestLeave();
        _payAllBut(c, ms, address(0));
        _drainAll(c);
        assertEq(c.getPublicSummary().yieldPot, -1_800e6, "every asset gone");
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[2]);
        assertEq(payout, 0, "savings part floored at 0");
        assertEq(fee, 0, "no fee on 0");
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ms[2]).status), uint256(MemberStatus.Left), "Left");
        assertEq(c.getMember(ms[2]).claimable, 0, "claimable 0");
        assertEq(c.getPublicSummary().sTotal, 1_500e6, "sTotal without m2");
    }

    // ---------------------------------------------------------------- R-J3

    function test_RJ3_twoLeaversOrderIndependent() public {
        _twoLeavers(true);
        _twoLeavers(false);
    }

    function test_RJ3_noSaverShareWhenValueNotPositive() public {
        (KuberCircle c, address[] memory ms) = _exitFixture();
        vm.prank(ms[1]);
        c.requestLeave();
        _drainAll(c);
        // V = -(saverPot 8_100_000 + rewards 3e6) <= 0: savings part 0, saver share 0, rewards 3e6, fee 90_000.
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[1]);
        assertEq(payout, 2_910_000, "rewards minus fee");
        assertEq(fee, 90_000, "fee");
        _settleAt(c, 7);
        assertEq(uint256(c.getMember(ms[1]).status), uint256(MemberStatus.Left), "Left");
        assertEq(c.getMember(ms[1]).claimable, 2_910_000, "claimable");
        assertEq(c.getPublicSummary().saverPot, 8_190_000, "nothing taken, the fee added");
    }

    // ---------------------------------------------------------------- W4 / D-08 / D-10

    function test_W4_prepaidLeaverWhileSettlementPending() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        _openEpoch3(c, ms);
        vm.prank(ms[2]);
        c.requestLeave();
        _warpTo(c, 4, false);
        _payNowAs(c, ms[2]);
        _payNowAs(c, ms[3]);
        assertEq(c.getMember(ms[2]).savings, 400e6, "pre-paid epoch 4");
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[2]);
        assertEq(payout, 388e6, "view payout");
        assertEq(fee, 12e6, "view fee");
        c.settle(type(uint256).max);
        assertEq(c.getMember(ms[2]).claimable, 388e6, "claimable");
        assertEq(_sumWeights(c, ms, 3, false), _h(c).wActiveAt(3), "sum == wActive at 3");
        assertEq(_sumWeights(c, ms, 3, true), _h(c).wSaverAt(3), "sum == wSaver at 3");
        _settleAt(c, 5);
        assertEq(_sumWeights(c, ms, 4, false), _h(c).wActiveAt(4), "sum == wActive at 4");
        assertEq(_sumWeights(c, ms, 4, true), _h(c).wSaverAt(4), "sum == wSaver at 4");
        assertEq(c.getPublicSummary().reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
    }

    function test_GOV_05_ruleChangeKeepsPendingLeaveFee() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        _openEpoch3(c, ms);
        vm.prank(ms[2]);
        c.requestLeave();
        uint256 id = _ruleAs(c, ms[3], 7, 2_000);
        _votes(c, id, ms, 0, 6, true);
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[2]);
        assertEq(payout, 291e6, "view payout at the locked 300");
        assertEq(fee, 9e6, "ceil(300e6 x 300 / 10_000)");
        _settleAt(c, 4);
        assertEq(c.getCircleState().rules.exitFeeBps, 2_000, "applied first (D-06)");
        assertEq(c.getMember(ms[2]).claimable, 291e6, "locked fee, not 240e6");
        // Later leaves use the new rate: m3's value is 300e6 + 9e6 × 900e6 / 4_500e6 (saver share of m2's fee).
        (payout, fee) = c.exitValueOf(ms[3]);
        assertEq(payout + fee, 301_800_000, "m3 exit value");
        assertEq(fee, Math.mulDiv(payout + fee, 2_000, 10_000, Math.Rounding.Ceil), "new rate");
    }

    function test_D08_leaveDroppedWhenConditionsFail() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[1]);
        c.requestLeave();
        _h(c).setLeavePending(ms[1], false);
        vm.prank(ms[1]);
        c.requestLoan(10e6, 1, 0, 0);
        _h(c).setLeavePending(ms[1], true);
        vm.recordLogs();
        _settleAt(c, 4);
        assertEq(_leftLogs(vm.getRecordedLogs(), ms[1]), 0, "no MemberLeft");
        Member memory m = c.getMember(ms[1]);
        assertEq(uint256(m.status), uint256(MemberStatus.Active), "still Active");
        assertFalse(m.leavePending, "stale leave cleared");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "the request went on to funding");
    }

    function test_D08_finalSettlementDoesNotExecuteLeaves() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        for (uint256 e = 2; e <= 7; ++e) {
            _settleAt(c, e);
        }
        vm.prank(ms[1]);
        c.requestLeave();
        _settleAt(c, 8);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "Ended");
        assertEq(uint256(c.getMember(ms[1]).status), uint256(MemberStatus.Active), "not executed");
        uint256 bal = usdc.balanceOf(ms[1]);
        vm.prank(ms[1]);
        c.withdraw();
        assertEq(usdc.balanceOf(ms[1]) - bal, 700e6, "the share-out, no fee");
    }

    function test_D10_exitValueOfZeroForNonMembers() public {
        (KuberCircle c,) = _exitFixture();
        (uint256 payout, uint256 fee) = c.exitValueOf(makeAddr("stranger"));
        assertEq(payout, 0, "payout");
        assertEq(fee, 0, "fee");
    }

    // ---------------------------------------------------------------- MEM-02 / D-09 kicks

    function test_MEM_02_kickPaysExitValueWithoutFee() public {
        (KuberCircle c, address[] memory ms) = _exitFixture();
        address m1 = ms[1];
        uint256 snap = vm.snapshotState();
        vm.prank(m1);
        c.requestLeave();
        (uint256 payL, uint256 feeL) = c.exitValueOf(m1);
        assertEq(payL, 596_343_066, "leave payout");
        assertEq(feeL, 18_443_600, "leave fee");
        vm.revertToState(snap);
        uint256 id = _kickAs(c, ms[0], m1);
        _votes(c, id, ms, 2, 4, true);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberKicked(m1, 614_786_666);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalApplied(id);
        c.settle(type(uint256).max);
        assertEq(c.getMember(m1).claimable, 614_786_666, "full exit value");
        assertEq(c.getMember(m1).claimable, payL + feeL, "P3: leave payout + fee");
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 6_480_000, "8_100_000 - 1_620_000, no fee");
        assertEq(p.yieldPot, 50_833_334, "yieldPot");
        KuberRegistry.MemberStats memory st = registry.memberStats(m1);
        assertEq(st.kicks, 1, "registry kicks");
        assertEq(registry.activeMemberships(m1), 0, "membership closed");
        assertEq(uint256(c.getMember(m1).status), uint256(MemberStatus.Kicked), "Kicked");
        assertEq(uint256(c.getProposal(id).status), uint256(ProposalStatus.Applied), "Applied");
        assertEq(_sumWeights(c, ms, 6, false), _h(c).wActiveAt(6), "sum == wActive");
        assertEq(_sumWeights(c, ms, 6, true), _h(c).wSaverAt(6), "sum == wSaver");
        assertEq(p.reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
    }

    function test_D09_kickDroppedWhenTargetLeavesFirst() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[1]);
        c.requestLeave();
        uint256 id = _kickAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 2, 4, true);
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[1]);
        assertEq(payout, 291e6, "view payout");
        assertEq(fee, 9e6, "view fee");
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ms[1]).status), uint256(MemberStatus.Left), "left, fee paid");
        assertEq(c.getMember(ms[1]).claimable, 291e6, "claimable");
        assertEq(uint256(c.getProposal(id).status), uint256(ProposalStatus.Dropped), "kick dropped");
        assertEq(c.getPublicSummary().saverPot, 9e6, "the fee reached the pot");
    }

    function test_W4_kickAtFinalSettlementMatchesShareOut() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 50, _rules().alloc);
        for (uint256 e = 2; e <= 7; ++e) {
            _settleAt(c, e);
        }
        _payAllBut(c, ms, address(0));
        usdc.mint(address(c), 60e6);
        uint256 snap = vm.snapshotState();
        uint256 id = _kickAs(c, ms[0], ms[5]);
        _votes(c, id, ms, 0, 4, true);
        _settleAt(c, 8);
        assertEq(uint256(c.getMember(ms[5]).status), uint256(MemberStatus.Kicked), "Kicked at the final settlement");
        assertEq(c.getMember(ms[5]).claimable, 710_000_000, "700e6 + 60e6 / 6");
        KuberRegistry.MemberStats memory st = registry.memberStats(ms[5]);
        assertEq(st.kicks, 1, "kicks");
        assertEq(st.circlesCompleted, 0, "no completion credit (R-J2 residual)");
        vm.revertToState(snap);
        _settleAt(c, 8);
        uint256 bal = usdc.balanceOf(ms[5]);
        vm.prank(ms[5]);
        c.withdraw();
        assertEq(usdc.balanceOf(ms[5]) - bal, 710_000_000, "same money as the share-out");
        assertEq(registry.memberStats(ms[5]).circlesCompleted, 1, "completion credit");
    }

    // ---------------------------------------------------------------- W4 multi-exit

    function test_W4_multiExitWithDefaultFundingAllocationChange() public {
        uint256[4] memory a = _multiExit(false, true);
        assertEq(a[0], 683_767_818, "m1");
        assertEq(a[1], 680_857_818, "m2");
        assertEq(a[2], 777_857_819, "m3 (pre-paid epoch 8)");
        assertEq(a[3], 701_915_278, "m4 kicked");
        a = _multiExit(true, true);
        uint256[4] memory b = _multiExit(true, false);
        assertEq(a[0], 660_910_118, "m1 shock, order A");
        assertEq(b[0], 660_910_119, "m1 shock, order B");
        assertEq(a[1], 658_000_119, "m2 shock, order A");
        assertEq(b[1], 658_000_118, "m2 shock, order B");
        assertEq(a[2], 751_842_511, "m3 shock, order A");
        assertEq(b[2], 751_842_511, "m3 shock, order B");
        assertEq(a[3], 678_350_639, "m4 shock, order A");
        assertEq(b[3], 678_350_639, "m4 shock, order B");
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(a[i], b[i], 1, "orders within 1 unit");
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev 10 members, totalEpochs 10, allocation 40/30/20/10. Loans 1 (m0, m1 vouches) and 2 (m9) funded at
    /// settle(3); m9 stops paying and is paused at settle(7). In epoch 7: three leaves (order A m1, m2, m3; B the
    /// reverse), a Kick on m4, an allocation change, a request by m8, optionally a -20% LP shock, and 7e6 of yield;
    /// m3 and m5 pre-pay epoch 8 before settle(7). Checks the step's invariants and that the circle runs to the end
    /// with every payout claimable. Returns the claimables of m1..m4 after settle(7).
    function _multiExit(bool shock, bool orderA) private returns (uint256[4] memory got) {
        (KuberCircle c, address[] memory ms) = _startGov(10, 10, 50, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(300e6, 2, 1_000, 0);
        _vouchAs(c, ms[1], 1, 30e6);
        vm.prank(ms[9]);
        c.requestLoan(10e6, 1, 0, 0);
        _settleAt(c, 4);
        vm.prank(ms[0]);
        c.claim();
        vm.startPrank(ms[9]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _settleAt(c, 5);
        _settleAt(c, 6);
        _settleAt(c, 7);
        (uint256 kid, uint256 aid) = _multiExitVotes(c, ms, orderA);
        vm.prank(ms[8]);
        c.requestLoan(50e6, 1, 0, 0);
        if (shock) lp.shock(-2_000);
        usdc.mint(address(c), 7e6);
        _warpTo(c, 8, false);
        _payNowAs(c, ms[3]);
        _payNowAs(c, ms[5]);
        c.settle(type(uint256).max);
        assertEq(uint256(c.getMember(ms[9]).status), uint256(MemberStatus.Suspended), "m9 paused");
        assertEq(uint256(c.getMember(ms[4]).status), uint256(MemberStatus.Kicked), "m4 kicked");
        assertEq(uint256(c.getProposal(kid).status), uint256(ProposalStatus.Applied), "kick applied");
        assertEq(uint256(c.getProposal(aid).status), uint256(ProposalStatus.Applied), "allocation applied");
        assertEq(c.getCircleState().rules.alloc.aave, 4_000, "new allocation");
        assertEq(uint256(c.getLoan(3).status), uint256(LoanStatus.Funded), "loan 3 funded");
        for (uint256 i = 1; i < 4; ++i) {
            assertEq(uint256(c.getMember(ms[i]).status), uint256(MemberStatus.Left), "left");
        }
        for (uint256 e = 7; e <= 8; ++e) {
            assertEq(_sumWeights(c, ms, e, false), _h(c).wActiveAt(e), "sum == wActive");
            assertEq(_sumWeights(c, ms, e, true), _h(c).wSaverAt(e), "sum == wSaver");
        }
        assertEq(c.getPublicSummary().reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
        for (uint256 i; i < 4; ++i) {
            got[i] = c.getMember(ms[i + 1]).claimable;
            vm.prank(ms[i + 1]);
            c.claim();
        }
        _multiExitFinish(c, ms);
        assertEq(usdc.balanceOf(address(c)), shock ? 4 : 2, "dust left in the circle");
    }

    function _multiExitVotes(KuberCircle c, address[] memory ms, bool orderA)
        private
        returns (uint256 kid, uint256 aid)
    {
        for (uint256 i; i < 3; ++i) {
            vm.prank(ms[orderA ? i + 1 : 3 - i]);
            c.requestLeave();
        }
        kid = _kickAs(c, ms[6], ms[4]);
        aid = _allocAs(c, ms[7], 1_000, 4_000, 4_000, 1_000);
        for (uint256 i; i < 10; ++i) {
            if (i != 4) {
                vm.prank(ms[i]);
                c.vote(kid, true);
            }
            vm.prank(ms[i]);
            c.vote(aid, true);
        }
    }

    /// @dev settle(8), (9), (10); every Active or Suspended member withdraws and every claimable is claimed.
    function _multiExitFinish(KuberCircle c, address[] memory ms) private {
        _settleAt(c, 9);
        _settleAt(c, 10);
        _settleAt(c, 11);
        for (uint256 i; i < ms.length; ++i) {
            MemberStatus st = c.getMember(ms[i]).status;
            if (st == MemberStatus.Active || st == MemberStatus.Suspended) {
                vm.prank(ms[i]);
                c.withdraw();
            }
            if (c.getMember(ms[i]).claimable != 0) {
                vm.prank(ms[i]);
                c.claim();
            }
        }
        assertEq(c.getPublicSummary().reservedClaims, 0, "every claim paid");
    }

    /// @dev Fresh exit fixture; m2 and m3 (identical savers) both leave, in the given order.
    function _twoLeavers(bool m2First) private {
        (KuberCircle c, address[] memory ms) = _exitFixture();
        vm.prank(m2First ? ms[2] : ms[3]);
        c.requestLeave();
        vm.prank(m2First ? ms[3] : ms[2]);
        c.requestLeave();
        // Each: 600e6 + floor(61e6 × 2_100 / 12_600) + 8_100_000 × 2_100 / 10_500 = 611_786_666; fee 18_353_600.
        (uint256 payout, uint256 fee) = c.exitValueOf(ms[2]);
        assertEq(payout, 593_433_066, "view payout");
        assertEq(fee, 18_353_600, "view fee");
        _settleAt(c, 7);
        assertEq(c.getMember(ms[2]).claimable, 593_433_066, "m2");
        assertEq(c.getMember(ms[3]).claimable, 593_433_066, "m3");
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.saverPot, 41_567_200, "8_100_000 - 2 x 1_620_000 + 2 x 18_353_600");
        assertEq(p.yieldPot, 40_666_668, "61e6 - 2 x 10_166_666");
        assertEq(_sumWeights(c, ms, 6, false), _h(c).wActiveAt(6), "sum == wActive");
        assertEq(_sumWeights(c, ms, 6, true), _h(c).wSaverAt(6), "sum == wSaver");
        assertEq(p.reservedClaims, _sumClaimable(c, ms), "reservedClaims == sum claimable");
    }

    // ---------------------------------------------------------------- T-MEM-3, T-MEM-4, D-11..D-13 (06-03)

    function test_T_MEM_3_applySponsorVoteAdmitted() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address[] memory aps = _newMembers(2);
        (address ap0, address ap1) = (aps[0], aps[1]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.JoinApplied(ap0);
        _applyAs(c, ap0);
        _applyAs(c, ap1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalCreated(1, ProposalKind.Join, ms[0], abi.encode(ap0));
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Sponsored(ms[0], ap0, 1);
        assertEq(_sponsorAs(c, ms[0], ap0), 1, "proposal 1");
        assertEq(registry.sponsorStats(ms[0]).sponsoredCount, 1, "sponsoredCount at sponsor()");
        Proposal memory p = c.getProposal(1);
        assertEq(uint256(p.kind), uint256(ProposalKind.Join), "Join");
        assertEq(p.target, ap0, "target");
        assertEq(p.proposer, ms[0], "proposer is the sponsor");
        assertEq(_sponsorAs(c, ms[1], ap1), 2, "proposal 2");
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.ProposalApplied(1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberAdmitted(ap0);
        c.settle(type(uint256).max);
        Member memory m = c.getMember(ap0);
        assertEq(uint256(m.status), uint256(MemberStatus.Active), "ap0 Active");
        assertEq(m.sponsor, ms[0], "sponsor recorded");
        assertEq(m.savings, 0, "zero savings");
        assertEq(m.weight, 0, "zero weight");
        assertEq(m.paidBitmap | m.missedBitmap, 0, "epochs <= 3 neither paid nor missed");
        assertEq(c.members().length, 7, "one admission per settlement");
        assertEq(uint256(c.getMember(ap1).status), uint256(MemberStatus.None), "ap1 waits");
        assertEq(uint256(c.getProposal(1).status), uint256(ProposalStatus.Applied), "1 Applied");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Passed), "2 Passed");
        assertEq(registry.activeMemberships(ap0), 1, "recordJoin");
        _approve(c, ap0);
        _approve(c, ap1);
        _settleAt(c, 5);
        assertEq(c.members().length, 8, "ap1 admitted at settle(4)");
        m = c.getMember(ap0);
        assertEq(m.paidCount, 1, "paid epoch 4");
        assertEq(m.savings, 100e6, "savings");
        assertEq(_h(c).weightAt(ap0, 4), 100e6, "counts from epoch 4");
        address[] memory all = _with(ms, aps);
        _assertLedger(c, all, 4);
        _settleAt(c, 6);
        _payNowAs(c, ap0);
        assertEq(c.getMember(ap0).paidCount, 3, "minSaveEpochs reached");
        uint256 id = _ruleAs(c, ap0, 1, 500);
        vm.prank(ap0);
        c.vote(id, true);
        assertEq(c.getProposal(id).yes, 1, "ap0 votes");
        _assertLedger(c, all, 6);
        _settleAt(c, 7);
        _settleAt(c, 8);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "Ended");
        for (uint256 i; i < 2; ++i) {
            KuberRegistry.SponsorStats memory s = registry.sponsorStats(ms[i]);
            assertEq(s.sponsoredCount, 1, "sponsoredCount");
            assertEq(s.sponsoredCompleted, 1, "sponsoredCompleted at finalize");
            assertEq(s.sponsoredSuspended, 0, "sponsoredSuspended");
        }
        assertEq(registry.sponsorStats(ms[2]).sponsoredCompleted, 0, "not a sponsor");
        KuberRegistry.MemberStats memory st = registry.memberStats(ap0);
        assertEq(st.circlesJoined, 1, "circlesJoined");
        assertEq(st.circlesCompleted, 1, "circlesCompleted");
        assertEq(registry.activeMemberships(ap0), 0, "slot freed");
        uint256 bal = usdc.balanceOf(ap0);
        vm.prank(ap0);
        c.withdraw();
        assertEq(usdc.balanceOf(ap0) - bal, 400e6, "epochs 4-7, yield 0");
    }

    function test_T_MEM_3_secondApprovedJoinerWaitsOneSettlement() public {
        (KuberCircle c, address[] memory ms, address ap0, address ap1) = _twoJoiners();
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ap0).status), uint256(MemberStatus.Active), "ap0 first");
        assertEq(uint256(c.getMember(ap1).status), uint256(MemberStatus.None), "ap1 waits");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Passed), "2 Passed");
        assertEq(registry.activeMemberships(ap1), 0, "no recordJoin yet");
        _approve(c, ap0);
        _approve(c, ap1);
        _warpTo(c, 5, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberAdmitted(ap1);
        c.settle(type(uint256).max);
        assertEq(c.members().length, 8, "8 entries");
        assertEq(c.members()[7], ap1, "appended");
        assertEq(c.getMember(ap1).sponsor, ms[1], "sponsor m1");
        assertEq(c.getMember(ap1).paidCount, 0, "ap1 counts from epoch 5");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Applied), "2 Applied");
        // Both joiners count in the denominator at once: 4 yes of 8 Active fail (4 of the 6 founders would pass).
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        _votes(c, id, ms, 0, 4, true);
        _settleAt(c, 6);
        assertEq(uint256(c.getProposal(id).status), uint256(ProposalStatus.Failed), "4 of 8 fails");
        assertEq(c.getCircleState().rules.ownRateBps, 300, "rule unchanged");
    }

    function test_T_MEM_3_newMemberVotesOnlyAfterMinSave() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        address founder = ms[5];
        _settleAt(c, 2);
        vm.prank(founder);
        usdc.approve(address(c), 0);
        _settleAt(c, 3);
        _approve(c, founder);
        _payAllBut(c, ms, address(0));
        assertEq(c.getMember(founder).paidCount, 2, "founder missed epoch 2");
        address[] memory aps = _newMembers(2);
        address ap0 = aps[0];
        _applyAs(c, ap0);
        uint256 join = _sponsorAs(c, ms[0], ap0);
        // D-04: founders vote from the first epoch, whatever their paidCount.
        vm.prank(founder);
        c.vote(join, true);
        assertEq(c.getProposal(join).yes, 1, "founder's vote counts");
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ap0).status), uint256(MemberStatus.Active), "admitted");
        _approve(c, ap0);
        uint256 id = _ruleAs(c, ms[0], 1, 500);
        vm.startPrank(ap0);
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        c.vote(id, true);
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        c.propose(ProposalKind.Rule, abi.encode(uint8(2), uint256(2_500)));
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        c.requestLoan(10e6, 1, 0, 0);
        vm.stopPrank();
        _applyAs(c, aps[1]);
        _sponsorReverts(c, ap0, aps[1], IKuberCircleErrors.NotEnoughSaved.selector);
        _settleAt(c, 5);
        _settleAt(c, 6);
        assertEq(c.getMember(ap0).paidCount, 2, "epochs 4 and 5");
        vm.prank(ap0);
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        c.propose(ProposalKind.Rule, abi.encode(uint8(1), uint256(500)));
        _payNowAs(c, ap0);
        assertEq(c.getMember(ap0).paidCount, 3, "epoch 6 paid");
        uint256 own = _ruleAs(c, ap0, 1, 500);
        vm.prank(ap0);
        c.vote(own, true);
        assertEq(c.getProposal(own).proposer, ap0, "ap0 proposes");
        assertEq(c.getProposal(own).yes, 1, "ap0 votes");
    }

    function test_T_MEM_4_sponsorRevertsEachReason() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        // aps[0] is "ap", aps[1..5] are ap2..ap6.
        address[] memory aps = _newMembers(6);
        _settleAt(c, 2);
        _applyAs(c, aps[0]);
        _sponsorReverts(c, ms[0], aps[0], IKuberCircleErrors.NotEnoughSaved.selector);
        _settleAt(c, 3);
        _payAllBut(c, ms, address(0));
        for (uint256 i = 1; i < 6; ++i) {
            _applyAs(c, aps[i]);
        }
        _sponsorReverts(c, makeAddr("stranger"), aps[0], IKuberCircleErrors.NotMember.selector);
        _sponsorReverts(c, ms[0], makeAddr("nonApplicant"), IKuberCircleErrors.NotApplicant.selector);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Sponsored(ms[0], aps[0], 1);
        _sponsorAs(c, ms[0], aps[0]);
        _sponsorReverts(c, ms[1], aps[0], IKuberCircleErrors.ProposalOpen.selector);
        _sponsorReverts(c, ms[0], aps[1], IKuberCircleErrors.AlreadySponsored.selector);
        _debt(ms[1]);
        _sponsorReverts(c, ms[1], aps[1], IKuberCircleErrors.HasOpenDebt.selector);
        vm.prank(factory.allCircles()[0]);
        registry.clearDebt(ms[1]);
        _sponsorAs(c, ms[1], aps[1]);
        vm.prank(ms[2]);
        c.requestLeave();
        _sponsorReverts(c, ms[2], aps[2], IKuberCircleErrors.LeavePending.selector);
        vm.prank(ms[2]);
        c.cancelLeave();
        for (uint256 i = 2; i < 5; ++i) {
            _sponsorAs(c, ms[i], aps[i]);
        }
        assertEq(c.openProposals().length, 5, "five open Joins");
        _sponsorReverts(c, ms[5], aps[5], IKuberCircleErrors.TooManyJoins.selector);
        _warpTo(c, 3, true);
        _sponsorReverts(c, ms[5], aps[5], IKuberCircleErrors.LockWindow.selector);
        _settleAt(c, 4);
        // The tally closed all five, so the limit is free again.
        _sponsorAs(c, ms[5], aps[5]);
        _approve(c, aps[0]);
        _settleAt(c, 5);
        _settleAt(c, 6);
        _payNowAs(c, aps[0]);
        assertEq(c.getMember(aps[0]).paidCount, 3, "a joiner who reached minSaveEpochs is an eligible sponsor");
        // e = 6: 6 + 2 > 7.
        _sponsorReverts(c, aps[0], makeAddr("late"), IKuberCircleErrors.JoinClosed.selector);
    }

    function test_D11_applyToJoinRevertsEachReason() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        _applyReverts(c, makeAddr("unverified"), IKuberCircleErrors.NotVerified.selector);
        address[] memory xs = _newMembers(4);
        _debt(xs[0]);
        _applyReverts(c, xs[0], IKuberCircleErrors.HasOpenDebt.selector);
        _applyReverts(c, ms[1], IKuberCircleErrors.AlreadyMember.selector);
        _applyAs(c, xs[1]);
        _applyReverts(c, xs[1], IKuberCircleErrors.AlreadyApplied.selector);
        _warpTo(c, 3, true);
        _applyReverts(c, xs[2], IKuberCircleErrors.LockWindow.selector);
        _settleAt(c, 4);
        _settleAt(c, 5);
        _settleAt(c, 6);
        // e = 6: 6 + 2 > 7.
        _applyReverts(c, xs[3], IKuberCircleErrors.JoinClosed.selector);
        (KuberCircle full,) = _startGov(6, 7, 6, _alloc(500, 5_000, 3_500, 1_000));
        _applyReverts(full, xs[3], IKuberCircleErrors.CircleFull.selector);
    }

    /// @dev A Forming-phase leaver's record was deleted (no money had moved), so they count as never a member.
    function test_D11_formingLeaverMayApply() public {
        address[] memory ms = _newMembers(6);
        KuberCircle c = _create(ms);
        _join(c, _tail(ms));
        vm.prank(ms[5]);
        c.leave();
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Active), "Active with 5");
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.JoinApplied(ms[5]);
        _applyAs(c, ms[5]);
    }

    /// @dev memberList keeps Left entries (the settlement cursor indexes it), so a leaver does not free a seat.
    function test_D11_leaverDoesNotFreeASeat() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 6, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[1]);
        c.requestLeave();
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ms[1]).status), uint256(MemberStatus.Left), "m1 Left");
        assertEq(c.members().length, 6, "Left entry kept");
        _applyReverts(c, _newMembers(1)[0], IKuberCircleErrors.CircleFull.selector);
    }

    function test_RJ2_sponsorCountsAsTheRoundsProposal() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address ap = _newMembers(1)[0];
        _applyAs(c, ap);
        _ruleAs(c, ms[0], 1, 500);
        _sponsorReverts(c, ms[0], ap, IKuberCircleErrors.AlreadyProposed.selector);
        _sponsorAs(c, ms[1], ap);
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.AlreadyProposed.selector);
        c.propose(ProposalKind.Rule, abi.encode(uint8(2), uint256(2_500)));
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ap).status), uint256(MemberStatus.Active), "admitted");
        uint256 id = _ruleAs(c, ms[1], 2, 2_500);
        assertEq(c.getProposal(id).proposer, ms[1], "next round is free");
    }

    function test_T_REG_2_applyAtMembershipCapReverts() public {
        (KuberCircle c,) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        address p = _newMembers(1)[0];
        _fiveCircles(p);
        assertEq(registry.activeMemberships(p), 5, "at the cap");
        _applyReverts(c, p, IKuberCircleErrors.AtMembershipCap.selector);
    }

    function test_T_MEM_1_cannotRejoinThisCycle() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[1]);
        c.requestLeave();
        uint256 kick = _kickAs(c, ms[0], ms[2]);
        // 4 of the 5 eligible voters (the target is excluded): 4 × 3 + 2 >= 2 × 6.
        _votes(c, kick, ms, 3, 3, true);
        vm.prank(ms[0]);
        c.vote(kick, true);
        _settleAt(c, 4);
        assertEq(uint256(c.getMember(ms[1]).status), uint256(MemberStatus.Left), "m1 Left");
        assertEq(uint256(c.getMember(ms[2]).status), uint256(MemberStatus.Kicked), "m2 Kicked");
        assertEq(registry.activeMemberships(ms[1]), 0, "not the cap");
        assertEq(registry.activeMemberships(ms[2]), 0, "not the cap");
        _applyReverts(c, ms[1], IKuberCircleErrors.AlreadyMember.selector);
        _applyReverts(c, ms[2], IKuberCircleErrors.AlreadyMember.selector);
    }

    function test_D13_admissionDropsFailedChecksAndAdmitsNext() public {
        _dropsCase(false);
        _dropsCase(true);
    }

    function test_D13_capAndEndOfCycleDropQueue() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        _settleAt(c, 4);
        _settleAt(c, 5);
        address[] memory aps = _newMembers(3);
        for (uint256 i; i < 3; ++i) {
            _applyAs(c, aps[i]);
            _sponsorAs(c, ms[i], aps[i]);
        }
        _fiveCircles(aps[0]);
        assertEq(registry.activeMemberships(aps[0]), 5, "ap0 at the cap");
        _settleAt(c, 6);
        assertEq(uint256(c.getProposal(1).status), uint256(ProposalStatus.Dropped), "1 Dropped: cap");
        assertEq(uint256(c.getMember(aps[0]).status), uint256(MemberStatus.None), "ap0 not admitted");
        assertEq(registry.activeMemberships(aps[0]), 5, "no recordJoin past the cap");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Applied), "2 Applied");
        assertEq(uint256(c.getMember(aps[1]).status), uint256(MemberStatus.Active), "ap1 admitted");
        assertEq(uint256(c.getProposal(3).status), uint256(ProposalStatus.Passed), "3 waits");
        address late = _newMembers(1)[0];
        _applyReverts(c, late, IKuberCircleErrors.JoinClosed.selector);
        _sponsorReverts(c, ms[3], late, IKuberCircleErrors.JoinClosed.selector);
        _settleAt(c, 7);
        assertEq(uint256(c.getProposal(3).status), uint256(ProposalStatus.Dropped), "k = 6 > totalEpochs - 2");
        assertEq(uint256(c.getMember(aps[2]).status), uint256(MemberStatus.None), "ap2 never admitted");
        assertEq(c.members().length, 7, "6 founders + ap1");
        _settleAt(c, 8);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "final settlement runs");
        assertEq(registry.sponsorStats(ms[1]).sponsoredCompleted, 1, "ap1 completed");
        assertEq(registry.sponsorStats(ms[2]).sponsoredCompleted, 0, "ap2 never joined");
    }

    function test_D13_droppedApplicantCanBeSponsoredAgain() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address ap0 = _newMembers(1)[0];
        _applyAs(c, ap0);
        _sponsorAs(c, ms[0], ap0);
        registry.setVerified(ap0, false);
        _settleAt(c, 4);
        assertEq(uint256(c.getProposal(1).status), uint256(ProposalStatus.Dropped), "1 Dropped: unverified");
        assertEq(uint256(c.getMember(ap0).status), uint256(MemberStatus.None), "not admitted");
        registry.setVerified(ap0, true);
        // One sponsorship per member per circle, even when it was dropped.
        _sponsorReverts(c, ms[0], ap0, IKuberCircleErrors.AlreadySponsored.selector);
        assertEq(_sponsorAs(c, ms[3], ap0), 2, "sponsored again");
        _settleAt(c, 5);
        assertEq(uint256(c.getMember(ap0).status), uint256(MemberStatus.Active), "admitted");
        assertEq(c.getMember(ap0).sponsor, ms[3], "the second sponsor");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Applied), "2 Applied");
        assertEq(registry.sponsorStats(ms[0]).sponsoredCount, 1, "the dropped sponsorship still counted");
    }

    function test_T_DF_4_sponsoredSuspended() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 8, 30, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        address ap = _newMembers(1)[0];
        _applyAs(c, ap);
        _sponsorAs(c, ms[0], ap);
        _settleAt(c, 4);
        _approve(c, ap);
        _settleAt(c, 5);
        _settleAt(c, 6);
        _payNowAs(c, ap);
        assertEq(c.getMember(ap).paidCount, 3, "paidCount 3");
        // 6 + 1 + 1 = 8 = totalEpochs.
        vm.prank(ap);
        c.requestLoan(100e6, 1, 0, 0);
        _settleAt(c, 7);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "funded at settle(6)");
        vm.startPrank(ap);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _settleAt(c, 8);
        _settleAt(c, 9);
        assertEq(uint256(c.getMember(ap).status), uint256(MemberStatus.Suspended), "paused at the final settlement");
        KuberRegistry.SponsorStats memory s = registry.sponsorStats(ms[0]);
        assertEq(s.sponsoredCount, 1, "sponsoredCount");
        assertEq(s.sponsoredSuspended, 1, "sponsoredSuspended");
        assertEq(s.sponsoredCompleted, 0, "a paused member does not complete");
        assertEq(registry.memberStats(ap).suspensions, 1, "ap suspensions");
        assertEq(registry.memberStats(ap).circlesCompleted, 0, "ap circlesCompleted");
    }

    /// @dev Completes T-DF-7 (P-6): Phase 5 covered create, invite, request-to-join, join, request, vouch, and agree;
    /// open debt anywhere also blocks applying and sponsoring until it is cleared.
    function test_T_DF_7_applyAndSponsorLockedOut() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address[] memory xs = _newMembers(2);
        (address x, address ap) = (xs[0], xs[1]);
        _debt(x);
        _applyReverts(c, x, IKuberCircleErrors.HasOpenDebt.selector);
        _applyAs(c, ap);
        _debt(ms[0]);
        _sponsorReverts(c, ms[0], ap, IKuberCircleErrors.HasOpenDebt.selector);
        vm.startPrank(factory.allCircles()[0]);
        registry.clearDebt(x);
        registry.clearDebt(ms[0]);
        vm.stopPrank();
        _applyAs(c, x);
        assertEq(_sponsorAs(c, ms[0], ap), 1, "sponsor after the debt is cleared");
    }

    /// @dev N-1 with a joiner whose first accrual epoch is later than everyone else's: admitted by the completing
    /// batch of settle(3) while settle(4) is already due; the joiner pre-pays epoch 5 before a batched settle(4)
    /// collects epoch 4 (a back-fill). m0's loan is funded in that settle(4), so W_saver differs from W_active.
    function test_N1_joinerWeightsMatchAccumulatorsBatchedAndPending() public {
        (KuberCircle c, address[] memory ms) = _startGov(6, 10, 30, _alloc(4_000, 3_000, 2_000, 1_000));
        _openEpoch3(c, ms);
        vm.prank(ms[0]);
        c.requestLoan(100e6, 2, 0, 0);
        address[] memory aps = _newMembers(1);
        address ap = aps[0];
        _applyAs(c, ap);
        _sponsorAs(c, ms[1], ap);
        _warpTo(c, 5, false);
        c.settle(2);
        c.settle(2);
        assertEq(uint256(c.getMember(ap).status), uint256(MemberStatus.None), "not before the completing batch");
        c.settle(2);
        assertEq(uint256(c.getMember(ap).status), uint256(MemberStatus.Active), "admitted by the completing batch");
        assertEq(c.getCircleState().settledEpoch, 3, "settle(4) still pending");
        // Queue.fund skips a late settlement (clock > k + 1), so m0's request is funded at settle(4).
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Pending), "not funded late");
        address[] memory all = _with(ms, aps);
        _assertLedger(c, all, 3);
        _approve(c, ap);
        _payNowAs(c, ap);
        _payNowAs(c, ms[2]);
        c.settle(3);
        c.settle(4);
        assertEq(c.getCircleState().settledEpoch, 4, "settle(4) done in two batches");
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Funded), "m0 borrowed at settle(4)");
        Member memory m = c.getMember(ap);
        assertEq(m.paidCount, 2, "epochs 4 and 5");
        assertEq(m.savings, 200e6, "savings");
        assertEq(_h(c).weightAt(ap, 4), 100e6, "epoch 4 back-filled");
        assertEq(_h(c).weightAt(ap, 5), 300e6, "100e6 + 200e6");
        for (uint256 e = 4; e <= 6; ++e) {
            _assertLedger(c, all, e);
        }
        _settleAt(c, 6);
        _settleAt(c, 7);
        for (uint256 e = 6; e <= 8; ++e) {
            _assertLedger(c, all, e);
        }
    }

    /// @dev 6 founders (totalEpochs 7, maxMembers 30, allocation 5/50/35/10) in epoch 3 OPEN, all pre-paid; ap0 and ap1
    /// apply, m0 sponsors ap0 (proposal 1) and m1 sponsors ap1 (proposal 2). Returns before settle(3).
    function _twoJoiners() private returns (KuberCircle c, address[] memory ms, address ap0, address ap1) {
        (c, ms) = _startGov(6, 7, 30, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address[] memory aps = _newMembers(2);
        (ap0, ap1) = (aps[0], aps[1]);
        _applyAs(c, ap0);
        _applyAs(c, ap1);
        _sponsorAs(c, ms[0], ap0);
        _sponsorAs(c, ms[1], ap1);
    }

    /// @dev maxMembers 7: ap0 fails a check at admission (unverified, or open debt when `viaDebt`), so ap1 is admitted
    /// in the same settlement and fills the circle; ap2 is dropped at the next settlement because the circle is full.
    function _dropsCase(bool viaDebt) private {
        (KuberCircle c, address[] memory ms) = _startGov(6, 7, 7, _alloc(500, 5_000, 3_500, 1_000));
        _openEpoch3(c, ms);
        address[] memory aps = _newMembers(3);
        for (uint256 i; i < 3; ++i) {
            _applyAs(c, aps[i]);
            _sponsorAs(c, ms[i], aps[i]);
        }
        if (viaDebt) _debt(aps[0]);
        else registry.setVerified(aps[0], false);
        _settleAt(c, 4);
        assertEq(uint256(c.getProposal(1).status), uint256(ProposalStatus.Dropped), "1 Dropped");
        assertEq(uint256(c.getMember(aps[0]).status), uint256(MemberStatus.None), "ap0 not admitted");
        assertEq(registry.activeMemberships(aps[0]), 0, "ap0 no recordJoin");
        assertEq(uint256(c.getProposal(2).status), uint256(ProposalStatus.Applied), "2 Applied, same settlement");
        assertEq(uint256(c.getMember(aps[1]).status), uint256(MemberStatus.Active), "ap1 admitted");
        assertEq(uint256(c.getProposal(3).status), uint256(ProposalStatus.Passed), "3 waits");
        assertEq(c.members().length, 7, "now full");
        _settleAt(c, 5);
        assertEq(uint256(c.getProposal(3).status), uint256(ProposalStatus.Dropped), "3 Dropped: full");
        assertEq(uint256(c.getMember(aps[2]).status), uint256(MemberStatus.None), "ap2 not admitted");
        assertEq(c.members().length, 7, "never past maxMembers");
    }

    /// @dev Σ member weights at `e` equal W_active (Active members) and W_saver (Active, never borrowed).
    function _assertLedger(KuberCircle c, address[] memory all, uint256 e) private view {
        assertEq(_sumWeights(c, all, e, false), _h(c).wActiveAt(e), "sum == wActive");
        assertEq(_sumWeights(c, all, e, true), _h(c).wSaverAt(e), "sum == wSaver");
    }

    function _with(address[] memory a, address[] memory b) private pure returns (address[] memory all) {
        all = new address[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            all[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            all[a.length + i] = b[i];
        }
    }

    function _approve(KuberCircle c, address who) private {
        vm.prank(who);
        usdc.approve(address(c), 5_000e6);
    }

    function _applyReverts(KuberCircle c, address who, bytes4 err) private {
        vm.prank(who);
        vm.expectRevert(err);
        c.applyToJoin();
    }

    function _sponsorReverts(KuberCircle c, address who, address applicant, bytes4 err) private {
        vm.prank(who);
        vm.expectRevert(err);
        c.sponsor(applicant);
    }

    function _leaveReverts(KuberCircle c, address who, bytes4 err) private {
        vm.prank(who);
        vm.expectRevert(err);
        c.requestLeave();
    }

    /// @dev Every asset (cash and both vaults) leaves the circle.
    function _drainAll(KuberCircle c) private {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        _h(c).drain(address(0xdead), p.cash + p.aaveValue + p.lpValue);
    }

    function _leftLogs(Vm.Log[] memory logs, address who) private pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics[0] == IKuberCircleEvents.MemberLeft.selector
                    && logs[i].topics[1] == bytes32(uint256(uint160(who)))
            ) {
                ++n;
            }
        }
    }
}
