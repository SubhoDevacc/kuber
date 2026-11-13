// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract TransientProbe {
    function roundTrip(uint256 v) external returns (uint256 r) {
        assembly {
            tstore(0, v)
            r := tload(0)
        }
    }
}

contract ToolchainTest is Test {
    function test_CancunTransientStorage() public {
        assertEq(new TransientProbe().roundTrip(42), 42);
    }

    function test_OpenZeppelinClone() public {
        TransientProbe probe = new TransientProbe();
        address clone = Clones.clone(address(probe));
        assertEq(TransientProbe(clone).roundTrip(7), 7);
    }
}
