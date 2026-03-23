// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IL1BlockOracle
 * @author Fluent Labs
 * @notice Interface for the L1BlockOracle contract
 * @dev Provides a function to get the current L1 block number
 */
interface IL1BlockOracle {
    /**
     * @notice Zero address not allowed for the submitter.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Submitted block number is not greater than the current value.
     * @dev selector: 0xd591b406
     */
    error BlockNotMonotonic(uint256 current, uint256 proposed);

    /**
     * @notice Caller is not the authorized submitter.
     * @dev selector: 0xd393e877
     */
    error UnauthorizedSubmitter(address account);

    /// @dev Emitted when the L1 block number is updated
    event L1BlockNumberUpdated(uint256 indexed blockNumber);

    /// @dev Emitted when the submitter address is updated
    event SubmitterUpdated(address indexed oldSubmitter, address indexed newSubmitter);

    /**
     * @notice Updates the submitter address
     * @param submitter The new submitter address
     */
    function setSubmitter(address submitter) external;

    /**
     * @notice Overrides the stored block number. Use only to correct a corrupted value.
     * @dev Bypasses monotonicity check. Only callable by owner.
     */
    function setL1BlockNumber(uint256 blockNumber) external;

    /**
     * @notice Updates the current L1 block number
     * @param blockNumber The new L1 block number
     */
    function updateL1BlockNumber(uint256 blockNumber) external;

    /**
     * @notice Returns the current L1 block number
     * @return The current L1 block number
     */
    function getL1BlockNumber() external view returns (uint256);

    /**
     * @notice Returns the submitter address
     * @return The submitter address
     */
    function getSubmitter() external view returns (address);
}
