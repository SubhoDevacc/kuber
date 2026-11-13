// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
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

    /// @dev Stands in for an investment loss until M3's vaults exist.
    function drain(address to, uint256 amount) external {
        $.token.safeTransfer(to, amount);
    }
}
