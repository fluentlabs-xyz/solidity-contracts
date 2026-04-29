// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {FluentBridge} from "../FluentBridge.sol";
import {Rollup} from "../../rollup/Rollup.sol";

import {MerkleTree} from "../../libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "../../libraries/ExcessivelySafeCall.sol";

import {IRollupErrors} from "../../interfaces/rollup/IRollup.sol";
import {L2BlockHeader, BatchStatus} from "../../interfaces/rollup/IRollupTypes.sol";
import {IFluentBridge, IFluentBridgeRead} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../interfaces/bridge/IL1FluentBridge.sol";

/**
 * @title L1FluentBridge
 * @author Fluent Labs
 *
 * @dev L1 bridge contract for the Fluent bridge that lives on Ethereum.
 */
contract L1FluentBridge is FluentBridge, IL1FluentBridge {
    // ============ Constants ============

    /// @dev Minimum gas required per {skipExpiredDeposits} loop iteration.
    ///      Covers SLOAD (deadline) + SLOAD (hash) + LOG3 (DepositSkipped) + loop overhead.
    uint256 public constant MIN_SKIP_GAS = 50_000;

    /**
     * @dev Maximum deposit acceptance deadline in L1 blocks (~7 days at 12 s/block).
     */
    uint32 public constant MAX_DEPOSIT_PROCESSING_WINDOW = 50_400;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.L1FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant L1_FLUENT_BRIDGE_STORAGE_LOCATION = 0x64776360b34cbf9c591fd7718af261c9ddf17ee353bef9c701b140ff387a6200;

    /// @custom:storage-location erc7201:Fluent.storage.L1FluentBridgeStorage
    struct L1FluentBridgeStorage {
        /// @dev Status of a rollback execution by message hash.
        mapping(bytes32 => IFluentBridge.MessageStatus) _rollbackMessages;
        /// @dev Rollup contract used for batch finalization and proof verification.
        Rollup _rollup;
        /// @dev Append-only mapping of sent message hashes indexed by sequence number.
        ///      The rollup consumes them in order during {Rollup-commitBatch} via
        ///      {consumeNextSentMessage}; consumed slots are NOT deleted, only the cursor advances.
        mapping(uint256 => bytes32) _sentMessageHashes;
        /// @dev Index of the next slot the bridge will write on send (sequence high water mark).
        uint64 _sentMessageBack;
        /// @dev Index of the next slot the rollup will consume; advances on consume,
        ///      moves backward on {rewindSentMessageCursor} during {Rollup-revertBatches}.
        uint64 _sentMessageFront;
        /// @dev L1-owned receive-message deadline snapshotted into outbound L1->L2 messages at send time.
        ///      0 disables the deadline. Owned by L1 so admin updates never retroactively expire messages
        ///      that were already sent under the previous deadline.
        uint64 _receiveMessageDeadline;
        /// @dev L1-owned window: max L1 blocks the rollup is allowed to take to consume a sent
        ///      message before being considered corrupted. Snapshotted into
        ///      {_sentMessageProcessByBlock} at send time so admin updates never retroactively
        ///      shorten in-flight messages. Same lifecycle pattern as {_receiveMessageDeadline}
        ///      (commit `7ee9271`). MUST be > 0 — strict liveness invariant enforced at the setter.
        uint64 _depositProcessingWindow;
        /// @dev Per-message frozen deadline: absolute L1 block by which this slot MUST be
        ///      consumed by the rollup. Computed at send as
        ///      `block.number + _depositProcessingWindow` and never modified.
        mapping(uint64 => uint64) _sentMessageProcessByBlock;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    // ============ Transient storage ============

    /**
     * @dev Batch index stashed during {receiveMessageWithProof} execution so gateways can
     *      consult the originating batch's rollup status via {isCurrentBatchPreconfirmed}.
     *      Zero outside an in-flight proof-based receive.
     *
     *      Lives in EIP-1153 transient storage (TSTORE/TLOAD) rather than regular storage:
     *      its lifetime is strictly one transaction, the EVM clears it automatically at tx
     *      end — so the enclosing function needs no manual cleanup and a revert anywhere
     *      down the call stack cannot leak stale context into a subsequent tx. Also an
     *      order-of-magnitude gas saving over cold/warm SSTOREs on every receive, and it
     *      doesn't consume an ERC-7201 `__gap` slot.
     */
    uint256 private transient _currentBatchIndex;

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

    modifier onlyRollupOrOwner() {
        // Only the bound rollup contract may call queue-consuming functions
        require(msg.sender == getRollup() || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), OnlyRollup());
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
     * @notice Initializes the L1 bridge with base config, rollup address, the L1-owned
     *         receive-message deadline snapshotted into outbound L1->L2 messages at send time,
     *         and the L1-owned deposit processing window snapshotted into per-message
     *         processing deadlines at send time.
     */
    function initialize(
        bytes calldata data,
        address newRollup,
        uint256 receiveMessageDeadline,
        uint256 depositProcessingWindow
    ) external initializer {
        // Decode and apply base bridge config (roles, other bridge, gas limit)
        __FluentBridgeStorage_init(data);

        // Bind the rollup contract used for finalization and proof verification
        _setRollup(newRollup);
        // Snapshot source for future L1->L2 message expiries
        _setReceiveMessageDeadline(receiveMessageDeadline);
        // Snapshot source for future per-message processing deadlines (rollup liveness)
        _setDepositProcessingWindow(depositProcessingWindow);
        // Sent-message cursors are zero-initialized by default — no explicit init required
    }

    // ============ Send hooks ============

    /// @inheritdoc FluentBridge
    function _beforeReceiveMessage(
        address /** from */,
        address /** to */,
        uint256 value,
        uint256 /** chainId */,
        uint256 /** validUntilBlockNumber */,
        uint256 /** messageNonce */,
        bytes calldata /** message */,
        bytes32 /** messageHash */
    ) internal view override returns (bool) {
        // Ensures the bridge has enough balance to cover the value being sent before allowing the message to be sent.
        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        return true;
    }

    /**
     * @dev Returns the L1-owned receive-message deadline snapshotted into new outbound
     *      L1->L2 messages. Overrides the base {FluentBridgeStorageLayout} default of 0.
     */
    function _getReceiveMessageDeadline() internal view override returns (uint256) {
        return _getL1FluentBridgeStorage()._receiveMessageDeadline;
    }

    /**
     * @dev Halts outbound L1->L2 sends while the rollup is in its corruption/safety-halt state.
     *      Mirrors the rollup's own `require(!_rollupCorrupted(), RollupCorrupted())` guard on
     *      state-changing functions (see {Rollup-_rollupCorrupted}) so the bridge does not keep
     *      enqueuing deposits into a rollup that is refusing new batches. Reverts with the
     *      rollup's {IRollupErrors-RollupCorrupted} selector so off-chain monitoring classifies
     *      this the same way as rollup-side rejections.
     */
    function _beforeSendMessage(address /** to */, bytes calldata /** message */) internal view override {
        require(!Rollup(getRollup()).isRollupCorrupted(), IRollupErrors.RollupCorrupted());
    }

    /// @inheritdoc FluentBridge
    /// @dev Records the message hash in the sent-message storage, freezes the per-message
    ///      processing deadline at send time, and advances the back cursor. Admin updates to
    ///      {_depositProcessingWindow} never affect this slot after this point — same
    ///      frozen-at-send invariant as {_receiveMessageDeadline} (commit `7ee9271`).
    function _afterSendMessage(bytes32 messageHash) internal override {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        uint64 back = $._sentMessageBack;
        // Append at the current back position; cursor advances to the next free slot
        $._sentMessageHashes[back] = messageHash;
        // Freeze per-message processing deadline at send time
        $._sentMessageProcessByBlock[back] = uint64(block.number) + $._depositProcessingWindow;
        unchecked {
            ++$._sentMessageBack;
        }
    }

    /**
     * @notice Leverage on 'receiveMessageWithProof()' instead of this function on L1.
     */
    function receiveMessage(
        address /** from */,
        address /** to */,
        uint256 /** value */,
        uint256 /** chainId */,
        uint256 /** validUntilBlockNumber */,
        uint256 /** messageNonce */,
        bytes calldata /** message */
    ) external override onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        revert("NOT_IMPLEMENTED");
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
        uint256 validUntilBlockNumber,
        uint256 messageNonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external nonReentrant onlyRole(RELAYER_ROLE) whenNotPaused {
        // Only finalized batches carry valid state roots — reject unfinalized ones
        // The rollup contract tracks batch lifecycle; finalized means SP1-proven or delay-elapsed
        BatchStatus status = Rollup(getRollup()).getBatch(batchIndex).status;
        require(status == BatchStatus.Finalized || status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(status)));
        // Messages originating from this chain cannot be "received" here — that would be a rollback
        // The chainId check differentiates between L2→L1 (receive) and L1→L2 (rollback) flows
        require(chainId != block.chainid, ForbiddenReceiveRollbackMessage());

        // Reconstruct the message hash used as the Merkle leaf in the withdrawal tree
        // All fields are deterministic — anyone can call this function permissionlessly
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message));
        // Prevent double-spend: each message can only be claimed once
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        // Two-level proof: block in batch root, then message in block's withdrawal root
        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);

        // Keep relayer and proof paths aligned: both consume the same sequential received nonce,
        // otherwise mixed-mode delivery leaves _receivedNonce stale and blocks receiveMessage.
        require(messageNonce == _takeNextReceivedNonce(), MessageReceivedOutOfOrder());
        // Prevent re-entrant calls back into the bridge itself
        require(to != address(this), ForbiddenSelfCall());
        // Hook for subclass logic (e.g. committed expiry check on L2); false = silently skip
        if (!_beforeReceiveMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message, messageHash)) return;
        // Stash the originating batch index for the duration of {_receiveMessage} so the
        // downstream gateway can consult {isCurrentBatchPreconfirmed}. Transient storage
        // (EIP-1153) auto-clears at tx end — no manual reset needed, and a revert anywhere
        // below cannot leak stale context into a later transaction.
        _currentBatchIndex = batchIndex;
        // Execute the cross-chain message with gasleft(), forwarding remaining gas
        // _receiveMessage records the outcome (Success/Failed) in storage
        (bool success, bytes memory data) = _receiveMessage(getExecuteGasLimit(), from, to, value, message, messageHash);
        emit ReceivedMessage(messageHash, success, data);
        // Clear the transient batch index
        _currentBatchIndex = 0;
    }

    /// @inheritdoc IFluentBridgeRead
    /// @dev True iff a proof-based receive is currently executing and the originating batch's
    ///      rollup status is {BatchStatus.Preconfirmed}. Returns false when called outside
    ///      {receiveMessageWithProof} (e.g. by the relayer path, view calls, or on L2).
    function isCurrentBatchPreconfirmed() public view override returns (bool) {
        uint256 idx = _currentBatchIndex;
        // idx == 0 is the sentinel: no proof-based receive is currently in flight.
        // Batch index 0 is the reserved genesis slot on {Rollup}, so a real message can
        // never legitimately reference it — safe to use as the "no context" marker.
        if (idx == 0) return false;
        return Rollup(getRollup()).isBatchPreconfirmed(idx);
    }

    // ============ Rollback ============

    /**
     * @inheritdoc IL1FluentBridge

     * @notice NOT IMPLEMENTED.

     * @dev Rollback of expired L1→L2 deposits is intentionally disabled
     *      for this release. The full flow (batch-finalized check, chainId guard, balance
     *      early-exit, dedup against received/rollback, two Merkle proofs, refund) is
     *      preserved in git history and will be restored together with the user-initiated
     *      cancel/refund mechanism that replaces {skipExpiredDeposits}.
     */
    function rollbackMessageWithProof(
        uint256 /** batchIndex */,
        L2BlockHeader calldata /** blockHeader */,
        address /** from */,
        address /** to */,
        uint256 /** value */,
        uint256 /** chainId */,
        uint256 /** validUntilBlockNumber */,
        uint256 /** messageNonce */,
        bytes calldata /** message */,
        MerkleTree.MerkleProof calldata /** withdrawalProof */,
        MerkleTree.MerkleProof calldata /** blockProof */
    ) external nonReentrant whenNotPaused {
        revert("NOT_IMPLEMENTED");
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
        // {Rollup-revertBatches} relies on this to rewind without re-sending the data.
        unchecked {
            ++$._sentMessageFront;
        }
    }

    /// @inheritdoc IL1FluentBridge
    function getMessageAt(uint256 index) public view returns (bytes32 hash) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // No additional checks due to gas optimization.
        hash = $._sentMessageHashes[index];
    }

    /// @inheritdoc IL1FluentBridge
    function getMessageHashesRange(uint64 from, uint64 to) external view returns (bytes32[] memory hashes) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        require(from <= to, InvalidRange(from, to));
        require(to <= $._sentMessageBack, RangeOutOfBounds(to, $._sentMessageBack));
        uint256 len;
        unchecked {
            len = uint256(to - from);
        }
        hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; ++i) {
            hashes[i] = $._sentMessageHashes[uint256(from) + i];
        }
    }

    /// @inheritdoc IL1FluentBridge
    function isOldestUnconsumedExpired() external view returns (bool) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        uint64 front = $._sentMessageFront;
        if (front == $._sentMessageBack) return false;
        return block.number > $._sentMessageProcessByBlock[front];
    }

    /// @inheritdoc IL1FluentBridge
    /// @dev TODO: replace with user-initiated cancel/refund mechanism.
    function skipExpiredDeposits() external whenNotPaused onlyRole(PAUSER_ROLE) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        uint64 front = $._sentMessageFront;
        uint64 back = $._sentMessageBack;
        require(front < back, SentMessageQueueEmpty());
        require(block.number > uint256($._sentMessageProcessByBlock[front]), NoExpiredDeposits());

        while (front < back && block.number > uint256($._sentMessageProcessByBlock[front])) {
            require(gasleft() >= MIN_SKIP_GAS, InsufficientGas());
            bytes32 messageHash = $._sentMessageHashes[uint256(front)];
            uint64 expiredAt = $._sentMessageProcessByBlock[front];
            emit DepositSkipped(front, messageHash, expiredAt);
            unchecked {
                ++front;
            }
        }
        $._sentMessageFront = front;
    }

    /// @inheritdoc IL1FluentBridge
    function advanceSentMessageCursor(uint64 count) public onlyRollupOrOwner {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Reverts if advancing the cursor would exceed the number of unconsumed messages
        require($._sentMessageFront + count <= $._sentMessageBack, InvalidAdvanceCount(count, getSentMessageQueueSize()));
        // Persistent semantics: the slots are NOT deleted — only the cursor advances.
        // {Rollup-revertBatches} relies on this to rewind without re-sending the data.
        unchecked {
            $._sentMessageFront += count;
        }
    }

    /// @inheritdoc IL1FluentBridge
    function rewindSentMessageCursor(uint64 newFront) public onlyRollup {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Monotonically backward only — the rollup is responsible for ensuring the
        // target stays at or above any finalized boundary, since finalized batches
        // cannot be reverted by {Rollup-revertBatches}.
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
    function getSentMessageQueueSize() public view returns (uint64) {
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        // Number of L1→L2 messages waiting to be consumed by the rollup
        return $._sentMessageBack - $._sentMessageFront;
    }

    /// @inheritdoc IL1FluentBridge
    function getSentMessageCursor() public view returns (uint64) {
        // Current consume cursor — the rollup snapshots this at commitBatch
        // and rewinds to a saved snapshot during revertBatches
        return _getL1FluentBridgeStorage()._sentMessageFront;
    }

    /// @inheritdoc IL1FluentBridge
    function getRollup() public view returns (address) {
        // Cast the typed Rollup reference back to address for external consumers
        return address(_getL1FluentBridgeStorage()._rollup);
    }

    /// @inheritdoc IL1FluentBridge
    function getReceiveMessageDeadline() public view returns (uint256) {
        return _getReceiveMessageDeadline();
    }

    /// @inheritdoc IL1FluentBridge
    function getDepositProcessingWindow() external view returns (uint64) {
        return _getL1FluentBridgeStorage()._depositProcessingWindow;
    }

    // ============ Admin ============

    /// @inheritdoc IL1FluentBridge
    function setRollup(address newRollup) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated: only the multi-sig can rebind the rollup contract
        _setRollup(newRollup);
    }

    /// @inheritdoc IL1FluentBridge
    function setReceiveMessageDeadline(uint256 newReceiveMessageDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReceiveMessageDeadline(newReceiveMessageDeadline);
    }

    /// @inheritdoc IL1FluentBridge
    function setDepositProcessingWindow(uint256 newDepositProcessingWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDepositProcessingWindow(newDepositProcessingWindow);
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

    /**
     * @dev Stores the L1-owned receive-message deadline used as the snapshot source
     *      for future outbound L1->L2 messages. The value is encoded into each message
     *      hash at send time, so existing in-flight messages are never affected by changes.
     *
     *      Must be strictly greater than 0. A zero deadline would make {sendMessage}
     *      produce `validUntilBlockNumber = 0`, which the L2 bridge rejects in
     *      `_beforeReceiveMessage`, silently stranding user funds with no rollback path.
     */
    function _setReceiveMessageDeadline(uint256 newReceiveMessageDeadline) internal {
        require(newReceiveMessageDeadline > 0, InvalidWindowConfig("must be greater than 0"));
        require(newReceiveMessageDeadline <= type(uint64).max, InvalidWindowConfig("exceeds maximum"));
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        emit ReceiveMessageDeadlineUpdated($._receiveMessageDeadline, newReceiveMessageDeadline);
        $._receiveMessageDeadline = uint64(newReceiveMessageDeadline);
    }

    /**
     * @dev Stores the L1-owned deposit processing window used as the snapshot source for
     *      future outbound L1->L2 messages. Each new sent message snapshots
     *      `block.number + window` into {_sentMessageProcessByBlock} at send time and never
     *      re-reads this field afterward, so admin updates affect future messages only.
     *      Same lifecycle pattern as {_setReceiveMessageDeadline} (commit `7ee9271`).
     *
     *      Must be strictly greater than 0. A zero window would make every freshly sent
     *      message instantly expired in the rollup's view.
     */
    function _setDepositProcessingWindow(uint256 newDepositProcessingWindow) internal {
        require(newDepositProcessingWindow > 0, InvalidWindowConfig("must be greater than 0"));
        require(newDepositProcessingWindow <= MAX_DEPOSIT_PROCESSING_WINDOW, InvalidWindowConfig("exceeds maximum"));
        L1FluentBridgeStorage storage $ = _getL1FluentBridgeStorage();
        emit DepositProcessingWindowUpdated($._depositProcessingWindow, newDepositProcessingWindow);
        $._depositProcessingWindow = uint64(newDepositProcessingWindow);
    }
}
