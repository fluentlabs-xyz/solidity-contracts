// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleTree} from "../../libraries/MerkleTree.sol";

import {IFluentBridge} from "./IFluentBridge.sol";
import {L2BlockHeader} from "../IRollupTypes.sol";

/**
 * @title IL1_FluentBridge
 * @author Fluent Labs
 * @dev Interface for the L1 bridge contract.
 */
interface IL1_FluentBridge {
    // ---------------------------
    // ========= Errors ==========
    // ---------------------------

    /**
     * @notice Caller is not the configured rollup contract.
     */
    error OnlyRollup();
    /**
     * @notice Receive-with-proof attempted on the same chain that originated the message.
     */
    error ForbiddenReceiveRollbackMessage();
    /**
     * @notice Rollback-with-proof attempted on the wrong chain for the encoded source chainId.
     */
    error ForbiddenRollbackReceivedMessage();
    /**
     * @notice Encoded rollback data does not match the expected message hash.
     */
    error RollbackMessageMismatch();
    /**
     * @notice Rollup batch is not approved or supplied block proof is invalid.
     */
    error InvalidBlockProof();
    /**
     * @notice Withdrawal Merkle proof does not prove the message hash under the batch root.
     */
    error InvalidWithdrawalProof();
    /**
     * @notice Attempted to unset rollup while the outbound message queue is non-empty.
     */
    error QueueNotEmpty();
    /**
     * @notice Bridge balance too low to execute rollback refund (locked native on source chain).
     */
    error InsufficientBridgeBalance(uint256 required);

    // ========== Events ==========

    /**
     * @notice Emitted when the address of the rollup contract is updated.
     */
    event RollupUpdated(address indexed prevValue, address indexed newValue);

    // ========== Functions ==========

    /**
     * @notice Get the address of the rollup contract that lives on L1 and
     *         is used to process prove messages from L1 -> L2.
     * @return The address of the rollup contract.
     */
    function getRollup() external view returns (address);
    /**
     * @notice Update the address of the rollup contract that lives on L1 and
     *         is used to process prove messages from L1 -> L2.
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
     * @notice Receives and executes a message with Merkle proofs (L1 only; messages from L2 to L1).
     * @param _batchIndex Index of the rollup batch containing the message.
     * @param _blockHeader L2 block header containing the withdrawal root.
     * @param _from Sender on the source chain.
     * @param _to Destination on this chain.
     * @param _value Value to forward.
     * @param _chainId Source chain id.
     * @param _blockNumber Block number on source chain.
     * @param _nonce Message nonce.
     * @param _message Message payload.
     * @param _withdrawal_proof Merkle proof for the withdrawal (message hash) against withdrawalRoot.
     * @param _block_proof Merkle proof for the block header against the batch root.
     */
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
}
