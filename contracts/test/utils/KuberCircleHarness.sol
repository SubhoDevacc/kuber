// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Invest} from "../../src/lib/Invest.sol";
import {Weights} from "../../src/lib/Weights.sol";

/// @dev Test-only: probes for the action/vote guards and exact weight reads at any epoch (D-15).
contract KuberCircleHarness is KuberCircle {
    using SafeERC20 for IERC20;

    function probeAction() external view {
        _checkAction();
    }

    function probeVote() external view {
        _checkVote();
    }

    function weightAt(address member, uint256 e) external view returns (uint256) {
        return Weights.weightOf($, member, e);
    }

    function wActiveAt(uint256 e) external view returns (uint256) {
        return Weights.accrued($.wActive, $.sActive, $.wActiveLast, e);
    }

    function wSaverAt(uint256 e) external view returns (uint256) {
        return Weights.accrued($.wSaver, $.sSaver, $.wSaverLast, e);
    }

    function creditClaimable(address member, uint256 amount) external {
        Weights.creditClaimable($, member, amount);
    }

    /// @dev Stands in for a loss anywhere in the pot; pulls from the vaults first like a payout.
    function drain(address to, uint256 amount) external {
        Invest.ensureCash($, amount);
        $.token.safeTransfer(to, amount);
    }

    function rebalanceNow() external returns (uint256 vaultValueBefore, uint256 pulledSinceRebalance) {
        return Invest.rebalance($);
    }

    function vaultValueAfterRebalance() external view returns (uint256) {
        return $.vaultValueAfterRebalance;
    }

    function vaultPulledSinceRebalance() external view returns (uint256) {
        return $.vaultPulledSinceRebalance;
    }
}
