// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberFactory} from "../../src/KuberFactory.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";
import {MockAaveVault} from "../../src/MockAaveVault.sol";
import {MockLPVault} from "../../src/MockLPVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {Alloc, BPS, FixedParams, RuleParams} from "../../src/lib/CircleTypes.sol";
import {KuberCircleHarness} from "./KuberCircleHarness.sol";

abstract contract CircleTestBase is Test {
    MockUSDC internal usdc;
    MockAaveVault internal aave;
    MockLPVault internal lp;
    KuberRegistry internal registry;
    KuberFactory internal factory;
    uint256 internal addrCount;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new MockUSDC(address(this));
        usdc.setMinter(address(this), true);
        aave = new MockAaveVault(usdc, "Mock Aave mUSDC", "maUSDC", address(this));
        lp = new MockLPVault(usdc, "Mock LP mUSDC", "mlpUSDC", address(this));
        // Without these, the first non-zero vault accrual reverts NotMinter (Phase 1 lesson).
        usdc.setMinter(address(aave), true);
        usdc.setMinter(address(lp), true);
        registry = new KuberRegistry(address(this), makeAddr("treasury"));
        factory = new KuberFactory(registry, IERC20(address(usdc)), address(aave), address(lp), _implementation());
        registry.setFactory(address(factory));
    }

    function _implementation() internal virtual returns (address) {
        return address(new KuberCircleHarness());
    }

    /// @dev Every circle from this base is a harness clone.
    function _h(KuberCircle c) internal pure returns (KuberCircleHarness) {
        return KuberCircleHarness(address(c));
    }

    function _fixed() internal view returns (FixedParams memory) {
        return FixedParams({
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
    }

    function _rules() internal pure returns (RuleParams memory) {
        return RuleParams({
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
    }

    /// @dev `n` fresh addresses, each verified and holding 10_000 mUSDC.
    function _newMembers(uint256 n) internal returns (address[] memory ms) {
        ms = new address[](n);
        for (uint256 i; i < n; ++i) {
            ms[i] = makeAddr(string.concat("member", vm.toString(++addrCount)));
            registry.setVerified(ms[i], true);
            usdc.mint(ms[i], 10_000e6);
        }
    }

    /// @dev ms[1..]: the invite list when ms[0] is the creator.
    function _tail(address[] memory ms) internal pure returns (address[] memory t) {
        t = new address[](ms.length - 1);
        for (uint256 i = 1; i < ms.length; ++i) {
            t[i - 1] = ms[i];
        }
    }

    /// @dev ms[0] creates with default params and invites ms[1..].
    function _create(address[] memory ms) internal returns (KuberCircle c) {
        FixedParams memory f = _fixed();
        address[] memory inv = _tail(ms);
        vm.prank(ms[0]);
        c = KuberCircle(factory.createCircle("circle", f, _rules(), inv));
    }

    /// @dev Joins in `order`, then `order` and the creator approve contribution × totalEpochs (R-G; moves no tokens).
    function _join(KuberCircle c, address[] memory order) internal {
        for (uint256 i; i < order.length; ++i) {
            vm.prank(order[i]);
            c.join();
        }
        KuberCircle.CircleState memory s = c.getCircleState();
        uint256 allowance = uint256(s.fixedParams.contribution) * s.fixedParams.totalEpochs;
        for (uint256 i; i < order.length; ++i) {
            vm.prank(order[i]);
            usdc.approve(address(c), allowance);
        }
        vm.prank(s.creator);
        usdc.approve(address(c), allowance);
    }

    /// @dev n new members (creator first), create, join in index order, warp to startTime, activate.
    function _start(uint256 n) internal returns (KuberCircle c, address[] memory ms) {
        ms = _newMembers(n);
        c = _create(ms);
        _join(c, _tail(ms));
        vm.warp(c.getCircleState().fixedParams.startTime);
        c.activate();
    }

    /// @dev Start of `epoch`, or the start of its LOCK window when `lock`.
    function _warpTo(KuberCircle c, uint256 epoch, bool lock) internal {
        FixedParams memory f = c.getCircleState().fixedParams;
        uint256 t = f.startTime + (epoch - 1) * f.epochDuration;
        if (lock) t += uint256(f.epochDuration) * (BPS - f.lockBps) / BPS;
        vm.warp(t);
    }

    /// @dev Gives `person` open debt through a factory-created circle (makes a throwaway one if none exists).
    function _debt(address person) internal {
        address circle = factory.circleCount() == 0 ? address(_create(_newMembers(5))) : factory.allCircles()[0];
        vm.prank(circle);
        registry.addDebt(person);
    }
}
