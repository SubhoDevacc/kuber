// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleEvents, Loan, LoanStatus, MemberStatus} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev S1: SPEC §4 under DECISIONS R-I (CONTEXT D-20), to the unit, whether members pre-pay before or after each
/// previous settlement. Any mismatch is a stop-and-report, never an edited expectation.
contract S1Test is BackingTestBase {
    function test_S1_workedExample_prepayAfterSettle() public {
        _s1(false);
    }

    function test_S1_workedExample_prepayBeforeSettle() public {
        _s1(true);
    }

    function _s1(bool prepayFirst) private {
        vm.recordLogs();
        (KuberCircle c, address[] memory p) = _s1Run(prepayFirst, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.MemberSuspended(2, 350e6, 300e6, 30e6, 20e6, 0, 106_749_998);
        c.settle(type(uint256).max);
        _checkS1(c, p);
    }

    function _checkS1(KuberCircle c, address[] memory p) private {
        // A owes 364_500_000 = 2 x 182_250_000 (175e6 + 4_050_000 + 3_200_000 each); D never pays loan 2.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid1;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != IKuberCircleEvents.InstallmentPaid.selector) {
                continue;
            }
            assertEq(uint256(logs[i].topics[1]), 1, "no installment of loan 2 paid");
            (, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(amount, 182_250_000, "loan 1 installment");
            ++paid1;
        }
        assertEq(paid1, 2, "two installments of loan 1");

        Loan memory l1 = c.getLoan(1);
        assertEq(l1.amount, 350e6, "loan 1 amount");
        assertEq(l1.saverInterest, 8_100_000, "loan 1 saverInterest");
        assertEq(l1.vouchers[0].interest, 6_400_000, "B interest");
        assertEq(uint256(l1.status), uint256(LoanStatus.Repaid), "loan 1 repaid");
        assertEq(c.getMember(p[1]).rewards, 6_400_000, "B rewards");
        assertEq(c.getMember(p[1]).pledgedOut, 0, "B pledge released");
        assertEq(c.getPublicSummary().saverPot, 8_100_000, "frozen savers' pot");

        Loan memory l2 = c.getLoan(2);
        assertEq(l2.saverInterest, 8_100_000, "loan 2 saverInterest");
        assertEq(l2.vouchers[0].interest, 2_400_000, "C interest");
        assertEq(l2.agreers[0].interest, 2_000_000, "E interest");
        assertEq(uint256(l2.status), uint256(LoanStatus.Defaulted), "loan 2 defaulted");
        assertEq(l2.vouchers[0].loss, 30e6, "C loss");
        assertEq(l2.agreers[0].loss, 20e6, "E loss");
        assertEq(l2.penaltyOwed, 35e6, "penalty owed");
        assertEq(l2.finesOwed, 21_749_998, "fines owed");
        // Fines by hand (D-10): 10_874_999 + 7_249_999 + 3_625_000; debt = 30e6 + 20e6 + 35e6 + 21_749_998.
        assertEq(uint256(10_874_999 + 7_249_999 + 3_625_000), 21_749_998);
        assertEq(c.debtOf(p[3]), 106_749_998, "D debt");
        assertTrue(registry.hasOpenDebt(p[3]), "D open debt");
        assertEq(uint256(c.getMember(p[3]).status), uint256(MemberStatus.Suspended), "D suspended");

        KuberCircle.PublicSummary memory s = c.getPublicSummary();
        assertEq(s.cash, 3_524_500_000, "cash");
        assertEq(s.reservedClaims + s.totalRewardsOwed + s.saverPot, 14_500_000, "liabilities");
        assertEq(s.sTotal, 3_450e6, "sTotal");
        assertEq(s.yieldPot, 60e6, "yieldPot");
        assertEq(s.wActive, 13_950e6, "wActive");
        assertEq(s.wSaver, 11_150e6, "wSaver");
        assertEq(_h(c).weightAt(p[0], 7), 2_800e6, "A weight");
        assertEq(_h(c).weightAt(p[1], 7), 2_800e6, "B weight");
        assertEq(_h(c).weightAt(p[2], 7), 2_770e6, "C weight");
        assertEq(_h(c).weightAt(p[4], 7), 2_780e6, "E weight");
        assertEq(_h(c).weightAt(p[5], 7), 2_800e6, "F weight");

        uint256[6] memory want = [uint256(712_043_010), 720_477_090, 683_926_264, 0, 693_976_540, 714_077_090];
        for (uint256 i; i < 6; ++i) {
            uint256 bal = usdc.balanceOf(p[i]);
            vm.prank(p[i]);
            c.withdraw();
            assertEq(usdc.balanceOf(p[i]) - bal, want[i], "payout");
        }
        assertEq(usdc.balanceOf(address(c)), 6, "dust");
    }
}
