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
    Loan,
    LoanStatus,
    Member
} from "./CircleTypes.sol";
import {Queue} from "./Queue.sol";

/// @notice Linked library (delegatecalled by KuberCircle and Settle): installments, fines, arrears, early payoff
/// (SPEC §2.5 Repayment, Payments; DECISIONS R-C, R-H). Every function applies its effects and returns the amount;
/// the caller makes the one token transfer last.
library Loans {
    using SafeCast for uint256;

    /// @notice payNow (maxN 1) and payArrears (maxN n): the oldest unpaid installments due in `clock` or earlier,
    /// each with its fines.
    function payDue(CircleStorage.Layout storage $, address borrower, uint256 maxN, uint256 clock)
        external
        returns (uint256 total, uint256 count)
    {
        uint256 id = $.members[borrower].activeLoanId;
        if (id == 0) return (0, 0);
        Loan storage loan = $.loans[id];
        uint256 n = loan.repayEpochs;
        uint256 f = loan.fundedEpoch;
        for (uint256 i = loan.installmentsPaid; i < n && count < maxN && f + 2 + i <= clock; ++i) {
            total += _pay($, id, i, clock);
            ++count;
        }
    }

    /// @notice Every remaining installment, due or not; only installments a settlement found unpaid carry fines;
    /// interest is unchanged (D-12).
    function repayAll(CircleStorage.Layout storage $, address borrower, uint256 clock)
        external
        returns (uint256 total)
    {
        uint256 id = $.members[borrower].activeLoanId;
        if (id == 0) revert IKuberCircleErrors.NoActiveLoan();
        uint256 n = $.loans[id].repayEpochs;
        for (uint256 i = $.loans[id].installmentsPaid; i < n; ++i) {
            total += _pay($, id, i, clock);
        }
    }

    /// @notice Collect pass of settle(k) for a borrower, after the contribution (D-13): auto-debit installments due
    /// by k, oldest first, each with its fines all-or-nothing within `avail`; record what is still unpaid; never
    /// reverts on a short budget. Returns what the caller pulls.
    function collect(CircleStorage.Layout storage $, address borrower, uint256 k, uint256 avail)
        external
        returns (uint256 pulled)
    {
        uint256 id = $.members[borrower].activeLoanId;
        Loan storage loan = $.loans[id];
        uint256 n = loan.repayEpochs;
        uint256 f = loan.fundedEpoch;
        uint256 i = loan.installmentsPaid;
        // lastCollectEpoch is still k − 1 here, so the fines match a hand payment made just before this pass.
        for (; i < n && f + 2 + i <= k; ++i) {
            uint256 a = installment(loan, i);
            if (pulled + a + _fineOf(loan, a, f + 2 + i) > avail) break;
            pulled += _pay($, id, i, k);
        }
        uint256 bps = loan.installFineBps;
        for (uint256 j = i; j < n && f + 2 + j <= k; ++j) {
            uint256 a = installment(loan, j);
            // settle(k) runs once per k and is the first to see an installment due in k: recorded as missed (R-H).
            if (f + 2 + j == k) {
                loan.missedCount += 1;
                emit IKuberCircleEvents.InstallmentMissed(id, j);
                $.registry.recordLateInstallment(borrower);
            }
            // This settlement's one fine; the amount paid later floors once over all of them (04-ADDENDUM A-3 c).
            emit IKuberCircleEvents.FineCharged(id, borrower, a * bps / BPS);
        }
        loan.lastCollectEpoch = k.toUint8();
        _pauseCheck($, borrower, id, k);
    }

    /// @notice Installment i: the sum of each component's part (R-C), so the installments sum to amount + interest.
    function installment(Loan storage loan, uint256 i) internal view returns (uint256 a) {
        uint256 n = loan.repayEpochs;
        a = _part(loan.amount, n, i) + _part(loan.saverInterest, n, i);
        Backing[] storage bs = loan.vouchers;
        for (uint256 j; j < bs.length; ++j) {
            a += _part(bs[j].interest, n, i);
        }
        bs = loan.agreers;
        for (uint256 j; j < bs.length; ++j) {
            a += _part(bs[j].interest, n, i);
        }
    }

    // One fine per settlement that found installment `a` (due in `due`) unpaid (R-H, 04-ADDENDUM A-1); one floor.
    function _fineOf(Loan storage loan, uint256 a, uint256 due) private view returns (uint256) {
        uint256 found = uint256(loan.lastCollectEpoch) + 1;
        return found > due ? a * loan.installFineBps * (found - due) / BPS : 0;
    }

    // Floor parts; the last installment carries the remainder.
    function _part(uint256 total, uint256 n, uint256 i) private pure returns (uint256) {
        return total / n + (i + 1 == n ? total % n : 0);
    }

    // D-11: installment i paid in epoch `c`; closes the loan at the last one. Returns installment + fine.
    function _pay(CircleStorage.Layout storage $, uint256 id, uint256 i, uint256 c) private returns (uint256) {
        Loan storage loan = $.loans[id];
        uint256 n = loan.repayEpochs;
        uint256 p = _part(loan.amount, n, i);
        uint256 s = _part(loan.saverInterest, n, i);
        $.outstandingPrincipal -= p;
        loan.principalRepaid += p.toUint128();
        $.saverPot += s;
        uint256 a = p + s + _payBackers($, loan.vouchers, n, i) + _payBackers($, loan.agreers, n, i);
        uint256 fine = _fineOf(loan, a, uint256(loan.fundedEpoch) + 2 + i);
        if (fine != 0) _fine($, loan, fine);
        loan.installmentsPaid = (i + 1).toUint8();
        emit IKuberCircleEvents.InstallmentPaid(id, i, a + fine);
        if (i + 1 == n) _close($, id, c);
        return a + fine;
    }

    function _payBackers(CircleStorage.Layout storage $, Backing[] storage bs, uint256 n, uint256 i)
        private
        returns (uint256 sum)
    {
        for (uint256 j; j < bs.length; ++j) {
            Backing storage b = bs[j];
            uint256 x = _part(b.interest, n, i);
            b.interestPaid += x.toUint128();
            $.members[b.backer].rewards += x.toUint128();
            sum += x;
        }
        $.totalRewardsOwed += sum;
    }

    // D-11: to the backers pro-rata by pledge (Σ pledges == backedNeed since funding), the last absorbing rounding;
    // to the savers' pot when there are none.
    function _fine(CircleStorage.Layout storage $, Loan storage loan, uint256 fine) private {
        uint256 nv = loan.vouchers.length;
        uint256 nb = nv + loan.agreers.length;
        if (nb == 0) {
            $.saverPot += fine;
            return;
        }
        uint256 need = loan.backedNeed;
        uint256 left = fine;
        for (uint256 j; j < nb; ++j) {
            Backing storage b = j < nv ? loan.vouchers[j] : loan.agreers[j - nv];
            uint256 x = j + 1 == nb ? left : fine * b.amount / need;
            left -= x;
            $.members[b.backer].rewards += x.toUint128();
        }
        $.totalRewardsOwed += fine;
    }

    // D-14: `c` is the payment's clock epoch, or k in the collect pass.
    function _close(CircleStorage.Layout storage $, uint256 id, uint256 c) private {
        Loan storage loan = $.loans[id];
        address borrower = loan.borrower;
        Member storage m = $.members[borrower];
        bool onTime = loan.missedCount == 0;
        loan.status = LoanStatus.Repaid;
        // A repaid loan cannot default, so M5's step 0 has nothing to cancel; unclaimed proceeds stay claimable.
        loan.unclaimed = 0;
        m.activeLoanId = 0;
        // Past the cycle no request is possible, so the cap only keeps it in uint8.
        m.cooldownUntil = (Math.min(c, $.fixedParams.totalEpochs) + $.fixedParams.cooldownEpochs).toUint8();
        Queue.releasePledges($, id);
        emit IKuberCircleEvents.LoanRepaid(id, onTime);
        // Trusted registry fixed at init.
        $.registry.recordRepaid(borrower, onTime);
    }

    /// @notice M5 fills this (05-CONTEXT D-06): pause trigger and waterfall. M4 only fines and records misses.
    // solhint-disable-next-line no-empty-blocks
    function _pauseCheck(CircleStorage.Layout storage, address, uint256, uint256) private pure {}
}
