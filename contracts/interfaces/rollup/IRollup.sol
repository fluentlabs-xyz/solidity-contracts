// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {L2BlockHeader, BatchRecord, ChallengeRecord, BlockDeposit} from "./IRollupTypes.sol";
import {MerkleTree} from "../../libraries/MerkleTree.sol";

/**
 * @title IRollupErrors
 * @dev Custom errors for the rollup contract.
 */
interface IRollupErrors {
    /**
     * @notice Rollup is in a corrupted state — all state-changing functions are blocked.
     * @dev selector: 0x5a92338c
     */
    error RollupCorrupted();

    /**
     * @notice Thrown when emergencyRevokeRole is called with a non-operational role.
     * @dev selector: 0xaecb755c
     */
    error InvalidOperationalRole(bytes32 role);

    /**
     * @notice Block's previousBlockHash does not match the expected chain tip.
     * @dev selector: 0x56bb540a
     */
    error WrongPreviousBlockHash(bytes32 expected, bytes32 provided);

    /**
     * @notice Deposit root for a block in the BlockDeposit array does not match the
     *         actual unconsumed bridge messages at the corresponding range.
     * @param expected The expected deposit root.
     * @param provided The provided deposit root.
     * @dev selector: 0x9f29a87b
     */
    error DepositRootMismatch(bytes32 expected, bytes32 provided);

    /**
     * @notice Batch has already been finalized and cannot be modified.
     * @dev selector: 0xa99bd781
     */
    error BatchAlreadyFinalized(uint256 batchIndex);

    /**
     * @notice Batch root has already been proven.
     * @dev selector:
     */
    error BatchRootAlreadyProven(uint256 batchIndex);

    /**
     * @notice Block commitment has already been proven.
     * @dev selector: 0x5fbe7d51
     */
    error BlockAlreadyProven(bytes32 commitment);

    /**
     * @notice Block commitment has already been challenged.
     * @dev selector: 0xd62ec379
     */
    error BlockAlreadyChallenged(bytes32 commitment);

    /**
     * @notice Block commitment has not been challenged — cannot resolve.
     * @dev selector: 0x4615a600
     */
    error BlockNotChallenged(bytes32 commitment);

    /**
     * @notice Block commitment has not been proven.
     * @dev selector: 0x0e68d7dc
     */
    error BlockNotProven(bytes32 commitment);

    /**
     * @notice Challenge deposit does not match the required amount.
     * @dev selector: 0x5ad2069b
     */
    error IncorrectChallengeDeposit(uint256 required, uint256 provided);

    /**
     * @notice Native ETH transfer to recipient failed.
     * @dev selector: 0xdea95fba
     */
    error EthTransferFailed(address recipient, uint256 amount);

    /**
     * @notice Block sequence is invalid — block[i].blockHash != block[i+1].previousBlockHash.
     * @dev selector: 0xd2aeda88
     */
    error InvalidBlockSequence(uint256 index, bytes32 currentHash, bytes32 nextPrevHash);

    /**
     * @notice Merkle tree construction requires at least one leaf.
     * @dev selector: 0x798e25ff
     */
    error NoLeavesProvided();

    /**
     * @notice Caller has no balance available for withdrawal.
     * @dev selector: 0xd0d04f60
     */
    error NothingToWithdraw();

    /**
     * @notice msg.value is insufficient to cover challenger incentive fees for force revert.
     * @dev selector: 0xdbbfb945
     */
    error NotEnoughValueIncentiveFee(uint256 value, uint256 incentiveFee);

    /**
     * @notice Merkle proof for the block header is invalid.
     * @dev selector: 0xcdb93653
     */
    error InvalidBlockProof();

    /**
     * @notice Admin address (in {InitConfiguration}) must not be zero.
     * @dev selector: 0x7289db0e
     */
    error ZeroAdmin();

    /**
     * @notice Bridge address must not be zero.
     * @dev selector: 0x361106cd
     */
    error ZeroBridge();

    /**
     * @notice SP1 verifier address must not be zero.
     * @dev selector: 0xf0500170
     */
    error ZeroSp1Verifier();

