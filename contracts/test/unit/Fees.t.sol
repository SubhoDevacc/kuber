// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {FixedParams, IKuberCircleEvents, MemberStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {GovTestBase} from "../utils/GovTestBase.sol";
import {HostileCircle, HONEST} from "../utils/HostileCircle.sol";

/// @dev 07-01 Task 1: protocol and manager fee at finalize and at exits (T-FEE-1, T-FEE-2; 07-CONTEXT D-01..D-03).
/// Every circle here: 5 members, contribution 100e6, all cash (no vault rounding), managerFeeBps 500, everyone pays
/// every epoch, so the weights are equal. `_settleAt(c, e)` settles epoch e − 1.
contract FeesTest is GovTestBase {
    uint256 internal constant MAX = type(uint256).max;
    bytes32 internal constant FEES_CHARGED = IKuberCircleEvents.FeesCharged.selector;

    address internal treasury;

    function setUp() public override {
        super.setUp();
        treasury = registry.treasury();
    }

    function test_T_FEE_1_finalizePositivePotRounding() public {
        (KuberCircle c, address[] memory ms) = _withManager(7);
        _settleThrough(c, 6);
        _warpTo(c, 8, false);
        usdc.mint(address(c), 100_000_007);
        vm.recordLogs();
        c.settle(MAX);
        (uint256 count, uint256 pf, uint256 mf) = _feeLogs(c, vm.getRecordedLogs());
        assertEq(count, 1, "one FeesCharged");
        // floor(100_000_007 × 1_000 / 10_000), then floor(90_000_007 × 500 / 10_000).
        assertEq(pf, 10_000_000, "protocol fee");
        assertEq(mf, 4_500_000, "manager fee");
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        assertEq(p.yieldPot, 85_500_007, "frozen pot");
        assertEq(p.feesCharged, 14_500_000, "feesCharged");
        assertEq(c.getMember(treasury).claimable, 10_000_000, "treasury claimable");
        assertEq(c.getMember(ms[1]).claimable, 4_500_000, "manager claimable");

        // floor(85_500_007 / 5) = 17_100_001 each; the manager's withdraw also carries its fee.
        for (uint256 i; i < 5; ++i) {
            assertEq(_withdraw(c, ms[i]), 700e6 + 17_100_001 + (i == 1 ? 4_500_000 : 0), "payout");
        }
        assertEq(_claim(c, treasury), 10_000_000, "treasury claim");
        assertEq(usdc.balanceOf(address(c)), 2, "floor dust");
    }

    function test_T_FEE_1_zeroPotNoFee() public {
        (KuberCircle c, address[] memory ms) = _withManager(7);
        _settleThrough(c, 6);
        _warpTo(c, 8, false);
        vm.recordLogs();
        c.settle(MAX);
        (uint256 count,,) = _feeLogs(c, vm.getRecordedLogs());
        assertEq(count, 0, "no FeesCharged");
        assertEq(c.getPublicSummary().yieldPot, 0);
        assertEq(c.getPublicSummary().feesCharged, 0);
        assertEq(c.getMember(treasury).claimable, 0);
        assertEq(c.getMember(ms[1]).claimable, 0);
    }

    function test_T_FEE_1_negativePotNoFee() public {
        (KuberCircle c, address[] memory ms) = _withManager(7);
        _settleThrough(c, 6);
        _warpTo(c, 8, false);
        _h(c).drain(address(0xbeef), 50e6);
        vm.recordLogs();
        c.settle(MAX);
        (uint256 count,,) = _feeLogs(c, vm.getRecordedLogs());
        assertEq(count, 0, "no FeesCharged");
        assertEq(c.getPublicSummary().yieldPot, -50e6);
        assertEq(c.getMember(treasury).claimable, 0);
        assertEq(c.getMember(ms[1]).claimable, 0);
        // 700e6 − ceil(50e6 × 700e6 / 3_500e6).
        for (uint256 i; i < 5; ++i) {
            assertEq(_withdraw(c, ms[i]), 690e6, "payout");
        }
    }

    /// @dev The T-END-2 "W_saver = 0" setup (test/unit/Repay.t.sol): all five borrow, so the savers' pot (15e6 of
    /// own-part interest) merges into the yield pot. 10e6 of yield arrives before the last settlement.
    function test_T_FEE_1_saverMergeNotCharged() public {
        registry.setProtocolFeeBps(1_000);
        (KuberCircle c, address[] memory ms) = _startLoans(5, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, ms);
        for (uint256 i; i < 5; ++i) {
            _request(c, ms[i], 100e6, 1, 0);
        }
        _settleAt(c, 4);
        for (uint256 i; i < 5; ++i) {
            vm.prank(ms[i]);
            c.claim();
        }
        _settleAt(c, 5);
        _settleAt(c, 6);
        uint256 saverPot = c.getPublicSummary().saverPot;
        assertEq(saverPot, 15e6);
        _settleAt(c, 7);
        _warpTo(c, 8, false);
        usdc.mint(address(c), 10e6);
        vm.recordLogs();
        c.settle(MAX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 count, uint256 pf, uint256 mf) = _feeLogs(c, logs);
        assertEq(count, 1);
        assertEq(mf, 0, "no manager");
        int256 frozen = _finalizedPot(c, logs);
        assertEq(c.getPublicSummary().yieldPot, frozen);
        // frozen = grossPot − fees + saverPot, so grossPot = frozen + pf − saverPot, and the fee is 10% of it only.
        uint256 gross = uint256(frozen) + pf - saverPot;
        assertEq(pf, gross * 1_000 / 10_000, "fee on the gross pot only");
        assertEq(c.getMember(treasury).claimable, pf);
        // By hand: gross 10e6 (the yield; the vaults redeem exactly), pf 1e6, frozen 9e6 + 15e6.
        assertEq(pf, 1e6);
        assertEq(frozen, 24e6);
        for (uint256 i; i < 5; ++i) {
            // 700e6 + 24e6 × 2_800 / 14_000.
            assertEq(_withdraw(c, ms[i]), 704_800_000, "payout");
        }
        assertEq(_claim(c, treasury), 1e6);
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    function test_T_FEE_1_exitPositiveShareThenFinalizeNoDoubleCharge() public {
        (KuberCircle c, address[] memory ms) = _withManager(8);
        _settleAt(c, 5);
        usdc.mint(address(c), 50e6);
        vm.prank(ms[3]);
        c.requestLeave();
        _settleAt(c, 6);
        // Pot 50e6 over five equal weights: gross share 10e6; pf 1_000_000, mf 5% of 9e6.
        assertEq(c.getMember(treasury).claimable, 1_000_000, "treasury after exit");
        assertEq(c.getMember(ms[1]).claimable, 450_000, "manager after exit");
        // value 500e6 + 10e6 − 1_450_000; exit fee ceil(508_550_000 × 300 / 10_000) = 15_256_500.
        assertEq(c.getMember(ms[3]).claimable, 493_293_500, "leaver payout");
        assertEq(c.getPublicSummary().feesCharged, 1_450_000);

        _settleAt(c, 7);
        _settleAt(c, 8);
        _warpTo(c, 9, false);
        vm.recordLogs();
        c.settle(MAX);
        (uint256 count, uint256 pf, uint256 mf) = _feeLogs(c, vm.getRecordedLogs());
        assertEq(count, 1);
        // Remaining pot 40e6: 10%, then 5% of 36e6.
        assertEq(pf, 4_000_000, "finalize protocol fee");
        assertEq(mf, 1_800_000, "finalize manager fee");
        assertEq(c.getPublicSummary().yieldPot, 34_200_000, "frozen pot");
        assertEq(c.getMember(treasury).claimable, 5_000_000, "10% of the 50e6 yield, once");
        assertEq(c.getMember(ms[1]).claimable, 2_250_000);
        assertEq(c.getPublicSummary().feesCharged, 7_250_000);
    }

    function test_T_FEE_1_exitNegativeShareNoFee() public {
        (KuberCircle c, address[] memory ms) = _withManager(8);
        _settleAt(c, 5);
        _h(c).drain(address(0xbeef), 50e6);
        vm.prank(ms[3]);
        c.requestLeave();
        vm.recordLogs();
        _settleAt(c, 6);
        (uint256 count,,) = _feeLogs(c, vm.getRecordedLogs());
        assertEq(count, 0, "no FeesCharged");
        assertEq(uint256(c.getMember(ms[3]).status), uint256(MemberStatus.Left));
        assertEq(c.getMember(treasury).claimable, 0);
        assertEq(c.getMember(ms[1]).claimable, 0);
        assertEq(c.getPublicSummary().feesCharged, 0);
    }

    function test_T_FEE_1_exitValueOfShowsNet() public {
        (KuberCircle c, address[] memory ms) = _withManager(8);
        _settleAt(c, 5);
        usdc.mint(address(c), 50e6);
        // Quote at settlement 5 before epoch 5 is paid: savings 400e6, gross yield share 10e6 (pot 50e6, 5 equal).
        uint256 snap = vm.snapshotState();
        registry.setProtocolFeeBps(0);
        (uint256 p0, uint256 f0,,) = c.exitValueOf(ms[3]);
        vm.revertToState(snap);
        (uint256 p1, uint256 f1,,) = c.exitValueOf(ms[3]);
        // Fee 0: only the manager fee, 5% of 10e6. Fee 1_000: pf 1e6, mf 5% of 9e6.
        assertEq(p0 + f0, 400e6 + 10e6 - 500_000, "value at fee 0");
        assertEq(p1 + f1, 400e6 + 10e6 - 1_000_000 - 450_000, "value at fee 1_000");
        assertEq((p0 + f0) - (p1 + f1), 1_000_000 - (500_000 - 450_000));
        assertLt(p1, p0);
    }

    function test_T_FEE_1_twoLeaversEitherOrderEqual() public {
        (KuberCircle c, address[] memory ms) = _withManager(8);
        _settleAt(c, 5);
        usdc.mint(address(c), 50e6);
        uint256 snap = vm.snapshotState();
        uint256[4] memory a = _twoLeave(c, ms[3], ms[4], ms[1]);
        vm.revertToState(snap);
        uint256[4] memory b = _twoLeave(c, ms[4], ms[3], ms[1]);
        assertEq(a[0], a[1], "equal payouts, order 3 then 4");
        assertEq(b[0], b[1], "equal payouts, order 4 then 3");
        assertEq(a[0], b[0], "same payout across orders");
        assertEq(a[2], b[2], "treasury credit across orders");
        assertEq(a[3], b[3], "manager credit across orders");
        // Gross share 10e6 each (the second leaver's pot is 40e6 over four weights): pf 1e6, mf 450_000 each.
        assertEq(a[0], 493_293_500);
        assertEq(a[2], 2_000_000);
        assertEq(a[3], 900_000);
    }

    function test_T_FEE_2_managerFeeAfterProtocolFee() public {
        // No manager: the manager fee is 0 and the protocol fee is 10% of the pot.
        (KuberCircle c, address[] memory ms) = _feeCircle(7);
        registry.setProtocolFeeBps(1_000);
        _openEpoch3(c, ms);
        _settleThrough(c, 6);
        _warpTo(c, 8, false);
        usdc.mint(address(c), 100e6);
        c.settle(MAX);
        assertEq(c.getCircleState().manager, address(0));
        assertEq(c.getMember(treasury).claimable, 10e6);
        assertEq(c.getPublicSummary().feesCharged, 10e6);
        assertEq(c.getPublicSummary().yieldPot, 90e6);

        // A manager (appointed at settle(3)); in epoch 4 a vote raises managerFeeBps 500 -> 1_000 while ms[4] has a
        // leave pending: the tally applies first, so the exit at settle(4) already uses 1_000 (live, R-E).
        (c, ms) = _withManager(7);
        uint256 t0 = c.getMember(treasury).claimable;
        usdc.mint(address(c), 50e6);
        vm.prank(ms[4]);
        c.requestLeave();
        uint256 id = _ruleAs(c, ms[0], 8, 1_000);
        _votes(c, id, ms, 0, 3, true);
        _settleAt(c, 5);
        assertEq(c.getCircleState().rules.managerFeeBps, 1_000);
        // Gross share 10e6: pf 1e6, mf (10e6 − 1e6) × 1_000 / 10_000.
        assertEq(c.getMember(treasury).claimable - t0, 1e6);
        assertEq(c.getMember(ms[1]).claimable, 900_000);
        _settleThrough(c, 6);
        _warpTo(c, 8, false);
        c.settle(MAX);
        // Finalize: remaining pot 40e6: pf 4e6, mf 36e6 × 10%.
        assertEq(c.getMember(treasury).claimable - t0, 5e6);
        assertEq(c.getMember(ms[1]).claimable, 900_000 + 3_600_000);
        assertEq(c.getPublicSummary().yieldPot, 32_400_000);
        // recordManagerEpoch ran at settlements 4, 5, 6, 7 (appointed at 3's apply step, after its read).
        KuberRegistry.ManagerStats memory st = registry.managerStats(ms[1]);
        assertEq(st.managedEpochs, 4, "managed epochs");
    }

    function test_T_FEE_2_managerClaimsWithLien() public {
        (KuberCircle c, address[] memory ms) = _withManager(8);
        _settleAt(c, 5);
        usdc.mint(address(c), 50e6);
        vm.prank(ms[3]);
        c.requestLeave();
        _settleAt(c, 6);
        address mgr = ms[1];
        assertEq(c.getMember(mgr).claimable, 450_000);
        // Open debt in a second (registry-listed) circle: the lien takes 200_000 of the fee.
        HostileCircle h = new HostileCircle(registry, usdc);
        vm.prank(address(factory));
        registry.authorizeCircle(address(h));
        h.owe(mgr);
        h.set(HONEST, 200_000, c);
        assertEq(_claim(c, mgr), 250_000, "manager receives the rest");
        assertEq(usdc.balanceOf(address(h)), 200_000, "lien paid");
        assertEq(c.getMember(mgr).claimable, 0);
    }

    // --- helpers ---

    /// @dev 5 members (ms[0] creates), `totalEpochs`, all cash, managerFeeBps 500; everyone approves 5_000e6.
    function _feeCircle(uint8 totalEpochs) internal returns (KuberCircle c, address[] memory ms) {
        ms = _newMembers(5);
        FixedParams memory f = _fixed();
        f.totalEpochs = totalEpochs;
        RuleParams memory r = _rules();
        r.managerFeeBps = 500;
        r.alloc = _alloc(0, 0, 0, 10_000);
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("fees", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < 5; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        vm.warp(f.startTime);
        c.activate();
    }

    /// @dev _feeCircle with protocol fee 1_000; ms[1] appointed manager by a vote in epoch 3 (applied at settle(3)).
    /// Returns at the start of epoch 4 with epochs 1..3 settled.
    function _withManager(uint8 totalEpochs) internal returns (KuberCircle c, address[] memory ms) {
        (c, ms) = _feeCircle(totalEpochs);
        registry.setProtocolFeeBps(1_000);
        _openEpoch3(c, ms);
        uint256 id = _managerAs(c, ms[0], ms[1]);
        _votes(c, id, ms, 0, 3, true);
        _settleAt(c, 4);
        assertEq(c.getCircleState().manager, ms[1]);
    }

    /// @dev Settles every epoch after settledEpoch up to `k`.
    function _settleThrough(KuberCircle c, uint256 k) internal {
        for (uint256 e = c.getCircleState().settledEpoch + 2; e <= k + 1; ++e) {
            _settleAt(c, e);
        }
    }

    function _withdraw(KuberCircle c, address who) internal returns (uint256 got) {
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        c.withdraw();
        got = usdc.balanceOf(who) - bal;
    }

    function _claim(KuberCircle c, address who) internal returns (uint256 got) {
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        c.claim();
        got = usdc.balanceOf(who) - bal;
    }

    /// @dev Number of FeesCharged events from `c` and the sums of their two amounts.
    function _feeLogs(KuberCircle c, Vm.Log[] memory logs) internal pure returns (uint256 n, uint256 pf, uint256 mf) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != FEES_CHARGED) continue;
            (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
            ++n;
            pf += a;
            mf += b;
        }
    }

    function _finalizedPot(KuberCircle c, Vm.Log[] memory logs) internal pure returns (int256 pot) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != IKuberCircleEvents.Finalized.selector) continue;
            (pot,,,,) = abi.decode(logs[i].data, (int256, uint256, uint256, uint256, uint256));
            return pot;
        }
        revert("no Finalized");
    }

    /// @dev `first` then `second` request a leave in epoch 5 OPEN; settle(5). Returns both payouts and the treasury's
    /// and the manager's claimable.
    function _twoLeave(KuberCircle c, address first, address second, address mgr)
        internal
        returns (uint256[4] memory r)
    {
        vm.prank(first);
        c.requestLeave();
        vm.prank(second);
        c.requestLeave();
        _settleAt(c, 6);
        r[0] = c.getMember(first).claimable;
        r[1] = c.getMember(second).claimable;
        r[2] = c.getMember(treasury).claimable;
        r[3] = c.getMember(mgr).claimable;
    }
}
