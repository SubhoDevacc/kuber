// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {Alloc, CircleStatus, FixedParams, RuleParams} from "../../src/lib/CircleTypes.sol";

/// @notice The deploy script's own wiring, then one circle through the deployed factory: 5 members, activated.
contract DeployTest is Test {
    function test_DeployWiresEverythingAndACircleRuns() public {
        Deploy.Deployed memory d = new Deploy().run();
        address admin = d.registry.owner();

        assertEq(d.usdc.owner(), admin);
        assertEq(d.aave.owner(), admin);
        assertEq(d.lp.owner(), admin);
        assertTrue(d.usdc.isMinter(address(d.aave)));
        assertTrue(d.usdc.isMinter(address(d.lp)));
        assertTrue(d.usdc.isMinter(admin));
        assertGt(d.aave.balanceOf(address(0xdEaD)), 0);
        assertGt(d.lp.balanceOf(address(0xdEaD)), 0);
        assertEq(d.registry.factory(), address(d.factory));
        assertEq(d.registry.treasury(), admin);
        assertEq(d.registry.protocolFeeBps(), 0);
        assertEq(d.factory.IMPLEMENTATION(), address(d.impl));

        address[] memory m = new address[](5);
        address[] memory invites = new address[](4);
        for (uint256 i; i < 5; ++i) {
            m[i] = makeAddr(string.concat("member", vm.toString(i)));
            vm.startPrank(admin);
            d.registry.setVerified(m[i], true);
            d.usdc.mint(m[i], 10_000e6);
            vm.stopPrank();
            if (i > 0) invites[i - 1] = m[i];
        }
        FixedParams memory f = FixedParams({
            contribution: 100e6,
            epochDuration: 60,
            lockBps: 2_000,
            startTime: uint64(block.timestamp + 60),
            minSaveEpochs: 3,
            totalEpochs: 7,
            minMembers: 5,
            maxMembers: 30,
            maxRepayEpochs: 3,
            cooldownEpochs: 1
        });
        RuleParams memory r = RuleParams({
            ownLtvBps: 9_000,
            ownRateBps: 300,
            perLoanMaxBps: 5_000,
            fastLaneBps: 3_000,
            penaltyBps: 1_000,
            contribFineBps: 100,
            installFineBps: 300,
            exitFeeBps: 300,
            managerFeeBps: 0,
            alloc: Alloc({loan: 500, aave: 5_000, lp: 3_500, cash: 1_000})
        });
        vm.prank(m[0]);
        KuberCircle c = KuberCircle(d.factory.createCircle("deploy check", f, r, invites));
        for (uint256 i; i < 5; ++i) {
            vm.startPrank(m[i]);
            if (i > 0) c.join();
            d.usdc.approve(address(c), 700e6);
            vm.stopPrank();
        }
        vm.warp(f.startTime);
        c.activate();

        KuberCircle.CircleState memory s = c.getCircleState();
        assertEq(uint8(s.status), uint8(CircleStatus.Active));
        assertEq(s.memberCount, 5);
    }
}