    /**
     * @notice Nitro verifier address (in {InitConfiguration}) must not be zero.
     * @dev selector: 0xcc77d1a1
     */
    error ZeroNitroVerifier();

    /**
     * @notice Nitro verifier target of {addNitroVerifier} / {removeNitroVerifier} must not be zero.
     * @dev selector: 0x4a8bdce3
     */
    error ZeroVerifier();

    /**
     * @notice {revertBatches} called with `toBatchIndex == 0` — genesis cannot be reverted.
     * @dev selector: 0x1b7028dd
     */
    error ZeroToBatchIndex();

    /**
     * @notice {commitBatch} called with zero `fromBlockHash`.
     * @dev selector: 0xf3ad5080
     */
    error ZeroFromBlockHash();

    /**
     * @notice {commitBatch} called with zero `toBlockHash`.
     * @dev selector: 0x70675c6d
     */
    error ZeroToBlockHash();

    /**
     * @notice {commitBatch} called with `numberOfBlocks == 0`.
     * @dev selector: 0xcbe1d68a
     */
    error ZeroNumberOfBlocks();

    /**
     * @notice {commitBatch} called with `expectedBlobsCount == 0`.
     * @dev selector: 0x29686fea
     */
    error ZeroExpectedBlobsCount();

    /**
     * @notice {submitBlobs} called with `numBlobs == 0`.
     * @dev selector: 0x7ac42834
     */
    error ZeroNumBlobs();

    /**
     * @notice BLOBHASH opcode returned zero for the requested index (out of range).
     * @dev selector: 0x3d4b5f62
     */
    error ZeroBlobHash();

    /**
     * @notice Genesis block hash (in {InitConfiguration}) must not be zero.
     * @dev selector: 0xd393efc3
     */
    error ZeroGenesisBlockHash();

    /**
     * @notice SP1 program verification key must not be zero.
     * @dev selector: 0x4bf2a2d8
     */
    error ZeroProgramVKey();

    /**
     * @notice gasLeft guard must not be zero.
     * @dev selector: 0xeb7df3d4
     */
    error ZeroGasLeft();

    /**
     * @notice gasLeft guard exceeds MAX_GAS_LEFT.
     * @dev selector: 0x9508b2f6
     */
    error GasLeftOutOfBounds();

    /**
     * @notice challengeDepositAmount is below MIN_CHALLENGE_DEPOSIT_AMOUNT.
     * @dev selector: 0xd1724dd8
     */
    error ChallengeDepositAmountOutOfBounds();

    /**
     * @notice incentiveFee is zero or exceeds MAX_INCENTIVE_FEE.
     * @dev selector: 0x9a3d3f1b
     */
    error IncentiveFeeOutOfBounds();

    /**
     * @notice Nitro enclave signature verification failed.
     * @dev selector: 0xb50f2b0e
     */
    error InvalidNitroSignature();

    /**
     * @notice Nitro verifier address is not in the enabled whitelist.
     * @dev selector: 0x3c50f28c
     */
    error NitroVerifierNotEnabled(address nitroVerifier);

    /**
     * @notice Nitro verifier address is already in the enabled whitelist.
     * @dev selector: 0x7d3f8b97
     */
    error NitroVerifierAlreadyEnabled(address nitroVerifier);

    /**
     * @notice nextBatchIndex would overflow uint96.
     * @dev selector: 0x26bb590f
     */
    error NextBatchIndexOverflow();

    /**
     * @notice Blob hashes were not fully submitted within the `submitBlobsWindow`.
     * @dev selector: 0xf9c77ce7
     */
    error SubmitBlobsWindowExceeded(uint256 deadline, uint256 currentBlock);

    /**
     * @notice Batch was not preconfirmed within the `preconfirmWindow`.
     * @dev selector: 0x915afa97
     */
    error PreconfirmWindowExceeded(uint256 deadline, uint256 currentBlock);

