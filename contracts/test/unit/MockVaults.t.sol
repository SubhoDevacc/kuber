// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockAaveVault} from "../../src/MockAaveVault.sol";
import {MockLPVault} from "../../src/MockLPVault.sol";

contract MockVaultsTest is Test {
    MockUSDC internal usdc;
    MockAaveVault internal aave;
    MockLPVault internal lp;
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    address internal constant DEAD = address(0xdead);
    uint64 internal constant TS = 1_700_000_000;

    function setUp() public {
        usdc = new MockUSDC(address(this));
        aave = new MockAaveVault(usdc, "Mock Aave Vault", "maUSDC", address(this));
        lp = new MockLPVault(usdc, "Mock LP Vault", "mlpUSDC", address(this));
        usdc.setMinter(address(aave), true);
        usdc.setMinter(address(lp), true);
        usdc.setMinter(address(this), true);
        usdc.mint(alice, 10_000_000_000);
        vm.startPrank(alice);
        usdc.approve(address(aave), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        vm.stopPrank();
        aave.setApy(500, TS);
    }

    function _deposit(MockAaveVault vault, uint256 assets) internal {
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function test_T_VLT_1_fivePercentPerYear() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 31_536_000);
        assertEq(aave.totalAssets(), 1_050_000_000);
        assertEq(usdc.balanceOf(address(aave)), 1_000_000_000);
    }

    function test_T_VLT_1_speedupMultipliesYield() public {
        aave.setSpeedup(10);
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 3_153_600);
        assertEq(aave.totalAssets(), 1_050_000_000);
    }

    function test_T_VLT_1_depositAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        _deposit(aave, 1_000_000_000);
        assertEq(usdc.balanceOf(address(aave)), 2_025_000_000);
        vm.warp(block.timestamp + 15_768_000);
        assertEq(aave.totalAssets(), 2_075_625_000);
    }

    function test_T_VLT_1_withdrawAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        vm.prank(alice);
        aave.withdraw(500_000_000, alice, alice);
        assertEq(usdc.balanceOf(address(aave)), 525_000_000);
        vm.warp(block.timestamp + 15_768_000);
        assertEq(aave.totalAssets(), 538_125_000);
    }

    function test_T_VLT_1_mintAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        vm.prank(alice);
        uint256 paid = aave.mint(1_000_000, alice);
        assertEq(usdc.balanceOf(address(aave)), 1_025_000_000 + paid);
    }

    function test_T_VLT_1_redeemAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        vm.prank(alice);
        uint256 out = aave.redeem(500_000_000, alice, alice);
        assertEq(usdc.balanceOf(address(aave)), 1_025_000_000 - out);
    }

    function test_T_VLT_1_setApyAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        vm.expectEmit(address(aave));
        emit MockAaveVault.ApySet(1_000, TS + 1);
        aave.setApy(1_000, TS + 1);
        assertEq(aave.apyBps(), 1_000);
        assertEq(aave.apySourceTs(), TS + 1);
        assertEq(usdc.balanceOf(address(aave)), 1_025_000_000);
        vm.warp(block.timestamp + 15_768_000);
        assertEq(aave.totalAssets(), 1_076_250_000);
    }

    function test_T_VLT_1_setSpeedupAccruesFirst() public {
        _deposit(aave, 1_000_000_000);
        vm.warp(block.timestamp + 15_768_000);
        vm.expectEmit(address(aave));
        emit MockAaveVault.SpeedupSet(2);
        aave.setSpeedup(2);
        assertEq(aave.speedup(), 2);
        assertEq(usdc.balanceOf(address(aave)), 1_025_000_000);
        vm.warp(block.timestamp + 7_884_000);
        assertEq(aave.totalAssets(), 1_050_625_000);
    }

    function test_T_VLT_1_setterBounds() public {
        assertEq(aave.speedup(), 1);
        vm.expectRevert(abi.encodeWithSelector(MockAaveVault.ApyOutOfBounds.selector, uint16(10_001)));
        aave.setApy(10_001, 0);
        aave.setApy(10_000, 0);
        assertEq(aave.apyBps(), 10_000);
        vm.expectRevert(abi.encodeWithSelector(MockAaveVault.SpeedupOutOfBounds.selector, uint32(0)));
        aave.setSpeedup(0);
        vm.expectRevert(abi.encodeWithSelector(MockAaveVault.SpeedupOutOfBounds.selector, uint32(1_000_001)));
        aave.setSpeedup(1_000_001);
        aave.setSpeedup(1_000_000);
        assertEq(aave.speedup(), 1_000_000);
    }

    function test_T_VLT_1_lpVaultAccruesToo() public {
        lp.setApy(500, TS);
        _deposit(lp, 1_000_000_000);
        vm.warp(block.timestamp + 31_536_000);
        assertEq(lp.totalAssets(), 1_050_000_000);
    }

    function test_T_VLT_2_shockLowersValueTenPercent() public {
        _deposit(lp, 1_000_000_000);
        vm.expectEmit(address(lp));
        emit MockLPVault.Shocked(-1000, 100_000_000);
        lp.shock(-1000);
        assertEq(lp.totalAssets(), 900_000_000);
        assertEq(usdc.balanceOf(DEAD), 100_000_000);
        uint256 value = lp.previewRedeem(lp.balanceOf(alice));
        assertLe(value, 900_000_000);
        assertApproxEqAbs(value, 900_000_000, 1);
    }

    function test_T_VLT_2_shockBounds() public {
        _deposit(lp, 1_000_000_000);
        vm.expectRevert(abi.encodeWithSelector(MockLPVault.ShockOutOfBounds.selector, int16(-10_000)));
        lp.shock(-10_000);
        vm.expectRevert(abi.encodeWithSelector(MockLPVault.ShockOutOfBounds.selector, type(int16).min));
        lp.shock(type(int16).min);
        lp.shock(-9_999);
        assertEq(lp.totalAssets(), 100_000);
    }

    function test_T_VLT_2_positiveShock() public {
        _deposit(lp, 1_000_000_000);
        lp.shock(1000);
        assertEq(lp.totalAssets(), 1_100_000_000);
    }

    function test_T_VLT_2_shockAccruesFirst() public {
        lp.setApy(500, TS);
        _deposit(lp, 1_000_000_000);
        vm.warp(block.timestamp + 31_536_000);
        lp.shock(-1000);
        assertEq(lp.totalAssets(), 945_000_000);
        assertEq(usdc.balanceOf(DEAD), 105_000_000);
    }

    function test_T_VLT_2_nonOwnerCallsRevert() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(err);
        lp.shock(-1000);
        vm.expectRevert(err);
        lp.setApy(500, 0);
        vm.expectRevert(err);
        lp.setSpeedup(2);
        vm.expectRevert(err);
        aave.setApy(500, 0);
        vm.expectRevert(err);
        aave.setSpeedup(2);
        vm.stopPrank();
    }

    function test_T_VLT_2_aaveHasNoShock() public {
        (bool ok,) = address(aave).call(abi.encodeWithSignature("shock(int16)", int16(-1000)));
        assertFalse(ok);
    }
}
