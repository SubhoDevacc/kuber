// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    CircleStatus,
    CircleStorage,
    IKuberCircleErrors,
    IKuberCircleEvents,
    Member,
    MemberStatus
} from "./CircleTypes.sol";
import {ShareOut} from "./ShareOut.sol";
import {Weights} from "./Weights.sol";

/// @notice Linked library (delegatecalled by KuberCircle): batched settlement of epoch `settledEpoch + 1`
/// (SPEC §2.5 Settlement steps). The collect pass walks `memberList` from `cursor`; the other steps run once.
library Settle {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Collects at most `maxMembers` members of the next unsettled epoch; finishes it when the cursor
    /// reaches the end. `clock` is the circle's current epoch.
    function run(CircleStorage.Layout storage $, uint256 maxMembers, uint256 clock) external {
        if ($.status != CircleStatus.Active) revert IKuberCircleErrors.NotActive();
        if (maxMembers == 0) revert IKuberCircleErrors.ZeroBatch();
        uint256 k = uint256($.settledEpoch) + 1;
        if (clock <= k) revert IKuberCircleErrors.EpochNotEnded();
        uint256 n = $.memberList.length;
        uint256 i = $.cursor;
        // `cursor + maxMembers` would overflow for maxMembers = type(uint256).max.
        uint256 end = maxMembers >= n - i ? n : i + maxMembers;
        for (; i < end; ++i) {
            _collect($, $.memberList[i], k);
        }
        if (end < n) {
            $.cursor = end.toUint16();
            return;
        }
        $.cursor = 0;
        _apply($);
        _fund($);
        _rebalance($);
        _reimburse($);
        $.settledEpoch = k.toUint8();
        emit IKuberCircleEvents.EpochSettled(k);
        // D-16: the last settlement finalizes; status Ended then blocks any further run (NotActive).
        if (k == $.fixedParams.totalEpochs) ShareOut.finalize($);
    }

    // D-17: pull the contribution for k unless pre-paid; a short balance or allowance records a miss, never a revert.
    function _collect(CircleStorage.Layout storage $, address member, uint256 k) private {
        Member storage m = $.members[member];
        if (m.status != MemberStatus.Active) return;
        uint64 bit = uint64(1 << k);
        if (m.paidBitmap & bit != 0) return;
        uint256 c = $.fixedParams.contribution;
        IERC20 token = $.token;
        if (token.balanceOf(member) >= c && token.allowance(member, address(this)) >= c) {
            m.paidBitmap |= bit;
            m.paidCount += 1;
            Weights.changeSavings($, member, int256(c), k);
            emit IKuberCircleEvents.ContributionPaid(member, k, c);
            // Auto-debit the member authorised with the advance allowance (R-G): an Active listed member, exactly c, unpaid k.
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(member, address(this), c);
        } else {
            m.missedBitmap |= bit;
            emit IKuberCircleEvents.ContributionMissed(member, k);
        }
    }

    // M6 fills this: passed proposals, leaves, kicks, the admitted joiner.
    // solhint-disable-next-line no-empty-blocks
    function _apply(CircleStorage.Layout storage) private pure {}

    // M4 fills this: fund the loan queue (skipped while settlement is behind), expire stale requests.
    // solhint-disable-next-line no-empty-blocks
    function _fund(CircleStorage.Layout storage) private pure {}

    // M3 fills this: rebalance toward the allocation.
    // solhint-disable-next-line no-empty-blocks
    function _rebalance(CircleStorage.Layout storage) private pure {}

    // M7 fills this: reimburse the caller's gas.
    // solhint-disable-next-line no-empty-blocks
    function _reimburse(CircleStorage.Layout storage) private pure {}
}
