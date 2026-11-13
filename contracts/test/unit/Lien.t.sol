// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    CircleStatus,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus
} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";
import {
    HostileCircle,
    HONEST,
    HUGE_DEBT,
    PULL_HALF,
    PULL_NONE,
    REENTER_CLAIM,
    REENTER_RECEIVE,
    REPORT_ZERO,
    REVERT_DEBT_OF,
    REVERT_RECEIVE
} from "../utils/HostileCircle.sol";

/// @dev 05-03: the payout with the lien (T-DF-6, R-O), own debt first, and a suspended member's share-out (T-END-1).
contract LienTest is BackingTestBase {
    uint256 internal constant Y_DEBT = 106_749_998;

    function test_T_DF_6_withdrawRepaysDebtInOtherCircleFirst() public {
        (KuberCircle x, KuberCircle y, address p, address[] memory my,) = _xy(7, 0, 0);
        assertEq(uint256(x.getCircleState().status), uint256(CircleStatus.Ended), "x ended");
        // y's settle(8) is pending and its window is LOCK: D-16 must still work.
        _warpTo(y, 9, true);
        uint256 xBal = usdc.balanceOf(address(x));
        uint256 pBal = usdc.balanceOf(p);
        vm.expectEmit(address(x));
        emit IKuberCircleEvents.LienPaid(p, address(y), Y_DEBT);
        vm.prank(p);
        x.withdraw();
        assertEq(usdc.balanceOf(p) - pBal, 593_250_002, "700e6 - y's debt");
        assertEq(xBal - usdc.balanceOf(address(x)), 700e6, "x pays exactly the payout");
        assertEq(y.debtOf(p), 0, "y repaid");
        Member memory b = y.getMember(p);
        assertEq(uint256(b.status), uint256(MemberStatus.Active), "reinstated in y");
        assertEq(b.reinstatedEpoch, 9, "from y's clock epoch");
        assertFalse(registry.hasOpenDebt(p), "registry debt cleared");
        assertEq(usdc.allowance(address(x), address(y)), 0, "no allowance left");
        assertEq(y.getMember(my[4]).savings, 700e6, "agreer repaid in y");
        assertEq(y.getMember(my[1]).rewards, 2_718_749, "fines to y's backers");
    }

    function test_T_DF_6_hostileCircleCannotBlockOrDrain() public {
        (KuberCircle x, KuberCircle y, address p,,) = _xy(7, 0, 0);
        HostileCircle h = _hostile(p);
        address[] memory cs = registry.debtCircles(p);
        assertEq(cs.length, 2, "two debt circles");
        assertEq(cs[0], address(y), "y first");
        assertEq(cs[1], address(h), "then h");
        uint8[8] memory modes = [
            REVERT_DEBT_OF, REVERT_RECEIVE, PULL_HALF, PULL_NONE, REENTER_CLAIM, REENTER_RECEIVE, HUGE_DEBT, REPORT_ZERO
        ];
        uint256[8] memory gets =
            [uint256(593_250_002), 593_250_002, 568_250_002, 593_250_002, 593_250_002, 593_250_002, 0, 593_250_002];
        uint256[8] memory pulls = [uint256(0), 0, 25e6, 0, 0, 0, 593_250_002, 0];
        for (uint256 i; i < 8; ++i) {
            uint256 snap = vm.snapshotState();
            h.set(modes[i], modes[i] == HUGE_DEBT ? 1e30 : 50e6, x);
            if (modes[i] == REPORT_ZERO) {
                // Never approved or called.
                vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.approve.selector, address(h)), 0);
            }
            Vm.Log[] memory logs = _withdrawLogged(x, p, gets[i]);
            assertEq(usdc.balanceOf(address(h)), pulls[i], "h pulled");
            assertEq(usdc.allowance(address(x), address(h)), 0, "no allowance to h");
            assertEq(y.debtOf(p), 0, "y paid first");
            address[] memory to = new address[](pulls[i] == 0 ? 1 : 2);
            uint256[] memory amts = new uint256[](to.length);
            (to[0], amts[0]) = (address(y), Y_DEBT);
            if (pulls[i] != 0) (to[1], amts[1]) = (address(h), pulls[i]);
            _liensAre(logs, x, to, amts);
            if (modes[i] == REENTER_CLAIM || modes[i] == REENTER_RECEIVE) {
                assertEq(
                    h.reentryError(),
                    abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                    "re-entry blocked"
                );
            }
            if (modes[i] == REPORT_ZERO || modes[i] == REVERT_DEBT_OF) assertEq(h.calls(), 0, "never called");
            vm.revertToState(snap);
        }
    }

    function test_T_DF_6_severalDebtCirclesPaidInOrder() public {
        (KuberCircle x, KuberCircle y, address p,,) = _xy(7, 0, 0);
        HostileCircle[4] memory hs = [_hostile(p), _hostile(p), _hostile(p), _hostile(p)];
        for (uint256 i; i < 3; ++i) {
            hs[i].set(HONEST, 10e6, x);
        }
        hs[3].set(REPORT_ZERO, 10e6, x);
        address[] memory cs = registry.debtCircles(p);
        assertEq(cs.length, 5, "y, h1, h2, h3, h0");
        assertEq(cs[0], address(y), "y first");
        Vm.Log[] memory logs = _withdrawLogged(x, p, 563_250_002);
        address[] memory to = new address[](4);
        uint256[] memory amts = new uint256[](4);
        (to[0], amts[0]) = (address(y), Y_DEBT);
        for (uint256 i; i < 3; ++i) {
            assertEq(cs[i + 1], address(hs[i]), "list order");
            assertEq(usdc.balanceOf(address(hs[i])), 10e6, "honest double paid");
            assertEq(usdc.allowance(address(x), address(hs[i])), 0, "no allowance");
            (to[i + 1], amts[i + 1]) = (address(hs[i]), 10e6);
        }
        assertEq(usdc.balanceOf(address(hs[3])), 0, "zero-debt double unpaid");
        assertEq(hs[3].calls(), 0, "zero-debt double never called");
        _liensAre(logs, x, to, amts);
    }

    function test_receiveLienPayment_onlyListedCircles() public {
        (KuberCircle c, address[] memory m) = _scenarioP(10, true, 4);
        address outsider = makeAddr("outsider");
        usdc.mint(outsider, 1_000e6);
        vm.startPrank(outsider);
        usdc.approve(address(c), 1_000e6);
        vm.expectRevert(IKuberCircleErrors.CallerNotCircle.selector);
        c.receiveLienPayment(m[3], 1_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(outsider), 1_000e6, "nothing pulled");
        assertEq(c.debtOf(m[3]), Y_DEBT, "debt unchanged");
    }

    function test_lien_unclaimedLoanProceedsAreLienFree() public {
        (KuberCircle x, KuberCircle y, address p,,) = _xy(10, 6, 3);
        Loan memory l = x.getLoan(1);
        assertEq(l.fundedEpoch, 6, "funded at x's settle(6)");
        assertEq(l.unclaimed, 100e6, "proceeds marked unclaimed");
        uint256 bal = usdc.balanceOf(p);
        vm.recordLogs();
        vm.expectEmit(address(x));
        emit IKuberCircleEvents.LoanClaimed(1, p, 100e6);
        vm.prank(p);
        x.claim();
        assertEq(usdc.balanceOf(p) - bal, 100e6, "proceeds in full");
        assertEq(_lienCount(vm.getRecordedLogs()), 0, "no LienPaid");
        assertEq(y.debtOf(p), Y_DEBT, "y untouched");
    }

    function test_lien_proceedsRepaidBeforeClaimAreLienable() public {
        (KuberCircle x, KuberCircle y, address p, address[] memory my,) = _xy(10, 3, 2);
        Loan memory l = x.getLoan(1);
        assertEq(uint256(l.status), uint256(LoanStatus.Repaid), "repaid by payNow in epochs 5 and 6");
        assertEq(l.unclaimed, 0, "marker cleared at repayment");
        assertEq(x.getMember(p).claimable, 100e6, "ordinary claimable");
        uint256 pot = y.getPublicSummary().saverPot;
        uint256 bal = usdc.balanceOf(p);
        vm.recordLogs();
        vm.expectEmit(address(x));
        emit IKuberCircleEvents.LienPaid(p, address(y), 100e6);
        vm.prank(p);
        x.claim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IKuberCircleEvents.LoanClaimed.selector, "no LoanClaimed");
        }
        assertEq(usdc.balanceOf(p), bal, "all of it to y");
        assertEq(y.debtOf(p), 6_749_998, "penalty left");
        assertEq(y.getMember(my[4]).savings, 700e6, "m4");
        assertEq(y.getMember(my[1]).savings, 700e6, "m1");
        assertEq(y.getMember(my[2]).savings, 700e6, "m2");
        assertEq(y.getMember(my[1]).rewards, 2_718_749, "m1 rewards");
        assertEq(y.getMember(my[2]).rewards, 5_437_499, "m2 rewards");
        assertEq(y.getMember(my[4]).rewards, 13_593_750, "m4 rewards");
        assertEq(y.getPublicSummary().saverPot - pot, 28_250_002, "100e6 - 50e6 - 21_749_998 of the penalty");
        assertEq(y.getLoan(1).penaltyOwed, 6_749_998, "penaltyOwed");
        assertEq(uint256(y.getMember(p).status), uint256(MemberStatus.Suspended), "still suspended");
    }

    function test_lien_claimRepaysOwnDebtHereFirst() public {
        (KuberCircle c, address[] memory m) = _scenarioP(7, false, 6);
        assertEq(c.getMember(m[3]).claimable, 116_666_666, "repaid-before-claim excess");
        assertEq(c.debtOf(m[3]), 10_874_999, "debt");
        uint256 bal = usdc.balanceOf(m[3]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.DebtRepaid(m[3], 10_874_999, 0);
        vm.prank(m[3]);
        c.claim();
        assertEq(usdc.balanceOf(m[3]) - bal, 105_791_667, "claimable minus own debt");
        assertEq(c.getMember(m[1]).claimable, 1_359_374, "m1 fines by pledge");
        assertEq(c.getMember(m[2]).claimable, 2_718_749, "m2");
        assertEq(c.getMember(m[4]).claimable, 6_796_876, "m4 absorbs rounding");
        assertFalse(registry.hasOpenDebt(m[3]), "debt cleared");
        assertEq(uint256(c.getMember(m[3]).status), uint256(MemberStatus.Suspended), "no reinstatement once Ended");
        bal = usdc.balanceOf(m[3]);
        vm.prank(m[3]);
        c.withdraw();
        assertEq(usdc.balanceOf(m[3]) - bal, 500e6, "leftover savings");
    }

    function test_T_END_1_suspendedPayoutPositiveYield() public {
        KuberCircle c = _tEnd1(true);
        uint256[6] memory want = [uint256(719_000_000), 727_156_249, 719_000_000, 0, 732_593_749, 719_000_000];
        _withdrawAll(c, 293_250_002, want, 0);
    }

    function test_T_END_1_suspendedPayoutNegativeYield() public {
        KuberCircle c = _tEnd1(false);
        // m3: 315e6 - ceil(360e6 * 315e6 / 3_815e6) = 29_724_771, minus its own debt 21_749_998.
        uint256[6] memory want = [uint256(640_944_954), 649_101_203, 640_944_954, 0, 654_538_703, 640_944_954];
        _withdrawAll(c, 263_525_231, want, 1);
    }

    // ---------------------------------------------------------------- helpers

    address[] internal tEndMembers;

    // T-END-1 for a suspended member: m3 is paused in the final settle(7), finalize records the leave.
    function _tEnd1(bool gain) private returns (KuberCircle c) {
        address[] memory m;
        (c, m) = _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        tEndMembers = m;
        _openEpoch3(c, m);
        vm.prank(m[3]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[1], 1, 30e6);
        _agreeAs(c, m[4], 1, 50e6);
        for (uint256 e = 4; e <= 8; ++e) {
            if (e >= 5) {
                // Contributions are pulled, installments are not.
                vm.prank(m[3]);
                usdc.approve(address(c), 100e6);
            }
            if (e == 8) {
                if (gain) usdc.mint(address(c), 60e6);
                else lp.shock(-5000);
            }
            _settleAt(c, e);
            if (e == 4) {
                vm.prank(m[3]);
                c.claim();
            }
            if (e < 8) _payAllBut(c, m, m[3]);
        }
        Loan memory l = c.getLoan(1);
        assertEq(uint256(l.status), uint256(LoanStatus.Defaulted), "defaulted");
        assertEq(l.finesOwed, 21_749_998, "fines owed");
        assertEq(l.penaltyOwed, 0, "penalty paid from leftover");
        assertEq(c.debtOf(m[3]), 21_749_998, "debt");
        assertEq(c.getMember(m[3]).savings, 315e6, "700e6 - 350e6 - 35e6");
        assertEq(uint256(c.getMember(m[3]).status), uint256(MemberStatus.Suspended), "suspended at the end");
        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.sTotal, 3_815e6, "sTotal includes the paused member");
        assertEq(s.yieldPot, gain ? int256(60e6) : -int256(360e6), "yield pot");
        assertEq(registry.activeMemberships(m[3]), 0, "recordLeave at finalize");
    }

    function _withdrawAll(KuberCircle c, uint256 m3Gets, uint256[6] memory want, uint256 dust) private {
        address[] memory m = tEndMembers;
        uint256 bal = usdc.balanceOf(m[3]);
        vm.prank(m[3]);
        c.withdraw();
        assertEq(usdc.balanceOf(m[3]) - bal, m3Gets, "m3: savings (no positive yield) minus own debt");
        assertEq(c.getMember(m[1]).claimable, 8_156_249, "m1: fines by pledge 30 : 50");
        assertEq(c.getMember(m[4]).claimable, 13_593_749, "m4");
        for (uint256 i; i < 6; ++i) {
            if (i == 3) continue;
            bal = usdc.balanceOf(m[i]);
            vm.prank(m[i]);
            c.withdraw();
            assertEq(usdc.balanceOf(m[i]) - bal, want[i], "payout");
        }
        assertEq(usdc.balanceOf(address(c)), dust, "dust left");
    }

    function _hostile(address p) private returns (HostileCircle h) {
        h = new HostileCircle(registry, usdc);
        vm.prank(address(factory));
        registry.authorizeCircle(address(h));
        h.owe(p);
    }

    // p withdraws from x: x pays exactly 700e6 and p receives `gets`; returns the logs.
    function _withdrawLogged(KuberCircle x, address p, uint256 gets) private returns (Vm.Log[] memory logs) {
        uint256 xBal = usdc.balanceOf(address(x));
        uint256 pBal = usdc.balanceOf(p);
        vm.recordLogs();
        vm.prank(p);
        x.withdraw();
        logs = vm.getRecordedLogs();
        assertEq(usdc.balanceOf(p) - pBal, gets, "p receives");
        assertEq(xBal - usdc.balanceOf(address(x)), 700e6, "x pays exactly the payout");
    }

    // The LienPaid events from x are exactly (to[i], amts[i]) in this order.
    function _liensAre(Vm.Log[] memory logs, KuberCircle x, address[] memory to, uint256[] memory amts) private pure {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(x) || logs[i].topics[0] != IKuberCircleEvents.LienPaid.selector) continue;
            assertLt(n, to.length, "extra LienPaid");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), to[n], "LienPaid circle");
            assertEq(abi.decode(logs[i].data, (uint256)), amts[n], "LienPaid amount");
            ++n;
        }
        assertEq(n, to.length, "LienPaid count");
    }

    function _lienCount(Vm.Log[] memory logs) private pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IKuberCircleEvents.LienPaid.selector) ++n;
        }
    }
}
