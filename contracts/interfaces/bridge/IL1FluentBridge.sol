// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {MerkleTree} from "../../libraries/MerkleTree.sol";

import {IFluentBridge} from "./IFluentBridge.sol";
import {L2BlockHeader} from "../IRollupTypes.sol";

/**
 * @title IL1FluentBridge
 * @author Fluent Labs
 * @dev Interface for the L1 bridge contract.
 */
interface IL1FluentBridge {
    // ---------------------------
    // ========= Errors ==========
    // ---------------------------

    /**
     * @notice Caller is not the configured rollup contract.
     * @dev selector: 0x3c2d9939
     */
    error OnlyRollup();
    /**
     * @notice Receive-with-proof attempted on the same chain that originated the message.
     * @dev selector: 0x902726d9
     */
    error ForbiddenReceiveRollbackMessage();
    /**
     * @notice Rollback-with-proof attempted on the wrong chain for the encoded source chainId.
     * @dev selector: 0x45aa65c8
     */
    error ForbiddenRollbackReceivedMessage();
    /**
     * @notice Encoded rollback data does not match the expected message hash.
     * @dev selector: 0x2bbc9fe6
     */
    error RollbackMessageMismatch();
    /**
     * @notice Rollup batch is not approved or supplied block proof is invalid.
     * @dev selector: 0xcdb93653
     */
    error InvalidBlockProof();
    /**
     * @notice Withdrawal Merkle proof does not prove the message hash under the batch root.
     * @dev selector: 0xb86abc9c
     */
    error InvalidWithdrawalProof();
    /**
     * @notice Attempted to unset rollup while the outbound message queue is non-empty.
     * @dev selector: 0x83f48206
     */
    error QueueNotEmpty();
    // ========== Events ==========

    /**
     * @notice Emitted when the address of the rollup contract is updated.
     */
    event RollupUpdated(address indexed prevValue, address indexed newValue);

    // ========== Functions ==========

    /**
     * @notice Get the address of the rollup contract that lives on L1 and
     *         is used to validate L2 batches and enable proof-based L2 to L1 message delivery.
     * @return The address of the rollup contract.
     */
    function getRollup() external view returns (address);
    /**
     * @notice Update the address of the rollup contract that lives on L1 and
     *         is used to validate L2 batches and enable proof-based L2 to L1 message delivery.
     * @param newRollup The address of the rollup contract.
     */
    function setRollup(address newRollup) external;
    /**
     * @notice Get the status of a rollback message by its hash.
     * @param key The hash of the rollback message.
     * @return The status of the rollback message.
     */
    function getRollbackMessage(bytes32 key) external view returns (IFluentBridge.MessageStatus);
    /**
     * @notice Dequeues the next sent message hash for rollup processing. Callable only by the rollup contract.
     * @return messageHash The next message hash in the queue.
     * @return blockNumber The block number when the message was sent and enqueued.
     */
    function popSentMessage() external returns (bytes32, uint256);

    /**
     * @notice Re-enqueues a message hash at the front of the sent-message queue. Callable only by the rollup contract.
     * @dev Used during {Rollup-forceRevertBatch} to restore deposits that were consumed by a batch which is being reverted.
     *      The restored entry receives a fresh block number so the freshness deadline is reset.
     * @param messageHash The message hash to restore.
     */
    function pushSentMessage(bytes32 messageHash) external;

    /**
     * @notice Receives and executes a message with Merkle proofs (L1 only; messages from L2 to L1).
     * @param batchIndex Index of the rollup batch containing the message.
     * @param blockHeader L2 block header containing the withdrawal root.
     * @param from Sender on the source chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param blockNumber Block number on source chain.
     * @param nonce Message nonce.
     * @param message Message payload.
     * @param withdrawalProof Merkle proof for the withdrawal (message hash) against withdrawalRoot.
     * @param blockProof Merkle proof for the block header against the batch root.
     */
    function receiveMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address payable to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external;

    /**
     * @notice Processes a rollback with Merkle proofs (L1 only; refunds sender when message was not received on L2).
     * @dev Can only be used on the **L1 side** to refund the original sender when a message was not successfully received on L2.
     * @param batchIndex Index of the rollup batch.
     * @param blockHeader L2 block header containing the withdrawal root.
     * @param from Original sender (refund recipient).
     * @param to Original destination (unused for refund).
     * @param value Value to refund.
     * @param chainId Source chain id.
     * @param blockNumber Block number on source chain.
     * @param nonce Message nonce.
     * @param message Message payload (for hash).
     * @param withdrawalProof Merkle proof for the rollback leaf against withdrawalRoot.
     * @param blockProof Merkle proof for the block header against the batch root.
     */
    function rollbackMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external;

    /**
     * @notice Number of messages in the L1 sent-message queue awaiting rollup consumption.
     * @return The current queue depth.
     */
    function getSentMessageQueueSize() external view returns (uint256);
}