    /**
     * @notice Number of submitted blob hashes exceeds the expected count for this batch.
     * @dev selector: 0x756c086a
     */
    error InvalidBlobCount(uint32 expected, uint256 provided);

    /**
     * @notice Batch is not in the expected status for this operation.
     * @dev selector: 0x0f36c0b9
     */
    error InvalidBatchStatus(uint256 batchIndex, uint8 current);

    /**
     * @notice Stored batch Merkle root does not match the root recomputed from the provided headers.
     */
    error InvalidBatchRoot(bytes32 storedRoot, bytes32 computedRoot);

    /**
     * @notice Block hash linkage does not match the chain recorded for this batch.
     */
    error InvalidLastBlockHash(bytes32 expected, bytes32 provided);

    /**
     * @notice Batch already has an active challenge (status `Challenged`).
     */
    error BatchAlreadyChallenged(uint256 batchIndex);

    /**
     * @notice Batch root was already proven or cannot be challenged in this way.
     */
    error BatchRootAlreadyChallenged(uint256 batchIndex);

    /**
     * @notice No open batch-root challenge exists for this batch.
     */
    error BatchRootNotChallenged(uint256 batchIndex);

    /**
     * @notice Cannot open a block challenge while a batch-root challenge is open for this batch.
     */
    error BatchRootChallengeOpen(uint256 batchIndex);

    /**
     * @notice Cannot open a batch-root challenge while block challenges are open for this batch.
     */
    error BlockChallengesOpen(uint256 batchIndex);

    /**
     * @notice Gas remaining is below the required threshold for safe iteration.
     * @dev selector: 0x1c26714c
     */
    error InsufficientGas();

    /**
     * @notice Provided batch index is out of the accepted range.
     * @dev selector: 0xb6d1990b
     */
    error InvalidBatchIndex(uint256 providedBatchIndex, uint256 currentBatchIndex);

    /**
     * @notice Challenge submitted after the batch-wide challenge window has closed.
     * @dev Fires when `block.number >= acceptedAtBlock + challengeWindow`.
     * @dev selector: 0x5118dbec
     */
    error ChallengeTooLate(uint256 batchIndex);

    /**
     * @notice Challenge resolution attempted after the recorded deadline.
     * @dev selector: 0x208c2197
     */
    error ChallengeResolutionTooLate(uint256 batchIndex, uint256 deadline, uint256 currentBlock);

    /**
     * @notice expectedBlobsCount does not fit into uint32 (storage truncation would occur).
     * @dev selector: 0xb011bd91
     */
    error ExpectedBlobsCountOverflow(uint256 expectedBlobsCount);

    /**
     * @notice depositRoot is set to the "no-deposits" sentinel but depositCount is non-zero.
     * @dev selector: 0xee65ef12
     */
    error InvalidDepositRootWithNonZeroCount(uint256 depositCount);

    /**
     * @notice submitBlobsWindow exceeds the uint24 storage range.
     * @dev selector: 0xfafb610f
     */
    error SubmitBlobsWindowOutOfBounds();

    /**
     * @notice preconfirmWindow exceeds the uint24 storage range.
     * @dev selector: 0x82dd2b00
     */
    error PreconfirmWindowOutOfBounds();

    /**
     * @notice challengeWindow exceeds the uint24 storage range.
     * @dev selector: 0xead17a86
     */
    error ChallengeWindowOutOfBounds();

    /**
     * @notice finalizationDelay exceeds the uint24 storage range.
     * @dev selector: 0xea1f08a4
     */
    error FinalizationDelayOutOfBounds();

    /**
     * @notice submitBlobsWindow must not be zero.
     * @dev selector: 0xb9e14f26
     */
    error ZeroSubmitBlobsWindow();

    /**
     * @notice submitBlobsWindow exceeds preconfirmWindow — must stay strictly within it.
     * @dev selector: 0x7dd0b2f8
     */
    error SubmitBlobsExceedsPreconfirm();

    /**
     * @notice preconfirmWindow is too close to submitBlobsWindow — needs at least MIN_PRECONFIRMATION_WINDOW gap.
     * @dev selector: 0xb3690832
     */
    error PreconfirmTooCloseToSubmitBlobs();

