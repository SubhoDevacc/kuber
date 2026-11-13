// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {IKuberCircleErrors, MemberStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev M5 review WR-01: a paused member cannot unback (it would free a pledge without repaying their backers).
contract ReviewUnbackTest is BackingTestBase {
    function test_pausedMemberCannotUnback() public {
        address[] memory p = _newMembers(7);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 10_000;
        KuberCircle c = _startPeople(p, 12, r);
        _activate(c);
        _settleAt(c, 2);
        _settleAt(c, 3);
        _payAllBut(c, p, address(0));
        // p6 requests an oversized loan that stays pending; S = p1 pledges 50e6 on it, then borrows (backed by p2).
        vm.prank(p[6]);
        c.requestLoan(1_000_000e6, 3, 0, 0);
        _vouchAs(c, p[1], 1, 50e6);
        vm.prank(p[1]);
        c.requestLoan(300e6, 3, 0, 0); // own = 250e6 * 0.9 = 225e6, backed 75e6
        _vouchAs(c, p[2], 2, 75e6);
        _settleAt(c, 4);
        vm.startPrank(p[1]);
        c.claim();
        usdc.approve(address(c), 0);
        vm.stopPrank();
        for (uint256 e = 5; e <= 8; ++e) {
            _settleAt(c, e);
        }
        assertEq(uint256(c.getMember(p[1]).status), uint256(MemberStatus.Suspended));
        uint256 debt0 = c.debtOf(p[1]);
        assertGt(debt0, 0);
        // Epoch 8, OPEN, nothing pending: the paused member's unback reverts.
        vm.prank(p[1]);
        vm.expectRevert(IKuberCircleErrors.NotMember.selector);
        c.unback(1);
        assertEq(c.getMember(p[1]).pledgedOut, 50e6, "pledge still held");
        assertEq(c.getLoan(1).vouchers.length, 1, "still a voucher");
        assertEq(c.debtOf(p[1]), debt0, "debt unchanged");
        // An Active backer can still unback.
        _vouchAs(c, p[3], 1, 10e6);
        vm.prank(p[3]);
        c.unback(1);
        assertEq(c.getMember(p[3]).pledgedOut, 0);
    }
}
