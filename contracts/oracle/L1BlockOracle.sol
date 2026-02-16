// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IL1BlockOracle.sol";

contract L1BlockOracle is IL1BlockOracle, Ownable {
    uint256 private l1BlockNumber;

    event L1BlockNumberUpdated(uint256 newBlockNumber);

    constructor() Ownable(msg.sender) {}

    function updateL1BlockNumber(uint256 _blockNumber) external onlyOwner {
        l1BlockNumber = _blockNumber;
        emit L1BlockNumberUpdated(_blockNumber);
    }

    function getL1BlockNumber() external view override returns (uint256) {
        return l1BlockNumber;
    }
}
