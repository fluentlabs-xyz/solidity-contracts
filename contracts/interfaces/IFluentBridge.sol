// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Rollup} from "../rollup/Rollup.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";

interface IBridgeErrorCodes {
    /// @dev Thrown when the caller is not the bridge authority.
    /// @dev Functions used: sendMessage (authorized path), receiveMessage, receiveFailedMessage.
    error OnlyBridgeAuthority();
    /// @dev Thrown when the caller is not the rollup contract.
    /// @dev Functions used: popSentMessage.
    error OnlyRollupAuthority();
    /// @dev Thrown when the rollup is not initialized (e.g. rollback on L2).
    error OnlyWhenRollupInited();
    /// @dev Thrown when the message has already been received (duplicate).
    error MessageAlreadyReceived();
    /// @dev Thrown when the message was received out of order (L2 receiveMessage nonce).
    error MessageReceivedOutOfOrder();
    /// @dev Thrown when retrying a message that is not in Failed status.
    error MessageNotFailed();
    /// @dev Thrown when the destination is the bridge itself or otherBridge (forbidden).
    error ForbiddenSelfCall();
    /// @dev Thrown when receiving a message that was already rollbacked (chainId check).
    error ForbiddenReceiveRollbackedMessage();
    /// @dev Thrown when executing rollback on the wrong chain.
    error ForbiddenRollbackReceivedMessage();
    error RollbackMessageMismatch();
    /// @dev Thrown when the batch is not approved or block proof is invalid.
    error InvalidBlockProof();
    /// @dev Thrown when the withdrawal Merkle proof is invalid.
    error InvalidWithdrawalProof();
    /// @dev Thrown when sendMessage destination is this contract or otherBridge.
    error InvalidDestinationAddress();
    /// @dev Thrown when the contract is paused.
    error ContractPaused();
}

interface IFluentBridge is IBridgeErrorCodes {
    /// @notice Enum describing the status of a cross-chain message.
    enum MessageStatus {
        None,
        Failed,
        Success
    }

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

    /// @notice Emitted after a message is received and executed (success or failure).
    event ReceivedMessage(bytes32 messageHash, bool successfulCall, bytes returnData);

    /// @notice Emitted when a rollback is triggered (message not received on L2 within deadline).
    event RollbackMessage(bytes32 messageHash, uint256 blockNumber);

    /// @notice Emitted after a rollback is executed (refund to sender).
    event ReceivedMessageRollback(bytes32 messageHash, bool successfulCall, bytes returnData);

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

    /// @notice Address authorized to send direct messages (L2 receiveMessage / receiveFailedMessage).
    function bridgeAuthority() external view returns (address);

    /// @notice Rollup contract address (L1 only; address(0) on L2).
    function rollup() external view returns (address);

    /// @notice L1 block oracle used for rollback deadline checks (L2).
    function l1BlockOracle() external view returns (address);

    /// @notice Returns the size of the sent message queue (L1; 0 on L2 when rollup is not set).
    function getQueueSize() external view returns (uint256);

    // ---------- Admin ----------

    /// @notice Sets the address of the bridge contract on the other chain.
    /// @param _otherBridge The address of the bridge on the other chain.
    function setOtherBridge(address _otherBridge) external;

    /// @notice Pauses the bridge (sendMessage, receive, rollback, etc. disabled). Only owner.
    function pause() external;

    /// @notice Unpauses the bridge. Only owner.
    function unpause() external;

    // ---------- L1 queue (Rollup) ----------

    /// @notice Dequeues the next sent message hash for rollup processing. Callable only by the rollup contract.
    /// @return The next message hash in the queue.
    function popSentMessage() external returns (bytes32);

    // ---------- Send / receive ----------

    /// @notice Sends a cross-chain message to the other chain.
    /// @param _to Destination address on the target chain.
    /// @param _message Calldata payload to deliver.
    function sendMessage(address _to, bytes calldata _message) external payable;

    /// @notice Receives and executes a message with Merkle proofs (L1 only; messages from L2).
    /// @param _batchIndex Index of the rollup batch containing the message.
    /// @param _commitmentBatch Block commitment for the batch.
    /// @param _from Sender on the source chain.
    /// @param _to Destination on this chain.
    /// @param _value Value to forward.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce.
    /// @param _message Message payload.
    /// @param _withdrawal_proof Merkle proof for the withdrawal (message hash).
    /// @param _block_proof Merkle proof for the block commitment.
    function receiveMessageWithProof(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
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
    /// @param _batchIndex Index of the rollup batch.
    /// @param _commitmentBatch Block commitment for the batch.
    /// @param _from Original sender (refund recipient).
    /// @param _to Original destination (unused for refund).
    /// @param _value Value to refund.
    /// @param _chainId Source chain id.
    /// @param _blockNumber Block number on source chain.
    /// @param _nonce Message nonce.
    /// @param _message Message payload (for hash).
    /// @param _rollback_proof Merkle proof for the rollback leaf.
    /// @param _block_proof Merkle proof for the block commitment.
    function rollbackMessageWithProof(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
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
    ) external payable;

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
