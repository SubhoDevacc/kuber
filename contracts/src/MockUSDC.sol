// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    mapping(address => bool) public isMinter;

    event MinterSet(address indexed account, bool allowed);

    error NotMinter(address caller);

    constructor(address initialOwner) ERC20("Mock USDC", "mUSDC") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Grants or revokes mint rights (the vaults and the dev-api faucet signer).
    function setMinter(address account, bool allowed) external onlyOwner {
        isMinter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    /// @notice Mints `amount` to `to`; callable only by a minter.
    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotMinter(msg.sender);
        _mint(to, amount);
    }
}
