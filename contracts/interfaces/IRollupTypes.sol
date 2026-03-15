pragma solidity ^0.8.20;

/// @dev Batch lifecycle: None → HeadersSubmitted → Accepted → Preconfirmed → Finalized
///      Challenged branches from Preconfirmed when a block is disputed.
///      Corrupted is a computed state — triggered by DA/preconfirm/challenge deadline expiry.
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

/// @dev Committed L2 block header submitted by the sequencer.
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

/// @dev Packed per-batch state record.
struct BatchRecord {
    /// @dev Merkle root of L2 block headers for this batch.
    bytes32 batchRoot;
    /// @dev L1 block number when the batch was accepted via acceptNextBatch.
    uint64 acceptedAtBlock;
    /// @dev Number of blobs the sequencer committed to at acceptance time.
    uint32 expectedBlobs;
    /// @dev Current lifecycle state of this batch.
    BatchStatus status;
}

/// @dev State record for an active block challenge.
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

/// @dev Initialization parameters passed to `initialize()`.
struct InitConfiguration {
    // ─── Roles ───
    address admin;
    address emergency;
    address sequencer;
    address challenger;
    address prover;
    address preconfirmationRole;
    // ─── Contracts ───
    address sp1Verifier;
    address nitroVerifier;
    address bridge;
    // ─── Keys ───
    bytes32 programVKey;
    bytes32 genesisHash;
    // ─── Parameters ───
    uint256 challengeDepositAmount;
    uint256 challengeBlockCount;
    uint256 approveBlockCount;
    uint256 acceptDepositDeadline;
    uint256 incentiveFee;
    uint256 daDeadlineBlocks;
    uint256 preconfirmDeadlineBlocks;
}
