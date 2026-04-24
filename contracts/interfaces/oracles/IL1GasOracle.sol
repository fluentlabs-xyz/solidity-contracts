// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IL1GasOracle
 * @author Fluent Labs
 * @notice Interface for the L1GasOracle contract
 * @dev Stores a valid [min, max] L1 gas price band. {getL1GasPrice} returns the ceiling (`max`)
 *      for conservative default fee quotes; callers may use any price in the band via the bridge's
 *      overload that accepts `l1GasPriceForFee`.
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
     * @notice `minPrice` must be <= `maxPrice`.
     */
    error InvalidGasPriceRange();

    /// @dev Emitted when the valid L1 gas price band changes (inclusive min/max, wei per gas unit).
    event L1GasPriceRangeUpdated(uint256 minPrice, uint256 maxPrice);

    /// @dev Emitted when the submitter address is updated.
    event SubmitterUpdated(address indexed oldSubmitter, address indexed newSubmitter);

    /**
     * @notice Updates the submitter address
     * @param submitter The new submitter address
     */
    function setSubmitter(address submitter) external;

    /**
     * @notice Owner override: sets both bounds to `gasPrice` (collapses the band to a point).
     */
    function setL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Owner override for the full band.
     */
    function setL1GasPriceRange(uint256 minPrice, uint256 maxPrice) external;

    /**
     * @notice Submitter updates the inclusive valid price band.
     */
    function updateL1GasPriceRange(uint256 minPrice, uint256 maxPrice) external;

    /**
     * @notice Submitter convenience: sets `minPrice == maxPrice == gasPrice`.
     */
    function updateL1GasPrice(uint256 gasPrice) external;

    /**
     * @notice Returns the band ceiling (wei per gas). Used by the bridge for default `getSentMessageFee()`.
     */
    function getL1GasPrice() external view returns (uint256);

    /**
     * @notice Returns the inclusive valid L1 gas price band (wei per gas).
     */
    function getL1GasPriceRange() external view returns (uint256 minPrice, uint256 maxPrice);

    /**
     * @notice Whether `price` lies in the current inclusive band.
     */
    function isL1GasPriceInRange(uint256 price) external view returns (bool);

    /**
     * @notice Returns the submitter address
     * @return The submitter address
     */
    function getSubmitter() external view returns (address);
}
