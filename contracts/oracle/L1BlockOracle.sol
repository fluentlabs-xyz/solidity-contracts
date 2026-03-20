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

    /// @dev Hot key address authorized to submit block number updates.
    address public submitter;

    constructor(address _submitter) Ownable(msg.sender) {
        submitter = _submitter;
    }

    /// @inheritdoc IL1BlockOracle
    function updateL1BlockNumber(uint256 _blockNumber) external override {
        if (msg.sender != submitter) revert OwnableUnauthorizedAccount(msg.sender);
        if (_blockNumber <= _l1BlockNumber) revert BlockNotMonotonic(_l1BlockNumber, _blockNumber);
        _l1BlockNumber = _blockNumber;
        emit L1BlockNumberUpdated(_blockNumber);
    }

    /// @notice Updates the submitter address.
    function setSubmitter(address _submitter) external onlyOwner {
        submitter = _submitter;
    }

    /// @inheritdoc IL1BlockOracle
    function getL1BlockNumber() external view override returns (uint256) {
        return _l1BlockNumber;
    }
}
