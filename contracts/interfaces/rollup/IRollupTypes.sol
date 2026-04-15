// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @dev Batch lifecycle: None → Committed → Submitted → Preconfirmed → Finalized.
 *      Challenged branches from any post-DA status (Submitted, Preconfirmed) when a
 *      block or batch-root dispute is opened, and restores back to the previous status
 *      ({BatchRecord-statusBeforeChallenge}) once all disputes resolve.
 *      Corrupted is a computed state — triggered by DA/preconfirm/challenge deadline
 *      expiry or by deposit liveness violation on the bridge.
 */
enum BatchStatus {
    /// @dev Initial state, batch does not exist.
    None,
    /// @dev Sequencer submitted the batchRoot via {Rollup-commitBatch}; waiting for blob submission.
    Committed,
    /// @dev All expected blobs are in DA; eligible for preconfirmation, block challenge,
    ///      or batch-root challenge.
    Submitted,
    /// @dev Nitro signature verified; eligible for finalization, block challenge, or
    ///      batch-root challenge.
    Preconfirmed,
    /// @dev At least one block or batch-root dispute is open. Restored to
    ///      {BatchRecord-statusBeforeChallenge} when all disputes resolve.
    Challenged,
    /// @dev Challenge period passed, batch is permanently accepted.
    Finalized
}

/**
 * @dev Committed L2 block header submitted by the sequencer.
 */
struct L2BlockHeader {
    /// @dev Hash of the previous block. Enforces correct block sequencing.
    bytes32 previousBlockHash;
    /// @dev Hash of the current block's contents.
    bytes32 blockHash;
    /// @dev Merkle root of L2→L1 withdrawals in this block (binds Nitro / SP1 verification).
    bytes32 withdrawalRoot;
    /// @dev Merkle root of L1→L2 deposit messages in this block.
    bytes32 depositRoot;
    /// @dev Number of L1→L2 deposits processed by this block.
    uint16 depositCount;
}

/**
 * @dev Per-block deposit bundle consumed from the L1 bridge during batch submission.
 *      Parallel-array convention with the L2 block headers reconstructed from blob DA;
 *      block-binding stays implicit and is enforced transitively by {Rollup-challengeBlock}
 *      against {L2BlockHeader-depositRoot}.
 */
struct BlockDeposit {
    bytes32 depositRoot;
    uint16 depositCount;
}

/**
 * @dev Packed per-batch state record. All batch-lifecycle timing windows are
 *      snapshotted at {Rollup-commitBatch} so later admin updates do not retroactively
 *      affect in-flight batches.
 */
struct BatchRecord {
    /// @dev Merkle root of L2 block headers for this batch.
    bytes32 batchRoot;
    // ─── Slot 2: 4 + 1 + 1 + 8 + 3 + 3 + 3 + 3 + 3 = 29 bytes used, 3 bytes free ───
    /// @dev L1 block number recorded when {Rollup-commitBatch} is called.
    uint32 acceptedAtBlock;
    /// @dev Number of blobs the sequencer committed to at submission time.
    uint8 expectedBlobs;
    /// @dev Current lifecycle state of this batch.
    BatchStatus status;
    /// @dev Snapshot of {L1FluentBridge-getSentMessageCursor} at the start of submission.
    ///      Used by {Rollup-revertBatches} to rewind the bridge consume cursor exactly
    ///      to the position it held before this batch consumed any deposits.
    uint64 sentMessageCursorStart;
    /// @dev Blob-submission window snapshotted from rollup config at submission time. Always > 0.
    uint24 submitBlobsWindowSnapshot;
    /// @dev Preconfirmation window snapshotted from rollup config at submission time. Always > 0.
    uint24 preconfirmationWindowSnapshot;
    /// @dev Challenge window snapshotted from rollup config at submission time. Always > 0.
    uint24 challengeWindowSnapshot;
    /// @dev Finalization delay snapshotted from rollup config at submission time. Always > 0.
    uint24 finalizationDelaySnapshot;
    /// @dev Number of L2 blocks in this batch. Sequencer-claimed at submit; bound to actual
    ///      Merkle leaf count via {Rollup-resolveBatchRootChallenge}.
    uint24 numberOfBlocks;
}

/**
 * @dev State record for an active block challenge.
 */
struct ChallengeRecord {
    /// @dev Index of the batch containing the challenged block.
    uint256 batchIndex;
    /// @dev ETH deposit locked by the challenger.
    uint256 deposit;
    /// @dev Previous status of the batch.
    BatchStatus previousStatus;
    /// @dev Address of the challenger.
    address challenger;
    /// @dev L1 block number by which the challenge must be resolved.
    uint256 deadline;
}

/**
 * @dev Initialization parameters passed to `initialize()`.
 */
struct InitConfiguration {
    // ─── Roles ───
    /// @dev Default admin, receives DEFAULT_ADMIN_ROLE
    address admin;
    /// @dev EMERGENCY_ROLE recipient; falls back to admin if zero
    address emergency;
    /// @dev SEQUENCER_ROLE recipient; falls back to admin if zero
    address sequencer;
    /// @dev CHALLENGER_ROLE recipient; falls back to admin if zero
    address challenger;
    /// @dev PROVER_ROLE recipient; falls back to admin if zero
    address prover;
    /// @dev PRECONFIRMATION_ROLE recipient; falls back to admin if zero
    address preconfirmationRole;
    // ─── Contracts ───
    /// @dev SP1 verifier contract for ZK proof validation
    address sp1Verifier;
    /// @dev Initial Nitro verifier to whitelist; zero to skip
    address nitroVerifier;
    /// @dev L1 FluentBridge contract address
    address bridge;
    // ─── Keys ───
    /// @dev SP1 program verification key
    bytes32 programVKey;
    /// @dev Genesis L2 block hash; anchors chain state before the first batch
    bytes32 genesisBlockHash;
    // ─── Parameters ───
    /// @dev ETH deposit required to open a challenge
    uint256 challengeDepositAmount;
    /// @dev Batch-wide challenge window in L1 blocks from acceptance; shared deadline for submission and resolution
    uint256 challengeWindow;
    /// @dev Minimum L1 blocks after acceptance before finalization
    uint256 finalizationDelay;
    /// @dev ETH reward paid to challengers during force revert
    uint256 incentiveFee;
    /// @dev Max L1 blocks after acceptance for blob submission; must be > 0
    uint256 submitBlobsWindow;
    /// @dev Max L1 blocks after acceptance for preconfirmation; must be > 0
    uint256 preconfirmWindow;
}
