// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MockAaveVault is ERC4626, Ownable, ReentrancyGuardTransient {
    uint16 public apyBps;
    uint64 public apySourceTs;
    uint32 public speedup = 1;
    uint64 public lastAccrual;

    event ApySet(uint16 apyBps, uint64 sourceTs);
    event SpeedupSet(uint32 speedup);

    error ApyOutOfBounds(uint16 apyBps);
    error SpeedupOutOfBounds(uint32 speedup);

    constructor(MockUSDC usdc, string memory name_, string memory symbol_, address initialOwner)
        ERC20(name_, symbol_)
        ERC4626(IERC20(address(usdc)))
        Ownable(initialOwner)
    {
        // Without this, tokens sent before the first deposit would accrue from timestamp 0.
        lastAccrual = uint64(block.timestamp);
    }

    /// @notice Vault balance plus the yield accrued since the last accrual and not yet minted.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        return bal + _pending(bal);
    }

    /// @notice Sets the mock APY (mock admin power); elapsed time is paid at the old rate first.
    function setApy(uint16 newApyBps, uint64 sourceTs) external onlyOwner nonReentrant {
        if (newApyBps > 10_000) revert ApyOutOfBounds(newApyBps);
        // Only external call is our hook-free MockUSDC.mint, and nonReentrant blocks state-changing re-entry.
        // slither-disable-next-line reentrancy-no-eth
        _accrue();
        apyBps = newApyBps;
        apySourceTs = sourceTs;
        emit ApySet(newApyBps, sourceTs);
    }

    /// @notice Sets the time multiplier for yield (mock admin power); elapsed time is paid at the old speed first.
    function setSpeedup(uint32 x) external onlyOwner nonReentrant {
        if (x == 0 || x > 1_000_000) revert SpeedupOutOfBounds(x);
        // Only external call is our hook-free MockUSDC.mint, and nonReentrant blocks state-changing re-entry.
        // slither-disable-next-line reentrancy-no-eth
        _accrue();
        speedup = x;
        emit SpeedupSet(x);
    }

    // Simple interest since lastAccrual; one floor division so the view and the mint always agree.
    function _pending(uint256 bal) internal view returns (uint256) {
        return bal * apyBps * (block.timestamp - lastAccrual) * speedup / (10_000 * 365 days);
    }

    function _accrue() internal {
        uint256 amount = _pending(IERC20(asset()).balanceOf(address(this)));
        lastAccrual = uint64(block.timestamp);
        if (amount != 0) MockUSDC(asset()).mint(address(this), amount);
    }

    // deposit and mint both route through here in OZ 5.6.1.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        _accrue();
        super._deposit(caller, receiver, assets, shares);
    }

    // withdraw and redeem both route through here in OZ 5.6.1.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        _accrue();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }
}
