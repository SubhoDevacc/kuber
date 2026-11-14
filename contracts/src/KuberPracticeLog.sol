// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice A public record of practice-circle steps. The money logic of the tutorial runs on a private practice chain;
/// this contract only records what happened so anyone can look it up. It holds no money and keeps no state.
contract KuberPracticeLog is Ownable {
    /// @notice The most entries one `record` call takes.
    uint256 public constant MAX_ENTRIES = 20;

    event PracticeAction(
        address indexed user, address indexed practiceCircle, string step, string action, bytes32 practiceTx
    );

    error LengthMismatch(uint256 actions, uint256 practiceTxs);
    error TooManyEntries(uint256 count);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Writes one PracticeAction event per entry: `actions[i]` happened as practice-chain tx `practiceTxs[i]`,
    /// during tutorial step `step`, for `user` in the practice circle `practiceCircle`.
    function record(
        address user,
        address practiceCircle,
        string calldata step,
        string[] calldata actions,
        bytes32[] calldata practiceTxs
    ) external onlyOwner {
        uint256 n = actions.length;
        if (n != practiceTxs.length) revert LengthMismatch(n, practiceTxs.length);
        if (n > MAX_ENTRIES) revert TooManyEntries(n);
        for (uint256 i; i < n; ++i) {
            emit PracticeAction(user, practiceCircle, step, actions[i], practiceTxs[i]);
        }
    }
}
