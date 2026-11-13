// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CircleStorage, Member, MemberStatus} from "./CircleTypes.sol";

/// @notice DECISIONS N-1 ledger. The only writer of savings, weight, lastAccrual, sTotal / sActive / sSaver,
/// wActive / wSaver and their `*Last`, claimable, and reservedClaims. A member leaves an accumulator exactly
/// when its predicate (Active; Active and never borrowed) stops holding, so Σ member weights == accumulator.
library Weights {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Weight of an entity (weight, savings, last) at epoch `e`; only meaningful for `e >= last`.
    function accrued(uint256 weight, uint256 savings, uint256 last, uint256 e) internal pure returns (uint256) {
        return e > last ? weight + savings * (e - last) : weight;
    }

    /// @notice Applies a savings change `delta` with effective epoch `effectiveEpoch` (>= 1).
    function changeSavings(CircleStorage.Layout storage $, address member, int256 delta, uint256 effectiveEpoch)
        internal
    {
        Member storage m = $.members[member];
        // Savings added after the cycle count for no epoch; `last` never exceeds totalEpochs.
        uint256 x = Math.min(effectiveEpoch, uint256($.fixedParams.totalEpochs) + 1);
        // A reinstated member's weight before reinstatedEpoch was discarded (R-N2): a change dated earlier (by a
        // settle(k) still running at the reinstatement) counts from reinstatedEpoch, not back-filled below weight 0.
        // Only a back-fill can be dated that early, as lastAccrual >= reinstatedEpoch - 1 from the reinstatement on.
        if (x <= m.lastAccrual) x = Math.max(x, m.reinstatedEpoch);
        (uint256 w, uint256 s, uint256 last) = _step(m.weight, m.savings, m.lastAccrual, delta, x);
        m.weight = w;
        m.savings = s.toUint128();
        m.lastAccrual = last.toUint8();
        $.sTotal = ($.sTotal.toInt256() + delta).toUint256();
        if (m.status != MemberStatus.Active) return;
        // One field per statement: a tuple assignment into the packed Layout fields is "Stack too deep".
        (w, s, last) = _step($.wActive, $.sActive, $.wActiveLast, delta, x);
        $.wActive = w;
        $.sActive = s;
        $.wActiveLast = last.toUint8();
        if (m.everBorrowed) return;
        (w, s, last) = _step($.wSaver, $.sSaver, $.wSaverLast, delta, x);
        $.wSaver = w;
        $.sSaver = s;
        $.wSaverLast = last.toUint8();
    }

    function weightOf(CircleStorage.Layout storage $, address member, uint256 e) internal view returns (uint256) {
        Member storage m = $.members[member];
        return accrued(m.weight, m.savings, m.lastAccrual, e);
    }

    function accrueGlobal(CircleStorage.Layout storage $, uint256 e) internal {
        if (e > $.wActiveLast) {
            $.wActive += $.sActive * (e - $.wActiveLast);
            $.wActiveLast = e.toUint8();
        }
        _accrueSaver($, e);
    }

    /// @notice Takes an Active member out of W_active (and W_saver if never borrowed); a no-op otherwise.
    /// sTotal keeps the member's savings (R-N).
    function removeFromActive(CircleStorage.Layout storage $, address member, uint256 e, MemberStatus newStatus)
        internal
    {
        Member storage m = $.members[member];
        if (m.status != MemberStatus.Active) return;
        // Every `last` is <= totalEpochs, so upTo is too, and it is >= every last it must line up.
        uint256 upTo = Math.max(
            Math.min(e, $.fixedParams.totalEpochs), Math.max(m.lastAccrual, Math.max($.wActiveLast, $.wSaverLast))
        );
        _accrueMember(m, upTo);
        accrueGlobal($, upTo);
        $.wActive -= m.weight;
        $.sActive -= m.savings;
        if (!m.everBorrowed) {
            $.wSaver -= m.weight;
            $.sSaver -= m.savings;
        }
        m.status = newStatus;
    }

    /// @notice Reinstates a Suspended member into W_active with weight 0 from epoch `e` (D-14; never W_saver).
    function addToActive(CircleStorage.Layout storage $, address member, uint256 e) internal {
        uint256 x = Math.min(e, uint256($.fixedParams.totalEpochs) + 1);
        Member storage m = $.members[member];
        m.status = MemberStatus.Active;
        m.weight = 0;
        m.lastAccrual = (x - 1).toUint8();
        (uint256 w, uint256 s, uint256 last) = _step($.wActive, $.sActive, $.wActiveLast, int256(uint256(m.savings)), x);
        $.wActive = w;
        $.sActive = s;
        $.wActiveLast = last.toUint8();
    }

    /// @notice Marks the member borrowed and, if it was an Active saver, takes it out of W_saver.
    function removeFromSaver(CircleStorage.Layout storage $, address member, uint256 e) internal {
        Member storage m = $.members[member];
        bool counted = m.status == MemberStatus.Active && !m.everBorrowed;
        m.everBorrowed = true;
        if (!counted) return;
        uint256 upTo = Math.max(Math.min(e, $.fixedParams.totalEpochs), Math.max(m.lastAccrual, $.wSaverLast));
        _accrueMember(m, upTo);
        _accrueSaver($, upTo);
        $.wSaver -= m.weight;
        $.sSaver -= m.savings;
    }

    function creditClaimable(CircleStorage.Layout storage $, address member, uint256 amount) internal {
        $.members[member].claimable += amount.toUint128();
        $.reservedClaims += amount;
    }

    function takeClaimable(CircleStorage.Layout storage $, address member) internal returns (uint256 amount) {
        amount = $.members[member].claimable;
        $.members[member].claimable = 0;
        $.reservedClaims -= amount;
    }

    /// @notice Cancels `amount` of the member's claimable (the waterfall's step 0).
    function debitClaimable(CircleStorage.Layout storage $, address member, uint256 amount) internal {
        $.members[member].claimable -= amount.toUint128();
        $.reservedClaims -= amount;
    }

    /// @notice Lowers only savings and sTotal, for a member already out of both accumulators (R-N).
    function debitSuspended(CircleStorage.Layout storage $, address member, uint256 amount) internal {
        $.members[member].savings -= amount.toUint128();
        $.sTotal -= amount;
    }

    // N-1 for one change (delta, x): accrue up to x - 1, or backfill delta over the epochs already accrued.
    function _step(uint256 weight, uint256 savings, uint256 last, int256 delta, uint256 x)
        private
        pure
        returns (uint256, uint256, uint256)
    {
        if (x - 1 > last) {
            weight += savings * (x - 1 - last);
            last = x - 1;
        } else if (x - 1 < last) {
            weight = (weight.toInt256() + delta * (last - (x - 1)).toInt256()).toUint256();
        }
        return (weight, (savings.toInt256() + delta).toUint256(), last);
    }

    function _accrueSaver(CircleStorage.Layout storage $, uint256 e) private {
        if (e > $.wSaverLast) {
            $.wSaver += $.sSaver * (e - $.wSaverLast);
            $.wSaverLast = e.toUint8();
        }
    }

    function _accrueMember(Member storage m, uint256 e) private {
        if (e > m.lastAccrual) {
            m.weight += uint256(m.savings) * (e - m.lastAccrual);
            m.lastAccrual = e.toUint8();
        }
    }
}
