// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Rollup} from "contracts/rollup/Rollup.sol";

contract FinalizingBridge {
    address public target;

    function setTarget(address _rollup) external {
        target = _rollup;
    }

    function popSentMessage() external returns (bytes32, uint256) {
        // realistic attack: call permissionless finalizeBatches during deposit processing
        Rollup(target).finalizeBatches(1);
        return (keccak256("deposit"), block.number);
    }
}