    /**
     * @notice challengeWindow is too close to preconfirmWindow — needs at least MIN_CHALLENGE_WINDOW gap.
     * @dev selector: 0x9c108196
     */
    error ChallengeTooCloseToPreconfirm();

    /**
     * @notice challengeWindow is too close to finalizationDelay — needs at least MIN_CHALLENGE_RESOLUTION_WINDOW gap.
     * @dev selector: 0xe68d9221
     */
    error ChallengeTooCloseToFinalization();

    /**
     * @notice finalizationDelay is too close to challengeWindow — needs at least MIN_CHALLENGE_RESOLUTION_WINDOW gap.
     * @dev selector: 0x666f15d2
     */
    error FinalizationTooCloseToChallenge();

    /**
     * @notice Block header `depositCount` exceeds the maximum value supported by on-chain processing.
     * @dev selector: 0x44c573ae
     */
    error DepositCountTooLarge(uint256 depositCount);

    /**
     * @notice Number of block headers in a batch exceeds the protocol's maximum allowed batch size.
     * @dev selector: 0x083e2f67
     */
    error BatchSizeTooLarge(uint256 batchSize);

    /**
     * @notice Number of blob hashes submitted exceeds the protocol's maximum allowed per batch.
     * @dev selector: 0xf09704a6
     */
    error BlobCountTooLarge(uint256 blobCount);

    /**
     * @notice Batch index mismatch with challenge record.
     * @dev selector: 0xc0586a8f
     */
    error BatchIndexMismatch(uint256 challengedBatchIndex, uint256 batchIndex);

    /**
     * @notice SP1 verifier address is not a contract.
     * @dev selector: 0xeed9c0c2
     */
    error Sp1VerifierNotAContract();

    /**
     * @notice Nitro verifier address is not a contract.
     * @dev selector: 0xc0136839
     */
    error NitroVerifierNotAContract();
}

/**
 * @title IRollupEvents
 * @dev Lifecycle and admin events emitted by the rollup contract.
 */
interface IRollupEvents {
    // ============ Admin config updates ============

    /**
     * @notice Emitted when the bridge contract address is updated.
     */
    event BridgeUpdated(address indexed previousBridge, address indexed newBridge);

    /**
     * @notice Emitted when the SP1 verifier contract address is updated.
     */
    event SP1VerifierUpdated(address indexed previousVerifier, address indexed newVerifier);

    /**
     * @notice Emitted when the SP1 program verification key is updated.
     */
    event ProgramVKeyUpdated(bytes32 indexed previousVKey, bytes32 indexed newVKey);

    /**
     * @notice Emitted when a Nitro verifier is added to the enabled whitelist.
     */
    event NitroVerifierEnabled(address indexed verifier);

    /**
     * @notice Emitted when a Nitro verifier is removed from the enabled whitelist.
     */
    event NitroVerifierDisabled(address indexed verifier);

    /**
     * @notice Emitted when the gas left is updated.
     */
    event GasLeftUpdated(uint32 previousGasLeft, uint32 newGasLeft);

    /**
     * @notice Emitted when the submit blobs window is updated.
     */
    event SubmitBlobsWindowUpdated(uint64 previousSubmitBlobsWindow, uint64 newSubmitBlobsWindow);

    /**
     * @notice Emitted when the preconfirm window is updated.
     */
    event PreconfirmWindowUpdated(uint64 previousPreconfirmWindow, uint64 newPreconfirmWindow);

    /**
     * @notice Emitted when the challenge window is updated.
     */
    event ChallengeWindowUpdated(uint64 previousChallengeWindow, uint64 newChallengeWindow);

    /**
     * @notice Emitted when the finalization delay is updated.
     */
    event FinalizationDelayUpdated(uint64 previousFinalizationDelay, uint64 newFinalizationDelay);

    /**
     * @notice Emitted when the challenge deposit amount is updated.
     */
    event ChallengeDepositAmountUpdated(uint256 previousChallengeDepositAmount, uint256 newChallengeDepositAmount);

