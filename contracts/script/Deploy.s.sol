// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KuberCircle} from "../src/KuberCircle.sol";
import {KuberFactory} from "../src/KuberFactory.sol";
import {KuberRegistry} from "../src/KuberRegistry.sol";
import {MockAaveVault} from "../src/MockAaveVault.sol";
import {MockLPVault} from "../src/MockLPVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Deploys and wires everything as CircleTestBase does. The deployer (the broadcast key) is the admin:
/// owner of the token, vaults, and registry, and a token minter (the faucet signer). Forge deploys and links the
/// KuberCircle libraries itself. `scripts/deploy.ts` runs this and writes `deployments/<network>.json`.
contract Deploy is Script {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Deployed {
        MockUSDC usdc;
        MockAaveVault aave;
        MockLPVault lp;
        KuberRegistry registry;
        KuberFactory factory;
        KuberCircle impl;
    }

    function run() external returns (Deployed memory d) {
        vm.startBroadcast();
        (, address admin,) = vm.readCallers();
        d = _deploy(admin, vm.envOr("TREASURY", admin));
        vm.stopBroadcast();
    }

    function _deploy(address admin, address treasury) internal returns (Deployed memory d) {
        d.usdc = new MockUSDC(admin);
        d.aave = new MockAaveVault(d.usdc, "Mock Aave mUSDC", "maUSDC", admin);
        d.lp = new MockLPVault(d.usdc, "Mock LP mUSDC", "mlpUSDC", admin);
        // Vaults mint their yield; without this the first non-zero accrual reverts NotMinter.
        d.usdc.setMinter(address(d.aave), true);
        d.usdc.setMinter(address(d.lp), true);
        d.usdc.setMinter(admin, true);
        // Dead shares before any circle exists, so no one can inflate a near-empty vault's share price.
        d.usdc.mint(admin, 2e6);
        d.usdc.approve(address(d.aave), 1e6);
        d.aave.deposit(1e6, DEAD);
        d.usdc.approve(address(d.lp), 1e6);
        d.lp.deposit(1e6, DEAD);
        d.registry = new KuberRegistry(admin, treasury);
        d.impl = new KuberCircle();
        d.factory =
            new KuberFactory(d.registry, IERC20(address(d.usdc)), address(d.aave), address(d.lp), address(d.impl));
        d.registry.setFactory(address(d.factory));
        // As the tests: SPEC §4 (S1) figures assume protocol fee 0. APY 0, speedup 1, gas settings 0 stay default.
        d.registry.setProtocolFeeBps(0);
    }
}
