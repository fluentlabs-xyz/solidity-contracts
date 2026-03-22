// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {L2BlockHeader, BatchRecord, ChallengeRecord} from "./IRollupTypes.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";

/**
 * @title IRollupErrors
 * @dev Custom errors for the rollup contract.
 */
interface IRollupErrors {
    /**
     * @notice Rollup is in a corrupted state — all state-changing functions are blocked.
     */
    error RollupCorrupted();

    /**
     * @notice Block's previousBlockHash does not match the expected chain tip.
     */
    error WrongPreviousBlockHash(bytes32 expected, bytes32 provided);

    /**
     * @notice Deposit root in the block header does not match the consumed bridge messages.
     */
    error DepositRootMismatch(bytes32 blockHash);

    /**
     * @notice L1 deposit was not consumed within the allowed window.
     */
    error AcceptDepositDeadlineExceeded(uint256 deadline, uint256 currentBlock);

    /**
     * @notice Batch has already been finalized and cannot be modified.
     */
    error BatchAlreadyFinalized(uint256 batchIndex);

    /**
     * @notice Block commitment has already been proven.
     */
    error BlockAlreadyProven(bytes32 commitment);

    /**
     * @notice Block commitment has already been challenged.
     */
    error BlockAlreadyChallenged(bytes32 commitment);

    /**
     * @notice Block commitment has not been challenged — cannot resolve.
     */
    error BlockNotChallenged(bytes32 commitment);

    /**
     * @notice Block commitment has not been proven.
     */
    error BlockNotProven(bytes32 commitment);

    /**
     * @notice Challenge deposit does not match the required amount.
     */
    error IncorrectChallengeDeposit(uint256 required, uint256 provided);

    /**
     * @notice Native ETH transfer to recipient failed.
     */
    error EthTransferFailed(address recipient, uint256 amount);

    /**
     * @notice Block sequence is invalid — block[i].blockHash != block[i+1].previousBlockHash.
     */
    error InvalidBlockSequence(uint256 index, bytes32 currentHash, bytes32 nextPrevHash);

    /**
     * @notice Merkle tree construction requires at least one leaf.
     */
    error NoLeavesProvided();

    /**
     * @notice Caller has no balance available for withdrawal.
     */
    error NothingToWithdraw();

    /**
     * @notice msg.value is insufficient to cover challenger incentive fees for force revert.
     */
    error NotEnoughValueIncentiveFee(uint256 value, uint256 incentiveFee);

    /**
     * @notice Merkle proof for the block header is invalid.
     */
    error InvalidBlockProof();

    /**
     * @notice Address field must not be zero.
     */
    error ZeroAddressNotAllowed(bytes32 field);

    /**
     * @notice Value field must not be zero.
     */
    error ZeroValueNotAllowed(bytes32 field);

    /**
     * @notice Nitro enclave signature verification failed.
     */
    error InvalidNitroSignature();

    /**
     * @notice Nitro verifier address is not in the enabled whitelist.
     */
    error NitroVerifierNotEnabled(address nitroVerifier);

    /**
     * @notice Nitro verifier address is already in the enabled whitelist.
     */
    error NitroVerifierAlreadyEnabled(address nitroVerifier);

    /**
     * @notice nextBatchIndex would overflow uint96.
     */
    error NextBatchIndexOverflow();

    /**
     * @notice Blob hashes were not fully submitted within the `submitBlobsWindow`.
     */
    error SubmitBlobsWindowExceeded(uint256 deadline, uint256 currentBlock);

    /**
     * @notice Batch was not preconfirmed within the `preconfirmWindow`.
     */
    error PreconfirmWindowExceeded(uint256 deadline, uint256 currentBlock);

    /**
     * @notice Number of submitted blob hashes exceeds the expected count for this batch.
     */
    error InvalidBlobCount(uint32 expected, uint256 provided);

    /**
     * @notice Batch is not in the expected status for this operation.
     */
    error InvalidBatchStatus(uint256 batchIndex, uint8 current);

    /**
     * @notice Gas remaining is below the required threshold for safe iteration.
     */
    error InsufficientGas();

    /**
     * @notice Provided batch index is out of the accepted range.
     */
    error InvalidBatchIndex(uint256 providedBatchIndex, uint256 currentBatchIndex);

    /**
     * @notice Challenge submitted too late — insufficient time remains within the
     *         finalization window for the prover to respond within `challengeWindow`.
     */
    error ChallengeTooLate(uint256 batchIndex);

    /**
     * @notice Challenge resolution attempted after the recorded deadline.
     */
    error ChallengeResolutionTooLate(uint256 batchIndex, uint256 deadline, uint256 currentBlock);

    /**
     * @notice expectedBlobsCount does not fit into uint32 (storage truncation would occur).
     */
    error ExpectedBlobsCountOverflow(uint256 expectedBlobsCount);

    /**
     * @notice depositRoot is set to the "no-deposits" sentinel but depositCount is non-zero.
     */
    error InvalidDepositRootWithNonZeroCount(uint256 depositCount);

    /**
     * @notice preconfirmWindow must exceed submitBlobsWindow — both are measured from
     *         acceptedAtBlock, so preconfirmation cannot be required before blob submission completes.
     */
    error InvalidWindowConfig(string reason);

    /**
     * @notice Block header `depositCount` exceeds the maximum value supported by on-chain processing.
     */
    error DepositCountTooLarge(uint256 depositCount);

