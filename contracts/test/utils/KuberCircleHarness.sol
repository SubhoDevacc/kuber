// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Member, MemberStatus} from "../../src/lib/CircleTypes.sol";
import {Invest} from "../../src/lib/Invest.sol";
import {Membership} from "../../src/lib/Membership.sol";
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

    function sActive() external view returns (uint256) {
        return $.sActive;
    }

    function sSaver() external view returns (uint256) {
        return $.sSaver;
    }

    function creditClaimable(address member, uint256 amount) external {
        Weights.creditClaimable($, member, amount);
    }

    /// @dev Backer rewards owed to `member` and a savers' pot, both liabilities in V and terms of the cash floor.
    function addLiabilities(address member, uint256 rewards, uint256 pot) external {
        $.members[member].rewards += uint128(rewards);
        $.totalRewardsOwed += rewards;
        $.saverPot += pot;
    }

    /// @dev Forces a member state the public API cannot reach while a request is pending (07 D-10c guard tests).
    function forceMember(address member, MemberStatus status, uint256 savings, uint256 pledgedOut) external {
        Member storage m = $.members[member];
        m.status = status;
        m.savings = uint128(savings);
        m.pledgedOut = uint128(pledgedOut);
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

    function loanCount() external view returns (uint256) {
        return $.loanCount;
    }

    /// @notice Settlement step 2's membership half alone, so a test can read V − sTotal right before and after the
    /// exits without the rebalance's vault rounding.
    function applyMembership(uint256 k, uint256 kickId) external {
        Membership.applyStep($, k, kickId);
    }

    /// @dev Stands in for M6's requestLeave so T-LN-1 can cover R-M now.
    function setLeavePending(address member, bool pending) external {
        $.members[member].leavePending = pending;
    }
}
