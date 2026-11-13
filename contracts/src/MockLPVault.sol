// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockAaveVault} from "./MockAaveVault.sol";

contract MockLPVault is MockAaveVault {
    event Shocked(int16 bps, uint256 amount);

    error ShockOutOfBounds(int16 bps);

    constructor(MockUSDC usdc, string memory name_, string memory symbol_, address initialOwner)
        MockAaveVault(usdc, name_, symbol_, initialOwner)
    {}

    /// @notice Simulates an LP price move of `bps` (mock admin power); a loss goes to 0xdead since mUSDC has no burn.
    function shock(int16 bps) external onlyOwner nonReentrant {
        // Checked before negation: -bps cannot overflow and a shock can never zero the vault.
        if (bps <= -10_000) revert ShockOutOfBounds(bps);
        _accrue();
        IERC20 usdc = IERC20(asset());
        uint256 amount = usdc.balanceOf(address(this)) * uint16(bps < 0 ? -bps : bps) / 10_000;
        if (bps > 0) MockUSDC(address(usdc)).mint(address(this), amount);
        else SafeERC20.safeTransfer(usdc, address(0xdead), amount);
        emit Shocked(bps, amount);
    }
}
