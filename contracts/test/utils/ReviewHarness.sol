// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {KuberCircleHarness} from "./KuberCircleHarness.sol";

/// @dev Getters for the running totals, for the review fuzz (test/fuzz/ReviewFuzz.t.sol).
contract ReviewHarness is KuberCircleHarness {
    function totals()
        external
        view
        returns (uint256 sTotal, uint256 sActive, uint256 sSaver, uint256 rewardsOwed, uint256 saverPot)
    {
        return ($.sTotal, $.sActive, $.sSaver, $.totalRewardsOwed, $.saverPot);
    }

    function lasts() external view returns (uint256 wActiveLast, uint256 wSaverLast) {
        return ($.wActiveLast, $.wSaverLast);
    }
}
