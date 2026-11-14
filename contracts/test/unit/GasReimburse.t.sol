// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleEvents} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "../utils/LoanTestBase.sol";

/// @dev A keeper contract that cannot receive anything: settle must not depend on paying it.
contract RevertingKeeper {
    function settle(KuberCircle c, uint256 n) external {
        c.settle(n);
    }

    receive() external payable {
        revert("no receive");
    }

    fallback() external payable {
        revert("no fallback");
    }
}

/// @dev 07-01 Task 2: gas reimbursement (T-FEE-3; 07-CONTEXT D-05, D-06). Settings: AVAX $30, gas price cap 100 gwei,
/// a per-epoch cap per test. Foundry's tx.gasprice is 0, so each test sets vm.txGasPrice after its setup settlements.
contract GasReimburseTest is LoanTestBase {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant PRICE = 30e6;
    uint256 internal constant GAS_CAP = 100e9;
    bytes32 internal constant REIMBURSED = IKuberCircleEvents.GasReimbursed.selector;

    address internal keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
    }

    function test_T_FEE_3_tinyCallsNotPaid() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        vm.recordLogs();
        vm.startPrank(keeper);
        for (uint256 i; i < 9; ++i) {
            c.settle(1);
        }
        c.settle(9);
        vm.stopPrank();
        assertEq(_reimbursedIn(c, vm.getRecordedLogs()), 0, "no GasReimbursed");
        assertEq(c.getCircleState().cursor, 18);
        assertEq(c.getMember(keeper).claimable, 0);
        assertEq(c.getPublicSummary().expenses, 0);
    }

    function test_T_FEE_3_tenMembersPaid() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        vm.startPrank(keeper);
        for (uint256 i; i < 9; ++i) {
            c.settle(1);
        }
        c.settle(9);
        uint256 before = c.getMember(keeper).claimable;
        vm.recordLogs();
        c.settle(10);
        vm.stopPrank();
        uint256 paid = _reimbursedIn(c, vm.getRecordedLogs());
        console.log("settle(10) paid", paid);
        assertGt(paid, 0, "paid");
        assertEq(c.getMember(keeper).claimable - before, paid, "claimable increase");
        assertEq(c.getPublicSummary().expenses, paid, "expenses");
    }

    function test_T_FEE_3_completingCallPaidEvenIfSmall() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        vm.startPrank(keeper);
        c.settle(40);
        c.settle(9);
        uint256 before = c.getPublicSummary().expenses;
        assertEq(c.getCircleState().cursor, 49);
        vm.recordLogs();
        c.settle(1);
        vm.stopPrank();
        uint256 paid = _reimbursedIn(c, vm.getRecordedLogs());
        console.log("completing settle(1) paid", paid);
        assertEq(c.getCircleState().settledEpoch, 1, "completed");
        assertGt(paid, 0, "completing call paid");
        assertEq(c.getPublicSummary().expenses - before, paid);
    }

    function test_T_FEE_3_capHoldsWithManyCalls() public {
        KuberCircle c = _fiftyAtEpoch2(300_000, 100 gwei);
        vm.startPrank(keeper);
        for (uint256 i; i < 5; ++i) {
            c.settle(10);
        }
        vm.stopPrank();
        assertEq(c.getCircleState().settledEpoch, 1);
        assertEq(c.getPublicSummary().expenses, 300_000, "capped for epoch 1");
        assertEq(c.getMember(keeper).claimable, 300_000);
        // The counter resets when the settlement completes: epoch 2 pays up to another 300_000.
        _warpTo(c, 3, false);
        vm.startPrank(keeper);
        for (uint256 i; i < 5; ++i) {
            c.settle(10);
        }
        vm.stopPrank();
        assertEq(c.getPublicSummary().expenses, 600_000, "capped again for epoch 2");
    }

    function test_T_FEE_3_zeroSettingsPayNothing() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        uint256 snap = vm.snapshotState();
        for (uint256 mode; mode < 3; ++mode) {
            vm.revertToState(snap);
            if (mode == 0) vm.txGasPrice(0);
            else if (mode == 1) registry.setGasSettings(0, GAS_CAP, 2e6);
            else registry.setGasSettings(PRICE, GAS_CAP, 0);
            vm.recordLogs();
            vm.prank(keeper);
            c.settle(MAX);
            assertEq(_reimbursedIn(c, vm.getRecordedLogs()), 0, "no event");
            assertEq(c.getCircleState().settledEpoch, 1);
            assertEq(c.getPublicSummary().expenses, 0, "expenses");
            assertEq(c.getMember(keeper).claimable, 0);
        }
    }

    function test_T_FEE_3_capLoweredMidSettlement() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        vm.prank(keeper);
        c.settle(10);
        uint256 paid = c.getPublicSummary().expenses;
        assertGt(paid, 1);
        registry.setGasSettings(PRICE, GAS_CAP, paid - 1);
        vm.recordLogs();
        vm.startPrank(keeper);
        c.settle(10);
        c.settle(MAX);
        vm.stopPrank();
        assertEq(_reimbursedIn(c, vm.getRecordedLogs()), 0, "nothing more this epoch");
        assertEq(c.getCircleState().settledEpoch, 1, "no revert, completed");
        assertEq(c.getPublicSummary().expenses, paid);
    }

    function test_T_FEE_3_expensesLowerV() public {
        (KuberCircle c, address[] memory ms) = _startLoans(10, 7, _alloc(0, 0, 0, 10_000), 5_000);
        ms;
        registry.setGasSettings(PRICE, GAS_CAP, 5e6);
        uint256 snap = vm.snapshotState();
        (int256 pot0, uint256 exp0) = _runToEnd(c, 0);
        vm.revertToState(snap);
        (int256 pot1, uint256 exp1) = _runToEnd(c, 25 gwei);
        console.log("expenses at 25 gwei", exp1);
        assertEq(exp0, 0);
        assertGt(exp1, 0);
        // The finalizing call's own reimbursement is a liability before the pot is computed.
        assertEq(uint256(pot0 - pot1), exp1, "pot drops by exactly expenses");
    }

    function test_T_FEE_3_paidWithinSpentGas() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        // The first reimbursed call of epoch 1 (measured: paid 545_110 of a 641_529 bound, 85%).
        (uint256 paid, uint256 bound) = _measured(c, 10);
        console.log("epoch 1 first: paid", paid, "bound", bound);
        assertGt(paid, 0);
        assertLe(paid, bound, "within spent gas");
        assertGe(paid * 100, bound * 40, "at least 40% for the first call");
        // A later call of the same epoch (measured: 493_810 of 538_929, 91.6%; floor 91.6 - 5 points).
        (paid, bound) = _measured(c, 10);
        console.log("epoch 1 later: paid", paid, "bound", bound);
        assertLe(paid, bound, "within spent gas");
        assertGe(paid * 1_000, bound * 866, "later call floor");
        // The first reimbursed call of epoch 2, whose collect writes are non-zero to non-zero (cheaper measured span).
        vm.prank(keeper);
        c.settle(MAX);
        _warpTo(c, 3, false);
        (paid, bound) = _measured(c, 10);
        console.log("epoch 2 first: paid", paid, "bound", bound);
        assertLe(paid, bound, "within spent gas");
        assertGe(paid * 100, bound * 40, "at least 40% for the first call");
    }

    function test_T_FEE_3_reimbursementNeverBlocksSettle() public {
        KuberCircle c = _fiftyAtEpoch2(2e6, 25 gwei);
        RevertingKeeper k = new RevertingKeeper();
        k.settle(c, MAX);
        assertEq(c.getCircleState().settledEpoch, 1, "settled");
        uint256 credited = c.getMember(address(k)).claimable;
        assertGt(credited, 0, "credited, not sent");
        assertEq(c.getPublicSummary().expenses, credited);
    }

    // --- helpers ---

    /// @dev 50 members (maxMembers 50, allocation 40/30/20/10) at the start of epoch 2, epoch 1 unsettled; gas settings
    /// ($30, 100 gwei, `cap`) and tx.gasprice `gp` set after the setup.
    function _fiftyAtEpoch2(uint256 cap, uint256 gp) internal returns (KuberCircle c) {
        (c,) = _startLoans(50, 7, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _warpTo(c, 2, false);
        registry.setGasSettings(PRICE, GAS_CAP, cap);
        vm.txGasPrice(gp);
    }

    /// @dev Settles epochs 1..7 one call each at gas price `gp`, 100e6 minted before the last; frozen pot, expenses.
    function _runToEnd(KuberCircle c, uint256 gp) internal returns (int256 pot, uint256 expenses) {
        vm.txGasPrice(gp);
        for (uint256 e = 2; e <= 8; ++e) {
            _warpTo(c, e, false);
            if (e == 8) usdc.mint(address(c), 100e6);
            vm.prank(keeper);
            c.settle(MAX);
        }
        KuberCircle.PublicSummary memory p = c.getPublicSummary();
        return (p.yieldPot, p.expenses);
    }

    /// @dev One keeper settle(n) measured from outside; returns what it was paid and the bound
    /// (outside gas + 21_000) × min(gasprice, cap) × price / 1e18.
    function _measured(KuberCircle c, uint256 n) internal returns (uint256 paid, uint256 bound) {
        uint256 before = c.getMember(keeper).claimable;
        vm.prank(keeper);
        uint256 g = gasleft();
        c.settle(n);
        uint256 outside = g - gasleft();
        paid = c.getMember(keeper).claimable - before;
        uint256 gp = tx.gasprice < GAS_CAP ? tx.gasprice : GAS_CAP;
        bound = (outside + 21_000) * gp * PRICE / 1e18;
    }

    function _reimbursedIn(KuberCircle c, Vm.Log[] memory logs) internal pure returns (uint256 sum) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(c) && logs[i].topics[0] == REIMBURSED) {
                sum += abi.decode(logs[i].data, (uint256));
            }
        }
    }
}
