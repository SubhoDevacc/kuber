// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    CircleStatus,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev 05-03: recovery (T-DF-5), lockout (T-DF-7), and R-N3. Contribution 100e6, vault APY 0.
contract DebtTest is BackingTestBase {
    // ---------------------------------------------------------------- T-DF-5

    function test_T_DF_5_partialRepayStopsInVoucherTier() public {
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        _partialRepay(c, m);
    }

    function test_T_DF_5_fullRepayReinstatesAndClearsDebt() public {
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        _partialRepay(c, m);
        uint256 pot = c.getPublicSummary().saverPot;
        uint256 bal = usdc.balanceOf(m[3]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(m[3], 76_749_998, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberReinstated(m[3]);
        vm.prank(m[3]);
        c.repayDebt(1_000e6);
        assertEq(bal - usdc.balanceOf(m[3]), 76_749_998, "pulls exactly the rest");
        assertEq(c.getMember(m[1]).savings, 700e6, "m1 loss repaid");
        assertEq(c.getMember(m[2]).savings, 700e6, "m2 loss repaid");
        // Fines 21_749_998 to rewards by pledge 10 : 20 : 50, the last absorbing rounding.
        assertEq(c.getMember(m[1]).rewards, 2_718_749, "m1 rewards");
        assertEq(c.getMember(m[2]).rewards, 5_437_499, "m2 rewards");
        assertEq(c.getMember(m[4]).rewards, 13_593_750, "m4 rewards");
        assertEq(c.getPublicSummary().saverPot - pot, 35e6, "penalty to the savers' pot");
        Loan memory l = c.getLoan(1);
        assertEq(l.finesOwed + l.penaltyOwed + l.vouchers[0].loss + l.vouchers[1].loss + l.agreers[0].loss, 0);
        Member memory b = c.getMember(m[3]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "reinstated");
        assertEq(b.reinstatedEpoch, 8, "counts from the clock epoch");
        assertEq(b.weight, 0, "weight restarts at 0");
        assertFalse(registry.hasOpenDebt(m[3]), "registry debt cleared");
        assertEq(registry.debtCircles(m[3]).length, 0, "no debt circles");
        _payAllBut(c, m, address(0));
        _settleAt(c, 9);
        assertEq(_h(c).weightAt(m[3], 8), 100e6, "one contribution counted for epoch 8");
        assertEq(_sumWeights(c, m, 8), _h(c).wActiveAt(8), "member weights == wActive");
        vm.prank(m[3]);
        vm.expectRevert(IKuberCircleErrors.NoDebt.selector);
        c.repayDebt(1);
    }

    function test_T_DF_5_reinstateWhileSettlementPending() public {
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        _payAllBut(c, m, m[3]);
        _warpTo(c, 9, false);
        vm.startPrank(m[3]);
        usdc.approve(address(c), 5_000e6);
        uint256 bal = usdc.balanceOf(m[3]);
        c.repayDebt(1_000e6);
        vm.stopPrank();
        assertEq(bal - usdc.balanceOf(m[3]), 106_749_998, "whole debt");
        Member memory b = c.getMember(m[3]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "reinstated");
        assertEq(b.reinstatedEpoch, 9, "clock epoch 9, settle(8) still pending");
        bal = usdc.balanceOf(m[3]);
        c.settle(type(uint256).max);
        assertEq(usdc.balanceOf(m[3]), bal, "epoch 8 never charged");
        b = c.getMember(m[3]);
        assertEq(b.paidBitmap & (1 << 8), 0, "bit 8 not paid");
        assertEq(b.missedBitmap & (1 << 8), 0, "bit 8 not missed");
        assertEq(_h(c).weightAt(m[3], 8), 0, "epoch 8 not counted");
        _payAllBut(c, m, address(0));
        _settleAt(c, 10);
        assertEq(_h(c).weightAt(m[3], 9), 100e6, "counted from epoch 9");
        assertEq(_sumWeights(c, m, 9), _h(c).wActiveAt(9), "member weights == wActive");
    }

    function test_T_DF_5_endedRepayGoesToBackersClaimable() public {
        (KuberCircle c, address[] memory m) = _scenarioP(7, true, 4);
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "ended");
        vm.startPrank(m[3]);
        usdc.approve(address(c), 5_000e6);
        c.repayDebt(30e6);
        vm.stopPrank();
        assertEq(c.getMember(m[4]).claimable, 20e6, "agreer first");
        assertEq(c.getMember(m[1]).claimable, 3_333_333, "m1 by remaining loss");
        assertEq(c.getMember(m[2]).claimable, 6_666_667, "m2 absorbs rounding");
        uint256 bal = usdc.balanceOf(m[3]);
        vm.prank(m[3]);
        c.repayDebt(1_000e6);
        assertEq(bal - usdc.balanceOf(m[3]), 76_749_998, "pulls the rest");
        // Fines plus penalty 56_749_998 by pledge 10 : 20 : 50.
        assertEq(c.getMember(m[1]).claimable, 17_093_749, "m1: 10e6 + 7_093_749");
        assertEq(c.getMember(m[2]).claimable, 34_187_499, "m2: 20e6 + 14_187_499");
        assertEq(c.getMember(m[4]).claimable, 55_468_750, "m4: 20e6 + 35_468_750");
        assertEq(uint256(c.getMember(m[3]).status), uint256(MemberStatus.Suspended), "no reinstatement once Ended");
        assertFalse(registry.hasOpenDebt(m[3]), "registry debt cleared");
        assertEq(c.debtOf(m[3]), 0, "debt 0");
        for (uint256 i; i < 6; ++i) {
            vm.prank(m[i]);
            c.withdraw();
        }
        assertEq(usdc.balanceOf(address(c)), 0, "everything paid out");
    }

    function test_T_DF_5_endedRepayWithoutBackersGoesToTreasury() public {
        address[] memory m = _newMembers(6);
        RuleParams memory r = _rules();
        r.ownLtvBps = 10_000;
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        KuberCircle c = _startPeople(m, 7, r);
        _activate(c);
        _openEpoch3(c, m);
        vm.prank(m[3]);
        c.requestLoan(300e6, 3, 0, 0);
        for (uint256 e = 4; e <= 8; ++e) {
            _settleAt(c, e);
            if (e == 4) {
                vm.startPrank(m[3]);
                c.claim();
                usdc.approve(address(c), 0);
                vm.stopPrank();
            }
            if (e < 8) _payAllBut(c, m, m[3]);
        }
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Ended), "ended");
        Loan memory l = c.getLoan(1);
        assertEq(l.vouchers.length + l.agreers.length, 0, "no backers");
        assertEq(l.penaltyOwed, 30e6, "penalty owed");
        // Installments 103e6: 9_270_000 + 6_180_000 + 3_090_000.
        assertEq(l.finesOwed, 18_540_000, "fines owed");
        assertEq(c.debtOf(m[3]), 48_540_000, "debt");
        address treasury = registry.treasury();
        uint256 t0 = usdc.balanceOf(treasury);
        uint256 bal = usdc.balanceOf(m[3]);
        vm.startPrank(m[3]);
        usdc.approve(address(c), 5_000e6);
        c.repayDebt(1_000e6);
        vm.stopPrank();
        assertEq(bal - usdc.balanceOf(m[3]), 48_540_000, "pulls the debt");
        assertEq(usdc.balanceOf(treasury) - t0, 48_540_000, "all of it to the treasury");
        assertFalse(registry.hasOpenDebt(m[3]), "registry debt cleared");
    }

    /// @dev Decided with 05-03: a debt-0 default starts the same cooldown as a repaid loan: a request
    /// in epoch k + cooldownEpochs reverts, the next epoch it succeeds.
    function test_RN2_zeroDebtDefaultStartsCooldown() public {
        address[] memory m = _newMembers(6);
        RuleParams memory r = _rules();
        r.installFineBps = 0;
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        KuberCircle c = _startPeople(m, 12, r);
        _activate(c);
        _openEpoch3(c, m);
        // Own part 100e6 of 300e6 free savings: the default is fully covered, penalty 10e6 paid, no fines.
        vm.prank(m[3]);
        c.requestLoan(100e6, 1, 0, 0);
        _settleAt(c, 4);
        vm.startPrank(m[3]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        _payAllBut(c, m, m[3]);
        _settleAt(c, 5);
        _payAllBut(c, m, m[3]);
        _settleAt(c, 6);
        _payAllBut(c, m, m[3]);
        _settleAt(c, 7);
        _payAllBut(c, m, m[3]);
        _settleAt(c, 8);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Defaulted), "defaulted at settle(7)");
        assertEq(c.debtOf(m[3]), 0, "debt 0");
        Member memory b = c.getMember(m[3]);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "not paused");
        assertEq(b.cooldownUntil, 8, "k + cooldownEpochs: paused at settle(7)");
        vm.startPrank(m[3]);
        usdc.approve(address(c), 5_000e6);
        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        c.requestLoan(10e6, 1, 0, 0);
        vm.stopPrank();
        _payAllBut(c, m, address(0));
        _settleAt(c, 9);
        vm.prank(m[3]);
        c.requestLoan(10e6, 1, 0, 0);
    }

    // ---------------------------------------------------------------- T-DF-7

    function test_T_DF_7_lockoutUntilDebtPaid() public {
        // Apply and sponsor join this test in M6 (DECISIONS P-6).
        (KuberCircle x, KuberCircle y, address p,, address[] memory mx) = _xy(10, 0, 0);
        assertTrue(registry.hasOpenDebt(p), "open debt");
        bytes4 err = IKuberCircleErrors.HasOpenDebt.selector;
        address[] memory fresh = _newMembers(4);
        vm.prank(p);
        vm.expectRevert(err);
        factory.createCircle("p", _fixed(), _rules(), fresh);
        address[] memory wList = _newMembers(5);
        wList[1] = p;
        vm.prank(wList[0]);
        KuberCircle w = KuberCircle(factory.createCircle("w", _fixed(), _rules(), _tail(wList)));
        vm.prank(p);
        vm.expectRevert(err);
        w.join();
        address[] memory zList = _newMembers(5);
        vm.prank(zList[0]);
        KuberCircle z = KuberCircle(factory.createCircle("z", _fixed(), _rules(), _tail(zList)));
        vm.prank(zList[0]);
        vm.expectRevert(err);
        z.invite(p);
        vm.prank(p);
        vm.expectRevert(err);
        z.requestToJoin();
        vm.prank(p);
        vm.expectRevert(err);
        x.requestLoan(10e6, 1, 0, 0);
        _payNowAs(x, mx[0]);
        assertEq(x.getMember(mx[0]).savings, 800e6, "mx[0] savings");
        vm.prank(mx[0]);
        x.requestLoan(1_000e6, 1, 0, 0);
        assertEq(x.getLoan(1).backedNeed, 280e6, "own 720e6, backed 280e6");
        vm.prank(p);
        vm.expectRevert(err);
        x.vouch(1, 1e6);
        vm.prank(p);
        vm.expectRevert(err);
        x.agree(1, 1e6);
        uint256 bal = usdc.balanceOf(p);
        vm.startPrank(p);
        usdc.approve(address(y), 5_000e6);
        y.repayDebt(1_000e6);
        vm.stopPrank();
        assertEq(bal - usdc.balanceOf(p), 106_749_998, "repaid in y");
        assertFalse(registry.hasOpenDebt(p), "debt cleared");
        _vouchAs(x, p, 1, 1e6);
        vm.prank(p);
        z.requestToJoin();
    }

    /// @dev M5 review item 1: p requests 100e6 over 1 in x in epoch 7 while clean; y's settle(7) pauses p (open
    /// debt), so x's settle(7) in the same block must not fund it (lien-free proceeds otherwise). The request keeps its
    /// place; once the debt in y is repaid x funds it at settle(8). Left unpaid it expires at settle(9).
    function test_T_DF_7_requestNotFundedWhileBorrowerHasOpenDebt() public {
        (KuberCircle x, KuberCircle y, address p,,) = _xy(10, 7, 1);
        assertTrue(registry.hasOpenDebt(p), "p defaulted in y");
        Loan memory l = x.getLoan(1);
        assertEq(uint256(l.status), uint256(LoanStatus.Pending), "not funded at x's settle(7)");
        assertEq(l.requestedEpoch, 7, "requested while clean");
        assertEq(l.age, 1, "aged like any skipped request");
        assertEq(x.getQueue().length, 1, "keeps its place");
        assertEq(x.getMember(p).pendingRequestId, 1, "still pending");
        assertEq(x.getMember(p).claimable, 0, "no proceeds");
        uint256 snap = vm.snapshotState();
        _settleAt(x, 9);
        assertEq(uint256(x.getLoan(1).status), uint256(LoanStatus.Pending), "still skipped at settle(8)");
        _settleAt(x, 10);
        assertEq(uint256(x.getLoan(1).status), uint256(LoanStatus.Expired), "expires normally at settle(9)");
        vm.revertToState(snap);
        vm.startPrank(p);
        usdc.approve(address(y), 5_000e6);
        y.repayDebt(1_000e6);
        vm.stopPrank();
        assertFalse(registry.hasOpenDebt(p), "debt cleared");
        _settleAt(x, 9);
        l = x.getLoan(1);
        assertEq(uint256(l.status), uint256(LoanStatus.Funded), "funded at settle(8)");
        assertEq(l.fundedEpoch, 8, "fundedEpoch");
        assertEq(x.getMember(p).claimable, 100e6, "proceeds");
    }

    // ---------------------------------------------------------------- R-N3

    /// @dev The design check's Order scenario: L1b's loan closes in the same settle(7) that pauses M (M backs L1).
    /// The end state is the same in both member orders. Rounding bound: the borrower's take, every tier total, the
    /// savers' pot, and every non-backer's savings are equal exactly; within a tier of n backers a backer's savings
    /// can differ by fewer than 2(n - 1) units (two running-remainder splits against one). Exact here: one backer
    /// per tier.
    function test_RN3_sameSettlementBothOrdersMatch() public {
        (KuberCircle a, address[] memory pa, Vm.Log[] memory la) = _rn3(false, false);
        _one(la, a, IKuberCircleEvents.MemberSuspended.selector, 2, abi.encode(300e6, 300e6, 0, 0, 0, 48_721_198));
        assertEq(_count(la, a, IKuberCircleEvents.DebtRepaid.selector), 0, "L1b first: nothing freed after the pause");
        (KuberCircle b, address[] memory pb, Vm.Log[] memory lb) = _rn3(true, false);
        _one(
            lb, b, IKuberCircleEvents.MemberSuspended.selector, 2, abi.encode(300e6, 220e6, 50e6, 30e6, 0, 128_721_198)
        );
        _one(lb, b, IKuberCircleEvents.DebtRepaid.selector, uint160(pb[2]), abi.encode(80e6, 48_721_198));
        // M's installments 104_006_666, 104_006_666, 104_006_668; fines 9_360_599 + 6_240_399 + 3_120_200.
        assertEq(uint256(9_360_599 + 6_240_399 + 3_120_200), 18_721_198);
        for (uint256 r; r < 2; ++r) {
            (KuberCircle c, address[] memory p) = r == 0 ? (a, pa) : (b, pb);
            Member memory m = c.getMember(p[2]);
            assertEq(m.savings, 0, "M savings");
            assertEq(m.pledgedOut, 0, "M pledge released");
            assertEq(uint256(m.status), uint256(MemberStatus.Suspended), "M suspended");
            assertEq(c.debtOf(p[2]), 48_721_198, "penalty 30e6 + fines 18_721_198");
            Loan memory l = c.getLoan(2);
            assertEq(l.vouchers[0].loss + l.agreers[0].loss, 0, "backers made whole");
            assertEq(l.penaltyOwed, 30e6, "penalty owed");
            assertEq(l.finesOwed, 18_721_198, "fines owed");
            assertEq(c.getMember(p[3]).savings, 700e6, "V2");
            assertEq(c.getMember(p[4]).savings, 700e6, "A2");
            assertEq(c.getPublicSummary().saverPot, 8_100_000, "saverPot");
            assertEq(c.getPublicSummary().sTotal, 3_500e6, "sTotal");
            assertEq(_h(c).wActiveAt(7), 14_000e6, "wActive at 7");
            assertEq(_sumWeights(c, p, 7), _h(c).wActiveAt(7), "member weights == wActive");
        }
        _sameState(a, pa, b, pb, true);
    }

    /// @dev L1 is funded at settle(5) (due 7, 8, 9); M is paused at settle(7) with 80e6 still pledged; L1b's own
    /// payNow in epoch 9 repays L1 and the freed pledge repays M's backers then, counted from the clock epoch.
    function test_RN3_laterSettlementRepaysBackersAtRelease() public {
        address[] memory p = _newMembers(6);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        KuberCircle c = _startPeople(p, 10, r);
        _activate(c);
        for (uint256 e = 1; e <= 9; ++e) {
            if (e > 1) {
                if (e == 8) vm.recordLogs();
                _settleAt(c, e);
            }
            if (e == 8) {
                _one(
                    vm.getRecordedLogs(),
                    c,
                    IKuberCircleEvents.MemberSuspended.selector,
                    2,
                    abi.encode(300e6, 220e6, 50e6, 30e6, 0, 128_721_198)
                );
                assertEq(c.getMember(p[2]).savings, 80e6, "M keeps the pledged 80e6");
                assertEq(c.getMember(p[2]).pledgedOut, 80e6, "still pledged to L1");
            }
            if (e == 9) break;
            _payAllBut(c, p, e >= 4 ? p[2] : address(0));
            if (e == 3) {
                vm.prank(p[1]);
                c.requestLoan(400e6, 3, 800, 0);
                _vouchAs(c, p[2], 1, 80e6);
                vm.prank(p[2]);
                c.requestLoan(300e6, 3, 800, 0);
                _vouchAs(c, p[3], 2, 50e6);
                _agreeAs(c, p[4], 2, 52e6);
            } else if (e == 4) {
                vm.startPrank(p[2]);
                c.claim();
                usdc.approve(address(c), 0);
                vm.stopPrank();
            } else if (e == 5) {
                _vouchAs(c, p[5], 1, 50e6);
            } else if (e == 6) {
                vm.prank(p[1]);
                c.claim();
            }
        }
        // Epoch 9, settle(8) done: L1b pays contribution 9 and installment 2, so L1 is Repaid.
        uint256 v2 = c.getMember(p[3]).savings;
        uint256 a2 = c.getMember(p[4]).savings;
        assertEq(c.debtOf(p[2]), 128_721_198, "debt before the release");
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(p[2], 80e6, 48_721_198);
        _payNowAs(c, p[1]);
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid), "L1 repaid");
        assertEq(c.getMember(p[3]).savings - v2, 50e6, "V2 repaid at the release");
        assertEq(c.getMember(p[4]).savings - a2, 30e6, "A2 repaid at the release");
        assertEq(c.getMember(p[2]).savings, 0, "M's freed savings went to the backers");
        Loan memory l = c.getLoan(2);
        assertEq(l.vouchers[0].loss + l.agreers[0].loss, 0, "losses 0");
        assertEq(l.penaltyOwed, 30e6, "penalty still owed");
        assertEq(c.debtOf(p[2]), 48_721_198, "debt after");
        for (uint256 i = 3; i < 6; ++i) {
            _payNowAs(c, p[i]);
        }
        _payNowAs(c, p[0]);
        _settleAt(c, 10);
        assertEq(_sumWeights(c, p, 9), _h(c).wActiveAt(9), "member weights == wActive at 9");
    }

    /// @dev The one accepted order-dependence (R-N3 exception): with no fines the release-first order never pauses M
    /// (R-N2); the pause-first order pauses M, R-N3 repays the rest, and M is reinstated from k + 1 in the same pass.
    function test_RN3_zeroFinesPauseThenReinstate() public {
        (KuberCircle a, address[] memory pa, Vm.Log[] memory la) = _rn3(false, true);
        _one(la, a, IKuberCircleEvents.MemberSuspended.selector, 2, abi.encode(300e6, 300e6, 0, 0, 30e6, 0));
        assertEq(_count(la, a, IKuberCircleEvents.DebtRepaid.selector), 0, "never paused");
        assertEq(registry.memberStats(pa[2]).suspensions, 0, "no suspension recorded");
        assertEq(_h(a).weightAt(pa[2], 7), 1_870e6, "M's weight kept");
        (KuberCircle b, address[] memory pb, Vm.Log[] memory lb) = _rn3(true, true);
        _one(lb, b, IKuberCircleEvents.MemberSuspended.selector, 2, abi.encode(300e6, 300e6, 0, 0, 20e6, 10e6));
        _one(lb, b, IKuberCircleEvents.DebtRepaid.selector, uint160(pb[2]), abi.encode(10e6, 0));
        assertEq(_count(lb, b, IKuberCircleEvents.MemberReinstated.selector), 1, "reinstated");
        assertEq(registry.memberStats(pb[2]).suspensions, 1, "one suspension recorded");
        assertEq(b.getMember(pb[2]).reinstatedEpoch, 8, "counts from k + 1");
        assertEq(_h(b).weightAt(pb[2], 7), 0, "weight restarts");
        for (uint256 r; r < 2; ++r) {
            (KuberCircle c, address[] memory p) = r == 0 ? (a, pa) : (b, pb);
            assertEq(c.getMember(p[2]).savings, 70e6, "M: 400e6 - 300e6 - 30e6 penalty");
            assertEq(uint256(c.getMember(p[2]).status), uint256(MemberStatus.Active), "M active");
            assertEq(c.debtOf(p[2]), 0, "debt 0");
            assertFalse(registry.hasOpenDebt(p[2]), "no registry debt");
            assertEq(c.getPublicSummary().saverPot, 38_100_000, "saverPot");
            assertEq(c.getPublicSummary().sTotal, 3_570e6, "sTotal");
            assertEq(c.getMember(p[3]).savings, 700e6, "V2");
            assertEq(c.getMember(p[4]).savings, 700e6, "A2");
            assertEq(_sumWeights(c, p, 7), _h(c).wActiveAt(7), "member weights == wActive");
        }
        _sameState(a, pa, b, pb, false);
    }

    // ---------------------------------------------------------------- helpers

    // The first repayDebt(30e6) of the T-DF-5 Active bullet: agreer first, then the vouchers by remaining loss.
    function _partialRepay(KuberCircle c, address[] memory m) private {
        assertEq(uint256(c.getCircleState().status), uint256(CircleStatus.Active), "active");
        vm.prank(m[3]);
        usdc.approve(address(c), 5_000e6);
        uint256 bal = usdc.balanceOf(m[3]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(m[3], 30e6, 76_749_998);
        vm.prank(m[3]);
        c.repayDebt(30e6);
        assertEq(bal - usdc.balanceOf(m[3]), 30e6, "pulled 30e6");
        assertEq(c.getMember(m[4]).savings, 700e6, "agreer m4: 680e6 + 20e6");
        assertEq(c.getMember(m[1]).savings, 693_333_333, "m1: 690e6 + 3_333_333");
        assertEq(c.getMember(m[2]).savings, 686_666_667, "m2: 680e6 + 6_666_667");
        Loan memory l = c.getLoan(1);
        assertEq(l.agreers[0].loss, 0, "agreer loss repaid");
        assertEq(l.vouchers[0].loss, 6_666_667, "m1 loss left");
        assertEq(l.vouchers[1].loss, 13_333_333, "m2 loss left");
        assertEq(c.debtOf(m[3]), 76_749_998, "debt left");
        assertEq(uint256(c.getMember(m[3]).status), uint256(MemberStatus.Suspended), "still suspended");
        assertTrue(registry.hasOpenDebt(m[3]), "still open");
    }

    function _sumWeights(KuberCircle c, address[] memory ms, uint256 e) private view returns (uint256 sum) {
        for (uint256 i; i < ms.length; ++i) {
            if (c.getMember(ms[i]).status == MemberStatus.Active) sum += _h(c).weightAt(ms[i], e);
        }
    }

    /// @dev The R-N3 Order fixture (members [A, L1b, M, V2, A2, F]); returns the logs of settle(7).
    function _rn3(bool mFirst, bool zeroFines)
        private
        returns (KuberCircle c, address[] memory p, Vm.Log[] memory logs)
    {
        p = _newMembers(6);
        address[] memory list = new address[](6);
        for (uint256 i; i < 6; ++i) {
            list[i] = p[i];
        }
        if (mFirst) (list[1], list[2]) = (p[2], p[1]);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        if (zeroFines) r.installFineBps = 0;
        c = _startPeople(list, 10, r);
        _activate(c);
        uint256 mStop = zeroFines ? 5 : 4;
        for (uint256 e = 1; e <= 7; ++e) {
            if (e > 1) _settleAt(c, e);
            for (uint256 i; i < 6; ++i) {
                // L1b leaves contribution 7 and L1's last installment to settle(7)'s auto-debit.
                if ((i == 2 && e >= mStop) || (i == 1 && e == 7)) continue;
                _payNowAs(c, p[i]);
            }
            if (e == 3) {
                vm.prank(p[1]);
                c.requestLoan(350e6, 3, 800, 0);
                _vouchAs(c, p[2], 1, 80e6);
                vm.prank(p[2]);
                c.requestLoan(300e6, 3, 800, 0);
                _vouchAs(c, p[3], 2, 50e6);
                _agreeAs(c, p[4], 2, 52e6);
            } else if (e == 4) {
                vm.prank(p[1]);
                c.claim();
                vm.prank(p[2]);
                c.claim();
            }
            if (e == mStop) {
                vm.prank(p[2]);
                usdc.approve(address(c), 0);
            }
        }
        assertEq(c.getLoan(1).backedNeed, 80e6, "L1: own 270e6, backed 80e6");
        assertEq(c.getLoan(2).backedNeed, 102e6, "L2: own 198e6, backed 102e6");
        vm.recordLogs();
        _settleAt(c, 8);
        logs = vm.getRecordedLogs();
        assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid), "L1 repaid in settle(7)");
        assertEq(uint256(c.getLoan(2).status), uint256(LoanStatus.Defaulted), "L2 defaulted in settle(7)");
    }

    // Every member's savings and claimable + rewards, the other five members' weights at 7, and the circle totals.
    function _sameState(KuberCircle a, address[] memory pa, KuberCircle b, address[] memory pb, bool withW)
        private
        view
    {
        for (uint256 i; i < 6; ++i) {
            Member memory x = a.getMember(pa[i]);
            Member memory y = b.getMember(pb[i]);
            assertEq(x.savings, y.savings, "savings equal");
            assertEq(uint256(x.claimable) + x.rewards, uint256(y.claimable) + y.rewards, "claimable + rewards equal");
            if (i != 2) assertEq(_h(a).weightAt(pa[i], 7), _h(b).weightAt(pb[i], 7), "weight at 7 equal");
        }
        Loan memory la = a.getLoan(2);
        Loan memory lb = b.getLoan(2);
        assertEq(la.vouchers[0].loss, lb.vouchers[0].loss, "voucher loss equal");
        assertEq(la.agreers[0].loss, lb.agreers[0].loss, "agreer loss equal");
        assertEq(la.penaltyOwed, lb.penaltyOwed, "penaltyOwed equal");
        assertEq(la.finesOwed, lb.finesOwed, "finesOwed equal");
        assertEq(a.debtOf(pa[2]), b.debtOf(pb[2]), "debt equal");
        assertEq(uint256(a.getMember(pa[2]).status), uint256(b.getMember(pb[2]).status), "M status equal");
        assertEq(a.getPublicSummary().saverPot, b.getPublicSummary().saverPot, "saverPot equal");
        assertEq(a.getPublicSummary().sTotal, b.getPublicSummary().sTotal, "sTotal equal");
        assertEq(_h(a).wSaverAt(7), _h(b).wSaverAt(7), "wSaver equal");
        if (withW) assertEq(_h(a).wActiveAt(7), _h(b).wActiveAt(7), "wActive equal");
    }

    // Exactly one event `sig` from `c` with this first indexed topic and data.
    function _one(Vm.Log[] memory logs, KuberCircle c, bytes32 sig, uint256 topic1, bytes memory data) private pure {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != sig) continue;
            ++found;
            assertEq(uint256(logs[i].topics[1]), topic1, "topic");
            assertEq(logs[i].data, data, "event fields");
        }
        assertEq(found, 1, "exactly one event");
    }

    function _count(Vm.Log[] memory logs, KuberCircle c, bytes32 sig) private pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(c) && logs[i].topics[0] == sig) ++n;
        }
    }
}
