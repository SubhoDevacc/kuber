// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CircleStatus, CircleStorage, IKuberCircleEvents, Member, MemberStatus} from "./CircleTypes.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library (delegatecalled by KuberCircle and Settle): freezes the share-out numbers at the last
/// settlement and computes each member's payout lazily from them (SPEC §2.5 Share-out, DECISIONS R-A).
library ShareOut {
    using SafeCast for uint256;

    /// @notice Runs once, inside the settlement of epoch totalEpochs (D-19).
    function finalize(CircleStorage.Layout storage $) external {
        // M3 redeems the vaults and M7 takes fees here, before the freeze.
        Weights.accrueGlobal($, $.fixedParams.totalEpochs);
        uint256 sTotal = $.sTotal;
        int256 pot = $.token.balanceOf(address(this)).toInt256()
            - ($.reservedClaims + $.totalRewardsOwed + $.saverPot).toInt256() - sTotal.toInt256();
        uint256 saverPot = $.saverPot;
        uint256 wSaver = $.wSaver;
        // SPEC share-out step 5: with no savers left, their pot joins the yield pot.
        if (wSaver == 0) {
            pot += saverPot.toInt256();
            saverPot = 0;
        }
        uint256 wActive = $.wActive;
        $.finalYieldPot = pot;
        $.finalWActive = wActive;
        $.finalWSaver = wSaver;
        $.finalSaverPot = saverPot;
        $.finalSTotal = sTotal;
        $.status = CircleStatus.Ended;
        emit IKuberCircleEvents.Finalized(pot, wActive, wSaver, saverPot, sTotal);
        uint256 n = $.memberList.length;
        for (uint256 i; i < n; ++i) {
            address member = $.memberList[i];
            // Suspended members at finalize are M5's (recordLeave there).
            if ($.members[member].status != MemberStatus.Active) continue;
            $.registry.recordComplete(member);
        }
    }

    /// @notice Effects only; the caller checks Ended, Active, and not withdrawn (D-20). Gains floor and losses
    /// ceil, so the sum of payouts never exceeds the pot and the dust stays in the circle.
    function payout(CircleStorage.Layout storage $, address member) external returns (uint256 amount) {
        Member storage m = $.members[member];
        uint256 w = Weights.weightOf($, member, $.fixedParams.totalEpochs);
        uint256 s = m.savings;
        int256 pot = $.finalYieldPot;
        if (pot > 0) {
            uint256 wActive = $.finalWActive;
            amount = s + (wActive == 0 ? 0 : Math.mulDiv(uint256(pot), w, wActive));
        } else if (pot < 0) {
            // R-A: a loss is shared by savings, not weight.
            if (s > 0) {
                uint256 loss = Math.mulDiv(uint256(-pot), s, $.finalSTotal, Math.Rounding.Ceil);
                amount = loss >= s ? 0 : s - loss;
            }
        } else {
            amount = s;
        }
        uint256 wSaver = $.finalWSaver;
        if (!m.everBorrowed && wSaver > 0) amount += Math.mulDiv($.finalSaverPot, w, wSaver);
        uint256 rewards = m.rewards;
        if (rewards > 0) {
            m.rewards = 0;
            $.totalRewardsOwed -= rewards;
            amount += rewards;
        }
        amount += Weights.takeClaimable($, member);
        m.withdrawn = true;
    }

    /// @notice Cross-circle lien on a payout to a person (DECISIONS R-O); returns what goes to the person.
    function lien(CircleStorage.Layout storage, address, uint256 amount) internal pure returns (uint256) {
        // M5 fills this: repay the person's open debt in other circles first.
        return amount;
    }
}
