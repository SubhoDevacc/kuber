// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Alloc, BPS, CircleStorage, IKuberCircleErrors, IKuberCircleEvents} from "./CircleTypes.sol";

/// @notice Linked library (delegatecalled by KuberCircle, Settle, and ShareOut): values the pot, rebalances the two
/// vaults toward the allocation under the cash floor, and pulls vault money for payouts (SPEC §2.5 Investing).
library Invest {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice V = cash + vault values + outstanding principal − liabilities (D-03, D-04). The only place V is
    /// computed; it is signed, and callers floor it at 0 where they need a uint.
    function valuation(CircleStorage.Layout storage $)
        internal
        view
        returns (int256 v, uint256 cash, uint256 aaveValue, uint256 lpValue)
    {
        cash = $.token.balanceOf(address(this));
        aaveValue = _value(IERC4626($.aaveVault));
        lpValue = _value(IERC4626($.lpVault));
        v = (cash + aaveValue + lpValue + $.outstandingPrincipal).toInt256()
            - ($.reservedClaims + $.totalRewardsOwed + $.saverPot).toInt256();
    }

    /// @notice The idle loan reserve (loan bucket − outstanding principal, at least 0) and the per-loan cap (D-05).
    function loanCapacity(CircleStorage.Layout storage $, int256 v)
        internal
        view
        returns (uint256 capacity, uint256 perLoanMax)
    {
        uint256 value = v > 0 ? uint256(v) : 0;
        uint256 bucket = value * $.rules.alloc.loan / BPS;
        uint256 principal = $.outstandingPrincipal;
        capacity = bucket > principal ? bucket - principal : 0;
        perLoanMax = value * $.rules.alloc.loan * $.rules.perLoanMaxBps / (BPS * BPS);
    }

    /// @notice Vault targets and the cash floor (D-05, D-06). No division by V: V = 0 gives zero targets and a
    /// floor equal to the liabilities.
    function targets(CircleStorage.Layout storage $, int256 v)
        internal
        view
        returns (uint256 aaveTarget, uint256 lpTarget, uint256 cashFloor)
    {
        uint256 value = v > 0 ? uint256(v) : 0;
        Alloc memory a = $.rules.alloc;
        aaveTarget = value * a.aave / BPS;
        lpTarget = value * a.lp / BPS;
        (uint256 idleLoanReserve,) = loanCapacity($, v);
        cashFloor = idleLoanReserve + value * a.cash / BPS + $.reservedClaims + $.totalRewardsOwed + $.saverPot;
    }

    /// @notice Settlement step 4 (D-06, D-07, A-1): withdraws from any vault above target, then deposits only cash
    /// above the floor (Aave first); below the floor it pulls the shortfall from Aave, then LP. Returns the vault
    /// value before anything moved and the tokens `ensureCash` pulled since the previous rebalance (R-K).
    function rebalance(CircleStorage.Layout storage $)
        external
        returns (uint256 vaultValueBefore, uint256 pulledSinceRebalance)
    {
        (int256 v, uint256 cash, uint256 aaveVal, uint256 lpVal) = valuation($);
        vaultValueBefore = aaveVal + lpVal;
        (uint256 aT, uint256 lT, uint256 floor) = targets($, v);
        IERC4626 aave = IERC4626($.aaveVault);
        IERC4626 lp = IERC4626($.lpVault);
        // `cash` tracks the real balance exactly: a withdraw sends exactly `got`, `_deposit` returns what it sent.
        if (aaveVal > aT) cash += _pull(aave, aaveVal - aT);
        if (lpVal > lT) cash += _pull(lp, lpVal - lT);
        if (cash >= floor) {
            uint256 d = _deposit($, aave, Math.min(aT > aaveVal ? aT - aaveVal : 0, cash - floor));
            _deposit($, lp, Math.min(lT > lpVal ? lT - lpVal : 0, cash - floor - d));
        } else {
            // Only when loans exceed the loan bucket or V = 0.
            _pull(lp, (floor - cash) - _pull(aave, floor - cash));
        }
        aaveVal = _value(aave);
        lpVal = _value(lp);
        $.vaultValueAfterRebalance = aaveVal + lpVal;
        pulledSinceRebalance = $.vaultPulledSinceRebalance;
        $.vaultPulledSinceRebalance = 0;
        emit IKuberCircleEvents.Rebalanced(aaveVal, lpVal, $.token.balanceOf(address(this)));
    }

    /// @notice Before any payout (D-10, A-1): tops cash up to `amount` from Aave, then LP, and records the pull.
    function ensureCash(CircleStorage.Layout storage $, uint256 amount) external {
        uint256 cash = $.token.balanceOf(address(this));
        if (cash >= amount) return;
        uint256 short = amount - cash;
        short -= _pull(IERC4626($.aaveVault), short);
        _pull(IERC4626($.lpVault), short);
        uint256 nowCash = $.token.balanceOf(address(this));
        // Reaching this means a bug: loss sharing keeps every payout within the assets.
        if (nowCash < amount) revert IKuberCircleErrors.InsufficientLiquidity();
        $.vaultPulledSinceRebalance += nowCash - cash;
    }

    /// @notice Finalize (D-11): redeems every share of both vaults before the yield pot is computed.
    function redeemAll(CircleStorage.Layout storage $) external {
        _redeemAll(IERC4626($.aaveVault));
        _redeemAll(IERC4626($.lpVault));
    }

    // What the circle would actually get for its shares, rounded down (D-03).
    function _value(IERC4626 vault) private view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this)));
    }

    function _pull(IERC4626 vault, uint256 want) private returns (uint256 got) {
        got = Math.min(want, vault.maxWithdraw(address(this)));
        // Shares and assets are read back with balanceOf/previewRedeem.
        // slither-disable-next-line unused-return
        if (got != 0) vault.withdraw(got, address(this), address(this));
    }

    // A deposit that would mint 0 shares is a donation (inflation attack on a near-empty vault), so the cash stays.
    function _deposit(CircleStorage.Layout storage $, IERC4626 vault, uint256 amount)
        private
        returns (uint256 deposited)
    {
        if (amount != 0 && vault.previewDeposit(amount) != 0) {
            $.token.forceApprove(address(vault), amount);
            // Shares and assets are read back with balanceOf/previewRedeem.
            // slither-disable-next-line unused-return
            vault.deposit(amount, address(this));
            deposited = amount;
        }
    }

    function _redeemAll(IERC4626 vault) private {
        uint256 shares = vault.balanceOf(address(this));
        // Shares and assets are read back with balanceOf/previewRedeem.
        // slither-disable-next-line unused-return
        if (shares != 0) vault.redeem(shares, address(this), address(this));
    }
}
