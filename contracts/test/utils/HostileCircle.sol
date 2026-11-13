// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KuberCircle} from "../../src/KuberCircle.sol";
import {KuberRegistry} from "../../src/KuberRegistry.sol";

// Modes of the double (file level so tests can import them).
uint8 constant HONEST = 0;
uint8 constant REVERT_DEBT_OF = 1;
uint8 constant REVERT_RECEIVE = 2;
uint8 constant PULL_HALF = 3;
uint8 constant PULL_NONE = 4;
uint8 constant REENTER_CLAIM = 5;
uint8 constant REENTER_RECEIVE = 6;
uint8 constant HUGE_DEBT = 7;
uint8 constant REPORT_ZERO = 8;

/// @dev Test-only: a registry-listed debt circle that fails or misbehaves in `receiveLienPayment` / `debtOf` (T-DF-6).
contract HostileCircle {
    KuberRegistry internal immutable REGISTRY;
    IERC20 internal immutable TOKEN;
    uint8 public mode;
    uint256 public debt;
    KuberCircle public payer;
    uint256 public calls;
    bytes public reentryError;

    constructor(KuberRegistry registry, IERC20 token) {
        REGISTRY = registry;
        TOKEN = token;
    }

    function set(uint8 mode_, uint256 debt_, KuberCircle payer_) external {
        (mode, debt, payer) = (mode_, debt_, payer_);
    }

    /// @dev Lists `person` as owing here; works once the registry lists this contract as a circle.
    function owe(address person) external {
        REGISTRY.addDebt(person);
    }

    function debtOf(address) external view returns (uint256) {
        if (mode == REVERT_DEBT_OF) revert("debtOf");
        return mode == REPORT_ZERO ? 0 : debt;
    }

    function receiveLienPayment(address, uint256 amount) external {
        ++calls;
        if (mode == REVERT_RECEIVE) revert("receive");
        if (mode == PULL_HALF) amount /= 2;
        if (mode == PULL_NONE) return;
        if (mode == REENTER_CLAIM || mode == REENTER_RECEIVE) {
            // Records the paying circle's answer to the re-entry, then returns without pulling.
            try this.reenter() {}
            catch (bytes memory err) {
                reentryError = err;
            }
            return;
        }
        require(TOKEN.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function reenter() external {
        if (mode == REENTER_CLAIM) payer.claim();
        else payer.receiveLienPayment(address(this), 1);
    }
}
