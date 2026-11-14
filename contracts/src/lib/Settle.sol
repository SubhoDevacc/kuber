// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    CircleStatus,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Member,
    MemberStatus
} from "./CircleTypes.sol";
import {Governance} from "./Governance.sol";
import {Invest} from "./Invest.sol";
import {KuberRegistry} from "../KuberRegistry.sol";
import {Loans} from "./Loans.sol";
import {Membership} from "./Membership.sol";
import {Queue} from "./Queue.sol";
import {ShareOut} from "./ShareOut.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library (delegatecalled by KuberCircle): batched settlement of epoch `settledEpoch + 1`
/// (SPEC §2.5 Settlement steps). The collect pass walks `memberList` from `cursor`; the other steps run once.
library Settle {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Gas a reimbursed call spends outside the measured span (07 D-05): the 21,000 intrinsic gas, calldata,
    /// the KuberCircle.settle dispatch and nonReentrant guard, the cold DELEGATECALL into this library (2,600), and
    /// the reimbursement step after its gasleft() read (registry reads and the storage writes).
    uint256 internal constant OVERHEAD = 30_000;
    /// @notice A call that does not complete the settlement is reimbursed only from this many list entries.
    uint256 internal constant MIN_REIMBURSED_BATCH = 10;

    /// @notice Collects at most `maxMembers` members of the next unsettled epoch; finishes it when the cursor
    /// reaches the end. `clock` is the circle's current epoch. D-06 order: apply, fund, rebalance, reimburse, then
    /// finalize, so the finalizing call's reimbursement is a liability before the yield pot and its own gas is not
    /// reimbursed.
    function run(CircleStorage.Layout storage $, uint256 maxMembers, uint256 clock) external {
        uint256 g0 = gasleft();
        (uint256 k, uint256 processed, bool done) = _advance($, maxMembers, clock);
        if (done || processed >= MIN_REIMBURSED_BATCH) _reimburse($, g0);
        if (!done) return;
        $.epochReimbursed = 0;
        $.settledEpoch = k.toUint8();
        emit IKuberCircleEvents.EpochSettled(k);
        // D-16: the last settlement finalizes; status Ended then blocks any further run (NotActive).
        if (k == $.fixedParams.totalEpochs) ShareOut.finalize($);
    }

    // Steps 1-4 for epoch k: the collect batch, then (once the cursor wraps) apply, fund, and rebalance. `processed`
    // counts the list entries walked, skipped non-Active ones included (they cost real gas; the cap bounds the total).
    function _advance(CircleStorage.Layout storage $, uint256 maxMembers, uint256 clock)
        private
        returns (uint256 k, uint256 processed, bool done)
    {
        if ($.status != CircleStatus.Active) revert IKuberCircleErrors.NotActive();
        if (maxMembers == 0) revert IKuberCircleErrors.ZeroBatch();
        k = uint256($.settledEpoch) + 1;
        if (clock <= k) revert IKuberCircleErrors.EpochNotEnded();
        uint256 n = $.memberList.length;
        uint256 i = $.cursor;
        // `cursor + maxMembers` would overflow for maxMembers = type(uint256).max.
        uint256 end = maxMembers >= n - i ? n : i + maxMembers;
        processed = end - i;
        for (; i < end; ++i) {
            _collect($, $.memberList[i], k);
        }
        if (end < n) {
            $.cursor = end.toUint16();
            return (k, processed, false);
        }
        $.cursor = 0;
        // R-K: the period since the previous rebalance belongs to the manager in place before this apply step.
        address mgr = $.manager;
        // Step 2 (D-06): rules, allocation, and manager, then the leaves and the kick, before funding (T-INV-3).
        Membership.applyStep($, k, Governance.tally($));
        Queue.fund($, k, clock);
        // Read before rebalance overwrites it.
        uint256 base = $.vaultValueAfterRebalance;
        uint256 vaultNow;
        uint256 pulled;
        if (k < $.fixedParams.totalEpochs) {
            (vaultNow, pulled) = Invest.rebalance($);
        } else {
            // The final settlement has no rebalance (finalize redeems everything), so the vaults are read before
            // finalize. Only the two vault values are needed: R-K measures the vaults, not cash.
            // slither-disable-next-line unused-return
            (,, uint256 aaveVal, uint256 lpVal) = Invest.valuation($);
            vaultNow = aaveVal + lpVal;
            pulled = $.vaultPulledSinceRebalance;
        }
        if (mgr != address(0)) Governance.recordManager($, mgr, base, vaultNow + pulled);
        done = true;
    }

    // D-17, D-13: pull the contribution for k unless pre-paid, then the installments due by k, from one
    // min(balance, allowance) budget and one transfer; a short budget records misses, never a revert.
    function _collect(CircleStorage.Layout storage $, address member, uint256 k) private {
        Member storage m = $.members[member];
        // R-N2: rounds missed while paused are not owed, so a reinstated member is collected from reinstatedEpoch.
        if (m.status != MemberStatus.Active || k < m.reinstatedEpoch) return;
        uint64 bit = uint64(1 << k);
        bool owes = m.paidBitmap & bit == 0;
        if (!owes && m.activeLoanId == 0) return;
        IERC20 token = $.token;
        uint256 avail = Math.min(token.balanceOf(member), token.allowance(member, address(this)));
        uint256 pull = 0;
        if (owes) {
            uint256 c = $.fixedParams.contribution;
            if (avail >= c) {
                m.paidBitmap |= bit;
                m.paidCount += 1;
                Weights.changeSavings($, member, int256(c), k);
                emit IKuberCircleEvents.ContributionPaid(member, k, c);
                pull = c;
                avail -= c;
            } else {
                m.missedBitmap |= bit;
                emit IKuberCircleEvents.ContributionMissed(member, k);
            }
        }
        if (m.activeLoanId != 0) pull += Loans.collect($, member, k, avail);
        // Auto-debit the member authorised with the advance allowance (R-G): an Active listed member, the unpaid
        // contribution for k and installments due by k, never more than min(balance, allowance).
        // slither-disable-next-line arbitrary-send-erc20
        if (pull != 0) token.safeTransferFrom(member, address(this), pull);
    }

    /// @notice 07 D-05: (gasUsed + OVERHEAD) × min(tx.gasprice, gasPriceCap) × avaxPriceUsd6 / 1e18, capped at
    /// maxReimbursePerEpoch per epoch, credited to the caller's claimable (pull) and added to expenses. Units: gas ×
    /// wei/gas = wei of AVAX; × USD6 per AVAX / 1e18 = token units (6 decimals). Overflow bound: 8e6 gas × 1e15 ×
    /// 1e12 < 2^256 (registry bounds). No transfer, so a reverting caller or empty cash cannot block settle; the
    /// claimable liability is what lowers V (V never reads expenses).
    /// What a caller can farm: a call under 10 entries that does not complete gets 0; splitting a settlement into
    /// 10-entry calls earns one OVERHEAD per call, which only approximates real unmeasured gas; a completing call
    /// always does real work (apply, fund, rebalance); the per-epoch cap bounds everything, including a block producer
    /// paid at a gas price it pays to itself and SSTORE refunds that gasUsed does not net out. A reimbursed call is
    /// paid for less than the gas it spends (a 50-member settle(10): 85% for the first call of epoch 1, 90-92% for
    /// later ones; test/unit/GasReimburse.t.sol), because the intrinsic gas, the dispatch before g0, the cold
    /// registry reads, and the writes here exceed OVERHEAD: the safe direction.
    function _reimburse(CircleStorage.Layout storage $, uint256 g0) private {
        uint256 used = g0 - gasleft();
        // Trusted registry fixed at init; the three reads cannot revert.
        KuberRegistry reg = $.registry;
        uint256 cap = reg.maxReimbursePerEpoch();
        uint256 paid = $.epochReimbursed;
        // Covers cap 0 and a cap lowered below what this epoch already paid.
        if (cap <= paid) return;
        uint256 amt = (used + OVERHEAD) * Math.min(tx.gasprice, reg.gasPriceCap()) * reg.avaxPriceUsd6() / 1e18;
        amt = Math.min(amt, cap - paid);
        if (amt == 0) return;
        $.epochReimbursed = paid + amt;
        $.expenses += amt;
        Weights.creditClaimable($, msg.sender, amt);
        emit IKuberCircleEvents.GasReimbursed(msg.sender, amt);
    }
}
