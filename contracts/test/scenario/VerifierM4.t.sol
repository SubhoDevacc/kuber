// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Alloc,
    BPS,
    FixedParams,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    RuleParams
} from "../../src/lib/CircleTypes.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev Verifier's own scenario (hand-computed before running). 8 members, contribution 100e6, 9 epochs,
/// minSaveEpochs 3, allocation 20/40/30/10, APY 0, ownLtv 90%, ownRate 4%, per-loan max 50%, fast lane 30%,
/// installFine 3%, cooldown 1. A = ms[1], B = ms[2], C = ms[3], D = ms[4]; ms[0], ms[5..7] never borrow.
contract VerifierM4Test is LoanTestBase {
    uint256 private constant MAX = type(uint256).max;

    KuberCircle c;
    address[] ms;
    address A;
    address B;
    address C;
    address D;

    function _start8() private {
        ms = _newMembers(8);
        FixedParams memory f = _fixed();
        f.totalEpochs = 9;
        f.maxMembers = 50;
        RuleParams memory r = _rules();
        r.ownRateBps = 400;
        r.alloc = Alloc({loan: 2_000, aave: 4_000, lp: 3_000, cash: 1_000});
        r.perLoanMaxBps = 5_000;
        r.fastLaneBps = 3_000;
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("verifier", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < 8; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        vm.warp(f.startTime);
        c.activate();
        A = ms[1];
        B = ms[2];
        C = ms[3];
        D = ms[4];
    }

    function _v() private view returns (uint256) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        return assets > liabilities ? assets - liabilities : 0;
    }

    function _pot() private view returns (uint256) {
        return c.getPublicSummary().saverPot;
    }

    function _out() private view returns (uint256) {
        return c.getPublicSummary().outstandingPrincipal;
    }

    function _funded(uint256 id, Lane lane, uint256 k, uint256 saverInterest) private view {
        Loan memory l = c.getLoan(id);
        assertEq(uint256(l.status), uint256(LoanStatus.Funded), "status");
        assertEq(uint256(l.lane), uint256(lane), "lane");
        assertEq(l.fundedEpoch, k, "fundedEpoch");
        assertEq(l.saverInterest, saverInterest, "saverInterest");
    }

    function test_verifierScenario() public {
        _start8();
        // ---- settle(1), settle(2): savings only.
        _settleAt(c, 2);
        assertEq(_v(), 800e6);
        assertEq(_out(), 0);
        assertEq(_pot(), 0);
        _settleAt(c, 3);
        assertEq(_v(), 1_600e6);
        assertEq(_out(), 0);
        assertEq(_pot(), 0);

        // ---- Epoch 3: A, B, C prepay (paidCount 3) and request.
        _payNowAs(c, A);
        _payNowAs(c, B);
        _payNowAs(c, C);
        vm.prank(A);
        assertEq(c.requestLoan(200e6, 2, 0, 0), 1);
        vm.prank(B);
        assertEq(c.requestLoan(100e6, 3, 0, 200), 2);
        vm.prank(C);
        assertEq(c.requestLoan(230e6, 1, 0, 0), 3);
        for (uint256 id = 1; id <= 3; ++id) {
            Loan memory l = c.getLoan(id);
            assertEq(l.ownPart, l.amount, "own part");
            assertEq(l.backedNeed, 0, "backed need");
            assertEq(l.ownRateBps, 400, "locked rate");
        }
        // D (paidCount 2) cannot request yet.
        vm.expectRevert(IKuberCircleErrors.NotEnoughSaved.selector);
        vm.prank(D);
        c.requestLoan(60e6, 2, 0, 500);

        // ---- settle(3): V 2_400e6, cap 480e6, per-loan max 240e6, fast budget 144e6.
        // Fast: B 100e6 (cap 380e6). Line: A 200e6 (cap 180e6), C 230e6 > 180e6 skipped, keeps its place.
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(2, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Line);
        c.settle(MAX);
        assertEq(_v(), 2_400e6);
        _funded(1, Lane.Line, 3, 8_000_000); // 200e6 × 4%
        _funded(2, Lane.Fast, 3, 6_000_000); // 100e6 × 4% + 100e6 × 2%
        assertEq(uint256(c.getLoan(3).status), uint256(LoanStatus.Pending));
        assertEq(c.getLoan(3).age, 1);
        assertEq(c.getQueue().length, 1);
        assertEq(_out(), 300e6);
        assertEq(_pot(), 0);
        assertEq(_h(c).wSaverAt(3), 3_600e6); // six savers × 600e6

        // ---- Epoch 4: A and B claim; B repays early; D requests with a higher extra.
        vm.prank(A);
        c.claim();
        vm.prank(B);
        c.claim();
        uint256 bal = usdc.balanceOf(B);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(2, 0, 35_333_333);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(2, 1, 35_333_333);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(2, 2, 35_333_334);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(2, true);
        vm.prank(B);
        c.repayAll();
        assertEq(bal - usdc.balanceOf(B), 106_000_000);
        assertEq(c.getMember(B).cooldownUntil, 5);
        assertEq(_pot(), 6_000_000);
        assertEq(_out(), 200e6);
        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        vm.prank(B);
        c.requestLoan(50e6, 1, 0, 0);
        vm.prank(D);
        assertEq(c.requestLoan(60e6, 2, 0, 500), 4);

        // ---- settle(4): V 3_200e6, bucket 640e6, outstanding 200e6 -> cap 440e6, max 320e6, fast budget 132e6.
        // Fast: D 60e6 (cap 380e6). Line: C 230e6 (cap 150e6).
        _warpTo(c, 5, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(4, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(3, Lane.Line);
        c.settle(MAX);
        assertEq(_v(), 3_200e6);
        _funded(3, Lane.Line, 4, 9_200_000); // 230e6 × 4%
        _funded(4, Lane.Fast, 4, 5_400_000); // 60e6 × 4% + 60e6 × 5%
        assertEq(c.getLoan(3).age, 1);
        assertEq(c.getQueue().length, 0);
        assertEq(_out(), 490e6);
        assertEq(_pot(), 6_000_000);
        assertEq(_h(c).wSaverAt(4), 4_000e6); // four savers × 1_000e6

        // ---- Epoch 5: B still in cooldown; C and D claim; A leaves room for the contribution only.
        vm.expectRevert(IKuberCircleErrors.InCooldown.selector);
        vm.prank(B);
        c.requestLoan(50e6, 1, 0, 0);
        vm.prank(C);
        c.claim();
        vm.prank(D);
        c.claim();
        vm.prank(A);
        usdc.approve(address(c), 100e6);

        // ---- settle(5): A's installment 0 (104e6) misses; one fine 3_120_000 recorded.
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(1, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(1, A, 3_120_000);
        c.settle(MAX);
        assertEq(_v(), 4_000e6);
        assertEq(c.getLoan(1).missedCount, 1);
        assertEq(c.getMember(A).paidCount, 5);
        assertEq(_out(), 490e6);
        assertEq(_pot(), 6_000_000);

        // ---- Epoch 6: A pays installment 0 one settlement late; B borrows again; D allows the contribution only.
        vm.prank(A);
        usdc.approve(address(c), 5_000e6);
        bal = usdc.balanceOf(A);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 0, 107_120_000);
        vm.prank(A);
        c.payArrears(1);
        assertEq(bal - usdc.balanceOf(A), 107_120_000);
        assertEq(_pot(), 13_120_000);
        assertEq(_out(), 390e6);
        vm.prank(B);
        assertEq(c.requestLoan(150e6, 2, 0, 0), 5);
        assertEq(c.getLoan(5).ownPart, 150e6);
        vm.prank(D);
        usdc.approve(address(c), 100e6);

        // ---- settle(6): A inst 1 (104e6, no fine) closes A late; C 239_200_000 closes C on time; D inst 0 misses.
        // Funding: V 4_800e6, bucket 960e6, outstanding 60e6 -> cap 900e6; B's 150e6 -> Line.
        uint256 balA = usdc.balanceOf(A);
        uint256 balC = usdc.balanceOf(C);
        _warpTo(c, 7, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(1, 1, 104e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(1, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(3, 0, 239_200_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(3, true);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(4, 0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(4, D, 981_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(5, Lane.Line);
        c.settle(MAX);
        assertEq(balA - usdc.balanceOf(A), 204e6);
        assertEq(balC - usdc.balanceOf(C), 339_200_000);
        assertEq(_v(), 4_800e6);
        _funded(5, Lane.Line, 6, 6_000_000); // 150e6 × 4%
        assertEq(_out(), 210e6);
        assertEq(_pot(), 26_320_000);
        assertEq(c.getMember(A).cooldownUntil, 7);
        assertEq(c.getMember(C).cooldownUntil, 7);

        // ---- Epoch 7: D again allows the contribution only. settle(7): inst 0 fined a second time, inst 1 misses.
        vm.prank(D);
        usdc.approve(address(c), 100e6);
        _warpTo(c, 8, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(4, D, 981_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentMissed(4, 1);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.FineCharged(4, D, 981_000);
        c.settle(MAX);
        assertEq(_v(), 5_600e6);
        assertEq(c.getLoan(4).missedCount, 2);
        assertEq(_out(), 210e6);
        assertEq(_pot(), 26_320_000);

        // ---- Epoch 8: D pays both: inst 0 two settlements late (2 fines), inst 1 one late.
        vm.prank(D);
        usdc.approve(address(c), 5_000e6);
        bal = usdc.balanceOf(D);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(4, 0, 34_662_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(4, 1, 33_681_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(4, false);
        vm.prank(D);
        c.payArrears(2);
        assertEq(bal - usdc.balanceOf(D), 68_343_000);
        assertEq(_pot(), 34_663_000);
        assertEq(_out(), 150e6);
        assertEq(c.getMember(D).cooldownUntil, 9);

        // ---- settle(8): B's second loan inst 0 (78e6).
        _warpTo(c, 9, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(5, 0, 78e6);
        c.settle(MAX);
        assertEq(_v(), 6_400e6);
        assertEq(_out(), 75e6);
        assertEq(_pot(), 37_663_000);

        // ---- settle(9): inst 1 closes B's second loan on time, then finalize.
        _warpTo(c, 10, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.InstallmentPaid(5, 1, 78e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanRepaid(5, true);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(0, 36_000e6, 18_000e6, 40_663_000, 7_200e6);
        c.settle(MAX);
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
        // 7_200e6 contributions + 40_663_000 interest and fines + B's unclaimed 150e6.
        assertEq(usdc.balanceOf(address(c)), 7_390_663_000);

        // Registry.
        _stats(A, 1, 0, 1);
        _stats(B, 2, 2, 0);
        _stats(C, 1, 1, 0);
        _stats(D, 1, 0, 2);

        // ---- Payouts: savers 900e6 + 40_663_000 × 4_500 / 18_000; borrowers 900e6; B also gets 150e6 unclaimed.
        uint256[8] memory want = [
            uint256(910_165_750),
            900_000_000,
            1_050_000_000,
            900_000_000,
            900_000_000,
            910_165_750,
            910_165_750,
            910_165_750
        ];
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            bal = usdc.balanceOf(ms[i]);
            vm.prank(ms[i]);
            c.withdraw();
            uint256 got = usdc.balanceOf(ms[i]) - bal;
            emit log_named_uint("payout", got);
            assertEq(got, want[i], "payout");
            sum += got;
        }
        assertEq(sum, 7_390_663_000);
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    function _stats(address who, uint256 loans, uint256 onTime, uint256 late) private view {
        KuberRegistry.MemberStats memory s = registry.memberStats(who);
        assertEq(s.loansTaken, loans, "loansTaken");
        assertEq(s.repaidOnTime, onTime, "repaidOnTime");
        assertEq(s.lateInstallments, late, "lateInstallments");
    }
}
