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

    /**
     * @dev Restricts to the authorized submitter address.
     */
    modifier onlySubmitter() {
        require(msg.sender == _submitter, UnauthorizedSubmitter(msg.sender));
        _;
    }

    /**
     * @dev Sets the contract owner to `msg.sender` and configures the initial submitter.
     */
    constructor(address submitter) Ownable(msg.sender) {
        _setSubmitter(submitter);
    }

    // ============ Submitter ============

    /// @inheritdoc IL1BlockOracle
    function updateL1BlockNumber(uint256 blockNumber) external override onlySubmitter {
        // enforce strict monotonicity to prevent stale or replayed block numbers
        require(blockNumber > _l1BlockNumber, BlockNotMonotonic(_l1BlockNumber, blockNumber));

        _l1BlockNumber = blockNumber;
        emit L1BlockNumberUpdated(blockNumber);
    }

    // ============ Owner ============

    /// @inheritdoc IL1BlockOracle
    function setL1BlockNumber(uint256 blockNumber) external onlyOwner {
        // owner bypass skips monotonicity check for emergency corrections
        _l1BlockNumber = blockNumber;
        emit L1BlockNumberUpdated(blockNumber);
    }

    /// @inheritdoc IL1BlockOracle
    function setSubmitter(address submitter) external override onlyOwner {
        _setSubmitter(submitter);
    }

    /**
     * @dev Validates and stores the submitter address. Reverts on zero address.
     */
    function _setSubmitter(address submitter) internal {
        require(submitter != address(0), ZeroAddressNotAllowed("submitter"));
        // emit before write so the event captures the previous submitter
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
