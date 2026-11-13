// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CircleStatus, CircleStorage, IKuberCircleEvents, Member, MemberStatus} from "./CircleTypes.sol";
import {Invest} from "./Invest.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library (delegatecalled by KuberCircle and Settle): freezes the share-out numbers at the last
/// settlement and computes each member's payout lazily from them (SPEC §2.5 Share-out, DECISIONS R-A).
library ShareOut {
    using SafeCast for uint256;

    /// @notice Runs once, inside the settlement of epoch totalEpochs (D-19).
    function finalize(CircleStorage.Layout storage $) external {
        Invest.redeemAll($);
        // M7 takes fees here, before the freeze.
        Weights.accrueGlobal($, $.fixedParams.totalEpochs);
        uint256 sTotal = $.sTotal;
        uint256 bal = $.token.balanceOf(address(this));
        uint256 owed = $.reservedClaims + $.totalRewardsOwed;
        // R-U: a loss beyond all savings comes out of the savers' bonus first; a balance below `owed` is outside
        // the model (invariant I5).
        if (bal < owed + $.saverPot) $.saverPot = bal > owed ? bal - owed : 0;
        uint256 saverPot = $.saverPot;
        int256 pot = bal.toInt256() - (owed + saverPot).toInt256() - sTotal.toInt256();
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
            MemberStatus st = $.members[member].status;
            if (st != MemberStatus.Active && st != MemberStatus.Suspended) continue;
            // D-17: a member still paused at the end leaves; `!=` only (Slither's incorrect-equality on `==`).
            if (st != MemberStatus.Active) $.registry.recordLeave(member);
            else $.registry.recordComplete(member);
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
            // R-N: a Suspended member gets no positive yield.
            amount = s + (wActive == 0 || m.status != MemberStatus.Active ? 0 : Math.mulDiv(uint256(pot), w, wActive));
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
}
