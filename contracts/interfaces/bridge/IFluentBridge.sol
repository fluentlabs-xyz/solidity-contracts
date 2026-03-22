// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleTree} from "../../libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../interfaces/IRollupTypes.sol";

/**
 * @title IFluentBridgeAdmin
 * @dev Admin functions for the bridge contract.
 */
interface IFluentBridgeAdmin {
    /**
     * @notice Update the address of the bridge contract on the other chain.
     * @param newOtherBridge The address of the bridge contract on the other chain.
     */
    function setOtherBridge(address newOtherBridge) external;
    /**
     * @notice Sets the gas limit for message execution.
     * @param newExecuteGasLimit The gas limit for message execution.
     */
    function setExecuteGasLimit(uint256 newExecuteGasLimit) external;
    /**
     * @notice Sets the address of the bridge relayer that is used to send messages to the other chain.
     * @param newRelayer The address of the relayer role.
     */
    function setRelayerRole(address newRelayer) external;
}

interface IFluentBridgeRead {
    /**
     * @notice Get the gas limit for message execution.
     * @return The gas limit for message execution.
     */
    function getExecuteGasLimit() external view returns (uint256);
    /**
     * @notice Get the address of the bridge contract on the other chain.
     * @return The address of the bridge contract on the other chain.
     */
    function getOtherBridge() external view returns (address);
}

/**
 * @title IFluentBridgeErrors
 * @dev Custom errors for the bridge contract.
 */
interface IFluentBridgeErrors {
    /**
     * @notice Invalid window configuration.
     */
    error InvalidWindowConfig(string field);
    /**
     * @notice Message hash has already been processed (duplicate receive or rollback).
     */
    error MessageAlreadyReceived();
    /**
     * @notice Inbound message nonce does not match the expected sequential receivedNonce.
     */
    error MessageReceivedOutOfOrder();
    /**
     * @notice receiveFailedMessage was called for a hash that is not marked as Failed.
     */
    error MessageNotFailed();
    /**
     * @notice Target address is this bridge (self-call) when executing a message or rollback.
     */
    error ForbiddenSelfCall();
    /**
     * @notice sendMessage destination is this bridge or the configured otherBridge, which is forbidden.
     */
    error InvalidDestinationAddress();
    /**
     * @notice Zero address supplied for a required configuration field.
     */
    error ZeroAddressNotAllowed(string field);
    /**
     * @notice Zero value supplied for a required configuration field.
     */
    error ZeroValueNotAllowed(string field);
}

interface IFluentBridgeEvents {
    /**
     * @notice Emitted when a message is sent to another chain.
     */
    event SentMessage(
        address indexed sender,
        address indexed to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes32 messageHash,
        bytes data
    );
    /**
     * @notice Emitted after a cross-chain message hash has been processed.
     * @dev `successfulCall` is true when the target call succeeded, and false when execution failed
     *      or when a rollback/timeout path was taken without invoking the target.
     */
    event ReceivedMessage(bytes32 messageHash, bool successfulCall, bytes returnData);
    /**
     * @notice Emitted when a rollback is triggered (message not received on L2 within deadline).
     */
    event RollbackMessage(bytes32 messageHash, uint256 blockNumber);
    /**
     * @notice Emitted after a rollback is executed (refund to sender).
     */
    event ReceivedMessageRollback(bytes32 messageHash, bool successfulCall, bytes returnData);
    /**
     * @notice Emitted when the address of the bridge contract on the other chain is updated.
     */
    event OtherBridgeUpdated(address indexed prevValue, address indexed newValue);
    /**
     * @notice Emitted when the gas limit for message execution is updated.
     */
    event ExecuteGasLimitUpdated(uint256 indexed prevValue, uint256 indexed newValue);
}

interface IFluentBridge is IFluentBridgeErrors, IFluentBridgeEvents {
    /// @notice Enum describing the status of a cross-chain message.
    enum MessageStatus {
        None,
        Failed,
        Success
    }

    // ---------- Storage / view getters ----------

    /**
     * @notice Next outbound message nonce (incremented on each sendMessage).
     * @return The next outbound message nonce.
     */
    function getNonce() external view returns (uint256);

    /**
     * @notice Next expected inbound received message nonce (L2 receiveMessage ordering).
     * @return The next expected inbound received message nonce.
     */
    function getReceivedNonce() external view returns (uint256);

    /**
     * @notice During receive execution, the address that sent the message on the other chain; otherwise address(0).
     * @return The address that sent the message on the other chain.
     */
    function getNativeSender() external view returns (address);

    /**
     * @notice Address of the bridge contract on the other chain.
     * @return The address of the bridge contract on the other chain.
     */
    function getOtherBridge() external view returns (address);

    /**
     * @notice Status of a received message by its hash (None, Failed, Success).
     * @param key The hash of the received message.
     * @return The status of the received message.
     */
    function getReceivedMessage(bytes32 key) external view returns (MessageStatus);

    /**
     * @notice Returns the size of the sent message queue (L1; 0 on L2 when rollup is not set).
     * @return The size of the sent message queue.
     */
    function getSentMessageQueueSize() external view returns (uint256);

    // ---------- Send / receive ----------

    /**
     * @notice Sends a cross-chain message to the other chain.
     * @param to Destination address on the target chain.
     * @param message Calldata payload to deliver.
     */
    function sendMessage(address to, bytes calldata message) external payable;

    /**
     * @notice Receives and executes a message sent by the bridge authority (L2 only; trusted relayer path).
     * @dev This function is used to receive and execute a message sent by the bridge authority (L2 only; trusted relayer path).
     *
     * @param from Sender on the other chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param blockNumber Block number on source chain.
     * @param nonce Message nonce (must match receivedNonce).
     * @param message Message payload.
     */
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes calldata message
    ) external payable;

    /**
     * @notice Retries execution of a previously failed message (same params as original receive).
     * @dev This function is used to retry execution of a previously failed message from anyone.
     *
     * @param from Sender on the other chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param blockNumber Block number on source chain.
     * @param nonce Message nonce.
     * @param message Message payload.
     */
    function receiveFailedMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes calldata message
    ) external payable;
}
