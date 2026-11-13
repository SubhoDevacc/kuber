// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC(owner);
    }

    function test_T_TOK_1_nonMinterMintReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.NotMinter.selector, stranger));
        usdc.mint(stranger, 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.NotMinter.selector, owner));
        usdc.mint(owner, 1);
    }

    function test_T_TOK_1_minterMints() public {
        vm.expectEmit(true, false, false, true);
        emit MockUSDC.MinterSet(minter, true);
        vm.prank(owner);
        usdc.setMinter(minter, true);
        assertTrue(usdc.isMinter(minter));

        vm.prank(minter);
        usdc.mint(alice, 1_000_000_000);
        assertEq(usdc.balanceOf(alice), 1_000_000_000);
        assertEq(usdc.totalSupply(), 1_000_000_000);
    }

    function test_T_TOK_1_revokedMinterReverts() public {
        vm.prank(owner);
        usdc.setMinter(minter, true);

        vm.expectEmit(true, false, false, true);
        emit MockUSDC.MinterSet(minter, false);
        vm.prank(owner);
        usdc.setMinter(minter, false);
        assertFalse(usdc.isMinter(minter));

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.NotMinter.selector, minter));
        usdc.mint(minter, 1);
    }

    function test_T_TOK_1_setMinterOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        usdc.setMinter(stranger, true);
    }

    function test_T_TOK_1_metadata() public view {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "mUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.owner(), owner);
    }
}
