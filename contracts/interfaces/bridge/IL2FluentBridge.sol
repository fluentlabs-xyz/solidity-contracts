// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IL2FluentBridge
 * @author Fluent Labs
 * @dev Interface for the L2 bridge contract.
 */
interface IL2FluentBridge {
    // ============ Errors ============

    /**
     * @notice ETH transfer to the fee treasury failed during outbound message fee deduction.
     * @dev selector: 0x5c389498
     */
    error FailedToDeductFee();

    // ========== Events ==========

    /**
     * @notice Emitted when the address of the L1 gas price oracle is updated.
     * @param prevValue The previous address of the L1 gas price oracle.
     * @param newValue The new address of the L1 gas price oracle.
     */
    event L1GasPriceOracleUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the gas price config is updated.
     * @param prevOverhead The previous overhead gas price.
     * @param newOverhead The new overhead gas price.
     * @param prevScalar The previous scalar gas price.
     * @param newScalar The new scalar gas price.
     * @param prevL1BaseFee The previous L1 base fee used in the gas price calculation.
     * @param newL1BaseFee The new L1 base fee used in the gas price calculation.
     */
    event GasPriceConfigUpdated(
        uint256 indexed prevOverhead,
        uint256 newOverhead,
        uint256 indexed prevScalar,
        uint256 newScalar,
        uint256 indexed prevL1BaseFee,
        uint256 newL1BaseFee
    );

    /**
     * @notice Emitted when the address of the L1 block oracle is updated.
     * @param prevValue The previous address of the L1 block oracle.
     * @param newValue The new address of the L1 block oracle.
     */
    event L1BlockOracleUpdated(address indexed prevValue, address indexed newValue);
    /**
     * @notice Emitted when the L1 gas limit is updated.
     * @param prevValue The previous L1 gas limit.
     * @param newValue The new L1 gas limit.
     */
    event L1GasLimitUpdated(uint256 indexed prevValue, uint256 indexed newValue);

    // ========== Functions ==========

    /**
     * @notice Update the address of the L1 block oracle that is used to get the
     *         latest L1 block number.
     * @param newL1BlockOracle The address of the L1 block oracle.
     */
    function setL1BlockOracle(address newL1BlockOracle) external;
    /**
     * @notice Get the address of the L1 block oracle that is used to get the
     *         latest L1 block number.
     * @return The address of the L1 block oracle.
     */
    function getL1BlockOracle() external view returns (address);
}
