// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";
import {KuberPracticeLog} from "../src/KuberPracticeLog.sol";

/// @notice Deploys KuberPracticeLog with the broadcast key as owner (the key the tutorial server records with).
/// `scripts/deploy-practice-log.ts` runs this and, after a Fuji broadcast, adds `practiceLog` to deployments/fuji.json.
contract DeployPracticeLog is Script {
    function run() external returns (KuberPracticeLog log) {
        vm.startBroadcast();
        (, address owner,) = vm.readCallers();
        log = new KuberPracticeLog(owner);
        vm.stopBroadcast();
    }
}
