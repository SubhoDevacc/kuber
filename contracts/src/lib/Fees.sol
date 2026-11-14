// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {BPS, CircleStorage, IKuberCircleEvents} from "./CircleTypes.sol";
import {Weights} from "./Weights.sol";

/// @notice Internal helpers (inlined, not linked): the protocol and manager fee on a positive yield amount (07 D-01,
/// DECISIONS R-K). Both are pull credits; a treasury contract that cannot call `claim` leaves its fees in
/// reservedClaims.
library Fees {
    /// @notice Protocol fee (registry.protocolFeeBps, read live so the owner can change it up to finalize), then the
    /// manager fee (managerFeeBps, read live per R-E) on what is left, only while a manager is appointed. Both floor,
    /// so neither is paid above its rate and the remainder stays in the pot; at finalize the per-member shares floor
    /// again and that dust stays in the circle.
    function quote(CircleStorage.Layout storage $, uint256 gain)
        internal
        view
        returns (uint256 protocolFee, uint256 managerFee)
    {
        if (gain == 0) return (0, 0);
        protocolFee = gain * $.registry.protocolFeeBps() / BPS;
        if ($.manager != address(0)) managerFee = (gain - protocolFee) * $.rules.managerFeeBps / BPS;
    }

    /// @notice The gain after both fees.
    function net(CircleStorage.Layout storage $, uint256 gain) internal view returns (uint256) {
        (uint256 protocolFee, uint256 managerFee) = quote($, gain);
        return gain - protocolFee - managerFee;
    }

    /// @notice Credits the treasury's and the manager's claimable (D-01). Never transfers, so neither can block a
    /// settlement.
    function credit(CircleStorage.Layout storage $, uint256 protocolFee, uint256 managerFee) internal {
        // Trusted registry fixed at init; treasury() is never zero.
        if (protocolFee != 0) Weights.creditClaimable($, $.registry.treasury(), protocolFee);
        if (managerFee != 0) Weights.creditClaimable($, $.manager, managerFee);
        uint256 sum = protocolFee + managerFee;
        if (sum == 0) return;
        $.feesCharged += sum;
        emit IKuberCircleEvents.FeesCharged(protocolFee, managerFee);
    }
}
