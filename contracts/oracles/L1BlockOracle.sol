// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IL1BlockOracle} from "../interfaces/oracles/IL1BlockOracle.sol";

/**
 * @title L1BlockOracle
 * @author Fluent Labs
 * @notice Oracle contract for the L1 block number
 * @dev Provides a function to get the current L1 block number and is used in the Fluent bridge
 *      to check if a message is eligible for rollback.
 */
contract L1BlockOracle is Ownable, IL1BlockOracle {
    /// @dev The current L1 block number
    uint256 internal _l1BlockNumber;

    /// @dev Hot key address authorized to submit block number updates.
    address internal _submitter;

    modifier onlySubmitter() {
        require(msg.sender == _submitter, OwnableUnauthorizedAccount(msg.sender));
        _;
    }

    constructor(address submitter) Ownable(msg.sender) {
        _setSubmitter(submitter);
    }

    // ============ Submitter ============

    /// @inheritdoc IL1BlockOracle
    function updateL1BlockNumber(uint256 blockNumber) external override onlySubmitter {
        require(blockNumber > _l1BlockNumber, BlockNotMonotonic(_l1BlockNumber, blockNumber));

        _l1BlockNumber = blockNumber;
        emit L1BlockNumberUpdated(blockNumber);
    }

    // ============ Owner ============

    /// @inheritdoc IL1BlockOracle
    function setL1BlockNumber(uint256 blockNumber) external onlyOwner {
        _l1BlockNumber = blockNumber;
        emit L1BlockNumberUpdated(blockNumber);
    }

    /// @inheritdoc IL1BlockOracle
    function setSubmitter(address submitter) external override onlyOwner {
        _setSubmitter(submitter);
    }

    function _setSubmitter(address submitter) internal {
        if (submitter == address(0)) revert ZeroAddressNotAllowed("submitter");
        emit SubmitterUpdated(_submitter, submitter);
        _submitter = submitter;
    }

    // ============ Views ============

    /// @inheritdoc IL1BlockOracle
    function getL1BlockNumber() external view override returns (uint256) {
        return _l1BlockNumber;
    }

    /// @inheritdoc IL1BlockOracle
    function getSubmitter() external view override returns (address) {
        return _submitter;
    }
}
