// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KuberPracticeLog} from "../../src/KuberPracticeLog.sol";

contract PracticeLogTest is Test {
    event PracticeAction(
        address indexed user, address indexed practiceCircle, string step, string action, bytes32 practiceTx
    );

    KuberPracticeLog internal plog;
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal circle = makeAddr("practiceCircle");

    function setUp() public {
        plog = new KuberPracticeLog(owner);
    }

    function _entries(uint256 n, uint256 m) internal pure returns (string[] memory actions, bytes32[] memory txs) {
        actions = new string[](n);
        txs = new bytes32[](m);
        for (uint256 i; i < n; ++i) {
            actions[i] = string.concat("action-", vm.toString(i));
        }
        for (uint256 i; i < m; ++i) {
            txs[i] = keccak256(abi.encode(i));
        }
    }

    function test_constructor_setsOwner() public view {
        assertEq(plog.owner(), owner);
    }

    function test_record_ownerEmitsOneEventPerEntry() public {
        string[] memory actions = new string[](2);
        actions[0] = "join";
        actions[1] = "pay";
        bytes32[] memory txs = new bytes32[](2);
        txs[0] = bytes32(uint256(0xa1));
        txs[1] = bytes32(uint256(0xb2));

        vm.expectEmit(true, true, false, true, address(plog));
        emit PracticeAction(alice, circle, "step-1", "join", txs[0]);
        vm.expectEmit(true, true, false, true, address(plog));
        emit PracticeAction(alice, circle, "step-1", "pay", txs[1]);
        vm.prank(owner);
        plog.record(alice, circle, "step-1", actions, txs);
    }

    function test_record_maxEntriesOk() public {
        (string[] memory actions, bytes32[] memory txs) = _entries(20, 20);
        vm.recordLogs();
        vm.prank(owner);
        plog.record(alice, circle, "step", actions, txs);
        assertEq(vm.getRecordedLogs().length, 20);
    }

    function test_record_emptyOk() public {
        (string[] memory actions, bytes32[] memory txs) = _entries(0, 0);
        vm.recordLogs();
        vm.prank(owner);
        plog.record(alice, circle, "step", actions, txs);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_record_revertsForNonOwner() public {
        (string[] memory actions, bytes32[] memory txs) = _entries(1, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        plog.record(alice, circle, "step", actions, txs);
    }

    function test_record_revertsOnLengthMismatch() public {
        (string[] memory actions, bytes32[] memory txs) = _entries(2, 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberPracticeLog.LengthMismatch.selector, 2, 1));
        plog.record(alice, circle, "step", actions, txs);
    }

    function test_record_revertsOverTwentyEntries() public {
        (string[] memory actions, bytes32[] memory txs) = _entries(21, 21);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KuberPracticeLog.TooManyEntries.selector, 21));
        plog.record(alice, circle, "step", actions, txs);
    }
}
