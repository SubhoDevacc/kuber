// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {
    Alloc,
    BPS,
    FixedParams,
    IKuberCircleErrors,
    MAX_EPOCHS,
    MAX_MEMBERS,
    MIN_EPOCH_DURATION,
    MIN_MEMBERS_FLOOR,
    MIN_SAVE_FLOOR,
    RuleParams
} from "./CircleTypes.sol";

/// @notice SPEC §2.5 bounds; takes candidate structs so M6 governance can reuse validateRules on a proposal.
library Params {
    function validateFixed(FixedParams memory f) internal view {
        // contribution × MAX_EPOCHS × MAX_MEMBERS must fit uint128 (02-VERIFICATION I-1).
        if (f.contribution == 0 || f.contribution > 1e30) revert IKuberCircleErrors.InvalidContribution();
        if (f.epochDuration < MIN_EPOCH_DURATION) revert IKuberCircleErrors.InvalidEpochDuration();
        if (f.lockBps < 1_000 || f.lockBps > 4_000) revert IKuberCircleErrors.InvalidLockBps();
        if (f.startTime <= block.timestamp) revert IKuberCircleErrors.InvalidStartTime();
        if (f.minSaveEpochs < MIN_SAVE_FLOOR) revert IKuberCircleErrors.InvalidMinSaveEpochs();
        if (f.totalEpochs < uint256(f.minSaveEpochs) + 3 || f.totalEpochs > MAX_EPOCHS) {
            revert IKuberCircleErrors.InvalidTotalEpochs();
        }
        if (f.minMembers < MIN_MEMBERS_FLOOR || f.maxMembers > MAX_MEMBERS || f.minMembers > f.maxMembers) {
            revert IKuberCircleErrors.InvalidMemberBounds();
        }
        if (f.maxRepayEpochs < 1 || f.maxRepayEpochs > 3) revert IKuberCircleErrors.InvalidMaxRepayEpochs();
        if (f.cooldownEpochs > 3) revert IKuberCircleErrors.InvalidCooldownEpochs();
    }

    function validateRules(RuleParams memory r) internal pure {
        if (r.ownLtvBps > BPS) revert IKuberCircleErrors.InvalidOwnLtv();
        if (r.ownRateBps > 2_000) revert IKuberCircleErrors.InvalidOwnRate();
        if (r.perLoanMaxBps < 1_000 || r.perLoanMaxBps > BPS) revert IKuberCircleErrors.InvalidPerLoanMax();
        if (r.fastLaneBps > 5_000) revert IKuberCircleErrors.InvalidFastLane();
        Alloc memory a = r.alloc;
        if (uint256(a.loan) + a.aave + a.lp + a.cash != BPS || a.loan > 4_000 || a.lp > 5_000 || a.cash < 500) {
            revert IKuberCircleErrors.InvalidAllocation();
        }
        if (r.penaltyBps > 5_000) revert IKuberCircleErrors.InvalidPenalty();
        if (r.contribFineBps > 1_000) revert IKuberCircleErrors.InvalidContribFine();
        if (r.installFineBps > 2_000) revert IKuberCircleErrors.InvalidInstallFine();
        if (r.exitFeeBps > 2_000) revert IKuberCircleErrors.InvalidExitFee();
        if (r.managerFeeBps > 1_000) revert IKuberCircleErrors.InvalidManagerFee();
    }
}
