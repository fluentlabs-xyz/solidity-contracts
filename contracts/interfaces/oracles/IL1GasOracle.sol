// SPDX-License-Identifier: Apache-2.0
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

    /**
     * @notice Gas price window must be strictly positive.
     */
    error InvalidGasPriceWindow();

    /// @dev Emitted when the committed L1 gas price (used for fee quotes) changes
    event L1GasPriceUpdated(uint256 gasPrice);

    /// @dev Emitted when the submitter posts a new value that will become committed at the next window boundary (or later).
    event L1GasPriceQueued(uint256 queuedPrice, uint256 earliestCommitTimestamp);

    /// @dev Emitted when the submitter address is updated
    event SubmitterUpdated(address indexed oldSubmitter, address indexed newSubmitter);

    /// @dev Emitted when the sliding window duration is updated
    event GasPriceWindowUpdated(uint256 oldWindow, uint256 newWindow);

    /**
     * @notice Updates the submitter address
     * @param submitter The new submitter address
     */
    function setSubmitter(address submitter) external;

    /**
     * @notice Overrides stored gas prices and realigns the sliding window to `block.timestamp`.
     * @dev Use only to correct a corrupted value. Makes `gasPrice` effective immediately for quoting.
     * @param gasPrice The new gas price
     */
    function setL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Updates the duration of the commitment window. Rolls any due commits first.
     * @param newWindowSeconds New window length in seconds; must satisfy `0 < newWindowSeconds <= type(uint32).max`
     */
    function setGasPriceWindow(uint256 newWindowSeconds) external;

    /**
     * @notice Queues a new L1 gas price; it becomes the committed {getL1GasPrice} at the next window boundary.
     * @param gasPrice The new L1 gas price
     */
    function updateL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Returns the committed L1 gas price used for fee computation (sliding window / discrete commits).
     * @return The gas price that is stable until {getGasPriceCommitment}'s `validUntil` (inclusive of quotes in that interval).
     */
    function getL1GasPrice() external view returns (uint256);

    /**
     * @notice Returns the window length in seconds between possible commitment changes (unless the owner resets the window).
     */
    function getGasPriceWindow() external view returns (uint256);

    /**
     * @notice Returns the committed L1 gas price and the next window boundary time.
     * @dev For L2 timestamps `t` with `t < validUntil`, {getL1GasPrice} equals `effectivePrice` (barring owner overrides).
     * @return effectivePrice Committed gas price used for fee quotes until `validUntil`
     * @return validUntil First timestamp at which the queued submitter update can change the committed price
     */
    function getGasPriceCommitment() external view returns (uint256 effectivePrice, uint256 validUntil);

    /**
     * @notice Returns the submitter address
     * @return The submitter address
     */
    function getSubmitter() external view returns (address);
}
