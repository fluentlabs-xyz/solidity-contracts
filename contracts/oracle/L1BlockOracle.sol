// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IL1BlockOracle} from "../interfaces/IL1BlockOracle.sol";

/**
 * @title L1BlockOracle
 * @author Fluent Labs
 * @notice Oracle contract for the L1 block number
 * @dev Provides a function to get the current L1 block number
 */
contract L1BlockOracle is Ownable, IL1BlockOracle {
    /// @notice The current L1 block number
    uint256 internal _l1BlockNumber;

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IL1BlockOracle
    function updateL1BlockNumber(uint256 _blockNumber) external onlyOwner {
        _l1BlockNumber = _blockNumber;
        emit L1BlockNumberUpdated(_blockNumber);
    }

    /// @inheritdoc IL1BlockOracle
    function getL1BlockNumber() external view override returns (uint256) {
        return _l1BlockNumber;
    }
}
