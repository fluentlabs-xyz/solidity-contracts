// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {MerkleTree} from "../../libraries/MerkleTree.sol";

import {IFluentBridge} from "./IFluentBridge.sol";
import {L2BlockHeader} from "../rollup/IRollupTypes.sol";

/**
 * @title IL1FluentBridge
 * @author Fluent Labs
 * @dev Interface for the L1 bridge contract.
 */
interface IL1FluentBridge {
    // ============ Errors ============

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
     * @notice Sent-message cursor cannot advance by `count` — not enough unconsumed messages remain.
     * @dev selector: 0xc743a919
     */
    error InvalidAdvanceCount(uint256 count, uint256 queueSize);

    /**
     * @notice Rewind target is greater than the current sent-message consume cursor.
     * @dev selector: 0x3df1aff3
     */
    error InvalidRewindTarget(uint256 newFront, uint256 currentFront);

    /**
     * @notice {getMessageHashesRange} called with `from > to`.
     */
    error InvalidRange(uint64 from, uint64 to);

    /**
     * @notice {getMessageHashesRange} end index exceeds the queue back cursor.
     */
    error RangeOutOfBounds(uint64 to, uint64 back);

    /**
     * @notice {skipExpiredDeposits} called while the head sent message is still fresh.
     */
    error NoExpiredDeposits();

    /**
     * @notice Gas floor reached in {skipExpiredDeposits} loop — call again to continue.
     * @dev selector: 0x1c26714c
     */
    error InsufficientGas();

    /**
     * @notice Rollup batch with index `batchIndex` is not expected status
     * @dev selector: 0x0f36c0b9
     */
    error InvalidBatchStatus(uint256 batchIndex, uint8 provided);

    // ========== Events ==========

    /**
     * @notice Emitted when the address of the rollup contract is updated.
     */
    event RollupUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the L1-owned receive-message deadline is updated.
     */
    event ReceiveMessageDeadlineUpdated(uint256 indexed prevValue, uint256 indexed newValue);

    /**
     * @notice Emitted when the L1-owned deposit processing window is updated.
     */
    event DepositProcessingWindowUpdated(uint256 indexed prevValue, uint256 indexed newValue);

    /**
     * @notice Emitted for each sent message slot skipped by {skipExpiredDeposits}.
     * @param cursor      Slot index that was skipped.
     * @param messageHash Hash of the sent message that will never be consumed by the rollup.
     * @param expiredAt   Frozen processing deadline that this slot missed.
     */
    event DepositSkipped(uint64 indexed cursor, bytes32 indexed messageHash, uint64 expiredAt);

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
     * @notice Returns the L1-owned receive-message deadline snapshotted into outbound L1->L2 messages at send time.
     *         0 disables the deadline.
     */
    function getReceiveMessageDeadline() external view returns (uint256);

    /**
     * @notice Updates the L1-owned receive-message deadline used as the snapshot source for new L1->L2 messages.
     * @dev Existing in-flight messages are never affected — the deadline is frozen at send time via the message hash.
     */
    function setReceiveMessageDeadline(uint256 newReceiveMessageDeadline) external;

    /**
     * @notice Returns the L1-owned deposit processing window snapshotted into outbound
     *         L1->L2 messages at send time. The bridge enforces this as a strict liveness
     *         invariant on the rollup's consume cursor — see {isOldestUnconsumedExpired}.
     *         Always > 0.
     */
    function getDepositProcessingWindow() external view returns (uint64);

    /**
     * @notice Updates the L1-owned deposit processing window used as the snapshot source for
     *         new outbound L1->L2 messages.
     * @dev Existing in-flight messages are never affected — the per-message deadline is frozen
     *      at send time via {_sentMessageProcessByBlock}, mirroring the
     *      {setReceiveMessageDeadline} pattern (commit `7ee9271`).
     */
    function setDepositProcessingWindow(uint256 newDepositProcessingWindow) external;
    /**
     * @notice Get the status of a rollback message by its hash.
     * @param key The hash of the rollback message.
     * @return The status of the rollback message.
     */
    function getRollbackMessage(bytes32 key) external view returns (IFluentBridge.MessageStatus);

