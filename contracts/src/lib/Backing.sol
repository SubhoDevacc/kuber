// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    Backing as Pledge,
    BackingTier,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    MAX_AGREERS,
    MAX_VOUCHERS,
    Member,
    MemberStatus
} from "./CircleTypes.sol";
import {Waterfall} from "./Waterfall.sol";

/// @notice Linked library (delegatecalled by KuberCircle): vouch, agree, unback, and pledge release (SPEC §2.5
/// Backing; DECISIONS R-D, R-M, R-O).
library Backing {
    using SafeCast for uint256;

    uint256 private constant NONE = type(uint256).max;

    /// @notice vouch / agree (05-CONTEXT D-02): pledges `amt` of the caller's free savings to pending request `id`.
    /// The caller already passed the action-class check (R-F).
    function back(CircleStorage.Layout storage $, uint256 id, uint256 amt, BackingTier tier) external {
        Loan storage loan = $.loans[id];
        Member storage m = $.members[msg.sender];
        if (loan.status != LoanStatus.Pending) revert IKuberCircleErrors.NotPending();
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (m.activeLoanId != 0) revert IKuberCircleErrors.HasActiveLoan();
        // Also rejects the borrower, whose pending request is this one, so no separate borrower error is needed.
        if (m.pendingRequestId != 0) revert IKuberCircleErrors.HasPendingRequest();
        if (m.leavePending) revert IKuberCircleErrors.LeavePending();
        if ($.registry.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        if (amt == 0) revert IKuberCircleErrors.ZeroAmount();
        if (amt > m.savings - m.pledgedOut) revert IKuberCircleErrors.ExceedsFreeSavings();
        if (_total(loan.vouchers) + _total(loan.agreers) + amt > loan.backedNeed) {
            revert IKuberCircleErrors.OverPledged();
        }
        bool agree = tier == BackingTier.Agree;
        if (_find(agree ? loan.vouchers : loan.agreers, msg.sender) != NONE) revert IKuberCircleErrors.OtherTier();
        Pledge[] storage bs = agree ? loan.agreers : loan.vouchers;
        uint256 i = _find(bs, msg.sender);
        uint256 total = i == NONE ? amt : bs[i].amount + amt;
        // R-D: the cap is on the address's cumulative agree pledge on this loan.
        if (agree && total > $.fixedParams.contribution) revert IKuberCircleErrors.AgreeCapExceeded();
        if (i == NONE) {
            if (bs.length == (agree ? MAX_AGREERS : MAX_VOUCHERS)) revert IKuberCircleErrors.TooManyBackers();
            // Not push(Pledge({...})): Slither 0.11.6 cannot build IR for that form and would skip this function.
            Pledge storage e = bs.push();
            e.backer = msg.sender;
            e.amount = total.toUint128();
        } else {
            bs[i].amount = total.toUint128();
        }
        m.pledgedOut += amt.toUint128();
        emit IKuberCircleEvents.Backed(id, msg.sender, tier, amt);
    }

    /// @notice unback (05-CONTEXT D-03): withdraws the caller's whole pledge on pending request `id`; the other
    /// entries keep their order.
    function unback(CircleStorage.Layout storage $, uint256 id) external {
        Loan storage loan = $.loans[id];
        if (loan.status != LoanStatus.Pending) revert IKuberCircleErrors.NotPending();
        Pledge[] storage bs = loan.vouchers;
        uint256 i = _find(bs, msg.sender);
        if (i == NONE) {
            bs = loan.agreers;
            i = _find(bs, msg.sender);
            if (i == NONE) revert IKuberCircleErrors.NotBacker();
        }
        uint256 amt = bs[i].amount;
        uint256 n = bs.length;
        for (; i + 1 < n; ++i) {
            bs[i] = bs[i + 1];
        }
        bs.pop();
        $.members[msg.sender].pledgedOut -= amt.toUint128();
        emit IKuberCircleEvents.Unbacked(id, msg.sender, amt);
    }

    /// @notice Called once per loan at its terminal status change (cancel, expiry, full repayment): every backer's
    /// pledge is freed; the entries stay as history (05-CONTEXT D-04). `e` is the clock epoch, or k inside settle(k);
    /// a paused backer's freed pledge pays their own backers at once (R-N3).
    function release(CircleStorage.Layout storage $, Loan storage loan, uint256 e, bool inSettlement) internal {
        _release($, loan.vouchers, e, inSettlement);
        _release($, loan.agreers, e, inSettlement);
    }

    function _release(CircleStorage.Layout storage $, Pledge[] storage bs, uint256 e, bool inSettlement) private {
        for (uint256 i; i < bs.length; ++i) {
            address backer = bs[i].backer;
            uint256 amt = bs[i].amount;
            Member storage m = $.members[backer];
            m.pledgedOut -= amt.toUint128();
            if (m.status == MemberStatus.Suspended) Waterfall.applyFreed($, backer, amt, e, inSettlement);
        }
    }

    function _total(Pledge[] storage bs) private view returns (uint256 sum) {
        for (uint256 i; i < bs.length; ++i) {
            sum += bs[i].amount;
        }
    }

    function _find(Pledge[] storage bs, address who) private view returns (uint256) {
        for (uint256 i; i < bs.length; ++i) {
            if (bs[i].backer == who) return i;
        }
        return NONE;
    }
}
