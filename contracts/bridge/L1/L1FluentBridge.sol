// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {FluentBridge} from "../FluentBridge.sol";
import {Rollup} from "../../rollup/Rollup.sol";

import {MerkleTree} from "../../libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "../../libraries/ExcessivelySafeCall.sol";

import {L2BlockHeader} from "../../interfaces/IRollupTypes.sol";
import {IFluentBridge} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../interfaces/bridge/IL1FluentBridge.sol";

/**
 * @title L1FluentBridge
 * @author Fluent Labs
 *
 * @dev L1 bridge contract for the Fluent bridge that lives on Ethereum.
 */
contract L1FluentBridge is FluentBridge, IL1FluentBridge {
    // ============ Constants ============

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.L1FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant L1_FLUENT_BRIDGE_STORAGE_LOCATION = 0xd6d3cd15e5afa78c26fd085a6164155ff3587cb8c325a04216e6557eff29c700;

    /// @custom:storage-location erc7201:fluent.storage.L1FluentBridgeStorage
    struct L1FluentBridgeStorage {
        /// @dev Status of a rollback execution by message hash.
        mapping(bytes32 => IFluentBridge.MessageStatus) _rollbackMessages;
        /// @dev Rollup contract used for batch finalization and proof verification.
        Rollup _rollup;
        /// @dev Append-only mapping of sent message hashes indexed by sequence number.
        ///      The rollup consumes them in order during {Rollup-acceptNextBatch} via
        ///      {consumeNextSentMessage}; consumed slots are NOT deleted, only the cursor advances.
        mapping(uint256 => bytes32) _sentMessageHashes;
        /// @dev Index of the next slot the bridge will write on send (sequence high water mark).
        uint256 _sentMessageBack;
        /// @dev Index of the next slot the rollup will consume; advances on consume,
        ///      moves backward on {rewindSentMessageCursor} during {Rollup-forceRevertBatch}.
        uint256 _sentMessageFront;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    // ============ Storage accessor ============

    /**
     * @dev Returns the ERC-7201 storage pointer for L1-specific bridge state.
     */
    function _getL1FluentBridgeStorage() private pure returns (L1FluentBridgeStorage storage $) {
        assembly ("memory-safe") {
            $.slot := L1_FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }

    // ============ Modifier ============

    /**
     * @dev Restricts function to be called only by the rollup contract.
     */
    modifier onlyRollup() {
        // Only the bound rollup contract may call queue-consuming functions
        require(msg.sender == getRollup(), OnlyRollup());
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the L1 bridge with base config and rollup address.
     */
    function initialize(bytes calldata data, address newRollup) external initializer {
        // Decode and apply base bridge config (roles, other bridge, gas limit)
        __FluentBridgeStorage_init(data);

        // Bind the rollup contract used for finalization and proof verification
        _setRollup(newRollup);
        // Sent-message cursors are zero-initialized by default — no explicit init required
    }

    // ============ Send hooks ============

    /// @inheritdoc FluentBridge
    function _beforeReceiveMessage(
        address /** from */,
        address /** to */,
        uint256 value,
        uint256 /** chainId */,
        uint256 /** blockNumber */,
        uint256 /** messageNonce */,
        bytes calldata /** message */
    ) internal view override returns (bool) {
        // Ensures the bridge has enough balance to cover the value being sent before allowing the message to be sent.
        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        return true;
    }

    /// @inheritdoc FluentBridge
    /// @dev Records the message hash in the sent-message storage and advances the back cursor.
    function _afterSendMessage(bytes32 messageHash) internal override {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Append at the current back position; cursor advances to the next free slot
        $._sentMessageHashes[$._sentMessageBack] = messageHash;
        unchecked {
            ++$._sentMessageBack;
        }
    }

    // ============ Receive with proof ============

    /// @inheritdoc IL1FluentBridge
    function receiveMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address payable to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external nonReentrant whenNotPaused {
        // Only finalized batches carry valid state roots — reject unfinalized ones
        // The rollup contract tracks batch lifecycle; finalized means SP1-proven or delay-elapsed
        require(Rollup(getRollup()).isBatchFinalized(batchIndex), InvalidBlockProof());
        // Messages originating from this chain cannot be "received" here — that would be a rollback
        // The chainId check differentiates between L2→L1 (receive) and L1→L2 (rollback) flows
        require(chainId != block.chainid, ForbiddenReceiveRollbackMessage());

        // Reconstruct the message hash used as the Merkle leaf in the withdrawal tree
        // All fields are deterministic — anyone can call this function permissionlessly
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        // Prevent double-spend: each message can only be claimed once
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        // Two-level proof: block in batch root, then message in block's withdrawal root
        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        // Prevent re-entrant calls back into the bridge itself
        require(to != address(this), ForbiddenSelfCall());
        // Hook for subclass logic (e.g. deadline checks on L2); false = silently skip
        if (!_beforeReceiveMessage(from, to, value, chainId, blockNumber, messageNonce, message)) return;

        // Execute the cross-chain message with gasleft(), forwarding remaining gas
        // _receiveMessage records the outcome (Success/Failed) in storage
        _receiveMessage(gasleft(), from, to, value, message, messageHash);
    }

    // ============ Rollback ============

    /// @inheritdoc IL1FluentBridge
    /// @dev Verifies two Merkle proofs (block + withdrawal) against the finalized batch,
    ///      then refunds the original sender from locked bridge balance.
    function rollbackMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external nonReentrant whenNotPaused {
        // Rollback requires a finalized batch so the proof anchors to a committed state
        // Without finalization, the withdrawal root is not yet trustworthy
        require(Rollup(getRollup()).isBatchFinalized(batchIndex), InvalidBlockProof());
        // Rollback only applies to messages that originated on THIS chain and failed on L2
        // If chainId == block.chainid, the message was sent FROM here, so rollback is valid
        require(chainId == block.chainid, ForbiddenRollbackReceivedMessage());
        // Verify bridge has enough ETH to refund before spending gas on proof verification
        // This is an early-exit optimization — no point verifying proofs if we cannot pay
        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        // Reconstruct the same hash that was included in the L2 withdrawal root
        // Encoding is deterministic so the hash is reproducible by anyone
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        // Guard against replaying a message that was already successfully received
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());
        // Guard against double-claiming the same rollback refund
        require(getRollbackMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        // Verify two Merkle proofs: block inclusion in batch, message inclusion in block
        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        // Execute the refund transfer back to the original sender
        _rollbackMessage(gasleft(), from, to, value, blockNumber, messageNonce, message, messageHash);
    }

    /**
     * @dev Verifies block inclusion in the batch root and message inclusion in the withdrawal root via two Merkle proofs.
     */
    function _verifyWithdrawal(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof,
        bytes32 messageHash
    ) internal view {
        // Reject empty headers — a zero hash means the block is uninitialized or invalid
        // This protects against submitting proofs against a placeholder header
        require(blockHeader.blockHash != bytes32(0), ZeroValueNotAllowed("blockHeader.blockHash"));
        // Withdrawal root must exist for the proof to have any meaning
        // A zero withdrawal root means the block had no outbound messages
        require(blockHeader.withdrawalRoot != bytes32(0), ZeroValueNotAllowed("withdrawalRoot"));

        // First proof: verify that this L2 block is part of the finalized batch
        // The leaf is the hash of the full block header fields
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(getRollup()).getBatch(batchIndex).batchRoot,
            keccak256(
                abi.encodePacked(blockHeader.previousBlockHash, blockHeader.blockHash, blockHeader.withdrawalRoot, blockHeader.depositRoot)
            ),
            blockProof.nonce,
            blockProof.proof
        );
        // Revert if the block header is not part of the committed batch
        require(blockValid, InvalidBlockProof());

        // Second proof: verify the message hash is a leaf in this block's withdrawal tree
        // This binds the specific message to a specific finalized L2 block
        bool withdrawalValid = MerkleTree.verifyMerkleProof(
            blockHeader.withdrawalRoot,
            messageHash,
            withdrawalProof.nonce,
            withdrawalProof.proof
        );
        // Revert if the message hash is not part of this block's withdrawal tree
        require(withdrawalValid, InvalidWithdrawalProof());
    }

    /**
     * @dev Sends ETH back to the original sender (`from`) via ExcessivelySafeCall. Records rollback status and emits event.
     */
    function _rollbackMessage(
        uint256 gasLimit,
        address from,
        address /*to*/,
        uint256 value,
        uint256 /*blockNumber*/,
        uint256 /*messageNonce*/,
        bytes calldata /*message*/,
        bytes32 messageHash
    ) internal {
        // Guard against the bridge refunding itself — `from` is set to `msg.sender` in
        // `sendMessage`, so this can only happen if the bridge itself originated the message
        require(from != address(this), ForbiddenSelfCall());

        // `message` is intentionally not forwarded to `from`.
        // The calldata was encoded for `to` on L2 — `from` is the original sender and was never
        // designed to receive it. Forwarding arbitrary calldata to an unprepared contract would
        // create an uncontrolled external call and a reentrancy vector.
        // Rollback is ETH-only; ERC-20 or other asset recovery is the responsibility of a
        // protocol-layer wrapper that exposes its own claimRollback(messageHash) function.
        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(from, value, "", gasLimit);
        // Record outcome so the same rollback cannot be claimed again
        // Success means the ETH transfer landed; Failed means the recipient reverted
        _getL1FluentBridgeStorage()._rollbackMessages[messageHash] = success
            ? IFluentBridge.MessageStatus.Success
            : IFluentBridge.MessageStatus.Failed;

        // Emit event with the transfer result and any return data for debugging
        emit ReceivedMessageRollback(messageHash, success, data);
    }

    // ============ Sent-message cursor ============

    /// @inheritdoc IL1FluentBridge
    function consumeNextSentMessage() public onlyRollup returns (bytes32 hash) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Reverts when the rollup tries to consume more deposits than have been sent
        require($._sentMessageFront < $._sentMessageBack, SentMessageQueueEmpty());
        hash = $._sentMessageHashes[$._sentMessageFront];
        // Persistent semantics: the slot is NOT deleted — only the cursor advances.
        // {Rollup-forceRevertBatch} relies on this to rewind without re-sending the data.
        unchecked {
            ++$._sentMessageFront;
        }
    }

    /// @inheritdoc IL1FluentBridge
    function rewindSentMessageCursor(uint256 newFront) public onlyRollup {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Monotonically backward only — the rollup is responsible for ensuring the
        // target stays at or above any finalized boundary, since finalized batches
        // cannot be reverted by {Rollup-forceRevertBatch}.
        require(newFront <= $._sentMessageFront, InvalidRewindTarget(newFront, $._sentMessageFront));
        $._sentMessageFront = newFront;
    }

    // ============ Views ============

    /// @inheritdoc IL1FluentBridge
    function getRollbackMessage(bytes32 key) public view returns (IFluentBridge.MessageStatus) {
        // Returns None if never rolled back, Success/Failed based on ETH transfer outcome
        return _getL1FluentBridgeStorage()._rollbackMessages[key];
    }

    /// @inheritdoc IL1FluentBridge
    function getSentMessageQueueSize() public view returns (uint256) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Number of L1→L2 messages waiting to be consumed by the rollup
        return $._sentMessageBack - $._sentMessageFront;
    }

    /// @inheritdoc IL1FluentBridge
    function getSentMessageCursor() public view returns (uint256) {
        // Current consume cursor — the rollup snapshots this at acceptNextBatch
        // and rewinds to a saved snapshot during forceRevertBatch
        return _getL1FluentBridgeStorage()._sentMessageFront;
    }

    /// @inheritdoc IL1FluentBridge
    function getRollup() public view returns (address) {
        // Cast the typed Rollup reference back to address for external consumers
        return address(_getL1FluentBridgeStorage()._rollup);
    }

    // ============ Admin ============

    /// @inheritdoc IL1FluentBridge
    function setRollup(address newRollup) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated: only the multi-sig can rebind the rollup contract
        _setRollup(newRollup);
    }

    /**
     * @dev Validates and stores the rollup address. Reverts on zero address or non-empty queue.
     */
    function _setRollup(address newRollup) internal {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Zero address would break all finalization and proof verification calls
        require(newRollup != address(0), ZeroAddressNotAllowed("rollup"));
        // Changing the rollup while messages are queued would orphan them
        // because the new rollup would not know about pending messages
        require($._sentMessageBack == $._sentMessageFront, QueueNotEmpty());
        // Emit old and new addresses for off-chain monitoring before writing
        emit RollupUpdated(getRollup(), newRollup);
        // Store the typed Rollup reference to avoid casting on every call
        $._rollup = Rollup(newRollup);
    }
}
