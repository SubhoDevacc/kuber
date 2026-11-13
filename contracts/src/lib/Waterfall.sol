// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    BPS,
    Backing as Pledge,
    CircleStatus,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Loan,
    LoanStatus,
    Member,
    MemberStatus
} from "./CircleTypes.sol";
import {KuberCircle} from "../KuberCircle.sol";
import {Governance} from "./Governance.sol";
import {Invest} from "./Invest.sol";
import {Loans} from "./Loans.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library: the default of a paused borrower (SPEC §2.5 Suspension, waterfall, debt; DECISIONS R-H, R-N,
/// R-N2), recovery and R-N3, and the one payout function with the cross-circle lien (D-15, R-O).
library Waterfall {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Steps 0-8 for loan `id` in settle(k); never reverts in a well-formed state (GroupLoss is unreachable).
    function suspend(CircleStorage.Layout storage $, uint256 id, uint256 k) external {
        Loan storage loan = $.loans[id];
        address b = loan.borrower;
        Member storage m = $.members[b];
        (uint256 fromB, uint256 p1, uint256 debt) = _cover($, loan, id, k);
        loan.status = LoanStatus.Defaulted;
        m.activeLoanId = 0;
        m.debtLoanId = id.toUint32();
        $.saverPot += p1;
        if (debt == 0) {
            // R-N2: savings covered everything and no fine or penalty is owed, so the member is not paused. Dated
            // after everything accrued (CR-01): part of the free savings may count only from after k (a catch-up
            // made while settle(k) was pending), so back-filling the drop over k..last could go below weight 0.
            Weights.changeSavings($, b, -SafeCast.toInt256(fromB + p1), Math.max(k, uint256(m.lastAccrual) + 1));
            // The same cooldown as a repaid loan (Loans._close); k <= totalEpochs inside settle(k).
            m.cooldownUntil = (k + $.fixedParams.cooldownEpochs).toUint8();
            return;
        }
        // Removed first: a suspended weight is discarded, so the borrower's own drop needs no N-1 back-fill.
        Weights.removeFromActive($, b, k, MemberStatus.Suspended);
        Weights.debitSuspended($, b, fromB + p1);
        Governance.dropVotes($, b);
        Governance.clearManager($, b);
        // Trusted registry fixed at init; neither call can revert for an authorized circle.
        $.registry.recordSuspension(b, m.sponsor);
        $.registry.addDebt(b);
    }

    /// @notice Repays up to `amt` of `person`'s debt, pulled from msg.sender (the debtor, or the paying circle of a
    /// lien), in the D-13 order; returns what was taken (0 when nothing is owed).
    function repay(CircleStorage.Layout storage $, address person, uint256 amt, uint256 clock)
        external
        returns (uint256 taken)
    {
        taken = Math.min(amt, debtOf($, person));
        if (taken == 0) return 0;
        uint256 toTreasury = _apply($, person, taken, clock, clock, true);
        $.token.safeTransferFrom(msg.sender, address(this), taken);
        if (toTreasury != 0) $.token.safeTransfer($.registry.treasury(), toTreasury);
    }

    /// @notice Every token transfer to a person: `lienable` first repays their debt here, then their debt in other
    /// listed circles (D-15, D-17); `free` (unclaimed loan proceeds, R-O) goes to them untouched.
    function payOut(CircleStorage.Layout storage $, address person, uint256 lienable, uint256 free, uint256 clock)
        external
    {
        uint256 own = Math.min(lienable, debtOf($, person));
        uint256 toTreasury = own == 0 ? 0 : _apply($, person, own, clock, clock, true);
        uint256 left = lienable - own;
        Invest.ensureCash($, left + free + toTreasury);
        IERC20 token = $.token;
        if (toTreasury != 0) token.safeTransfer($.registry.treasury(), toTreasury);
        // Every ledger effect is done; the untrusted calls come last (CEI).
        if (left != 0) left = _lien($, token, person, left);
        token.safeTransfer(person, left + free);
    }

    /// @notice R-N3 for Backing.release: a Suspended member's freed pledge pays their own backers at once.
    function applyFreed(CircleStorage.Layout storage $, address member, uint256 freed, uint256 e, bool inSettlement)
        external
    {
        _freed($, member, freed, e, inSettlement);
    }

    /// @notice KuberCircle.applyFreed (R-N3 exception): a Suspended member's free savings pay their own backers'
    /// losses, then penalty, credited at the clock epoch; a no-op when neither is owed or nothing is free.
    function applyFreeSavings(CircleStorage.Layout storage $, address member, uint256 clock) external {
        if ($.status != CircleStatus.Active) revert IKuberCircleErrors.NotActive();
        Member storage m = $.members[member];
        // Only a Suspended member can owe this circle while it is Active (D-14 reinstates at debt 0).
        if (m.status != MemberStatus.Suspended) revert IKuberCircleErrors.NoDebt();
        _freed($, member, m.savings - m.pledgedOut, clock, false);
    }

    /// @notice What `person` still owes this circle for their latest defaulted loan.
    function debtOf(CircleStorage.Layout storage $, address person) internal view returns (uint256) {
        uint256 id = $.members[person].debtLoanId;
        if (id == 0) return 0;
        Loan storage loan = $.loans[id];
        return _losses(loan.vouchers) + _losses(loan.agreers) + loan.finesOwed + loan.penaltyOwed;
    }

    // Steps 0-7: unclaimed proceeds, borrower, vouchers, agreers, group (asserted 0), penalty, fines, the event.
    // Returns the borrower's savings drop (fromB, p1 to the savers' pot) and the debt.
    function _cover(CircleStorage.Layout storage $, Loan storage loan, uint256 id, uint256 k)
        private
        returns (uint256 fromB, uint256 p1, uint256 debt)
    {
        uint256 o = loan.amount - loan.principalRepaid;
        {
            // Step 0 capped at o: proceeds above the unpaid principal were repaid from the wallet and stay claimable.
            uint256 u = Math.min(loan.unclaimed, o);
            loan.unclaimed = 0;
            if (u != 0) {
                loan.principalRepaid += u.toUint128();
                Weights.debitClaimable($, loan.borrower, u);
                o -= u;
            }
            $.outstandingPrincipal -= o + u;
        }
        Member storage m = $.members[loan.borrower];
        uint256 free = m.savings - m.pledgedOut;
        fromB = Math.min(free, o);
        uint256 fromV = _seize($, loan.vouchers, o - fromB, k);
        uint256 fromA = _seize($, loan.agreers, o - fromB - fromV, k);
        // Group share 0 by construction: free >= ownPart and the pledges sum to backedNeed (05-02 proof).
        if (fromB + fromV + fromA != o) revert IKuberCircleErrors.GroupLoss();
        uint256 penalty = o * loan.penaltyBps / BPS;
        p1 = Math.min(free - fromB, penalty);
        uint256 fines = _fines(loan, k);
        loan.finesOwed = fines.toUint128();
        loan.penaltyOwed = (penalty - p1).toUint128();
        debt = fromV + fromA + fines + penalty - p1;
        emit IKuberCircleEvents.MemberSuspended(id, o, fromB, fromV, fromA, p1, debt);
    }

    // D-08: takes min(want, Σ pledges) pro-rata by pledge with a running remainder, so each share <= its pledge and
    // the last entry gets exactly what is left; every pledge is released after its loss is taken (D-04).
    function _seize(CircleStorage.Layout storage $, Pledge[] storage bs, uint256 want, uint256 k)
        private
        returns (uint256 take)
    {
        uint256 left = _pledged(bs);
        take = Math.min(want, left);
        uint256 rest = take;
        uint256 n = bs.length;
        for (uint256 i; i < n; ++i) {
            Pledge storage e = bs[i];
            uint256 amt = e.amount;
            uint256 share = rest * amt / left;
            rest -= share;
            left -= amt;
            e.loss = share.toUint128();
            address backer = e.backer;
            $.members[backer].pledgedOut -= e.amount;
            if (share != 0) Weights.changeSavings($, backer, -share.toInt256(), k);
            // R-N3: the unseized part of a paused backer's pledge is freed now.
            if (amt > share && $.members[backer].status == MemberStatus.Suspended) {
                _freed($, backer, amt - share, k, true);
            }
        }
    }

    // R-N3: up to the agreer and voucher losses plus penalty still owed (never fines), from the freed savings;
    // inside settle(k) a reinstatement counts from k + 1, so epoch k is never collected from the member.
    function _freed(CircleStorage.Layout storage $, address member, uint256 freed, uint256 e, bool inSettlement)
        private
    {
        Loan storage loan = $.loans[$.members[member].debtLoanId];
        uint256 x = Math.min(freed, _losses(loan.agreers) + _losses(loan.vouchers) + loan.penaltyOwed);
        if (x == 0) return;
        Weights.debitSuspended($, member, x);
        // Releases happen only while Active (before finalize), so nothing goes to the treasury here.
        _apply($, member, x, e, inSettlement ? e + 1 : e, false);
    }

    // D-13, R-N2: x <= debt, applied to agreers' losses, vouchers' losses, fines (if withFines), then penalty. Active
    // backers' savings are credited at epoch e. Returns what goes to the registry treasury (Ended, no backers).
    function _apply(
        CircleStorage.Layout storage $,
        address person,
        uint256 x,
        uint256 e,
        uint256 reinstateFrom,
        bool withFines
    ) private returns (uint256 toTreasury) {
        Loan storage loan = $.loans[$.members[person].debtLoanId];
        bool active = $.status == CircleStatus.Active;
        uint256 left = x - _payLosses($, loan.agreers, x, active, e);
        left -= _payLosses($, loan.vouchers, left, active, e);
        uint256 f = withFines ? Math.min(left, loan.finesOwed) : 0;
        uint256 pen = left - f;
        loan.finesOwed -= f.toUint128();
        loan.penaltyOwed -= pen.toUint128();
        bool backed = loan.vouchers.length + loan.agreers.length != 0;
        if (active) {
            if (backed) _toBackers($, loan, f, true);
            else $.saverPot += f;
            $.saverPot += pen;
        } else if (backed) {
            _toBackers($, loan, f + pen, false);
        } else {
            // D-13: the savers' bonus is already paid out, so what it would get goes to the treasury.
            toTreasury = f + pen;
        }
        _afterRepay($, person, x, reinstateFrom);
    }

    // D-14: at debt 0 the registry debt is cleared and, while Active, the member is reinstated with weight 0.
    function _afterRepay(CircleStorage.Layout storage $, address person, uint256 x, uint256 reinstateFrom) private {
        uint256 remaining = debtOf($, person);
        emit IKuberCircleEvents.DebtRepaid(person, x, remaining);
        if (remaining != 0) return;
        Member storage m = $.members[person];
        if ($.status == CircleStatus.Active && m.status == MemberStatus.Suspended) {
            Weights.addToActive($, person, reinstateFrom);
            m.reinstatedEpoch = Math.min(reinstateFrom, uint256($.fixedParams.totalEpochs) + 1).toUint8();
            // The normal cooldown (Loans._close), counted from the epoch of reinstatement; capped to stay in uint8.
            m.cooldownUntil =
                (Math.min(reinstateFrom, $.fixedParams.totalEpochs) + $.fixedParams.cooldownEpochs).toUint8();
            emit IKuberCircleEvents.MemberReinstated(person);
        }
        // Trusted registry fixed at init; a no-op when absent.
        $.registry.clearDebt(person);
    }

    // R-N2: min(want, Σ loss) pro-rata by remaining loss with a running remainder (each share <= its loss, the last
    // absorbs rounding); an Active backer gets it back in savings at epoch e while the circle is Active.
    function _payLosses(CircleStorage.Layout storage $, Pledge[] storage bs, uint256 want, bool active, uint256 e)
        private
        returns (uint256 paid)
    {
        uint256 left = _losses(bs);
        paid = Math.min(want, left);
        uint256 rest = paid;
        uint256 n = bs.length;
        for (uint256 i; i < n && rest != 0; ++i) {
            Pledge storage b = bs[i];
            uint256 loss = b.loss;
            uint256 share = rest * loss / left;
            rest -= share;
            left -= loss;
            if (share == 0) continue;
            b.loss = (loss - share).toUint128();
            address backer = b.backer;
            if (active && $.members[backer].status == MemberStatus.Active) {
                Weights.changeSavings($, backer, share.toInt256(), e);
            } else {
                Weights.creditClaimable($, backer, share);
            }
        }
    }

    // Pro-rata by pledge (floor), vouchers then agreers, the last entry gets the remainder; to an Active backer's
    // rewards when `rewards`, else to claimable.
    function _toBackers(CircleStorage.Layout storage $, Loan storage loan, uint256 amount, bool rewards) private {
        if (amount == 0) return;
        uint256 need = loan.backedNeed;
        uint256 nv = loan.vouchers.length;
        uint256 n = nv + loan.agreers.length;
        uint256 rest = amount;
        for (uint256 i; i < n; ++i) {
            Pledge storage b = i < nv ? loan.vouchers[i] : loan.agreers[i - nv];
            uint256 share = i + 1 == n ? rest : amount * b.amount / need;
            rest -= share;
            address backer = b.backer;
            if (rewards && $.members[backer].status == MemberStatus.Active) {
                $.members[backer].rewards += share.toUint128();
                $.totalRewardsOwed += share;
            } else {
                Weights.creditClaimable($, backer, share);
            }
        }
    }

    // D-15: approve at most min(left, reported debt) per listed circle and read what was pulled from the allowance,
    // so a reverting, lying, short-pulling, or re-entering circle can neither block the payout nor take more.
    function _lien(CircleStorage.Layout storage $, IERC20 token, address person, uint256 left)
        private
        returns (uint256)
    {
        address[] memory cs = $.registry.debtCircles(person);
        for (uint256 i; i < cs.length && left != 0; ++i) {
            address c = cs[i];
            if (c == address(this)) continue;
            uint256 amt = 0;
            try KuberCircle(c).debtOf(person) returns (uint256 d) {
                amt = Math.min(left, d);
            } catch {
                continue;
            }
            if (amt == 0) continue;
            token.forceApprove(c, amt);
            // A failing circle must not block the payout; what it took is read from the allowance below.
            // solhint-disable-next-line no-empty-blocks
            try KuberCircle(c).receiveLienPayment(person, amt) {} catch {}
            uint256 paid = amt - token.allowance(address(this), c);
            if (paid != amt) token.forceApprove(c, 0);
            if (paid != 0) {
                left -= paid;
                emit IKuberCircleEvents.LienPaid(person, c, paid);
            }
        }
        return left;
    }

    // D-10: each unpaid installment's fines as of the pause, the same formula a payment would use.
    function _fines(Loan storage loan, uint256 k) private view returns (uint256 sum) {
        uint256 n = loan.repayEpochs;
        uint256 f = loan.fundedEpoch;
        for (uint256 j = loan.installmentsPaid; j < n && f + 2 + j <= k; ++j) {
            sum += Loans._fineOf(loan, Loans.installment(loan, j), f + 2 + j);
        }
    }

    function _pledged(Pledge[] storage bs) private view returns (uint256 sum) {
        for (uint256 i; i < bs.length; ++i) {
            sum += bs[i].amount;
        }
    }

    function _losses(Pledge[] storage bs) private view returns (uint256 sum) {
        for (uint256 i; i < bs.length; ++i) {
            sum += bs[i].loss;
        }
    }
}
