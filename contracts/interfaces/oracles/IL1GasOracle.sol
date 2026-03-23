// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IL1GasOracle
 * @author Fluent Labs
 * @notice Interface for the L1GasOracle contract
 * @dev Provides a function to get the current L1 gas price
 */
interface IL1GasOracle {
    /**
     * @notice Zero address not allowed for the submitter.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Caller is not the authorized submitter.
     * @dev selector: 0xd393e877
     */
    error UnauthorizedSubmitter(address account);

    /// @dev Emitted when the L1 gas price is updated
    event L1GasPriceUpdated(uint256 gasPrice);

    /// @dev Emitted when the submitter address is updated
    event SubmitterUpdated(address indexed oldSubmitter, address indexed newSubmitter);

    /**
     * @notice Updates the submitter address
     * @param submitter The new submitter address
     */
    function setSubmitter(address submitter) external;

    /**
     * @notice Overrides the stored gas price. Use only to correct a corrupted value.
     * @param gasPrice The new gas price
     */
    function setL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Updates the current L1 gas price
     * @param gasPrice The new L1 gas price
     */
    function updateL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Returns the current L1 gas price
     * @return The current L1 gas price
     */
    function getL1GasPrice() external view returns (uint256);

    /**
     * @notice Returns the submitter address
     * @return The submitter address
     */
    function getSubmitter() external view returns (address);
}
