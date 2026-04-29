// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IFluentBridgeAdmin
 * @dev Admin functions for the bridge contract.
 */
interface IFluentBridgeAdmin {
    /**
     * @notice Update the address that receives outbound message fees (L2 `sendMessage` fee path).
     * @param newFeeTreasury The new treasury address (may be zero on L1 when unused).
     */
    function setFeeTreasury(address newFeeTreasury) external;
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

/**
 * @title IFluentBridgeRead
 * @dev Read-only getters for bridge configuration and state.
 */
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
    /**
     * @notice Treasury receiving fees charged on L2 outbound messages (zero when unused).
     */
    function getFeeTreasury() external view returns (address);
    /**
     * @notice Fee charged on the next outbound message (0 when no fee applies).
     */
    function getSentMessageFee() external view returns (uint256);
    /**
     * @notice True iff the currently executing cross-chain message originated from an L1 batch
     *         whose rollup status is {BatchStatus.Preconfirmed}. False in every other case —
     *         including {BatchStatus.Finalized}, the L1 relayer path, every L2 receive path,
     *         and any call made outside an in-flight receive execution.
     * @dev Used by gateway-level rate limits that are only meaningful during the optimistic
     *      preconfirmation window. Once the originating batch is Finalized the consumer MUST
     *      treat the call as unrestricted; outside a receive the return is always false.
     */
    function isCurrentBatchPreconfirmed() external view returns (bool);
}

/**
 * @title IFluentBridgeErrors
 * @dev Custom errors for the bridge contract.
 */
interface IFluentBridgeErrors {
    /**
     * @notice Invalid window configuration.
     * @dev selector: 0x14bef653
     */
    error InvalidWindowConfig(string field);
    /**
     * @notice Message hash has already been processed (duplicate receive or rollback).
     * @dev selector: 0x66a98a4b
     */
    error MessageAlreadyReceived();
    /**
     * @notice Inbound message nonce does not match the expected sequential receivedNonce.
     * @dev selector: 0x2ae88f59
     */
    error MessageReceivedOutOfOrder();
    /**
     * @notice receiveFailedMessage was called for a hash that is not marked as Failed.
     * @dev selector: 0xeb8adf0e
     */
    error MessageNotFailed();
    /**
     * @notice Target address is this bridge (self-call) when executing a message or rollback.
     * @dev selector: 0xef42d941
     */
    error ForbiddenSelfCall();
    /**
     * @notice sendMessage destination is this bridge or the configured otherBridge, which is forbidden.
     * @dev selector: 0x52098529
     */
    error InvalidDestinationAddress();
    /**
     * @notice Zero address supplied for a required configuration field.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);
    /**
     * @notice Zero value supplied for a required configuration field.
     * @dev selector: 0x78bcc63a
     */
    error ZeroValueNotAllowed(string field);
    /**
     * @notice Insufficient `msg.value` to cover the outbound message fee.
     * @dev selector: 0x025dbdd4
     */
    error InsufficientFee();
    /**
     * @notice Bridge balance too low to cover the native value required by the message.
     */
    error InsufficientBridgeBalance(uint256 required);
    /**
     * @notice Gateway is not whitelisted.
     * @dev selector: 0x4185a6fb
     */
    error GatewayNotWhitelisted();
    /**
     * @notice Gateway is already registered while registering a new gateway via {registerGateway}.
     * @dev selector: 0xdd704277
     */
    error GatewayAlreadyRegistered();
    /**
     * @notice Gateway is not registered while deregistering a gateway via {unregisterGateway}.
     * @dev selector: 0x162e1dfc
     */
    error GatewayNotRegistered();
    /**
     * @notice The provided address is not a contract.
     * @dev selector: 0x09ee12d5
     */
    error NotAContract();
}

/**
 * @title IFluentBridgeEvents
 * @dev Events emitted by the bridge contract.
 */
