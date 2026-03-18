// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IL2FluentBridge
 * @author Fluent Labs
 * @dev Interface for the L2 bridge contract.
 */
interface IL2FluentBridge {
    // ========= Errors ==========

    // ========== Events ==========

    /**
     * @notice Emitted when the address of the L1 block oracle is updated.
     * @param prevValue The previous address of the L1 block oracle.
     * @param newValue The new address of the L1 block oracle.
     */
    event L1BlockOracleUpdated(address indexed prevValue, address indexed newValue);
    /**
     * @notice Emitted when the number of L1 blocks after which a message becomes eligible for rollback is updated.
     */
    event ReceiveMessageDeadlineUpdated(uint256 indexed prevValue, uint256 indexed newValue);

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
    /**
     * @notice Get the number of L1 blocks after which a message becomes eligible for rollback.
     * @return The number of L1 blocks after which a message becomes eligible for rollback.
     */
    function getReceiveMessageDeadline() external view returns (uint256);
    /**
     * @notice Sets the number of L1 blocks after which a message becomes eligible for rollback.
     * @param newReceiveMessageDeadline The number of L1 blocks after which a message becomes eligible for rollback.
     */
    function setReceiveMessageDeadline(uint256 newReceiveMessageDeadline) external;
}
