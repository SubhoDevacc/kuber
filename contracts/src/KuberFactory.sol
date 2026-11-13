// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {KuberRegistry} from "./KuberRegistry.sol";
import {KuberCircle} from "./KuberCircle.sol";
import {FixedParams, IKuberCircleErrors, RuleParams} from "./lib/CircleTypes.sol";

contract KuberFactory is IKuberCircleErrors {
    KuberRegistry public immutable REGISTRY;
    IERC20 public immutable TOKEN;
    address public immutable AAVE_VAULT;
    address public immutable LP_VAULT;
    address public immutable IMPLEMENTATION;
    address[] internal circles;

    event CircleCreated(address indexed circle, address indexed creator, string name);

    constructor(KuberRegistry registry_, IERC20 token_, address aaveVault_, address lpVault_, address implementation_) {
        if (
            address(registry_) == address(0) || address(token_) == address(0) || aaveVault_ == address(0)
                || lpVault_ == address(0) || implementation_ == address(0)
        ) revert ZeroAddress();
        if (
            aaveVault_ == lpVault_ || IERC4626(aaveVault_).asset() != address(token_)
                || IERC4626(lpVault_).asset() != address(token_)
        ) revert InvalidVault();
        REGISTRY = registry_;
        TOKEN = token_;
        AAVE_VAULT = aaveVault_;
        LP_VAULT = lpVault_;
        IMPLEMENTATION = implementation_;
    }

    /// @notice Clones, authorizes, and initializes a circle. The membership cap and the invite-list rules
    /// surface from `initialize` (registry `MembershipCapReached`, `TooFewInvites`, ...).
    function createCircle(
        string calldata name,
        FixedParams calldata fixedParams_,
        RuleParams calldata rules_,
        address[] calldata invites
    ) external returns (address circle) {
        if (!REGISTRY.verified(msg.sender)) revert NotVerified();
        if (REGISTRY.hasOpenDebt(msg.sender)) revert HasOpenDebt();
        circle = Clones.clone(IMPLEMENTATION);
        circles.push(circle);
        emit CircleCreated(circle, msg.sender, name);
        // Before initialize: initialize calls registry.recordJoin(creator), which needs the circle authorized.
        REGISTRY.authorizeCircle(circle);
        KuberCircle(circle).initialize(msg.sender, name, fixedParams_, rules_, invites);
    }

    function allCircles() external view returns (address[] memory) {
        return circles;
    }

    function circleCount() external view returns (uint256) {
        return circles.length;
    }
}
