// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, FixedParams, RuleParams} from "../../src/lib/CircleTypes.sol";
import {CircleTestBase} from "./CircleTestBase.sol";

/// @dev Shared helpers for the Phase 4 loan tests (Loans, Queue, Repay).
abstract contract LoanTestBase is CircleTestBase {
    function _alloc(uint16 loanBps, uint16 aaveBps, uint16 lpBps, uint16 cashBps) internal pure returns (Alloc memory) {
        return Alloc({loan: loanBps, aave: aaveBps, lp: lpBps, cash: cashBps});
    }

    /// @dev n members (ms[0] creates), custom totalEpochs, allocation, and per-loan max; each member approves 5_000e6
    /// (contributions plus installments); warped to startTime and activated.
    function _startLoans(uint256 n, uint8 totalEpochs, Alloc memory al, uint16 perLoanMaxBps)
        internal
        returns (KuberCircle c, address[] memory ms)
    {
        ms = _newMembers(n);
        FixedParams memory f = _fixed();
        f.totalEpochs = totalEpochs;
        f.maxMembers = 50;
        RuleParams memory r = _rules();
        r.alloc = al;
        r.perLoanMaxBps = perLoanMaxBps;
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("loans", f, r, _tail(ms)));
        _join(c, _tail(ms));
        for (uint256 i; i < n; ++i) {
            vm.prank(ms[i]);
            usdc.approve(address(c), 5_000e6);
        }
        vm.warp(f.startTime);
        c.activate();
    }

    /// @dev Settles epoch e − 1 at the start of epoch e.
    function _settleAt(KuberCircle c, uint256 e) internal {
        _warpTo(c, e, false);
        c.settle(type(uint256).max);
    }

    function _payNowAs(KuberCircle c, address who) internal {
        vm.prank(who);
        c.payNow();
    }

    /// @dev offeredRateBps 0.
    function _request(KuberCircle c, address who, uint256 amount, uint256 repayEpochs, uint256 extraBps)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return c.requestLoan(amount, repayEpochs, 0, extraBps);
    }

    /// @dev Epochs 1 and 2 auto-debited, then each payer pre-pays epoch 3 in OPEN (paidCount 3, savings 300e6).
    function _openEpoch3(KuberCircle c, address[] memory payers) internal {
        _settleAt(c, 2);
        _settleAt(c, 3);
        for (uint256 i; i < payers.length; ++i) {
            _payNowAs(c, payers[i]);
        }
    }
}