    /**
     * @notice Peeks at the sent message hash at the given index without advancing the consume cursor.
     * @param index The index of the message hash to peek at (0-based).
     * @return hash The message hash at the given index.
     */
    function getMessageAt(uint256 index) external view returns (bytes32 hash);

    /**
     * @notice Reads `to - from` consecutive sent-message hashes in a single call.
     * @dev Used by {Rollup-_checkDeposits} to fetch all deposits in a batch with one external
     *      call instead of N per-deposit reads. Saves the external-call overhead per deposit
     *      while preserving the per-deposit SLOAD cost (the bridge does the same SLOAD work
     *      internally — only the call frame is amortized).
     * @param from First slot to read (inclusive).
     * @param to End slot (exclusive). Must be `<=` the current back cursor.
     */
    function getMessageHashesRange(uint64 from, uint64 to) external view returns (bytes32[] memory hashes);

    /**
     * @notice True if the oldest unconsumed sent message has missed its frozen processing
     *         deadline. False if the queue is empty.
     * @dev Used by {Rollup-_rollupCorrupted} as the deposit-liveness corruption signal.
     *      The bridge owns the timing parameter and snapshots; the rollup is a thin consumer.
     */
    function isOldestUnconsumedExpired() external view returns (bool);

    /**
     * @notice Permissionless escape hatch: advance the consume cursor past every
     *         consecutive expired sent message at the head of the queue.
     * @dev    TEMPORARY. Each skipped slot represents a permanently lost user deposit
     *         until the user-initiated cancel/refund mechanism replaces this function.
     */
    function skipExpiredDeposits() external;

    /**
     * @notice Moves the sent-message consume cursor forward by `count`. Callable only by the rollup contract.
     * @dev Used during {Rollup-commitBatch} to pop messages that are included in the accepted batch.
     *      The rollup is responsible for ensuring `count` does not exceed the number of unconsumed messages —
     *      `commitBatch` already prevents over-consuming, so this is upheld by construction.
     * @param count Number of messages to consume (advance the cursor by).
     */
    function advanceSentMessageCursor(uint64 count) external;

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
     * @dev Used during {Rollup-revertBatches} to undo all consumes that belonged to reverted batches.
     *      The rollup is responsible for ensuring `newFront` does not cross any finalized batch boundary —
     *      `revertBatches` already prevents reverting finalized batches, so this is upheld by construction.
     * @param newFront New consume cursor value. Must be `<=` the current cursor.
     */
    function rewindSentMessageCursor(uint64 newFront) external;

    /**
     * @notice Receives and executes a message with Merkle proofs (L1 only; messages from L2 to L1).
     * @param batchIndex Index of the rollup batch containing the message.
     * @param blockHeader L2 block header containing the withdrawal root.
     * @param from Sender on the source chain.
     * @param to Destination on this chain.
     * @param value Value to forward.
     * @param chainId Source chain id.
     * @param validUntilBlockNumber Absolute L1 block number committed in the message hash (0 = no deadline).
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
        uint256 validUntilBlockNumber,
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
     * @param validUntilBlockNumber Absolute L1 block number committed in the message hash (0 = no deadline).
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
        uint256 validUntilBlockNumber,
        uint256 nonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external;

    /**
     * @notice Number of L1→L2 messages waiting to be consumed by the rollup.
     * @return The number of unconsumed messages: `back - front`.
     */
    function getSentMessageQueueSize() external view returns (uint64);

    /**
     * @notice Current sent-message consume cursor (the index of the next message the rollup will consume).
     * @dev The rollup snapshots this value at the start of {Rollup-commitBatch} and rewinds to it
     *      during {Rollup-revertBatches}.
     */
    function getSentMessageCursor() external view returns (uint64);
}
