// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {L2BlockHeader} from "./IRollupTypes.sol";

interface IBridgeErrorCodes {
    /// @dev Caller is not the configured bridge relayer (trusted relayer path).
    error OnlyBridgeAuthority();
    /// @dev Caller is not the configured rollup contract.
    error OnlyRollupAuthority();
    /// @dev Rollup address is unset where a rollup-backed operation is required.
    error OnlyWhenRollupInited();
    /// @dev Message hash has already been processed (duplicate receive or rollback).
    error MessageAlreadyReceived();
    /// @dev Inbound message nonce does not match the expected sequential receivedNonce.
    error MessageReceivedOutOfOrder();
    /// @dev receiveFailedMessage was called for a hash that is not marked as Failed.
    error MessageNotFailed();
    /// @dev Target address is this bridge (self-call) when executing a message or rollback.
    error ForbiddenSelfCall();
    /// @dev Receive-with-proof attempted on the same chain that originated the message.
    error ForbiddenReceiveRollbackedMessage();
    /// @dev Rollback-with-proof attempted on the wrong chain for the encoded source chainId.
    error ForbiddenRollbackReceivedMessage();
    /// @dev Encoded rollback data does not match the expected message hash.
    error RollbackMessageMismatch();
    /// @dev Rollup batch is not approved or supplied block proof is invalid.
    error InvalidBlockProof();
    /// @dev Withdrawal Merkle proof does not prove the message hash under the batch root.
    error InvalidWithdrawalProof();
    /// @dev sendMessage destination is this bridge or the configured otherBridge, which is forbidden.
    error InvalidDestinationAddress();
    /// @dev Operation is disallowed because the bridge is paused.
    error ContractPaused();
    /// @dev Zero address supplied for a required configuration field.
    error ZeroAddressNotAllowed(string field);
    /// @dev Attempted to unset rollup while the outbound message queue is non-empty.
    error QueueNotEmpty();
    /// @dev msg.value does not match the message's native value (receive: caller must supply value; rollback: must be 0).
    error InvalidMessageValue(uint256 expected, uint256 provided);
    /// @dev Bridge balance too low to execute rollback refund (locked native on source chain).
    error InsufficientBridgeBalance(uint256 required);
    /// @dev Zero value supplied for a required configuration field.
    error ZeroValueNotAllowed(string field);
}

interface IFluentBridgeEvents {
    /// @notice Emitted when a message is sent to another chain.
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

    /// @notice Emitted after a cross-chain message hash has been processed.
    /// @dev `successfulCall` is true when the target call succeeded, and false when execution failed
    ///      or when a rollback/timeout path was taken without invoking the target.
    event ReceivedMessage(bytes32 messageHash, bool successfulCall, bytes returnData);

    /// @notice Emitted when a rollback is triggered (message not received on L2 within deadline).
    event RollbackMessage(bytes32 messageHash, uint256 blockNumber);

    /// @notice Emitted after a rollback is executed (refund to sender).
    event ReceivedMessageRollback(bytes32 messageHash, bool successfulCall, bytes returnData);

    /// @notice Emitted when the address of the bridge contract on the other chain is updated.
    event OtherBridgeUpdated(address indexed prevValue, address indexed newValue);

    /// @notice Emitted when the address of the rollup contract is updated.
    event RollupUpdated(address indexed prevValue, address indexed newValue);

    /// @notice Emitted when the address of the L1 block oracle is updated.
    event L1BlockOracleUpdated(address indexed prevValue, address indexed newValue);

    /// @notice Emitted when the number of L1 blocks after which a message becomes eligible for rollback is updated.
    event ReceiveMessageDeadlineUpdated(uint256 indexed prevValue, uint256 indexed newValue);
}

interface IFluentBridge is IBridgeErrorCodes, IFluentBridgeEvents {
    /// @notice Enum describing the status of a cross-chain message.
    enum MessageStatus {
        None,
        Failed,
        Success
    }

    // ---------- Storage / view getters ----------

