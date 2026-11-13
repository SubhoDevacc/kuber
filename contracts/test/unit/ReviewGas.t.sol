// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircle} from "../../src/KuberCircle.sol";
import {LoanStatus, MemberStatus, RuleParams} from "../../src/lib/CircleTypes.sol";
import {BackingTestBase} from "../utils/BackingTestBase.sol";

/// @dev M5 review CR-02: requests expiring in the completing settle call only release a paused backer's pledge
/// (DECISIONS R-N3 exception), so the unsplittable call stays bounded. Before the fix the 10 x 10 shape cost 15.0M.
contract ReviewGasTest is BackingTestBase {
    KuberCircle internal c;
    address[] internal ppl;

    // ppl[0] creator (plain saver); S = ppl[1..nS]; B = next 20 (backers of every S loan); R = next nR (requesters).
    function _build(uint256 nS, uint256 nR) internal returns (uint256 gasCompleting) {
        uint256 n = 1 + nS + 20 + nR;
        ppl = _newMembers(n);
        for (uint256 i; i < n; ++i) {
            usdc.mint(ppl[i], 90_000e6);
        }
        RuleParams memory r = _rules();
        r.alloc = _alloc(4_000, 3_000, 2_000, 1_000);
        r.perLoanMaxBps = 10_000;
        c = _startPeople(ppl, 12, r);
        _activate(c);
        for (uint256 e = 2; e <= 3; ++e) {
            _settleAt(c, e);
        }
        _payAllBut(c, ppl, address(0)); // epoch 3: everyone has 300e6
        uint256 b0 = 1 + nS;
        uint256 r0 = b0 + 20;
        // R: oversized requests that are never eligible and expire at settle(9) (9 + 1 + 3 > 12).
        for (uint256 j; j < nR; ++j) {
            vm.prank(ppl[r0 + j]);
            c.requestLoan(1_000_000e6, 3, 0, 0);
        }
        // S: pledge 10e6 on every R request (vouch for the first 10 S, agree for the rest), then borrow.
        for (uint256 i; i < nS; ++i) {
            address s = ppl[1 + i];
            for (uint256 j; j < nR; ++j) {
                if (i < 10) _vouchAs(c, s, j + 1, 10e6);
                else _agreeAs(c, s, j + 1, 10e6);
            }
        }
        for (uint256 i; i < nS; ++i) {
            address s = ppl[1 + i];
            vm.prank(s);
            uint256 id = c.requestLoan(300e6, 3, 0, 0);
            // own = (300 - 10 nR) * 0.9; the rest is pledged by the 20 B members as 10 vouchers + 10 agreers.
            uint256 need = c.getLoan(id).backedNeed;
            uint256 v = need * 3 / 4 / 10;
            uint256 a = (need - v * 10) / 10;
            for (uint256 t; t < 10; ++t) {
                _vouchAs(c, ppl[b0 + t], id, v);
            }
            for (uint256 t; t < 9; ++t) {
                _agreeAs(c, ppl[b0 + 10 + t], id, a);
            }
            _agreeAs(c, ppl[b0 + 19], id, need - v * 10 - a * 9);
        }
        _settleAt(c, 4); // settle(3) funds every S loan
        for (uint256 i; i < nS; ++i) {
            vm.startPrank(ppl[1 + i]);
            c.claim();
            usdc.approve(address(c), 0);
            vm.stopPrank();
        }
        for (uint256 e = 5; e <= 9; ++e) {
            _settleAt(c, e); // settle(7) defaults every S with debt to its 20 backers
        }
        uint256[] memory debts = new uint256[](nS);
        for (uint256 i; i < nS; ++i) {
            assertEq(uint256(c.getMember(ppl[1 + i]).status), uint256(MemberStatus.Suspended), "S paused");
            debts[i] = c.debtOf(ppl[1 + i]);
        }
        // settle(9): collect everyone but the last member, then measure the completing call (expiry).
        _warpTo(c, 10, false);
        c.settle(n - 1);
        uint256 g = gasleft();
        c.settle(1);
        gasCompleting = g - gasleft();
        emit log_named_uint("gas of the completing settle(9)", gasCompleting);
        for (uint256 j; j < nR; ++j) {
            assertEq(uint256(c.getLoan(j + 1).status), uint256(LoanStatus.Expired), "expired");
        }
        // The pledges are released; the paused backers' debts are left for applyFreed (R-N3 exception).
        for (uint256 i; i < nS; ++i) {
            assertEq(c.getMember(ppl[1 + i]).pledgedOut, 0, "pledge released");
            assertEq(c.debtOf(ppl[1 + i]), debts[i], "no repayment inside the completing call");
        }
    }

    function test_gas_completing_S10_R10() public {
        assertLt(_build(10, 10), 8_000_000, "completing call under 8M (G1)");
        // Afterwards anyone applies each paused member's freed 100e6 (10 pledges of 10e6) to its backers' losses:
        // own (300e6 - 100e6) * 0.9 = 180e6, so the default took fromB 200e6 and 90e6 + 10e6 from the backers.
        uint256 maxGas;
        for (uint256 i; i < 10; ++i) {
            address s = ppl[1 + i];
            uint256 d = c.debtOf(s);
            uint256 g = gasleft();
            c.applyFreed(s);
            g -= gasleft();
            if (g > maxGas) maxGas = g;
            assertEq(d - c.debtOf(s), 100e6, "losses repaid");
            assertEq(c.getMember(s).savings, 0);
        }
        emit log_named_uint("max gas of one applyFreed (20 backers)", maxGas);
    }

    function test_gas_completing_S15_R14() public {
        assertLt(_build(15, 14), 8_000_000, "completing call under 8M (G1)");
    }
}
