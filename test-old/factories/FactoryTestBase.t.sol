// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "../Rollup/Base.t.sol";

abstract contract FactoryTestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bool left, bool right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }
}