    /**
     * @notice Number of block headers in a batch exceeds the protocol's maximum allowed batch size.
     */
    error BatchSizeTooLarge(uint256 batchSize);

    /**
     * @notice Number of blob hashes submitted exceeds the protocol's maximum allowed per batch.
     */
    error BlobCountTooLarge(uint256 blobCount);

    /**
     * @notice Batch index mismatch with challenge record.
     */
    error BatchIndexMismatch(uint256 challengedBatchIndex, uint256 batchIndex);

    /**
     * @notice Address field is not a contract.
     */
    error NotAContract(string field);
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
     * @notice Emitted when the accept deposit deadline is updated.
     */
    event AcceptDepositDeadlineUpdated(uint32 previousAcceptDepositDeadline, uint32 newAcceptDepositDeadline);

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
     * @notice Emitted when sequencer submits L2 block headers for a new batch.
     */
    event BatchHeadersSubmitted(uint256 indexed batchIndex, bytes32 batchRoot, uint256 expectedBlobs);

    /**
     * @notice Emitted when sequencer submits blob hashes for a batch.
     */
    event BatchBlobsSubmitted(uint256 indexed batchIndex, uint256 numBlobs, uint256 totalBlobs);

    /**
     * @notice Emitted when all expected blobs are submitted and batch moves to Accepted.
     */
    event BatchAccepted(uint256 indexed batchIndex);

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
     * @notice Emitted when a prover resolves a challenge with Nitro + SP1 proof.
     */
    event ChallengeResolved(uint256 indexed batchIndex, bytes32 indexed commitment, address indexed prover);

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
     * @notice Number of L1 blocks a challenger has to submit a challenge.
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
     * @notice Max L1 blocks between L1 deposit and L2 block acceptance.
     */
    function acceptDepositDeadline() external view returns (uint256);

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

    /**
     * @notice Returns the last block hash in a batch, used for chain linking.
     */
    function lastBlockHashInBatch(uint256 batchIndex) external view returns (bytes32);

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
     * @notice Returns the full state record for a challenge.
     */
    function getChallenge(bytes32 commitment) external view returns (ChallengeRecord memory);

    /**
     * @notice Returns all commitments currently in the challenge queue.
     * @dev Heap-internal order — only index 0 is guaranteed to be the earliest deadline.
     *      Sort off-chain by getChallenge(commitment).deadline if ordered traversal is needed.
     *      This full-array snapshot can be expensive for large queues; prefer
     *      challengeQueueLength/challengeQueueAt for pagination-like iteration.
     */
    function challengeQueue() external view returns (bytes32[] memory);

    /**
     * @notice Returns the number of commitments in the challenge queue.
     */
    function challengeQueueLength() external view returns (uint256);

    /**
     * @notice Returns the queue element at a heap index.
     * @dev Heap-internal order; not sorted by deadline except that index 0 is the earliest.
     */
    function challengeQueueAt(uint256 index) external view returns (bytes32);

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
     * @notice Submit a new batch of L2 block headers.
     */
    function acceptNextBatch(L2BlockHeader[] calldata blockHeaders, uint256 expectedBlobsCount) external;

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

    // ============ Prover ============

    /**
     * @notice Resolve a challenge by providing Nitro + SP1 proofs.
     */
    function resolveChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes calldata nitroSignature,
        bytes calldata sp1Proof
    ) external;

    // ============ Anyone ============

    /**
     * @notice Finalize consecutive batches up to and including `toBatchIndex`.
     * @dev Permissionless. Stops early if a batch is not yet eligible (cooldown not passed).
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
     * @notice Set minimum gas threshold per block header iteration in acceptNextBatch.
     */
    function setGasLeft(uint32 newGasLeft) external;

    /**
     * @notice Set the maximum L1 blocks between deposit creation and batch inclusion.
     */
    function setAcceptDepositDeadline(uint32 newAcceptDepositDeadline) external;

    /**
     * @notice Set the maximum L1 blocks after batch acceptance for batch blob submission.
     */
    function setSubmitBlobsWindow(uint64 newSubmitBlobsWindow) external;

    /**
     * @notice Set the maximum L1 blocks after batch acceptance for batch preconfirmation
     *         (measured from acceptedAtBlock).
     */
    function setPreconfirmWindow(uint64 newPreconfirmWindow) external;

    /**
     * @notice Set the maximum L1 blocks a challenger has to submit a challenge after batch acceptance.
     */
    function setChallengeWindow(uint64 newChallengeWindow) external;

    /**
     * @notice Set the minimum L1 blocks after batch acceptance before finalization.
     */
    function setFinalizationDelay(uint64 newFinalizationDelay) external;

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
     * @notice Force-revert all non-finalized batches above `toBatchIndex`.
     * @dev Only callable by EMERGENCY_ROLE. Refunds challenger deposits with incentive fee.
     *      Sets `_nextBatchIndex` to `toBatchIndex + 1`, effectively discarding all
     *      batches in the range `(toBatchIndex, lastAcceptedBatchIndex]`.
     * @param toBatchIndex The last batch to keep. All batches above this index are reverted.
     */
    function forceRevertBatch(uint256 toBatchIndex) external payable;
}

/**
 * @title IRollup
 * @dev Composite rollup interface aggregating all sub-interfaces.
 */
interface IRollup is IRollupConfig, IRollupRead, IRollupWrite, IRollupAdmin, IRollupEmergency {}
