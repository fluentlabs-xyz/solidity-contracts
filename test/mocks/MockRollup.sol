// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract MockRollup {
    bool public finalized;

    function setFinalized(bool value) external {
        finalized = value;
    }

    function isBatchFinalized(uint256) external view returns (bool) {
        return finalized;
    }
}
