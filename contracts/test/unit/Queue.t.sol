// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {
    Alloc,
    BPS,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    Member
} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev The funding step (04-02): eligibility, capacity and the per-loan max from V, the aged / fast / line /
/// spill-back lanes, the funding effects, and claim. Contribution 100e6, APY 0, every settlement at the exact
/// start of the next epoch, offeredRateBps 0. A loan funded at k has its first installment due at k + 2; every
/// settlement here at or after that epoch asserts only state the collect pass does not touch, or comes after every
/// allowance was revoked.
contract QueueTest is LoanTestBase {
    uint256 private constant MAX = type(uint256).max;

    /// @dev S6: 6 members, allocation 40/30/20/10, per-loan max 50%. At settle(3): V 1_800e6, bucket 720e6, max 360e6.
    function _s6() private returns (KuberCircle c, address[] memory ms) {
        return _startLoans(6, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
    }

    /// @dev S10: 10 members, allocation 10/40/40/10, per-loan max 100%, all ten prepay epoch 3. At settle(3):
    /// V 3_000e6, bucket = max = 300e6, fast budget 90e6; at settle(4): V 4_000e6, bucket 400e6.
    function _s10() private returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _startLoans(10, 7, _alloc(1_000, 4_000, 4_000, 1_000), 10_000);
        _openEpoch3(c, ms);
    }

    function test_T_LN_3_backedRequestNeverEligible() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        address m1 = ms[1];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _payNowAs(c, m1);
        assertEq(_request(c, m0, 270e6, 2, 0), 1);
        // Own 270e6, backed 80e6: needs pledges M5 adds, so never eligible here.
        vm.prank(m1);
        assertEq(c.requestLoan(350e6, 2, 800, 0), 2);
        assertEq(c.getLoan(2).backedNeed, 80e6);

        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Line);
        c.settle(MAX);

        Loan memory loan = c.getLoan(1);
        assertEq(uint256(loan.status), uint256(LoanStatus.Funded));
        assertEq(uint256(loan.lane), uint256(Lane.Line));
        assertEq(loan.fundedEpoch, 3);
        // 270e6 × 300 / 10_000.
        assertEq(loan.saverInterest, 8_100_000);
        assertEq(loan.unclaimed, 270e6);
        assertEq(loan.age, 0);
        Member memory b = c.getMember(m0);
        assertEq(b.claimable, 270e6);
        assertEq(b.activeLoanId, 1);
        assertEq(b.pendingRequestId, 0);
        assertTrue(b.everBorrowed);
        assertFalse(c.getMember(m1).everBorrowed);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.reservedClaims, 270e6);
        assertEq(p.outstandingPrincipal, 270e6);
        assertEq(registry.memberStats(m0).loansTaken, 1);
        assertEq(registry.memberStats(m1).loansTaken, 0);
        // Six members at 600e6 each; m0's whole weight left W_saver.
        assertEq(_h(c).wActiveAt(3), 3_600e6);
        assertEq(_h(c).wSaverAt(3), 3_000e6);
        assertEq(_h(c).weightAt(m0, 3), 600e6);
        // Floor = idle 450e6 + buffer 180e6 + reservedClaims 270e6.
        _assertSplit(c, 900e6, 540e6, 360e6);
        _assertPending(c, 2, 1);
        assertEq(_q(c), _ids(2));

        // settle(4): V 2_400e6, so capacity 960e6 − 270e6 = 690e6 is ample; id 2 is aged and still not eligible.
        _settleAt(c, 5);
        assertEq(_v(c), 2_400e6);
        _assertPending(c, 2, 2);
        assertEq(c.getMember(m1).pendingRequestId, 2);

        // settle(5): 5 + 1 + 2 > 7, expires without ever being funded.
        _settleAt(c, 6);
        loan = c.getLoan(2);
        assertEq(uint256(loan.status), uint256(LoanStatus.Expired));
        assertEq(uint256(loan.lane), uint256(Lane.None));
        assertEq(loan.fundedEpoch, 0);
        assertEq(loan.unclaimed, 0);
        b = c.getMember(m1);
        assertEq(b.pendingRequestId, 0);
        assertEq(b.activeLoanId, 0);
        assertEq(b.claimable, 0);
        assertFalse(b.everBorrowed);
        assertEq(registry.memberStats(m1).loansTaken, 0);
        assertEq(c.getQueue().length, 0);
    }

    function test_T_LN_1_activeLoanBlocksRequest() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 270e6, 2, 0);
        _settleAt(c, 4);
        assertEq(c.getMember(m0).activeLoanId, 1);

        vm.expectRevert(IKuberCircleErrors.HasActiveLoan.selector);
        vm.prank(m0);
        c.requestLoan(10e6, 1, 0, 0);
        assertEq(_h(c).loanCount(), 1);
        assertEq(c.getQueue().length, 0);
        assertEq(c.getMember(m0).pendingRequestId, 0);
    }

    function test_claim_paysProceedsAndClearsMarker() public {
        (KuberCircle c, address[] memory ms) = _s6();
        address m0 = ms[0];
        _openEpoch3(c, new address[](0));
        _payNowAs(c, m0);
        _request(c, m0, 270e6, 2, 0);
        _settleAt(c, 4);
        assertEq(c.getLoan(1).unclaimed, 270e6);

        // Start of epoch 5: settle(4) is pending, and claim still works.
        _warpTo(c, 5, false);
        assertEq(c.getCircleState().settledEpoch, 3);
        uint256 before = usdc.balanceOf(m0);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanClaimed(1, m0, 270e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Claimed(m0, 270e6);
        vm.prank(m0);
        c.claim();

        assertEq(usdc.balanceOf(m0), before + 270e6);
        assertEq(c.getLoan(1).unclaimed, 0);
        Member memory b = c.getMember(m0);
        assertEq(b.claimable, 0);
        assertEq(b.activeLoanId, 1);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.reservedClaims, 0);
        assertEq(p.outstandingPrincipal, 270e6);
        // Paid from cash (900e6), no vault pull.
        _assertSplit(c, 630e6, 540e6, 360e6);

        vm.expectRevert(IKuberCircleErrors.NothingToClaim.selector);
        vm.prank(m0);
        c.claim();
    }

    function test_T_Q_1_unfundedRequestKeepsAge() public {
        (KuberCircle c, address[] memory ms) = _s10();
        _request(c, ms[1], 250e6, 3, 0);
        _request(c, ms[2], 160e6, 1, 0);

        // settle(3): id 1 Line (cap 300e6 → 50e6); id 2 160e6 > 50e6, skipped.
        _settleAt(c, 4);
        _assertFunded(c, 1, Lane.Line, 7_500_000);
        _assertPending(c, 2, 1);

        assertEq(_request(c, ms[3], 30e6, 2, 0), 3);
        assertEq(_q(c), _ids(2, 3));

        // settle(4): cap 400e6 − 250e6 = 150e6; id 2 160e6 > 150e6 skipped again, keeps its age and place.
        _settleAt(c, 5);
        _assertPending(c, 2, 2);
        assertEq(c.getLoan(2).requestedEpoch, 3);
        _assertFunded(c, 3, Lane.Line, 900_000);
        assertEq(c.getLoan(3).fundedEpoch, 4);
        assertEq(_q(c), _ids(2));
        assertEq(c.getPublicSummary().outstandingPrincipal, 280e6);
    }

    function test_T_Q_2_fastLaneBudgetAndExtra() public {
        (KuberCircle c, address[] memory ms) = _s10();
        _request(c, ms[1], 90e6, 1, 200);
        _request(c, ms[2], 50e6, 1, 500);
        _request(c, ms[3], 40e6, 1, 500);
        _request(c, ms[4], 130e6, 1, 0);
        _request(c, ms[5], 120e6, 1, 0);

        // Fast order id 2, id 3 (extra 500, older first), id 1 (200); budget 90e6: id 2 → 40e6, id 3 → 0, id 1
        // skipped. Line (cap 210e6): id 4 → 80e6; id 5 120e6 skipped. Spill back: id 1 90e6 > 80e6 skipped.
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(2, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(3, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(4, Lane.Line);
        c.settle(MAX);

        // Own 1_500_000 + extra 2_500_000.
        _assertFunded(c, 2, Lane.Fast, 4_000_000);
        // Own 1_200_000 + extra 2_000_000.
        _assertFunded(c, 3, Lane.Fast, 3_200_000);
        // Line pays no extra.
        _assertFunded(c, 4, Lane.Line, 3_900_000);
        // id 1 would have fit the 90e6 budget alone; higher extras went first.
        _assertPending(c, 1, 1);
        _assertPending(c, 5, 1);
        assertEq(_q(c), _ids(1, 5));
        assertEq(c.getPublicSummary().outstandingPrincipal, 220e6);

        // Repaid in epoch 4 (no fines): only the two fast-lane winners paid extra; the unfunded extra payer paid
        // nothing. 4_000_000 + 3_200_000 + 3_900_000.
        for (uint256 i = 2; i <= 4; ++i) {
            vm.prank(ms[i]);
            c.repayAll();
        }
        assertEq(c.getPublicSummary().saverPot, 11_100_000);
    }

    function test_T_Q_3_spillBackOrderHighestExtraThenOldest() public {
        (KuberCircle c, address[] memory ms) = _s10();
        // Four extra payers, each above the 90e6 fast budget, and one line request.
        _request(c, ms[1], 110e6, 1, 100);
        _request(c, ms[2], 100e6, 1, 300);
        _request(c, ms[3], 120e6, 1, 300);
        _request(c, ms[4], 100e6, 1, 200);
        _request(c, ms[5], 90e6, 1, 0);

        // Fast lane funds nothing. Line: id 5 → 210e6 left. Spill back, highest extra then oldest: id 2 → 110e6;
        // id 3 120e6 skipped; id 4 → 10e6; id 1 skipped. List order would fund ids 1 and 2; newest first among equal
        // extras would fund id 3 alone; lowest extra first would fund ids 1 and 4.
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(5, Lane.Line);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(2, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(4, Lane.Fast);
        c.settle(MAX);

        _assertFunded(c, 5, Lane.Line, 2_700_000);
        // Own 3_000_000 + extra 3_000_000.
        _assertFunded(c, 2, Lane.Fast, 6_000_000);
        // Own 3_000_000 + extra 2_000_000.
        _assertFunded(c, 4, Lane.Fast, 5_000_000);
        _assertPending(c, 1, 1);
        _assertPending(c, 3, 1);
        assertEq(_q(c), _ids(1, 3));
        assertEq(c.getPublicSummary().outstandingPrincipal, 290e6);
    }

    function test_T_Q_3_lineOldestFirstGetsUnusedFastBudget() public {
        (KuberCircle c, address[] memory ms) = _s10();
        _request(c, ms[1], 100e6, 1, 300);
        _request(c, ms[2], 30e6, 1, 100);
        _request(c, ms[3], 120e6, 1, 0);
        _request(c, ms[4], 100e6, 1, 0);
        _request(c, ms[5], 70e6, 1, 0);

        // Fast: id 1 100e6 > 90e6 skipped; id 2 funded, 60e6 of the budget unused. Line (270e6, including the
        // unused 60e6): id 3 → 150e6, id 4 → 50e6, id 5 70e6 skipped. Spill back: id 1 100e6 > 50e6 skipped.
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(2, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(3, Lane.Line);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(4, Lane.Line);
        c.settle(MAX);

        _assertFunded(c, 2, Lane.Fast, 1_200_000);
        // The line funded 220e6 > 300e6 − 90e6, so it used the fast lane's leftover; newest first would have
        // funded id 5 and id 4 and skipped id 3.
        _assertFunded(c, 3, Lane.Line, 3_600_000);
        _assertFunded(c, 4, Lane.Line, 3_000_000);
        _assertPending(c, 1, 1);
        _assertPending(c, 5, 1);
        assertEq(_q(c), _ids(1, 5));
        assertEq(c.getPublicSummary().outstandingPrincipal, 250e6);
    }

    function test_T_Q_3_spillBackFundsExtraPayer() public {
        (KuberCircle c, address[] memory ms) = _s10();
        _request(c, ms[1], 100e6, 1, 300);
        _request(c, ms[2], 30e6, 1, 100);
        _request(c, ms[3], 80e6, 1, 0);
        _request(c, ms[4], 50e6, 1, 0);

        // id 2 Fast (cap 270e6); line id 3 → 190e6, id 4 → 140e6; spill back id 1 100e6 ≤ 140e6.
        _warpTo(c, 4, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(2, Lane.Fast);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(3, Lane.Line);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(4, Lane.Line);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Fast);
        c.settle(MAX);

        _assertFunded(c, 2, Lane.Fast, 1_200_000);
        _assertFunded(c, 3, Lane.Line, 2_400_000);
        _assertFunded(c, 4, Lane.Line, 1_500_000);
        // Spilled back: lane Fast, pays its extra (own 3_000_000 + extra 3_000_000).
        _assertFunded(c, 1, Lane.Fast, 6_000_000);
        assertEq(c.getQueue().length, 0);
        assertEq(c.getPublicSummary().outstandingPrincipal, 260e6);
    }

    function test_T_Q_4_tooBigKeepsPlace() public {
        (KuberCircle c, address[] memory ms) = _s10();
        _request(c, ms[1], 200e6, 3, 0);
        _request(c, ms[2], 110e6, 2, 0);
        _request(c, ms[3], 80e6, 3, 0);

        // settle(3): id 1 → 100e6 left; id 2 110e6 skipped; id 3 → 20e6 left.
        _settleAt(c, 4);
        _assertFunded(c, 1, Lane.Line, 6_000_000);
        _assertPending(c, 2, 1);
        _assertFunded(c, 3, Lane.Line, 2_400_000);

        assertEq(_request(c, ms[4], 100e6, 2, 0), 4);
        assertEq(_q(c), _ids(2, 4));

        // settle(4): cap 400e6 − 280e6 = 120e6: id 2 → 10e6 left; id 4 100e6 skipped. Had id 2 lost its place,
        // id 4 would have been funded and id 2 skipped.
        _settleAt(c, 5);
        _assertFunded(c, 2, Lane.Line, 3_300_000);
        assertEq(c.getLoan(2).fundedEpoch, 4);
        _assertPending(c, 4, 1);
        assertEq(_q(c), _ids(4));
        assertEq(c.getPublicSummary().outstandingPrincipal, 390e6);
    }

    function test_T_Q_6_perLoanMaxAndBucketCapacity() public {
        // Demo allocation 5/50/35/10, per-loan max 50%; all six prepay.
        (KuberCircle c, address[] memory ms) = _startLoans(6, 7, _alloc(500, 5_000, 3_500, 1_000), 5_000);
        _openEpoch3(c, ms);
        _request(c, ms[1], 46e6, 2, 0);
        _request(c, ms[2], 45e6, 2, 0);
        _request(c, ms[3], 40e6, 2, 0);
        _request(c, ms[4], 10e6, 2, 0);

        // settle(3): V 1_800e6, bucket 90e6, max 1_800e6 × 500 × 5_000 / 10_000² = 45e6. id 1 above the max;
        // id 2 → 45e6 left; id 3 → 5e6 left; id 4 10e6 > 5e6 skipped.
        _settleAt(c, 4);
        assertEq(_v(c), 1_800e6);
        _assertPending(c, 1, 1);
        _assertFunded(c, 2, Lane.Line, 1_350_000);
        _assertFunded(c, 3, Lane.Line, 1_200_000);
        _assertPending(c, 4, 1);
        assertEq(c.getPublicSummary().outstandingPrincipal, 85e6);

        // settle(4): V 2_400e6, bucket 120e6, max 60e6, cap 35e6: id 1 is under the max now but 46e6 > 35e6.
        _settleAt(c, 5);
        assertEq(_v(c), 2_400e6);
        _assertPending(c, 1, 2);
        _assertFunded(c, 4, Lane.Line, 300_000);
        assertEq(c.getLoan(4).fundedEpoch, 4);
        assertEq(_q(c), _ids(1));
        assertEq(c.getPublicSummary().outstandingPrincipal, 95e6);
    }

    function test_agedFirst_ownPartBeatsFastLane() public {
        // The backed version (T-Q-7) is M5 (DECISIONS P-6).
        (KuberCircle c, address[] memory ms) = _startLoans(10, 7, _alloc(500, 4_500, 4_000, 1_000), 10_000);
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[2]);
        // A: 240e6 over 1 epoch, extra 100.
        assertEq(_request(c, ms[2], 240e6, 1, 100), 1);

        // settle(3): bucket = max = 150e6, A is above the max.
        _settleAt(c, 4);
        _assertPending(c, 1, 1);
        // settle(4): 200e6, still above.
        _settleAt(c, 5);
        _assertPending(c, 1, 2);

        // B: 50e6 over 1 epoch, extra 1_000.
        assertEq(c.getMember(ms[4]).paidCount, 4);
        assertEq(_request(c, ms[4], 50e6, 1, 1_000), 2);

        // settle(5): V 5_000e6, bucket = max = 250e6. Aged: A → 10e6 left. Fast budget 3e6: B skipped; spill back
        // 50e6 > 10e6 skipped. Without aged-first the fast lane (budget 75e6) would fund B and leave 200e6 < 240e6.
        _warpTo(c, 6, false);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Aged);
        c.settle(MAX);

        assertEq(_v(c), 5_000e6);
        // 240e6 × 3%; the aged lane charges no extra.
        _assertFunded(c, 1, Lane.Aged, 7_200_000);
        assertEq(c.getLoan(1).fundedEpoch, 5);
        _assertPending(c, 2, 1);
        assertEq(_q(c), _ids(2));
        assertEq(c.getPublicSummary().outstandingPrincipal, 240e6);
    }

    function test_agedFirst_oldestFirstAndFastBudgetOfCapacityLeft() public {
        // D-06 (d) aged oldest first, and R-D: the fast budget is fastLaneBps × the capacity left after aged funding.
        (KuberCircle c, address[] memory ms) = _startLoans(10, 7, _alloc(500, 4_500, 4_000, 1_000), 10_000);
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[2]);
        _payNowAs(c, ms[3]);
        // A1 210e6, A2 220e6: both above the max at settle(3) (150e6) and settle(4) (200e6).
        assertEq(_request(c, ms[2], 210e6, 1, 0), 1);
        assertEq(_request(c, ms[3], 220e6, 1, 0), 2);
        _settleAt(c, 4);
        _settleAt(c, 5);
        _assertPending(c, 1, 2);
        _assertPending(c, 2, 2);
        // F: 30e6 with extra 500; L: 20e6 with no extra.
        assertEq(_request(c, ms[4], 30e6, 1, 500), 3);
        assertEq(_request(c, ms[5], 20e6, 1, 0), 4);

        // settle(5): cap = max = 250e6. Aged, oldest first: A1 → 40e6 left; A2 220e6 skipped (newest first would
        // fund A2 and skip A1). Fast budget 40e6 × 30% = 12e6: F skipped. Line: L → 20e6 left. Spill back: F 30e6 >
        // 20e6 skipped. A budget of 30% of the total (75e6, capped at the 40e6 left) would fund F and leave L out.
        _settleAt(c, 6);
        _assertFunded(c, 1, Lane.Aged, 6_300_000);
        _assertPending(c, 2, 3);
        _assertPending(c, 3, 1);
        _assertFunded(c, 4, Lane.Line, 600_000);
        assertEq(_q(c), _ids(2, 3));
        assertEq(c.getPublicSummary().outstandingPrincipal, 230e6);
    }

    function test_T_EP_3_noFundingDuringCatchUp() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        _payNowAs(c, ms[0]);
        // 3 + 1 + 1 = 5.
        _request(c, ms[0], 200e6, 1, 0);

        // Nobody settles until the start of epoch 6.
        _warpTo(c, 6, false);
        // settle(3): clock 6 > 4, catching up.
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 3);
        _assertPending(c, 1, 0);
        assertEq(c.getLoan(1).fundedEpoch, 0);
        // settle(4): clock 6 > 5, catching up.
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 4);
        _assertPending(c, 1, 0);
        assertEq(c.getLoan(1).fundedEpoch, 0);
        assertEq(c.getPublicSummary().outstandingPrincipal, 0);
        // settle(5): clock 6 = 5 + 1, funding runs. First installment due 7 = 5 + 2: a fresh schedule.
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.LoanFunded(1, Lane.Line);
        c.settle(MAX);
        assertEq(c.getCircleState().settledEpoch, 5);
        _assertFunded(c, 1, Lane.Line, 6_000_000);
        assertEq(c.getLoan(1).fundedEpoch, 5);
        assertEq(c.getLoan(1).age, 0);
        assertEq(c.getPublicSummary().outstandingPrincipal, 200e6);
    }

    function test_A4_rebalancePullsVaultsWhenCashBelowFloor() public {
        (KuberCircle c, address[] memory ms) = _s6();
        _openEpoch3(c, new address[](0));
        for (uint256 i; i < 3; ++i) {
            _payNowAs(c, ms[i]);
        }
        _request(c, ms[0], 270e6, 3, 0);
        _request(c, ms[1], 270e6, 3, 0);
        _request(c, ms[2], 180e6, 3, 0);

        // settle(3): all three Line, 720e6 fills the bucket.
        _settleAt(c, 4);
        _assertFunded(c, 1, Lane.Line, 8_100_000);
        _assertFunded(c, 2, Lane.Line, 8_100_000);
        _assertFunded(c, 3, Lane.Line, 5_400_000);
        _assertSplit(c, 900e6, 540e6, 360e6);

        // Epoch 4: the borrowers claim, then every member revokes the allowance (nothing is pulled from here on).
        for (uint256 i; i < 3; ++i) {
            vm.prank(ms[i]);
            c.claim();
        }
        assertEq(usdc.balanceOf(address(c)), 180e6);
        for (uint256 i; i < 6; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 0);
        }

        // settle(4) after LP −50% (LP 180e6): V 1_620e6, bucket 648e6 < outstanding 720e6. Aave target 486e6, LP
        // target 324e6, floor 162e6 (buffer only): 54e6 pulled from Aave, 72e6 into LP.
        _warpTo(c, 5, false);
        lp.shock(-5000);
        assertEq(c.getPublicSummary().lpValue, 180e6);
        c.settle(MAX);
        assertEq(_v(c), 1_620e6);
        _assertSplit(c, 162e6, 486e6, 252e6);

        // settle(5) after LP +38.1% (LP 348_012_000): V 1_716_012_000, Aave target 514_803_600, LP target
        // 343_202_400, floor 171_601_200. Pulling LP's 4_809_600 excess leaves cash 166_809_600 below the floor,
        // so 4_791_600 comes from Aave (cash first, Aave ends below its target).
        _warpTo(c, 6, false);
        lp.shock(3810);
        assertEq(c.getPublicSummary().lpValue, 348_012_000);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Rebalanced(481_208_400, 343_202_400, 171_601_200);
        c.settle(MAX);
        _assertSplit(c, 171_601_200, 481_208_400, 343_202_400);
        assertEq(_v(c), 1_716_012_000);
        assertEq(usdc.balanceOf(address(c)), _floor(c));
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.outstandingPrincipal, 720e6);
        assertGt(p.outstandingPrincipal, _v(c) * 4_000 / BPS);
    }

    function test_G2_fundingGasWith50Requests() public {
        // (a) 50 backed requests (own 270e6, backed 80e6), none eligible.
        emit log_string("G2 (a): 50 requests, none eligible");
        (, uint256 fa) = _g2(_alloc(4_000, 5_000, 0, 1_000), 5_000, 350e6, 0, 50);
        assertLt(fa, 3_000_000);
        // (b) G2 per DECISIONS P-7b: the worst-case selection, 50 eligible in ascending-extra order, 2 funded by
        // spill back (bucket = max = 750e6, fast budget 225e6 < 260e6).
        emit log_string("G2 (b): 50 eligible, ascending extras, 2 funded");
        (, uint256 fb) = _g2(_alloc(500, 8_500, 0, 1_000), 10_000, 260e6, 1, 48);
        assertLt(fb, 3_000_000);
        // (c) Funding all 50 is reachable because there is no minimum loan size; it costs ~4.8M because each funded
        // loan makes two zero-to-non-zero writes plus a registry write, and the funding step passes 3M at about 25
        // funded loans. The whole settle call stays under G1's 8M.
        emit log_string("G2 (c): 50 eligible, all funded");
        (uint256 wc,) = _g2(_alloc(4_000, 5_000, 0, 1_000), 5_000, 100e6, 2, 0);
        assertLt(wc, 8_000_000);
    }

    /// @dev Cash and vault values from the summary view; the token agrees on cash.
    function _assertSplit(KuberCircle c, uint256 cash, uint256 aaveV, uint256 lpV) private view {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(usdc.balanceOf(address(c)), cash, "cash");
        assertEq(p.cash, cash, "summary cash");
        assertEq(p.aaveValue, aaveV, "aave value");
        assertEq(p.lpValue, lpV, "lp value");
    }

    function _assertFunded(KuberCircle c, uint256 id, Lane lane, uint256 saverInterest) private view {
        Loan memory loan = c.getLoan(id);
        assertEq(uint256(loan.status), uint256(LoanStatus.Funded), "status");
        assertEq(uint256(loan.lane), uint256(lane), "lane");
        assertEq(loan.saverInterest, saverInterest, "saverInterest");
        assertEq(loan.unclaimed, loan.amount, "unclaimed");
        assertEq(c.getMember(loan.borrower).activeLoanId, id, "activeLoanId");
        assertEq(c.getMember(loan.borrower).pendingRequestId, 0, "pendingRequestId");
    }

    function _assertPending(KuberCircle c, uint256 id, uint256 age) private view {
        Loan memory loan = c.getLoan(id);
        assertEq(uint256(loan.status), uint256(LoanStatus.Pending), "status");
        assertEq(loan.age, age, "age");
        assertEq(uint256(loan.lane), uint256(Lane.None), "lane");
        assertEq(c.getMember(loan.borrower).pendingRequestId, id, "pendingRequestId");
    }

    /// @dev V from public state (Phase 3 formula), independent of Invest.
    function _v(KuberCircle c) private view returns (uint256) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        uint256 assets = p.cash + p.aaveValue + p.lpValue + p.outstandingPrincipal;
        uint256 liabilities = p.reservedClaims + p.totalRewardsOwed + p.saverPot;
        return assets > liabilities ? assets - liabilities : 0;
    }

    function _q(KuberCircle c) private view returns (uint256[] memory out) {
        uint32[] memory q = c.getQueue();
        out = new uint256[](q.length);
        for (uint256 i; i < q.length; ++i) {
            out[i] = q[i];
        }
    }

    function _ids(uint256 a) private pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) private pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    /// @dev Phase 3's cash floor from public state: idle loan reserve + cash buffer + liabilities.
    function _floor(KuberCircle c) private view returns (uint256) {
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        Alloc memory a = c.getCircleState().rules.alloc;
        uint256 v = _v(c);
        uint256 bucket = v * a.loan / BPS;
        uint256 idle = bucket > p.outstandingPrincipal ? bucket - p.outstandingPrincipal : 0;
        return idle + v * a.cash / BPS + p.reservedClaims + p.totalRewardsOwed + p.saverPot;
    }

    /// @dev Gas of settle(3) with 50 members who all prepaid epoch 3, without and with 50 requests of `amount` over
    /// 3 epochs (extra by `kind`: 0 none, 1 i + 1, 2 (i % 2) × (i + 1)); `left` requests must remain pending.
    function _g2(Alloc memory al, uint16 maxBps, uint256 amount, uint256 kind, uint256 left)
        private
        returns (uint256 withRequests, uint256 funding)
    {
        (KuberCircle c, address[] memory ms) = _startLoans(50, 7, al, maxBps);
        _openEpoch3(c, ms);
        _warpTo(c, 4, false);
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        c.settle(MAX);
        uint256 baseline = g - gasleft();
        vm.revertToState(snap);
        _warpTo(c, 3, false);
        for (uint256 i; i < 50; ++i) {
            _request(c, ms[i], amount, 3, kind == 0 ? 0 : kind == 1 ? i + 1 : (i % 2) * (i + 1));
        }
        _warpTo(c, 4, false);
        g = gasleft();
        c.settle(MAX);
        withRequests = g - gasleft();
        funding = withRequests - baseline;
        emit log_named_uint("G2 baseline", baseline);
        emit log_named_uint("G2 with requests", withRequests);
        emit log_named_uint("G2 funding gas", funding);
        assertEq(c.getQueue().length, left, "requests left");
    }
}