    /**
     * @notice Emitted when the incentive fee is updated.
     */
    event IncentiveFeeUpdated(uint256 previousIncentiveFee, uint256 newIncentiveFee);

    // ============ Batch lifecycle ============

    /**
     * @notice Emitted when sequencer commits a new batchRoot via {Rollup-commitBatch}.
     */
    event BatchCommitted(
        uint256 indexed batchIndex,
        bytes32 batchRoot,
        bytes32 fromBlockHash,
        bytes32 toBlockHash,
        uint24 numberOfBlocks,
        uint256 expectedBlobs
    );

    /**
     * @notice Emitted when sequencer submits blob hashes for a batch.
     */
    event BatchBlobsSubmitted(uint256 indexed batchIndex, uint256 numBlobs, uint256 totalBlobs);

    /**
     * @notice Emitted when all expected blobs are submitted and the batch moves to Submitted.
     */
    event BatchSubmitted(uint256 indexed batchIndex);

    /**
     * @notice Emitted when Nitro preconfirmation is committed for a batch.
     */
    event BatchPreconfirmed(uint256 indexed batchIndex, address indexed verifierContract, address indexed verifier);

    /**
     * @notice Emitted when a batch is permanently finalized after the challenge period.
     */
    event BatchFinalized(uint256 indexed batchIndex);

    /**
     * @notice Emitted when admin force-reverts batches from a given index onward.
     */
    event BatchReverted(uint256 indexed fromBatchIndex);

    // ============ Challenge lifecycle ============

    /**
     * @notice Emitted when a challenger disputes a block in a preconfirmed batch.
     */
    event BlockChallenged(uint256 indexed batchIndex, bytes32 indexed commitment, address indexed challenger);

    /**
     * @notice Emitted when a challenger opens a batch-root validity dispute.
     */
    event BatchRootChallenged(uint256 indexed batchIndex);

    /**
     * @notice Emitted when a prover resolves a challenge with Nitro + SP1 proof.
     */
    event ChallengeResolved(uint256 indexed batchIndex, bytes32 indexed commitment, address indexed prover);

    /**
     * @notice Emitted when a batch root challenge is resolved.
     */
    event BatchRootChallengeResolved(uint256 indexed batchIndex, address indexed prover);

    // ============ Rewards ============

    /**
     * @notice Emitted when a challenger claims their reward (deposit + incentive fee).
     */
    event ChallengerRewardClaimed(address indexed challenger, uint256 amount);

    /**
     * @notice Emitted when a prover claims their proof reward.
     */
    event ProofRewardClaimed(address indexed prover, uint256 amount);
}

/**
 * @title IRollupConfig
 * @dev Configuration view functions exposing rollup parameters.
 */
interface IRollupConfig {
    /**
     * @notice Bridge contract address for L1 <-> L2 message passing.
     */
    function bridge() external view returns (address);

    /**
     * @notice SP1 verifier contract used for ZK proof verification.
     */
    function sp1Verifier() external view returns (address);

    /**
     * @notice SP1 program verification key bound to the current rollup program.
     */
    function programVKey() external view returns (bytes32);

    /**
     * @notice Number of L1 blocks after batch acceptance before finalization is allowed.
     */
    function finalizationDelay() external view returns (uint256);

    /**
     * @notice Batch-wide challenge window in L1 blocks, measured from acceptance.
     *         Both challenge submission and resolution must occur before the deadline.
     */
    function challengeWindow() external view returns (uint256);

    /**
     * @notice ETH deposit required to open a challenge.
     */
    function challengeDepositAmount() external view returns (uint256);

    /**
     * @notice ETH incentive paid to challengers during force-revert distribution.
     */
    function incentiveFee() external view returns (uint256);

    /**
     * @notice Max L1 blocks after batch acceptance for blob submission.
     */
    function submitBlobsWindow() external view returns (uint256);

    /**
     * @notice Max L1 blocks after batch acceptance for preconfirmation.
     */
    function preconfirmWindow() external view returns (uint256);
}