    /// @notice Next outbound message nonce (incremented on each sendMessage).
    function nonce() external view returns (uint256);

    /// @notice Next expected inbound received message nonce (L2 receiveMessage ordering).
    function receivedNonce() external view returns (uint256);

    /// @notice Number of L1 blocks after which a message becomes eligible for rollback (L2 only; 0 on L1).
    function receiveMessageDeadline() external view returns (uint256);

    /// @notice During receive execution, the address that sent the message on the other chain; otherwise address(0).
    function nativeSender() external view returns (address);

    /// @notice Address of the bridge contract on the other chain.
    function otherBridge() external view returns (address);

    /// @notice Status of a received message by its hash (None, Failed, Success).
    function receivedMessage(bytes32 key) external view returns (MessageStatus);

    /// @notice Status of a rollback execution by message hash.
    function rollbackMessage(bytes32 key) external view returns (MessageStatus);

    /// @notice Rollup contract address (L1 only; address(0) on L2).
    function rollup() external view returns (address);

    /// @notice L1 block oracle used for rollback deadline checks (L2).
    function l1BlockOracle() external view returns (address);

    /// @notice Returns the size of the sent message queue (L1; 0 on L2 when rollup is not set).
    function sentMessageQueueSize() external view returns (uint256);

    // ---------- L1 queue (Rollup) ----------

    /// @notice Dequeues the next sent message hash for rollup processing. Callable only by the rollup contract.
    /// @return The next message hash in the queue.
    function popSentMessage() external returns (bytes32, uint256);

    // ---------- Send / receive ----------

    /**
     * @notice Sends a cross-chain message to the other chain.
     * @param _to Destination address on the target chain.
     * @param _message Calldata payload to deliver.
     */
    function sendMessage(address _to, bytes calldata _message) external payable;

    /// @notice Receives and executes a message with Merkle proofs (L1 only; messages from L2 to L1).
    /// @param _batchIndex Index of the rollup batch containing the message.
    /// @param _blockHeader L2 block header containing the withdrawal root.
    /// @param _from Sender on the source chain.
    /// @param _to Destination on this chain.
    /// @param _value Value to forward.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce.
    /// @param _message Message payload.
    /// @param _withdrawal_proof Merkle proof for the withdrawal (message hash) against withdrawalRoot.
    /// @param _block_proof Merkle proof for the block header against the batch root.
    function receiveMessageWithProof(
        uint256 _batchIndex,
        L2BlockHeader calldata _blockHeader,
        address _from,
        address payable _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        MerkleTree.MerkleProof calldata _withdrawal_proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable;

    /// @notice Processes a rollback with Merkle proofs (L1 only; refunds sender when message was not received on L2).
    /// @dev Can only be used on the **L1 side** to refund the original sender when a message was not successfully received on L2.
    /// @param _batchIndex Index of the rollup batch.
    /// @param _blockHeader L2 block header containing the withdrawal root.
    /// @param _from Original sender (refund recipient).
    /// @param _to Original destination (unused for refund).
    /// @param _value Value to refund.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce.
    /// @param _message Message payload (for hash).
    /// @param _rollback_proof Merkle proof for the rollback leaf against withdrawalRoot.
    /// @param _block_proof Merkle proof for the block header against the batch root.
    function rollbackMessageWithProof(
        uint256 _batchIndex,
        L2BlockHeader calldata _blockHeader,
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        MerkleTree.MerkleProof calldata _rollback_proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable;

    /// @notice Receives and executes a message sent by the bridge authority (L2 only; trusted relayer path).
    /// @param _from Sender on the other chain.
    /// @param _to Destination on this chain.
    /// @param _value Value to forward.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce (must match receivedNonce).
    /// @param _message Message payload.
    function receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external;

    /// @notice Retries execution of a previously failed message (same params as original receive).
    /// @param _from Sender on the other chain.
    /// @param _to Destination on this chain.
    /// @param _value Value to forward.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce.
    /// @param _message Message payload.
    function receiveFailedMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external payable;
}
