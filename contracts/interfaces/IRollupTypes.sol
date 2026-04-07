// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @dev Batch lifecycle: None → HeadersSubmitted → Accepted → Preconfirmed → Finalized.
 *      Challenged branches from Preconfirmed when a block is disputed.
 *      Corrupted is a computed state — triggered by DA/preconfirm/challenge deadline expiry.
 */
enum BatchStatus {
    /// @dev Initial state, batch does not exist.
    None,
    /// @dev Sequencer submitted L2 block headers, waiting for blob submission.
    HeadersSubmitted,
    /// @dev All blobs submitted, waiting for preconfirmation.
    Accepted,
    /// @dev Nitro signature verified, eligible for challenge or finalization.
    Preconfirmed,
    /// @dev At least one block is being challenged.
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
    /// @dev Merkle root of L2→L1 withdrawal messages in this block.
    bytes32 withdrawalRoot;
    /// @dev Merkle root of L1→L2 deposit messages in this block.
    bytes32 depositRoot;
    /// @dev Number of L1→L2 deposits received in this block.
    uint256 depositCount;
}

/**
 * @dev Packed per-batch state record. Layout (2 storage slots):
 *      - Slot 1: bytes32 batchRoot (32)
 *      - Slot 2: uint64 acceptedAtBlock (8) + uint32 expectedBlobs (4) + uint8 status (1)
 *                + 3 × uint48 window snapshots (18) = 31 bytes
 *
 *      All batch-level timing windows are snapshotted at {IRollupWrite-acceptNextBatch}
 *      so later admin updates do not retroactively affect in-flight batches. The window
 *      snapshots are stored as uint48 (max ≈ 2.8e14 blocks) to keep the whole record in
 *      two storage slots — the rollup admin setters enforce the same upper bound.
 */
struct BatchRecord {
    /// @dev Merkle root of L2 block headers for this batch.
    bytes32 batchRoot;
    /// @dev L1 block number recorded when {IRollupWrite-acceptNextBatch} is called (status becomes HeadersSubmitted).
    uint64 acceptedAtBlock;
    /// @dev Number of blobs the sequencer committed to at acceptance time.
    uint32 expectedBlobs;
    /// @dev Current lifecycle state of this batch.
    BatchStatus status;
    /// @dev Blob-submission window snapshotted from rollup config at acceptance time; 0 disables the deadline.
    uint48 submitBlobsWindowSnapshot;
    /// @dev Challenge window snapshotted from rollup config at acceptance time.
    uint48 challengeWindowSnapshot;
    /// @dev Finalization delay snapshotted from rollup config at acceptance time.
    uint48 finalizationDelaySnapshot;
}

/**
 * @dev State record for an active block challenge.
 */
struct ChallengeRecord {
    /// @dev Index of the batch containing the challenged block.
    uint256 batchIndex;
    /// @dev ETH deposit locked by the challenger.
    uint256 deposit;
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
    /// @dev Genesis block hash stored at batch index 0
    bytes32 genesisHash;
    // ─── Parameters ───
    /// @dev ETH deposit required to open a challenge
    uint256 challengeDepositAmount;
    /// @dev Batch-wide challenge window in L1 blocks from acceptance; shared deadline for submission and resolution
    uint256 challengeWindow;
    /// @dev Minimum L1 blocks after acceptance before finalization
    uint256 finalizationDelay;
    /// @dev ETH reward paid to challengers during force revert
    uint256 incentiveFee;
    /// @dev Max L1 blocks after acceptance for blob submission; 0 = disabled
    uint256 submitBlobsWindow;
    /// @dev Hard cap on the total deposit count across all block headers in a batch; enforced in
    ///      {IRollupWrite-acceptNextBatch}. Must be non-zero. Bounds per-batch acceptance work
    ///      now that the preconfirm deadline no longer indirectly caps it.
    uint256 maxDepositsPerBatch;
    /// @dev Max batch size to revert at once
    uint256 maxForceRevertBatchSize;
}
