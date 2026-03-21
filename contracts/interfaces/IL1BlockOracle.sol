// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IL1BlockOracle
 * @author Fluent Labs
 * @notice Interface for the L1BlockOracle contract
 * @dev Provides a function to get the current L1 block number
 */
interface IL1BlockOracle {
    /// @notice Submitted block number is not greater than the current value.
    error BlockNotMonotonic(uint256 current, uint256 proposed);

    /// @dev Emitted when the L1 block number is updated
    event L1BlockNumberUpdated(uint256 indexed _blockNumber);

    /// @dev Emitted when the submitter address is updated
    event SubmitterUpdated(address indexed oldSubmitter, address indexed newSubmitter);

    /**
     * @notice Updates the current L1 block number
     * @param _blockNumber The new L1 block number
     */
    function updateL1BlockNumber(uint256 _blockNumber) external;

    /**
     * @notice Returns the current L1 block number
     * @return The current L1 block number
     */
    function getL1BlockNumber() external view returns (uint256);
}
