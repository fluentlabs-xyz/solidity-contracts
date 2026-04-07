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
    /**
     * @notice Sent-message cursor cannot advance — no unconsumed messages remain.
     * @dev selector: 0x4875ecb8
     */
    error SentMessageQueueEmpty();
    /**
     * @notice Rewind target is greater than the current sent-message consume cursor.
     * @dev selector: 0x3df1aff3
     */
    error InvalidRewindTarget(uint256 newFront, uint256 currentFront);
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
     * @notice Reads the next sent-message hash for rollup consumption and advances the consume cursor.
     *         Callable only by the rollup contract.
     * @dev Persistent semantics: the underlying slot is not deleted, only the cursor moves forward.
     *      This allows {rewindSentMessageCursor} to undo a consume without re-sending the hash.
     * @return hash The next message hash in send order.
     */
    function consumeNextSentMessage() external returns (bytes32 hash);

    /**
     * @notice Moves the sent-message consume cursor backward to `newFront`. Callable only by the rollup contract.
     * @dev Used during {Rollup-forceRevertBatch} to undo all consumes that belonged to reverted batches.
     *      The rollup is responsible for ensuring `newFront` does not cross any finalized batch boundary —
     *      `forceRevertBatch` already prevents reverting finalized batches, so this is upheld by construction.
     * @param newFront New consume cursor value. Must be `<=` the current cursor.
     */
    function rewindSentMessageCursor(uint256 newFront) external;

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
     * @notice Number of L1→L2 messages waiting to be consumed by the rollup.
     * @return The number of unconsumed messages: `back - front`.
     */
    function getSentMessageQueueSize() external view returns (uint256);

    /**
     * @notice Current sent-message consume cursor (the index of the next message the rollup will consume).
     * @dev The rollup snapshots this value at the start of {Rollup-acceptNextBatch} and rewinds to it
     *      during {Rollup-forceRevertBatch}.
     */
    function getSentMessageCursor() external view returns (uint256);
}
