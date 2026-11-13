// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    BPS,
    Backing,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Lane,
    Loan,
    LoanStatus,
    MAX_EXTRA,
    MAX_OFFERED_RATE,
    Member,
    MemberStatus
} from "./CircleTypes.sol";
import {Invest} from "./Invest.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library (delegatecalled by KuberCircle and Settle): loan requests, the pending list, and the
/// funding step of settlement (SPEC §2.5 Loans, Funding).
library Queue {
    using SafeCast for uint256;

    uint8 private constant WAITING = 0;
    uint8 private constant ELIGIBLE = 1;
    uint8 private constant DONE = 2;

    // One funding pass: the pending ids (oldest first), each one's state, the epoch being settled, and the
    // capacity still unused.
    struct Pass {
        uint32[] ids;
        uint8[] st;
        uint256 k;
        uint256 cap;
    }

    /// @notice A request in epoch `e`; the caller already passed the action-class check (R-F). Locks the R-E terms.
    function request(
        CircleStorage.Layout storage $,
        uint256 amount,
        uint256 repayEpochs,
        uint256 offeredRateBps,
        uint256 extraBps,
        uint256 e
    ) external returns (uint256 id) {
        Member storage m = $.members[msg.sender];
        if (m.status != MemberStatus.Active) revert IKuberCircleErrors.NotMember();
        if (m.paidCount < $.fixedParams.minSaveEpochs) revert IKuberCircleErrors.NotEnoughSaved();
        if (m.activeLoanId != 0) revert IKuberCircleErrors.HasActiveLoan();
        if (m.pendingRequestId != 0) revert IKuberCircleErrors.HasPendingRequest();
        if (e <= m.cooldownUntil) revert IKuberCircleErrors.InCooldown();
        if (repayEpochs == 0 || repayEpochs > $.fixedParams.maxRepayEpochs) {
            revert IKuberCircleErrors.InvalidRepayEpochs();
        }
        if (e + 1 + repayEpochs > $.fixedParams.totalEpochs) revert IKuberCircleErrors.RepayPastEnd();
        if (offeredRateBps > MAX_OFFERED_RATE) revert IKuberCircleErrors.InvalidOfferedRate();
        if (extraBps > MAX_EXTRA) revert IKuberCircleErrors.InvalidExtra();
        if (amount == 0) revert IKuberCircleErrors.ZeroAmount();
        if (m.leavePending) revert IKuberCircleErrors.LeavePending();
        if ($.registry.hasOpenDebt(msg.sender)) revert IKuberCircleErrors.HasOpenDebt();
        id = ++$.loanCount;
        uint256 own = Math.min(amount, uint256(m.savings - m.pledgedOut) * $.rules.ownLtvBps / BPS);
        Loan storage loan = $.loans[id];
        loan.borrower = msg.sender;
        loan.offeredRateBps = offeredRateBps.toUint16();
        loan.extraBps = extraBps.toUint16();
        loan.ownLtvBps = $.rules.ownLtvBps;
        loan.ownRateBps = $.rules.ownRateBps;
        loan.penaltyBps = $.rules.penaltyBps;
        loan.installFineBps = $.rules.installFineBps;
        loan.amount = amount.toUint128();
        loan.ownPart = own.toUint128();
        loan.backedNeed = (amount - own).toUint128();
        loan.repayEpochs = repayEpochs.toUint8();
        loan.requestedEpoch = e.toUint8();
        loan.status = LoanStatus.Pending;
        m.pendingRequestId = id.toUint32();
        $.pendingIds.push(id.toUint32());
        emit IKuberCircleEvents.LoanRequested(id, msg.sender, amount, repayEpochs, offeredRateBps, extraBps);
    }

    /// @notice Borrower only, Pending only: the extra can only go up, to at most MAX_EXTRA (D-04).
    function raiseExtra(CircleStorage.Layout storage $, uint256 id, uint256 newExtraBps) external {
        Loan storage loan = _own($, id);
        if (newExtraBps <= loan.extraBps || newExtraBps > MAX_EXTRA) revert IKuberCircleErrors.InvalidExtra();
        loan.extraBps = newExtraBps.toUint16();
    }

    /// @notice Borrower only, Pending only: removes the request from the list without reordering the rest (D-04).
    function cancel(CircleStorage.Layout storage $, uint256 id) external {
        Loan storage loan = _own($, id);
        loan.status = LoanStatus.Cancelled;
        $.members[msg.sender].pendingRequestId = 0;
        uint32[] storage ids = $.pendingIds;
        uint256 n = ids.length;
        uint256 i = 0;
        // A Pending id is always in the list (pushed at request, removed when it leaves Pending).
        while (ids[i] != id) {
            ++i;
        }
        for (; i + 1 < n; ++i) {
            ids[i] = ids[i + 1];
        }
        ids.pop();
        releasePledges($, id);
    }

    /// @notice Settlement step 3 for epoch `k`; `clock` is the current epoch. Never reverts because of a request.
    function fund(CircleStorage.Layout storage $, uint256 k, uint256 clock) external {
        // D-05: catching up, so no loan starts with installments already overdue; skipped passes add no age.
        if (clock > k + 1) return;
        uint32[] memory ids = $.pendingIds;
        uint256 n = ids.length;
        if (n == 0) return;
        Pass memory p = Pass({ids: ids, st: new uint8[](n), k: k, cap: 0});
        _expire($, p);
        uint256 maxLoan = _capacity($, p);
        for (uint256 i; i < n; ++i) {
            if (p.st[i] == WAITING && _eligible($, $.loans[ids[i]], maxLoan)) p.st[i] = ELIGIBLE;
        }
        // D-06 (d): aged requests, oldest first, from total capacity, no extra.
        for (uint256 i; i < n; ++i) {
            if (p.st[i] == ELIGIBLE && $.loans[ids[i]].age >= 2) _try($, p, i, p.cap, Lane.Aged);
        }
        // (e) fast lane: R-D's budget is a share of the capacity left after aged funding.
        (uint256[] memory fast, uint256 nFast) = _fastOrder($, p);
        uint256 budget = p.cap * $.rules.fastLaneBps / BPS;
        for (uint256 j; j < nFast; ++j) {
            budget -= _try($, p, 255 - (fast[j] & 0xff), budget, Lane.Fast);
        }
        // (f) line, oldest first: all capacity still unused, so the fast lane's leftover flows here.
        for (uint256 i; i < n; ++i) {
            if (p.st[i] == ELIGIBLE && $.loans[ids[i]].extraBps == 0) _try($, p, i, p.cap, Lane.Line);
        }
        // (g) spill back: the unfunded extra payers again, in fast-lane order; they pay the extra.
        for (uint256 j; j < nFast; ++j) {
            _try($, p, 255 - (fast[j] & 0xff), p.cap, Lane.Fast);
        }
        _ageAndCompact($, p);
    }

    /// @notice M5 fills this (05-CONTEXT D-04): release every backer's pledge. M4 loans have no backers.
    // solhint-disable-next-line no-empty-blocks
    function releasePledges(CircleStorage.Layout storage, uint256) internal pure {}

    function _own(CircleStorage.Layout storage $, uint256 id) private view returns (Loan storage loan) {
        loan = $.loans[id];
        if (loan.borrower != msg.sender) revert IKuberCircleErrors.NotBorrower();
        if (loan.status != LoanStatus.Pending) revert IKuberCircleErrors.NotPending();
    }

    // D-06 (a): a request whose repay window would pass the end expires and leaves the list.
    function _expire(CircleStorage.Layout storage $, Pass memory p) private {
        uint256 last = $.fixedParams.totalEpochs;
        for (uint256 i; i < p.ids.length; ++i) {
            Loan storage loan = $.loans[p.ids[i]];
            if (p.k + 1 + loan.repayEpochs <= last) continue;
            loan.status = LoanStatus.Expired;
            $.members[loan.borrower].pendingRequestId = 0;
            p.st[i] = DONE;
            releasePledges($, p.ids[i]);
            emit IKuberCircleEvents.RequestExpired(p.ids[i]);
        }
    }

    // D-06 (b): Phase 3 owns both formulas; allocation and perLoanMax are read live (R-E).
    function _capacity(CircleStorage.Layout storage $, Pass memory p) private view returns (uint256 maxLoan) {
        // Only V is needed here; the cash and vault split is for the rebalance.
        // slither-disable-next-line unused-return
        (int256 v,,,) = Invest.valuation($);
        (p.cap, maxLoan) = Invest.loanCapacity($, v);
    }

    // D-06 (c): Active borrower, within the per-loan max and the locked LTV, and fully pledged.
    function _eligible(CircleStorage.Layout storage $, Loan storage loan, uint256 maxLoan) private view returns (bool) {
        Member storage m = $.members[loan.borrower];
        if (m.status != MemberStatus.Active || loan.amount > maxLoan) return false;
        if (loan.ownPart > uint256(m.savings - m.pledgedOut) * loan.ownLtvBps / BPS) return false;
        return _pledged(loan.vouchers) + _pledged(loan.agreers) == loan.backedNeed;
    }

    function _pledged(Backing[] storage b) private view returns (uint256 sum) {
        for (uint256 i; i < b.length; ++i) {
            sum += b[i].amount;
        }
    }

    // Eligible extra payers as keys `extra << 8 | (255 − index)` (index < 50), sorted descending: highest extra
    // first, then oldest.
    function _fastOrder(CircleStorage.Layout storage $, Pass memory p)
        private
        view
        returns (uint256[] memory keys, uint256 c)
    {
        uint256 n = p.ids.length;
        keys = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (p.st[i] != ELIGIBLE) continue;
            uint256 extra = $.loans[p.ids[i]].extraBps;
            if (extra == 0) continue;
            uint256 key = extra << 8 | (255 - i);
            uint256 j = c++;
            for (; j > 0 && keys[j - 1] < key; --j) {
                keys[j] = keys[j - 1];
            }
            keys[j] = key;
        }
    }

    // Funds request `i` if it is eligible and fits `room` (always ≤ p.cap); otherwise nothing about it changes,
    // so it keeps its place. Returns the amount funded.
    function _try(CircleStorage.Layout storage $, Pass memory p, uint256 i, uint256 room, Lane lane)
        private
        returns (uint256 amount)
    {
        if (p.st[i] != ELIGIBLE) return 0;
        amount = $.loans[p.ids[i]].amount;
        if (amount > room) return 0;
        p.st[i] = DONE;
        p.cap -= amount;
        _fundOne($, p.ids[i], lane, p.k);
    }

    // D-08, R-C: interest fixed now (each term floors once), proceeds to claimable, the borrower out of W_saver.
    function _fundOne(CircleStorage.Layout storage $, uint256 id, Lane lane, uint256 k) private {
        Loan storage loan = $.loans[id];
        uint256 amount = loan.amount;
        uint256 interest = uint256(loan.ownPart) * loan.ownRateBps / BPS;
        if (lane == Lane.Fast) interest += amount * loan.extraBps / BPS;
        loan.saverInterest = interest.toUint128();
        uint256 rate = loan.offeredRateBps;
        Backing[] storage b = loan.vouchers;
        for (uint256 i; i < b.length; ++i) {
            b[i].interest = (b[i].amount * rate / BPS).toUint128();
        }
        b = loan.agreers;
        for (uint256 i; i < b.length; ++i) {
            b[i].interest = (b[i].amount * rate / (2 * BPS)).toUint128();
        }
        loan.lane = lane;
        loan.status = LoanStatus.Funded;
        loan.fundedEpoch = k.toUint8();
        loan.unclaimed = amount.toUint128();
        address borrower = loan.borrower;
        Member storage m = $.members[borrower];
        m.pendingRequestId = 0;
        m.activeLoanId = id.toUint32();
        $.outstandingPrincipal += amount;
        Weights.creditClaimable($, borrower, amount);
        // Idempotent: the first loan sets everBorrowed and removes the weight accrued to k (N-1).
        Weights.removeFromSaver($, borrower, k);
        emit IKuberCircleEvents.LoanFunded(id, lane);
        // Trusted registry fixed at init; cannot revert for an authorized circle.
        $.registry.recordLoan(borrower);
    }

    // D-06 (h), R-D: every request still pending ages by one; the others leave the list, order kept (no sort).
    function _ageAndCompact(CircleStorage.Layout storage $, Pass memory p) private {
        uint256 n = p.ids.length;
        uint256 kept = 0;
        for (uint256 i; i < n; ++i) {
            if (p.st[i] == DONE) continue;
            $.loans[p.ids[i]].age += 1;
            p.ids[kept++] = p.ids[i];
        }
        if (kept == n) return;
        uint32[] storage list = $.pendingIds;
        for (uint256 i; i < kept; ++i) {
            list[i] = p.ids[i];
        }
        for (uint256 i = kept; i < n; ++i) {
            list.pop();
        }
    }
}