/**
 * @title IRollupRead
 * @dev Read-only state accessors for batch, challenge, and reward data.
 */
interface IRollupRead {
    // ============ Batch state ============

    /**
     * @notice Returns the full state record for a batch.
     */
    function getBatch(uint256 batchIndex) external view returns (BatchRecord memory);

    /**
     * @notice Returns the index of the next batch to be submitted.
     */
    function nextBatchIndex() external view returns (uint256);

    /**
     * @notice Returns the index of the last finalized batch.
     */
    function lastFinalizedBatchIndex() external view returns (uint256);

    // ============ Batch helpers ============

    /**
     * @notice Returns true if the batch has been finalized.
     */
    function isBatchFinalized(uint256 batchIndex) external view returns (bool);

    /**
     * @notice Returns true if the batch is preconfirmed (eligible for challenge or finalization).
     */
    function isBatchPreconfirmed(uint256 batchIndex) external view returns (bool);

    // ============ Challenge state ============

    /**
     * @notice Returns the full state record for a block challenge by commitment hash.
     *         Returns a zero record if no active challenge exists.
     */
    function getChallenge(bytes32 commitment) external view returns (ChallengeRecord memory);

    /**
     * @notice Returns the active batch-root challenge record for a given batch index.
     *         Returns a zero record if no active challenge exists.
     */
    function getBatchRootChallenge(uint256 batchIndex) external view returns (ChallengeRecord memory);

    /**
     * @notice Returns all commitments currently in the challenge queue.
     * @dev Heap-internal order — only index 0 is guaranteed to be the earliest deadline.
     *      Sort off-chain by getChallenge(commitment).deadline if ordered traversal is needed.
     *      This full-array snapshot can be expensive for large queues; prefer
     *      challengeQueueLength/challengeQueueAt for pagination-like iteration.
     */
    function blockChallengeQueue() external view returns (bytes32[] memory);

    /**
     * @notice Returns the number of commitments in the block challenge queue.
     */
    function blockChallengeQueueLength() external view returns (uint256);

    /**
     * @notice Returns the queue element at a heap index.
     * @dev Heap-internal order; not sorted by deadline except that index 0 is the earliest block commitment.
     */
    function blockChallengeQueueAt(uint256 index) external view returns (bytes32);

    /**
     * @notice Returns blob hashes submitted for a batch.
     */
    function batchBlobHashes(uint256 batchIndex) external view returns (bytes32[] memory);

    /**
     * @notice Returns commitments of blocks that have been challenged in a batch.
     */
    function batchChallengedBlocks(uint256 batchIndex) external view returns (bytes32[] memory);

    /**
     * @notice Returns commitments of blocks that have been proven in a batch.
     */
    function batchProvenBlocks(uint256 batchIndex) external view returns (bytes32[] memory);

    /**
     * @notice Returns true if a block commitment has been proven.
     */
    function isBlockProven(bytes32 commitment) external view returns (bool);

    // ============ Reward balances ============

    /**
     * @notice Returns the claimable reward balance for a challenger.
     */
    function claimableChallengerReward(address challenger) external view returns (uint256);

    /**
     * @notice Returns the claimable reward balance for a prover.
     */
    function claimableProofReward(address prover) external view returns (uint256);
}

/**
 * @title IRollupWrite
 * @dev State-mutating batch lifecycle functions: acceptance, DA, preconfirmation,
 *      challenge, resolution, finalization, and reward withdrawal.
 */
interface IRollupWrite {
    // ============ Sequencer ============

