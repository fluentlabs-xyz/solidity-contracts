// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IL1BlockOracle {
    function getL1BlockNumber() external view returns (uint256);
} 