interface IFluentBridgeEvents {
    /**
     * @notice Emitted when a message is sent to another chain.
     */
    event SentMessage(
        address indexed sender,
        address indexed to,
        uint256 value,
        uint256 fee,
        uint256 chainId,
        uint256 validUntilBlockNumber,
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
     * @notice Emitted when a retry of a previously failed message is attempted via `receiveFailedMessage`.
     * @dev `successfulCall` is true when the target call succeeded, and false when execution failed.
     */
    event RetriedFailedMessage(bytes32 messageHash, bool successfulCall, bytes returnData);

    /**
     * @notice Emitted when a rollback is triggered (message reached its committed expiry on L2).
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
    /**
     * @notice Emitted when the fee treasury address is updated.
     */
    event FeeTreasuryUpdated(address indexed prevValue, address indexed newValue);
    /**
     * @notice Emitted when a gateway is registered as a trusted peer on this bridge.
     * @dev A registered gateway is eligible as both a `sendMessage` destination (outbound)
     *      and a `_receiveMessage` target (inbound). See {FluentBridge.sendMessage} and
     *      {FluentBridge._receiveMessage}.
     */
    event GatewayRegistered(address indexed gateway);
    /**
     * @notice Emitted when a gateway is de-registered from the trusted peer set.
     * @dev Once deregistered, the bridge rejects further sends to and receives from this
     *      address. In-flight outbound messages already enqueued are unaffected; in-flight
     *      inbound messages will revert on receive with {GatewayNotWhitelisted}.
     */
    event GatewayDeregistered(address indexed gateway);
}

interface IFluentBridgeWrite {
    /**
     * @notice Sends a cross-chain message with optional native value.
     * @dev Deducts the L2 send fee (if any), encodes and hashes the message,
     *      then calls {_afterSendMessage} for chain-specific hooks (L1 enqueue).
     *
     * @param to Destination address on the target chain.
     * @param message Calldata payload to deliver.
     */
    function sendMessage(address to, bytes calldata message) external payable;
    /**
     * @notice Receives and executes a relayer-delivered cross-chain message.
     * @dev Enforces sequential nonce, verifies message not already processed,
     *      then delegates to {_receiveMessage} for ExcessivelySafeCall execution.
     *
     * @param from Sender on the other chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param validUntilBlockNumber Absolute L1 block number by which the message must be received (0 = no deadline).
     * @param nonce Message nonce (must match receivedNonce).
     * @param message Message payload.
     */
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 validUntilBlockNumber,
        uint256 nonce,
        bytes calldata message
    ) external;
    /**
     * @notice Retries a previously failed message. Anyone can call with the original params.
     * @dev Requires message status == Failed. Uses full gasleft() instead of executeGasLimit.
     *
     * @param from Sender on the other chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param validUntilBlockNumber Absolute L1 block number by which the message must be received (0 = no deadline).
     * @param nonce Message nonce.
     * @param message Message payload.
     */
    function receiveFailedMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 validUntilBlockNumber,
        uint256 nonce,
        bytes calldata message
    ) external;
}

/**
 * @title IFluentBridge
 * @dev Core bridge interface: message lifecycle (send, receive, retry), state queries, and status tracking.
 */
interface IFluentBridge is IFluentBridgeErrors, IFluentBridgeEvents, IFluentBridgeWrite {
    /**
     * @dev Configuration parameters for bridge initialization.
     */
    struct InitConfiguration {
        /// @dev Address authorized to perform admin actions.
        address adminRole;
        /// @dev Address authorized to pause the contract.
        address pauserRole;
        /// @dev Address authorized to relay messages.
        address relayerRole;
        /// @dev Address of the bridge contract on the other chain.
        address otherBridge;
    }

    /**
     * @dev Describes the status of a cross-chain message.
     */
    enum MessageStatus {
        /// @dev Message has not been received yet.
        None,
        /// @dev Message execution reverted; eligible for retry via {receiveFailedMessage}.
        Failed,
        /// @dev Message executed successfully.
        Success
    }

    // ============ Functions ============

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
}