    /**
     * @notice Submit a new batch from a precomputed root.
     * @dev Eager header validation is delegated to {challengeBlock} + SP1; chain linkage
     *      between adjacent batches is enforced at {resolveBatchRootChallenge}.
     * @param batchRoot Merkle root of L2 block header commitments for this batch.
     * @param fromBlockHash Hash of the first L2 block in this batch. Emit-only indexer
     *                      metadata included in {IRollupEvents-BatchCommitted}; not stored
     *                      or validated against {batchRoot} on-chain beyond a non-zero check.
     * @param toBlockHash Hash of the last L2 block in this batch. Emit-only indexer
     *                    metadata included in {IRollupEvents-BatchCommitted}; not stored
     *                    or validated against {batchRoot} on-chain beyond a non-zero check.
     * @param numberOfBlocks Number of L2 blocks in the batch (sequencer-claimed; bound to
     *                       leaf count via Q3 check at challenge resolution time).
     * @param blockDeposits Per-block deposit bundles for the bridge cursor advance.
     * @param expectedBlobsCount Number of EIP-4844 blobs the sequencer commits to submit
     *                           via subsequent {submitBlobs} calls.
     */
    function commitBatch(
        bytes32 batchRoot,
        bytes32 fromBlockHash,
        bytes32 toBlockHash,
        uint24 numberOfBlocks,
        BlockDeposit[] calldata blockDeposits,
        uint8 expectedBlobsCount
    ) external;

    /**
     * @notice Submit blob hashes for DA verification of an accepted batch.
     *
     * @dev The function might be called multiple times to submit multiple blobs for a single batch.
     * @param batchIndex The index of the batch to submit blobs for.
     * @param numBlobs The number of blobs to submit determined by the caller(authority).
     */
    function submitBlobs(uint256 batchIndex, uint256 numBlobs) external;

    // ============ Preconfirmation ============

    /**
     * @notice Preconfirm a batch using a Nitro enclave signature.
     */
    function preconfirmBatch(address nitroVerifier, uint256 batchIndex, bytes calldata signature) external;

    // ============ Challenger ============

    /**
     * @notice Challenge a specific L2 block in a preconfirmed batch.
     * @dev Caller must send exactly `challengeDepositAmount` in ETH as a deposit.
     *      Challenges are accepted while `block.number < acceptedAtBlock + challengeWindow`.
     *      The deadline is fixed at acceptance time — all windows are measured from
     *      `acceptedAtBlock`, not from challenge creation.
     * @param batchIndex The batch index to challenge.
     * @param blockHeader The L2 block header to challenge.
     * @param blockProof The Merkle proof of the L2 block header.
     */
    function challengeBlock(uint256 batchIndex, L2BlockHeader calldata blockHeader, MerkleTree.MerkleProof calldata blockProof) external payable;

    /**
     * @notice Challenge the validity of the batch Merkle root (batch-root dispute path).
     */
    function challengeBatchRoot(uint256 batchIndex) external payable;

    // ============ Prover ============

    /**
     * @notice Resolve a batch-root challenge by showing headers that reproduce the committed root.
     */
    function resolveBatchRootChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata lastBlockHeaderInPreviousBatch,
        L2BlockHeader[] calldata blockHeaders,
        MerkleTree.MerkleProof calldata lastBlockProof
    ) external;

    /**
     * @notice Resolve a block challenge by providing SP1 proof.
     * @param batchIndex Index of the batch containing the challenged block.
     * @param blockHeader L2 block header that was challenged.
     * @param blockProof Merkle proof of the block header against the batch root.
     * @param sp1Proof SP1 ZK proof validating the block execution.
     */
    function resolveBlockChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        bytes calldata sp1Proof
    ) external;

    // ============ Anyone ============

    /**
     * @notice Finalize consecutive batches up to and including `toBatchIndex`.
     * @dev Permissionless. Stops early if a batch is not yet eligible.
     *      Sequential — batch N finalizes only after batch N-1.
     * @param toBatchIndex Last batch index to attempt finalization for.
     * @return finalized Number of batches successfully finalized.
     */
    function finalizeBatches(uint256 toBatchIndex) external returns (uint256 finalized);

    /**
     * @notice Finalize a batch early by proving all its blocks have valid SP1 proofs.
     * @dev Skips the cooldown period. Caller supplies all L2BlockHeaders to reconstruct
     *      the batchRoot and verify each commitment exists in provenBlocks.
     * @param batchIndex The batch to finalize.
     * @param blockHeaders All L2 block headers in the batch in submission order.
     */
    function finalizeWithProofs(uint256 batchIndex, L2BlockHeader[] calldata blockHeaders) external;

    /**
     * @notice Claim reward as challenger (deposit + incentive fee if challenge was valid).
     */
    function withdrawChallengerReward() external;

    /**
     * @notice Claim pending proof reward as prover.
     */
    function withdrawProofReward() external;
}

