// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CircleTestBase} from "../utils/CircleTestBase.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {CircleStatus, IKuberCircleErrors, IKuberCircleEvents, Member, Window} from "../../src/lib/CircleTypes.sol";

/// @dev Finalize and withdraw (D-19, D-20, R-A). c = 100e6, contribFineBps 100, 6 members, 7 epochs. Every payout
/// is the member's token balance change across `withdraw()`.
contract ShareOutTest is CircleTestBase {
    uint256 internal constant MAX = type(uint256).max;

    /// @dev Warp to the start of epoch `e` and settle epoch e − 1 in one call.
    function _warpSettle(KuberCircle c, uint256 e) internal {
        _warpTo(c, e, false);
        c.settle(MAX);
    }

    function _withdraw(KuberCircle c, address m) internal returns (uint256) {
        uint256 before = usdc.balanceOf(m);
        vm.prank(m);
        c.withdraw();
        return usdc.balanceOf(m) - before;
    }

    /// @dev F = ms[5] is collected at settle(1), misses epoch 2 (allowance 0), is collected again from settle(3),
    /// and catches up epoch 2 in epoch 4 (fine 2e6). Ends in epoch 8 with settle(7) not yet run.
    function _fFlow() internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _start(6);
        address f = ms[5];
        _warpSettle(c, 2);
        vm.prank(f);
        usdc.approve(address(c), 0);
        _warpSettle(c, 3);
        vm.prank(f);
        usdc.approve(address(c), 700e6);
        _warpSettle(c, 4);
        vm.prank(f);
        c.catchUp(2);
        for (uint256 e = 5; e <= 7; ++e) {
            _warpSettle(c, e);
        }
        _warpTo(c, 8, false);
    }

    /// @dev T-END-1 (Active members) with D-23(d): a 60e6 donation before the last settlement is shared by weight.
    function test_T_END_1_payoutFormulaDonationSharedByWeight() public {
        (KuberCircle c, address[] memory ms) = _fFlow();
        usdc.mint(address(c), 60e6);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(60e6, 16_600e6, 16_600e6, 2e6, 4_200e6);
        c.settle(MAX);

        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 4_262e6);
        assertEq(p.yieldPot, 60e6);
        assertEq(p.wActive, 16_600e6);
        assertEq(p.wSaver, 16_600e6);
        assertEq(p.saverPot, 2e6);
        assertEq(p.sTotal, 4_200e6);
        // F's savings by epoch: 100, 100, 200, 400, 500, 600, 700.
        for (uint256 i; i < 6; ++i) {
            Member memory m = c.getMember(ms[i]);
            assertEq(m.savings, 700e6);
            assertEq(m.weight, i == 5 ? 2_600e6 : 2_800e6);
        }

        // m0..m4: 700e6 + floor(60e6 × 2_800 / 16_600) + floor(2e6 × 2_800 / 16_600) = 700e6 + 10_120_481 + 337_349.
        // F:      700e6 + floor(60e6 × 2_600 / 16_600) + floor(2e6 × 2_600 / 16_600) = 700e6 + 9_397_590 + 313_253.
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 want = i == 5 ? 709_710_843 : 710_457_830;
            vm.expectEmit(address(c));
            emit IKuberCircleEvents.Withdrawn(ms[i], want);
            assertEq(_withdraw(c, ms[i]), want);
            sum += want;
        }
        assertEq(sum, 4_261_999_993);
        assertEq(usdc.balanceOf(address(c)), 7);
    }

    function test_T_END_1_withdrawIncludesClaimable() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        for (uint256 e = 2; e <= 7; ++e) {
            _warpSettle(c, e);
        }
        _warpTo(c, 8, false);
        usdc.mint(address(c), 4e6);
        _h(c).creditClaimable(ms[3], 4e6);
        c.settle(MAX);

        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.yieldPot, 0, "claims are a liability, not yield");
        assertEq(p.reservedClaims, 4e6);
        assertEq(p.cash, 4_204e6);
        for (uint256 i; i < 6; ++i) {
            assertEq(_withdraw(c, ms[i]), i == 3 ? 704e6 : 700e6);
        }
        assertEq(c.getPublicSummary().reservedClaims, 0);
        assertEq(c.getMember(ms[3]).claimable, 0);
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    /// @dev D-23(c): every member pays all 7 epochs (payNow in OPEN, payNow in LOCK, or auto-debit).
    function test_D23c_sixMembersSevenEpochsWeightsAndPayouts() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        for (uint256 e = 1; e <= 7; ++e) {
            _warpTo(c, e, false);
            if (e >= 2) c.settle(MAX);
            for (uint256 i; i < 2; ++i) {
                vm.prank(ms[i]);
                c.payNow();
            }
            _warpTo(c, e, true);
            vm.prank(ms[2]);
            c.payNow();
        }
        _warpSettle(c, 8);
        assertEq(uint8(c.getCircleState().status), uint8(CircleStatus.Ended));

        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.wActive, 16_800e6);
        assertEq(p.wSaver, 16_800e6);
        assertEq(p.sTotal, 4_200e6);
        assertEq(p.yieldPot, 0);
        uint256 bal = usdc.balanceOf(address(c));
        assertEq(bal, 4_200e6);
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            Member memory m = c.getMember(ms[i]);
            assertEq(m.weight, 2_800e6);
            assertEq(m.paidBitmap, 254, "epochs 1..7 paid");
            assertEq(m.missedBitmap, 0);
            uint256 got = _withdraw(c, ms[i]);
            assertEq(got, 700e6);
            sum += got;
        }
        assertEq(sum, bal);
        assertEq(usdc.balanceOf(address(c)), 0, "dust 0");
    }

    function test_T_END_3_secondWithdrawRevertsDustStays() public {
        (KuberCircle c, address[] memory ms) = _fFlow();
        vm.prank(ms[0]);
        vm.expectRevert(IKuberCircleErrors.NotEnded.selector);
        c.withdraw();
        usdc.mint(address(c), 60e6);
        c.settle(MAX);

        for (uint256 i; i < 6; ++i) {
            _withdraw(c, ms[i]);
        }
        assertEq(usdc.balanceOf(address(c)), 7);
        for (uint256 i; i < 6; ++i) {
            assertTrue(c.getMember(ms[i]).withdrawn);
            vm.prank(ms[i]);
            vm.expectRevert(IKuberCircleErrors.AlreadyWithdrawn.selector);
            c.withdraw();
        }
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.withdraw();
        assertEq(usdc.balanceOf(address(c)), 7, "dust stays");
    }

    /// @dev D-20 negative branch (T-END-2 proper is M3's): F misses epoch 2 for good; 100e6 leaves before
    /// settle(7). Loss = ceil(100e6 × savings / 4_100e6): 17_073_171 (savings 700e6), 14_634_147 (F, 600e6).
    function test_negativeYield_lossSharedBySavings() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        address f = ms[5];
        _warpSettle(c, 2);
        vm.prank(f);
        usdc.approve(address(c), 0);
        _warpSettle(c, 3);
        vm.prank(f);
        usdc.approve(address(c), 700e6);
        for (uint256 e = 4; e <= 7; ++e) {
            _warpSettle(c, e);
        }
        _warpTo(c, 8, false);
        _h(c).drain(makeAddr("sink"), 100e6);
        c.settle(MAX);

        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 4_000e6);
        assertEq(p.sTotal, 4_100e6);
        assertEq(p.saverPot, 0);
        assertEq(p.yieldPot, -100e6);
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 savings = c.getMember(ms[i]).savings;
            assertEq(savings, i == 5 ? 600e6 : 700e6);
            uint256 got = _withdraw(c, ms[i]);
            assertEq(got, i == 5 ? 585_365_853 : 682_926_829);
            assertLe(got, savings);
            sum += got;
        }
        assertEq(sum, 3_999_999_998);
        assertEq(usdc.balanceOf(address(c)), 2);
    }

    /// @dev Boundary of R-A: a loss of exactly sTotal takes every savings part to 0 (loss = ceil(4_200e6 × s /
    /// 4_200e6) = s); the saver pot stays backed and is still paid by weight. ms[5] misses epoch 1 and catches it
    /// up in epoch 2 (x = 2, fine 1e6), so its weight is 27c and W = 16_700e6.
    function test_negativeYield_lossEqualToSavingsPaysOnlySaverShare() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        vm.prank(ms[5]);
        usdc.approve(address(c), 0);
        _warpSettle(c, 2);
        vm.startPrank(ms[5]);
        usdc.approve(address(c), 1_000e6);
        c.catchUp(1);
        vm.stopPrank();
        for (uint256 e = 3; e <= 7; ++e) {
            _warpSettle(c, e);
        }
        for (uint256 i; i < 6; ++i) {
            vm.prank(ms[i]);
            c.payNow();
        }
        _warpTo(c, 8, false);
        _h(c).drain(makeAddr("sink"), 4_200e6);
        c.settle(MAX);

        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.cash, 1e6);
        assertEq(p.saverPot, 1e6);
        assertEq(p.yieldPot, -4_200e6);
        assertEq(p.wSaver, 16_700e6);
        // Saver share only: floor(1e6 × 2_800 / 16_700) = 167_664; ms[5]: floor(1e6 × 2_700 / 16_700) = 161_676.
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 got = _withdraw(c, ms[i]);
            assertEq(got, i == 5 ? 161_676 : 167_664);
            sum += got;
        }
        assertEq(sum, 999_996);
        assertEq(usdc.balanceOf(address(c)), 4);
    }

    /// @dev DECISIONS R-U: an LP crash plus a drain leaves 1e5 against sTotal 4_200e6 and a 1e6 savers' pot. Finalize
    /// cuts the savers' pot to the 1e5 left, so every member can withdraw.
    function test_RU_lossAboveSavingsCutsSaverPot() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        vm.prank(ms[5]);
        usdc.approve(address(c), 0);
        _warpSettle(c, 2);
        vm.startPrank(ms[5]);
        usdc.approve(address(c), 1_000e6);
        c.catchUp(1);
        vm.stopPrank();
        for (uint256 e = 3; e <= 7; ++e) {
            _warpSettle(c, e);
        }
        for (uint256 i; i < 6; ++i) {
            vm.prank(ms[i]);
            c.payNow();
        }
        _warpTo(c, 8, false);
        lp.shock(-9998);
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        _h(c).drain(makeAddr("sink"), p.cash + p.aaveValue + p.lpValue - 1e5);
        c.settle(MAX);

        p = c.getPublicSummary();
        assertEq(p.cash, 1e5);
        assertEq(p.saverPot, 1e5);
        assertEq(p.yieldPot, -4_200e6);
        assertEq(p.wSaver, 16_700e6);
        // Without R-U the saver shares add up to more than the cash and the first withdraw reverts InsufficientLiquidity.
        // Saver share only: floor(1e5 × 2_800 / 16_700) = 16_766; ms[5]: floor(1e5 × 2_700 / 16_700) = 16_167.
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            uint256 got = _withdraw(c, ms[i]);
            assertEq(got, i == 5 ? 16_167 : 16_766);
            sum += got;
        }
        assertEq(sum, 99_997);
        assertEq(usdc.balanceOf(address(c)), 3);
    }

    /// @dev T-02-21: nobody saves inside the cycle (ms[1] catches up epoch 1 at clock 9, which counts for no epoch),
    /// so W_active = W_saver = 0. The saver pot (fine 8e6) joins the yield pot, no division by zero happens, and
    /// with no weight to share by, the pot stays in the circle.
    function test_finalize_zeroWeightsMergesSaverPot() public {
        (KuberCircle c, address[] memory ms) = _start(6);
        for (uint256 i; i < 6; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 0);
        }
        _warpSettle(c, 2);
        _warpTo(c, 9, false);
        vm.startPrank(ms[1]);
        usdc.approve(address(c), 108e6);
        c.catchUp(1);
        vm.stopPrank();
        for (uint256 k = 2; k <= 6; ++k) {
            c.settle(MAX);
        }
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Finalized(8e6, 0, 0, 0, 100e6);
        c.settle(MAX);

        assertEq(c.getMember(ms[1]).weight, 0);
        for (uint256 i; i < 6; ++i) {
            assertEq(_withdraw(c, ms[i]), i == 1 ? 100e6 : 0);
        }
        assertEq(usdc.balanceOf(address(c)), 8e6);
    }

    function test_claim_paysClaimableAnyTime() public {
        KuberCircle forming = _create(_newMembers(5));
        vm.expectRevert(IKuberCircleErrors.NotActive.selector);
        forming.claim();

        (KuberCircle c, address[] memory ms) = _start(6);
        usdc.mint(address(c), 5e6);
        _h(c).creditClaimable(ms[1], 5e6);
        // Epoch 2 LOCK with settle(1) still pending (R-F pay class).
        _warpTo(c, 2, true);
        assertEq(uint8(c.currentWindow()), uint8(Window.Lock));
        assertEq(c.getCircleState().settledEpoch, 0);
        uint256 bal = usdc.balanceOf(ms[1]);
        vm.expectEmit(address(c));
        emit IKuberCircleEvents.Claimed(ms[1], 5e6);
        vm.prank(ms[1]);
        c.claim();
        assertEq(usdc.balanceOf(ms[1]), bal + 5e6);
        assertEq(c.getPublicSummary().reservedClaims, 0);
        vm.prank(ms[1]);
        vm.expectRevert(IKuberCircleErrors.NothingToClaim.selector);
        c.claim();
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IKuberCircleErrors.NothingToClaim.selector);
        c.claim();

        c.settle(MAX);
        for (uint256 e = 3; e <= 8; ++e) {
            _warpSettle(c, e);
        }
        assertEq(uint8(c.getCircleState().status), uint8(CircleStatus.Ended));
        assertEq(c.getPublicSummary().yieldPot, 0);

        usdc.mint(address(c), 3e6);
        _h(c).creditClaimable(ms[2], 3e6);
        bal = usdc.balanceOf(ms[2]);
        vm.prank(ms[2]);
        c.claim();
        assertEq(usdc.balanceOf(ms[2]), bal + 3e6);
        // Neither claim is paid again by withdraw.
        assertEq(_withdraw(c, ms[2]), 700e6);
        assertEq(_withdraw(c, ms[1]), 700e6);
    }
}
