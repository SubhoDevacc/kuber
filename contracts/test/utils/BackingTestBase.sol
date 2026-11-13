// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {FixedParams, LoanStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {LoanTestBase} from "./LoanTestBase.sol";

/// @dev Shared helpers for the Phase 5 tests (Backing, Default, Debt, Lien, S1).
abstract contract BackingTestBase is LoanTestBase {
    function _vouchAs(KuberCircle c, address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        c.vouch(id, amt);
    }

    function _agreeAs(KuberCircle c, address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        c.agree(id, amt);
    }

    /// @dev Every member except `skip` calls payNow; address(0) skips nobody.
    function _payAllBut(KuberCircle c, address[] memory ms, address skip) internal {
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i] != skip) _payNowAs(c, ms[i]);
        }
    }

    /// @dev people[0] creates (default params with `totalEpochs`, maxMembers 50) and invites the rest, who join in
    /// array order; everyone approves 5_000e6. No warp and no activate, so two circles can start in one block.
    function _startPeople(address[] memory people, uint8 totalEpochs, RuleParams memory r)
        internal
        returns (KuberCircle c)
    {
        FixedParams memory f = _fixed();
        f.totalEpochs = totalEpochs;
        f.maxMembers = 50;
        vm.prank(people[0]);
        c = KuberCircle(factory.createCircle("people", f, r, _tail(people)));
        for (uint256 i = 1; i < people.length; ++i) {
            vm.prank(people[i]);
            c.join();
        }
        for (uint256 i; i < people.length; ++i) {
            vm.prank(people[i]);
            usdc.approve(address(c), 5_000e6);
        }
    }

    function _activate(KuberCircle c) internal {
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
    }

    /// @dev Scenario P (05-02): m3 borrows 350e6 over 3 (own 270e6; m1 vouches 10e6, m2 20e6, m4 agrees 50e6),
    /// funded at settle(3), due 5, 6, 7. Optionally claims in epoch 4; sets allowance 0 in `revokeEpoch`; the others
    /// pay every epoch. Returns right after settle(7).
    function _scenarioP(uint8 totalEpochs, bool claimIt, uint256 revokeEpoch)
        internal
        returns (KuberCircle c, address[] memory m)
    {
        (c, m) = _startLoans(6, totalEpochs, _alloc(4_000, 3_000, 2_000, 1_000), 5_000);
        _openEpoch3(c, m);
        vm.prank(m[3]);
        c.requestLoan(350e6, 3, 800, 0);
        _vouchAs(c, m[1], 1, 10e6);
        _vouchAs(c, m[2], 1, 20e6);
        _agreeAs(c, m[4], 1, 50e6);
        for (uint256 e = 4; e <= 8; ++e) {
            _settleAt(c, e);
            if (e == 4 && claimIt) {
                vm.prank(m[3]);
                c.claim();
            }
            if (e == revokeEpoch) {
                vm.prank(m[3]);
                usdc.approve(address(c), 0);
            }
            if (e < 8) _payAllBut(c, m, m[3]);
        }
    }

    /// @dev S1 (SPEC §4, DECISIONS R-I) through epoch 7's payments; settle(7) is left to the caller. p = A..F; the
    /// member list is A..F, or A, B, C, E, F, D when `dLast`. `prepayFirst`: payers pay epoch e before settle(e − 1).
    function _s1Run(bool prepayFirst, bool dLast) internal returns (KuberCircle c, address[] memory p) {
        registry.setProtocolFeeBps(0);
        registry.setGasSettings(0, 0, 0);
        p = _newMembers(6);
        address[] memory order = new address[](6);
        for (uint256 i; i < 6; ++i) {
            order[i] = p[i];
        }
        if (dLast) (order[3], order[4], order[5]) = (p[4], p[5], p[3]);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        c = _startPeople(order, 7, r);
        _activate(c);
        _payAllBut(c, p, address(0));
        for (uint256 e = 2; e <= 7; ++e) {
            _warpTo(c, e, false);
            address skip = e >= 4 ? p[3] : address(0);
            if (prepayFirst) _payAllBut(c, p, skip);
            c.settle(type(uint256).max);
            if (!prepayFirst) _payAllBut(c, p, skip);
            if (e == 3) {
                vm.prank(p[0]);
                c.requestLoan(350e6, 2, 800, 0);
                vm.prank(p[3]);
                c.requestLoan(350e6, 3, 800, 0);
                _vouchAs(c, p[1], 1, 80e6);
                _vouchAs(c, p[2], 2, 30e6);
                _agreeAs(c, p[4], 2, 50e6);
            } else if (e == 4) {
                vm.prank(p[0]);
                c.claim();
                vm.startPrank(p[3]);
                c.claim();
                usdc.approve(address(c), 0);
                vm.stopPrank();
            } else if (e == 6) {
                // CONTEXT D-20: after epoch 6.
                assertEq(c.getMember(p[1]).rewards, 6_400_000, "B rewards after epoch 6");
                assertEq(c.getPublicSummary().saverPot, 8_100_000, "saverPot after epoch 6");
                assertEq(uint256(c.getLoan(1).status), uint256(LoanStatus.Repaid), "loan 1 repaid");
            }
        }
        _warpTo(c, 8, false);
        usdc.mint(address(c), 60e6);
    }

    /// @dev Two circles sharing p: y (10 epochs, my, p = my[3]) runs scenario P with p as the borrower; x (`xTotal`
    /// epochs, mx = [o0, p, o1, o2, o3]) starts in the same block. Everyone pays every epoch except p in y from epoch 4;
    /// p claims in y in epoch 4 and sets its y-allowance to 0; in epoch `pLoanEpoch` p requests 100e6 over
    /// `pLoanRepay` in x. Returns right after settle(7) of both, at the start of epoch 8: p paused in y, debt 106_749_998.
    function _xy(uint8 xTotal, uint256 pLoanEpoch, uint256 pLoanRepay)
        internal
        returns (KuberCircle x, KuberCircle y, address p, address[] memory my, address[] memory mx)
    {
        my = _newMembers(6);
        p = my[3];
        address[] memory others = _newMembers(4);
        mx = new address[](5);
        (mx[0], mx[1], mx[2], mx[3], mx[4]) = (others[0], p, others[1], others[2], others[3]);
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 5_000;
        x = _startPeople(mx, xTotal, r);
        y = _startPeople(my, 10, r);
        _activate(x);
        _activate(y);
        for (uint256 e = 1; e <= 7; ++e) {
            if (e > 1) {
                _warpTo(y, e, false);
                y.settle(type(uint256).max);
                x.settle(type(uint256).max);
            }
            _payAllBut(x, mx, address(0));
            _payAllBut(y, my, e >= 4 ? p : address(0));
            if (e == 3) {
                vm.prank(p);
                y.requestLoan(350e6, 3, 800, 0);
                _vouchAs(y, my[1], 1, 10e6);
                _vouchAs(y, my[2], 1, 20e6);
                _agreeAs(y, my[4], 1, 50e6);
            } else if (e == 4) {
                vm.startPrank(p);
                y.claim();
                usdc.approve(address(y), 0);
                vm.stopPrank();
            }
            if (e == pLoanEpoch) {
                vm.prank(p);
                x.requestLoan(100e6, pLoanRepay, 0, 0);
            }
        }
        _warpTo(y, 8, false);
        y.settle(type(uint256).max);
        x.settle(type(uint256).max);
    }
}