/**
 * @title IRollupAdmin
 * @dev Admin configuration setters, restricted to DEFAULT_ADMIN_ROLE.
 */
interface IRollupAdmin {
    /**
     * @notice Update the bridge contract address.
     */
    function setBridge(address newBridge) external;

    /**
     * @notice Update the SP1 verifier contract address.
     */
    function setSp1Verifier(address newVerifier) external;

    /**
     * @notice Update the SP1 program verification key.
     */
    function setProgramVKey(bytes32 newVKey) external;

    /**
     * @notice Add a Nitro verifier to the enabled whitelist.
     */
    function enableNitroVerifier(address verifier) external;

    /**
     * @notice Remove a Nitro verifier from the enabled whitelist.
     */
    function disableNitroVerifier(address verifier) external;

    /**
     * @notice Set minimum gas threshold per block header iteration in resolveBatchRootChallenge.
     */
    function setGasLeft(uint32 newGasLeft) external;

    /**
     * @notice Set the maximum L1 blocks after batch acceptance for batch blob submission.
     */
    function setSubmitBlobsWindow(uint24 newSubmitBlobsWindow) external;

    /**
     * @notice Set the maximum L1 blocks after batch acceptance for batch preconfirmation
     *         (measured from acceptedAtBlock).
     */
    function setPreconfirmWindow(uint24 newPreconfirmWindow) external;

    /**
     * @notice Set the maximum L1 blocks after batch acceptance for challenge submission.
     */
    function setChallengeWindow(uint24 newChallengeWindow) external;

    /**
     * @notice Set the minimum L1 blocks after batch acceptance before finalization.
     */
    function setFinalizationDelay(uint24 newFinalizationDelay) external;

    /**
     * @notice Set the ETH deposit required to open a challenge.
     */
    function setChallengeDepositAmount(uint256 newChallengeDepositAmount) external;

    /**
     * @notice Set the ETH reward paid to challengers who successfully challenged a batch.
     */
    function setIncentiveFee(uint256 newIncentiveFee) external;
}

/**
 * @title IRollupEmergency
 * @dev Emergency pause and recovery functions, restricted to EMERGENCY_ROLE.
 */
interface IRollupEmergency {
    /**
     * @notice Returns true if the rollup is in a corrupted state.
     */
    function isRollupCorrupted() external view returns (bool);

    /**
     * @notice Pause all non-emergency functions.
     * @dev Only callable by EMERGENCY_ROLE.
     */
    function pause() external;

    /**
     * @notice Unpause the contract.
     * @dev Only callable by EMERGENCY_ROLE.
     */
    function unpause() external;

    /**
     * @notice Revert all non-finalized batches starting from `toBatchIndex`.
     * @dev Only callable by EMERGENCY_ROLE. Refunds both block challenger deposits and
     *      batch-root challenger deposits along with the incentive fee (Q5).
     *      Sets `_nextBatchIndex` to `toBatchIndex`, effectively discarding all
     *      batches in the range `[toBatchIndex, lastAcceptedBatchIndex]`.
     * @param toBatchIndex The first batch to revert. This batch and every batch above it are reverted.
     */
    function revertBatches(uint256 toBatchIndex) external payable;

    /**
     * @notice Revoke a role from an account.
     * @dev Only callable by EMERGENCY_ROLE.
     */
    function emergencyRevokeRole(bytes32 role, address account) external;
}

/**
 * @title IRollup
 * @dev Composite rollup interface aggregating all sub-interfaces.
 */
interface IRollup is IRollupConfig, IRollupRead, IRollupWrite, IRollupAdmin, IRollupEmergency {}
