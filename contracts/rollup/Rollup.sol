// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {Heap} from "../libraries/Heap.sol";
import {RollupStorageLayout} from "./RollupStorageLayout.sol";

import {IRollupWrite, IRollupEmergency} from "../interfaces/IRollup.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {INitroVerifier} from "../interfaces/INitroVerifier.sol";
import {IL1FluentBridge} from "../interfaces/bridge/IL1FluentBridge.sol";
import {L2BlockHeader, BatchStatus, BatchRecord, ChallengeRecord} from "../interfaces/IRollupTypes.sol";

/**
 * @title Rollup
 * @author Fluent Labs
 * @dev Rollup contract serves as an Optimistic Rollup in a relation with FluentBridge with two verifier paths: AWS Nitro Enclave for preconfirmation
 * and SP1 for ZK proof-based challenge resolution.
 *
 * Batches progress through HeadersSubmitted → Accepted → Preconfirmed → Finalized, with
 * Challenged as a transient branch from either Accepted or Preconfirmed. Preconfirmation
 * via {preconfirmBatch} has no deadline — it can happen at any time after blob submission.
 *
 * All timing windows are measured from the block in which `acceptNextBatch` was called
 * ({BatchRecord-acceptedAtBlock}). The windows are:
 * - {RollupStorage-submitBlobsWindow}: deadline for the sequencer to submit blob hashes.
 * - {RollupStorage-challengeWindow}: deadline by which open challenges must be resolved.
 * - {RollupStorage-finalizationDelay}: minimum wait before a batch can be finalized.
 *
 * If any deadline is exceeded, {isRollupCorrupted} returns true and all state-changing
 * functions revert with {RollupCorrupted} until the corrupted batch is cleared via
 * {forceRevertBatch}.
 *
 * == Security: challenge timing and finalization ==
 *
 * The invariant `challengeWindow < finalizationDelay` (enforced at initialization and
 * on every admin update) guarantees that the challenge window closes strictly before any
 * batch becomes eligible for finalization. With the reference deployment parameters
 * (`challengeWindow = 36 h`, `finalizationDelay = 48 h`) the gap is 12 hours, so a
 * batch can never be finalized while challenges are still accepted.
 *
 * A challenge submitted near the end of the window leaves the prover very little wall-clock
 * time to respond, because the resolution deadline is always `acceptedAtBlock + challengeWindow`
 * regardless of when the challenge was created. If the prover cannot submit both a Nitro
 * attestation and an SP1 proof before that deadline, the rollup enters the corrupted
 * (safety-halt) state. This is by design:
 *
 * - *No funds are at risk* — the corrupted state blocks all mutations until
 *   {EMERGENCY_ROLE} calls {forceRevertBatch} to roll back the affected batch.
 * - The challenger's deposit remains locked in the reverted challenge record and is not
 *   returned, disincentivizing frivolous last-moment challenges.
 * - The sequencer can re-submit the batch after the corrupted state is cleared.
 *
 * Operators should therefore ensure the prover infrastructure can generate dual proofs
 * well within the `challengeWindow` and monitor {BlockChallenged} events in real time.
 */
contract Rollup is RollupStorageLayout, IRollupWrite, IRollupEmergency {
    // Attach min-heap operations to the HeapStorage type for the challenge priority queue
    using Heap for Heap.HeapStorage;

    // ============ Constructor ============

    /// @dev https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#initializing_the_implementation_contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly;
        // only proxies should call initialize()
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the upgradeable rollup (replaces constructor when used behind a proxy).
     * @param data ABI-encoded {InitConfiguration}.
     */
    function initialize(bytes memory data) external initializer {
        // Initialize all inherited OZ modules — order matters for storage layout
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Decode InitConfiguration from `data` and populate ERC-7201 namespaced storage
        __RollupStorage_init(data);
    }

    // ============ IRollupEmergency ============

    /// @inheritdoc IRollupEmergency
    function isRollupCorrupted() external view returns (bool) {
        // Delegates to the internal view that checks deadline violations
        // on the oldest non-finalized batch
        return _rollupCorrupted();
    }

    /// @inheritdoc IRollupEmergency
    function pause() external onlyRole(EMERGENCY_ROLE) {
        // Access control: only EMERGENCY_ROLE can halt the rollup
        _pause();
    }

    /// @inheritdoc IRollupEmergency
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        // Access control: only EMERGENCY_ROLE can resume operations
        _unpause();
    }

    /// @inheritdoc IRollupEmergency
    function forceRevertBatch(uint256 toBatchIndex) external payable onlyRole(EMERGENCY_ROLE) nonReentrant {
        // Access control: EMERGENCY_ROLE + nonReentrant guard (payable — receives ETH for incentive fees)
        RollupStorage storage $ = _getRollupStorage();
        // Identify the most recent batch so we know the revert range [toBatchIndex+1 .. lastAccepted]
        uint256 lastAcceptedBatchIndex = $._nextBatchIndex - 1;
        // Index 0 holds the genesis hash and must never be reverted
        require(toBatchIndex > 0, ZeroValueNotAllowed("toBatchIndex"));
        // Cap the number of batches that can be reverted in one call to bound gas usage
        require(lastAcceptedBatchIndex - toBatchIndex <= $._maxForceRevertBatchSize, InvalidBatchIndex(toBatchIndex, lastAcceptedBatchIndex));

        // Safety check: finalized batches are immutable and must never be rolled back
        for (uint256 i = lastAcceptedBatchIndex; i > toBatchIndex; i--) {
            require($._batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        // Incentive accounting: challengers who flagged bad batches get their deposit back + a fee
        uint256 totalIncentiveFees = 0;
        // Cache the per-challenge incentive fee to avoid repeated storage reads in the loop
        uint256 fee = $._incentiveFee;

        // Process each batch in reverse order: refund challengers and wipe batch storage
        for (uint256 i = lastAcceptedBatchIndex; i > toBatchIndex; i--) {
            totalIncentiveFees += _processForceRevertChallenged($._batchChallengedBlocks[i], fee);
            _cleanupForceRevertBatch(i);
        }

        // Caller must send enough ETH to cover all incentive fees owed to challengers
        require(msg.value >= totalIncentiveFees, NotEnoughValueIncentiveFee(msg.value, totalIncentiveFees));
        // Reset the batch counter so the next batch starts right after the revert target
        require(toBatchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        // casting to 'uint96' is safe because we validate the bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._nextBatchIndex = uint96(toBatchIndex + 1);

        // Refund any overpayment back to the caller (underflow safe: require on L115 guarantees msg.value >= totalIncentiveFees)
        uint256 refund = msg.value - totalIncentiveFees;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, EthTransferFailed(msg.sender, refund));
        }

        // Notify off-chain indexers that all batches after toBatchIndex have been rolled back
        emit BatchReverted(toBatchIndex);
    }

    /**
     * @dev Iterates challenged blocks for `batchIndex` during force-revert: refunds challenger
     *      deposits, accumulates incentive fees for the caller, and removes each challenge
     *      from the priority queue.
     * @return totalFees Sum of incentive fees earned by the caller.
     */
    function _processForceRevertChallenged(bytes32[] storage challengedBlocks, uint256 fee) internal returns (uint256 totalFees) {
        RollupStorage storage $ = _getRollupStorage();
        // Iterate every challenged block commitment in this batch
        for (uint256 i = 0; i < challengedBlocks.length; i++) {
            bytes32 commitment = challengedBlocks[i];
            ChallengeRecord storage challenge = $._challenges[commitment];
            // Cache challenger address — used for both existence check and reward credit
            address challenger = challenge.challenger;

            // Only credit rewards when a real challenger exists (zero address = no active challenge)
            if (challenger != address(0)) {
                // Refund the actual locked deposit and pay an incentive fee
                // (credited, not transferred — challenger withdraws via withdrawChallengerReward)
                $._challengerRewards[challenger] += challenge.deposit + fee;
                // Track total fees so the caller can verify sufficient msg.value was sent
                totalFees += fee;
            }

            // Remove from the min-heap so _rollupCorrupted() no longer sees this challenge
            _removeChallengeFromQueue(commitment);

            // Wipe challenge and proof state for this commitment
            delete $._challenges[commitment];
            delete $._provenBlocks[commitment];
        }
    }

    /**
     * @dev Deletes all storage associated with `batchIndex` during force-revert and restores
     *      the deposits that were popped by this batch back to the front of the bridge queue.
     *
     *      Restoration order matters: {forceRevertBatch}'s outer loop processes batches
     *      newest-to-oldest. Within each batch we iterate popped deposits in reverse so each
     *      `pushSentMessage` places the item at the new front. Combined, the final queue
     *      state has the deposits in their original nonce-ascending order — which the
     *      off-chain sequencer requires to re-match its L2 ReceivedMessage events.
     *
     *      External call to the bridge is safe here: {forceRevertBatch} holds the
     *      nonReentrant guard, and the bridge is trusted.
     */
    function _cleanupForceRevertBatch(uint256 batchIndex) internal {
        RollupStorage storage $ = _getRollupStorage();
        // Restore deposits in reverse so the final queue order matches the original pop order.
        bytes32[] storage depositIds = $._batchDepositIds[batchIndex];
        uint256 depositCount = depositIds.length;
        address bridgeAddr = $._bridge;
        for (uint256 i = depositCount; i > 0; --i) {
            IL1FluentBridge(bridgeAddr).pushSentMessage(depositIds[i - 1]); // wake-disable-line reentrancy
        }
        // Delete all storage slots associated with this batch to reclaim gas
        // and ensure reverted batches leave no residual state
        delete $._batches[batchIndex];
        delete $._batchProvenBlocks[batchIndex];
        delete $._batchChallengedBlocks[batchIndex];
        delete $._batchBlobHashes[batchIndex];
        delete $._batchDepositIds[batchIndex];
        // Remove the chain-linkage hash so re-submitted batches don't collide
        delete $._lastBlockHashInBatch[batchIndex];
    }

    // ============ Sequencer ============

    /// @inheritdoc IRollupWrite
    function acceptNextBatch(
        L2BlockHeader[] calldata blockHeaders,
        uint256 expectedBlobsCount
    ) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        // Access control: SEQUENCER_ROLE only; paused check + reentrancy guard active
        RollupStorage storage $ = _getRollupStorage();

        // Read the next available batch index — each batch gets a unique monotonic index
        uint256 batchIndex = $._nextBatchIndex;
        // Halt all ingestion when a deadline has been violated (corrupted state)
        require(!_rollupCorrupted(), RollupCorrupted());

        uint256 batchSize = blockHeaders.length;
        // At least one L2 block header is required to form a valid batch
        require(batchSize > 0, NoLeavesProvided());
        // Chain-linkage: first header must connect to the last block of the previous batch
        // to maintain an unbroken L2 block sequence across batches
        require(
            blockHeaders[0].previousBlockHash == $._lastBlockHashInBatch[batchIndex - 1],
            WrongPreviousBlockHash($._lastBlockHashInBatch[batchIndex - 1], blockHeaders[0].previousBlockHash)
        );

        // Cache gas floor to prevent an out-of-gas DoS in the validation loop below
        uint256 gasLeft = $._gasLeft;
        // Per-batch deposit cap — sum of depositCount across all headers must not exceed this
        uint256 totalDeposits = 0;
        uint256 depositCap = uint256($._maxDepositsPerBatch);

        // Validate header chain linkage AND accumulate deposit counts in a single pass.
        // The chain-linkage check pairs headers[i] with headers[i+1], so the loop runs
        // to batchSize-1; the last header's deposits are counted after the loop.
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            // Ensure enough gas remains for each iteration to prevent partial execution
            require(gasleft() >= gasLeft, InsufficientGas());
            // Verify the sequential block hash chain — any break means corrupted or misordered headers
            require(
                blockHeaders[i].blockHash == blockHeaders[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockHeaders[i].blockHash, blockHeaders[i + 1].previousBlockHash)
            );
            // Accumulate deposit count and fail fast if the cap is already breached
            totalDeposits += blockHeaders[i].depositCount;
            require(totalDeposits <= depositCap, DepositCountTooLarge(totalDeposits));
        }

        // Last header: chain-linkage already anchored by the loop above, only deposit cap remains
        totalDeposits += blockHeaders[batchSize - 1].depositCount;
        require(totalDeposits <= depositCap, DepositCountTooLarge(totalDeposits));

        // Sanity check: a zero deposit root must have zero deposit count (no phantom deposits)
        if (blockHeaders[batchSize - 1].depositRoot == ZERO_BYTES_HASH) {
            require(blockHeaders[batchSize - 1].depositCount == 0, InvalidDepositRootWithNonZeroCount(blockHeaders[batchSize - 1].depositCount));
        }

        // Build the Merkle root from all block header commitments — used for proofs later
        bytes32 batchRoot = _calculateBatchRoot(blockHeaders);

        // --- Effects: write all storage before any external calls (CEI pattern) ---
        BatchRecord storage batch = $._batches[batchIndex];
        batch.batchRoot = batchRoot;
        // Record the L1 block number — all timing windows are measured from this anchor
        batch.acceptedAtBlock = uint64(block.number);
        // Store expected blob count so submitBlobs can validate completeness
        require(expectedBlobsCount <= type(uint32).max, ExpectedBlobsCountOverflow(expectedBlobsCount));
        // casting to 'uint32' is safe because we validate the bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        batch.expectedBlobs = uint32(expectedBlobsCount);
        // Initial status: blobs have not been submitted yet
        batch.status = BatchStatus.HeadersSubmitted;
        // Persist the last block hash for chain-linkage with the next batch
        $._lastBlockHashInBatch[batchIndex] = blockHeaders[batchSize - 1].blockHash;
        // Overflow protection: _nextBatchIndex is uint96, ensure increment stays in range
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        // casting to 'uint96' is safe because we validate the bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._nextBatchIndex = uint96(batchIndex + 1);

        // --- Interactions (CEI): external bridge calls happen after all state writes above ---
        // Pop deposits from the L1 bridge queue and verify they match the header's depositRoot
        for (uint256 i = 0; i < batchSize; ++i) {
            // Only check blocks that claim deposits — skip blocks with empty deposit roots
            if (blockHeaders[i].depositRoot != ZERO_BYTES_HASH) _checkDeposits(batchIndex, blockHeaders[i]);
        }

        // Notify indexers of the new batch — includes the Merkle root for off-chain verification
        emit BatchHeadersSubmitted(batchIndex, batchRoot, expectedBlobsCount);
    }

    /// @inheritdoc IRollupWrite
    function submitBlobs(uint256 batchIndex, uint256 numBlobs) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        // Access control: SEQUENCER_ROLE only; can be called in multiple txs to submit blobs incrementally
        RollupStorage storage $ = _getRollupStorage();
        // Block ingestion if a deadline has been violated anywhere in the batch pipeline
        require(!_rollupCorrupted(), RollupCorrupted());

        BatchRecord storage batch = $._batches[batchIndex];
        // Load the running list of already-submitted blob hashes for this batch
        bytes32[] storage blobHashes = $._batchBlobHashes[batchIndex];

        // At least one blob must be submitted per call
        require(numBlobs > 0, ZeroValueNotAllowed("numBlobs"));
        // Total submitted blobs (existing + new) must not exceed the declared count from acceptNextBatch
        require(blobHashes.length + numBlobs <= batch.expectedBlobs, InvalidBlobCount(batch.expectedBlobs, blobHashes.length + numBlobs));
        // Blobs can only be submitted while the batch is in HeadersSubmitted state
        require(batch.status == BatchStatus.HeadersSubmitted, InvalidBatchStatus(batchIndex, uint8(batch.status)));

        // If the submit-blobs deadline is enabled (non-zero), enforce the time window
        if ($._submitBlobsWindow != 0) {
            require(
                block.number <= uint256(batch.acceptedAtBlock) + $._submitBlobsWindow,
                SubmitBlobsWindowExceeded(uint256(batch.acceptedAtBlock) + $._submitBlobsWindow, block.number)
            );
        }

        // Read EIP-4844 versioned blob hashes from this transaction via the BLOBHASH opcode
        for (uint256 i = 0; i < numBlobs; ++i) {
            bytes32 blobHash = _getBlobHash(i);
            // Zero blobhash means the index is out of range — no more blobs in this tx
            require(blobHash != bytes32(0), ZeroValueNotAllowed("blobHash"));
            // Append to persistent storage; later used by Nitro/SP1 verifiers for data binding
            blobHashes.push(blobHash);
        }

        // Log progress — allows off-chain monitoring of partial blob submissions
        emit BatchBlobsSubmitted(batchIndex, numBlobs, blobHashes.length);

        // State transition: once all expected blobs are recorded, batch moves to Accepted
        // This enables the preconfirmation step in the batch lifecycle
        if (blobHashes.length == batch.expectedBlobs) {
            batch.status = BatchStatus.Accepted;
            emit BatchAccepted(batchIndex);
        }
    }

    // ============ Preconfirmation ============

    /// @inheritdoc IRollupWrite
    function preconfirmBatch(
        address nitroVerifier,
        uint256 batchIndex,
        bytes calldata signature
    ) external onlyRole(PRECONFIRMATION_ROLE) whenNotPaused nonReentrant {
        // Access control: PRECONFIRMATION_ROLE (typically the TEE preconfirmation service)
        // Ensure the Nitro verifier contract is on the admin-maintained whitelist
        _validateNitroVerifier(nitroVerifier);

        RollupStorage storage $ = _getRollupStorage();
        // Halt if the rollup is in a corrupted state (deadline violation)
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        // Only batches with all blobs submitted (Accepted) can be preconfirmed
        require(batch.status == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        // External call to the Nitro verifier: validates the enclave attestation signature
        // over the batch root and blob hashes; returns the signer address for the event
        address verifier = INitroVerifier(nitroVerifier).verifyBatch(batch.batchRoot, $._batchBlobHashes[batchIndex], signature);

        // State transition: Accepted → Preconfirmed
        batch.status = BatchStatus.Preconfirmed;
        emit BatchPreconfirmed(batchIndex, nitroVerifier, verifier);
    }

    // ============ Challenger ============

    /// @inheritdoc IRollupWrite
    function challengeBlock(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        // Access control: CHALLENGER_ROLE + payable (must attach exact deposit amount)
        RollupStorage storage $ = _getRollupStorage();
        // Cannot challenge when the rollup is already in a corrupted/halted state
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        // Challenges target Accepted or Preconfirmed batches — HeadersSubmitted has no blobs,
        // Challenged already has an open dispute, Finalized is immutable.
        require(
            batch.status == BatchStatus.Accepted || batch.status == BatchStatus.Preconfirmed,
            InvalidBatchStatus(batchIndex, uint8(batch.status))
        );
        // Exact deposit required — overpayment is not refunded, underpayment is rejected;
        // this deposit is forfeited to the prover if the challenge is resolved
        require(msg.value == $._challengeDepositAmount, IncorrectChallengeDeposit($._challengeDepositAmount, msg.value));
        // Challenge must be submitted before the challenge window closes (strict less-than)
        require(block.number < uint256(batch.acceptedAtBlock) + $._challengeWindow, ChallengeTooLate(batchIndex));

        // Compute the keccak commitment of the challenged block header
        bytes32 commitment = _computeCommitment(blockHeader);
        // Verify the block is actually part of this batch via Merkle inclusion proof
        require(MerkleTree.verifyMerkleProof(batch.batchRoot, commitment, blockProof.nonce, blockProof.proof), InvalidBlockProof());
        // A block that has already been proven correct cannot be challenged again
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        // Prevent duplicate challenges on the same block — batchIndex 0 is genesis (never used)
        require($._challenges[commitment].batchIndex == 0, BlockAlreadyChallenged(commitment));

        // State transition: Preconfirmed → Challenged (remains Challenged until all disputes resolve)
        batch.status = BatchStatus.Challenged;
        // Record this commitment in the batch's challenged-blocks list
        $._batchChallengedBlocks[batchIndex].push(commitment);

        // Create the challenge record with the resolution deadline derived from the challenge window
        uint256 deadline = uint256(batch.acceptedAtBlock) + $._challengeWindow;
        $._challenges[commitment] = ChallengeRecord({deposit: msg.value, challenger: _msgSender(), deadline: deadline, batchIndex: batchIndex});
        // Insert into the min-heap priority queue ordered by deadline — _rollupCorrupted()
        // peeks at the earliest deadline to detect expiry
        $._challengePriority[commitment] = deadline;
        $._challengeQueue.push($._challengePriority, $._challengeQueueIndex, commitment);

        // Notify off-chain watchers — provers monitor this event to begin generating proofs
        emit BlockChallenged(batchIndex, commitment, _msgSender());
    }

    // ============ Prover ============

    /// @inheritdoc IRollupWrite
    function resolveChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes calldata nitroSignature,
        bytes calldata sp1Proof
    ) external nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        // Access control: PROVER_ROLE — only authorized provers can resolve challenges
        RollupStorage storage $ = _getRollupStorage();
        // Cannot resolve challenges when the rollup is corrupted (must force-revert first)
        require(!_rollupCorrupted(), RollupCorrupted());

        // Derive the commitment from the block header — this uniquely identifies the block
        bytes32 commitment = _computeCommitment(blockHeader);

        // Validate: challenge exists, not yet proven, and block is in the batch Merkle tree
        _validateChallenge(batchIndex, commitment, blockProof);
        // Dual verification: both Nitro enclave attestation AND SP1 ZK proof must pass
        _verifyNitroAndSp1(batchIndex, blockHeader, nitroVerifier, nitroSignature, sp1Proof);

        ChallengeRecord storage challenged = $._challenges[commitment];
        // Cache the deposit amount before deleting the challenge record
        uint256 deposit = challenged.deposit;

        // Effects before interactions (CEI): credit reward before deleting challenge state
        // Mark the block as proven so it cannot be challenged again
        $._provenBlocks[commitment] = true;
        // Track proven blocks per batch — used to detect when all challenges are resolved
        $._batchProvenBlocks[batchIndex].push(commitment);
        // Transfer the challenger's deposit to the prover as a reward
        // (credited, not transferred — prover withdraws via withdrawProofReward)
        $._proverRewards[_msgSender()] += deposit;

        // Clean up: delete the challenge record and remove from the priority queue
        delete $._challenges[commitment];
        _removeChallengeFromQueue(commitment);

        // When every challenged block in the batch has been proven, set to Preconfirmed
        // so the batch can proceed toward finalization
        if ($._batchChallengedBlocks[batchIndex].length == $._batchProvenBlocks[batchIndex].length) {
            $._batches[batchIndex].status = BatchStatus.Preconfirmed;
        }
        // Log resolution — off-chain systems track this to update batch confidence scores
        emit ChallengeResolved(batchIndex, commitment, _msgSender());
    }

    // ============ Anyone ============

    /// @inheritdoc IRollupWrite
    function finalizeBatches(uint256 toBatchIndex) external whenNotPaused returns (uint256 finalized) {
        // Permissionless — anyone can call to finalize eligible batches
        RollupStorage storage $ = _getRollupStorage();
        // Target batch must exist (have been accepted at some point)
        require(toBatchIndex < $._nextBatchIndex, InvalidBatchIndex(toBatchIndex, $._nextBatchIndex));

        // Start from the batch right after the last finalized one (sequential finalization)
        uint256 from = uint256($._lastFinalizedBatchIndex) + 1;
        // Attempt to finalize each batch in order; stop at the first ineligible batch
        for (uint256 i = from; i <= toBatchIndex; ++i) {
            // _tryFinalizeBatch returns false if the batch is not yet eligible (delay not met)
            if (!_tryFinalizeBatch(i)) break;
            ++finalized;
        }
    }

    /// @inheritdoc IRollupWrite
    function finalizeWithProofs(uint256 batchIndex, L2BlockHeader[] calldata blockHeaders) external whenNotPaused {
        // Permissionless: bypasses finalizationDelay if every block in the batch has been SP1-proven
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $._batches[batchIndex];

        // Only preconfirmed batches can be finalized (not HeadersSubmitted, Accepted, etc.)
        require(batch.status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        // Batches must finalize in strict sequential order — no gaps allowed
        require(batchIndex == uint256($._lastFinalizedBatchIndex) + 1, InvalidBatchIndex(batchIndex, uint256($._lastFinalizedBatchIndex) + 1));

        // Verify supplied headers reconstruct the accepted batchRoot — prevents
        // submitting an arbitrary set of headers that weren't in the original batch
        require(_calculateBatchRoot(blockHeaders) == batch.batchRoot, InvalidBlockProof());

        // Verify every block commitment in the batch has been proven via SP1
        // This is the key difference from finalizeBatches: proofs replace the time delay
        for (uint256 i = 0; i < blockHeaders.length; ++i) {
            bytes32 commitment = _computeCommitment(blockHeaders[i]);
            require($._provenBlocks[commitment], BlockNotProven(commitment));
        }

        // State transition: Preconfirmed → Finalized
        batch.status = BatchStatus.Finalized;
        // Advance the finalization watermark — used by finalizeBatches and sequential ordering
        require(batchIndex <= type(uint64).max, InvalidBatchIndex(batchIndex, uint256($._lastFinalizedBatchIndex) + 1));
        // casting to 'uint64' is safe because we validate the bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._lastFinalizedBatchIndex = uint64(batchIndex);
        emit BatchFinalized(batchIndex);
    }

    /// @inheritdoc IRollupWrite
    function withdrawChallengerReward() external nonReentrant whenNotPaused {
        // Permissionless pull pattern: challengers withdraw their own rewards
        RollupStorage storage $ = _getRollupStorage();
        address payable challenger = payable(_msgSender());
        // Read the accumulated reward balance (deposits refunded + incentive fees)
        uint256 amount = $._challengerRewards[challenger];
        // Revert early if nothing to withdraw — prevents zero-value transfers
        require(amount != 0, NothingToWithdraw());

        // CEI: zero the balance BEFORE the external call to prevent reentrancy
        $._challengerRewards[challenger] = 0;
        // Balance zeroed before transfer (CEI) and nonReentrant guard is active — false positive
        (bool success, ) = challenger.call{value: amount}(""); // wake-disable-line reentrancy
        require(success, EthTransferFailed(challenger, amount));

        emit ChallengerRewardClaimed(challenger, amount);
    }

    /// @inheritdoc IRollupWrite
    function withdrawProofReward() external nonReentrant whenNotPaused {
        // Permissionless pull pattern: provers withdraw their own rewards
        RollupStorage storage $ = _getRollupStorage();
        address payable prover = payable(_msgSender());
        // Read the accumulated reward balance (forfeited challenger deposits)
        uint256 amount = $._proverRewards[prover];
        // Revert early if nothing to withdraw — prevents zero-value transfers
        require(amount != 0, NothingToWithdraw());

        // CEI: zero the balance BEFORE the external call to prevent reentrancy
        $._proverRewards[prover] = 0;
        // Balance zeroed before transfer (CEI) and nonReentrant guard is active — false positive
        (bool success, ) = prover.call{value: amount}(""); // wake-disable-line reentrancy
        require(success, EthTransferFailed(prover, amount));

        emit ProofRewardClaimed(prover, amount);
    }

    // ============ Internal — lifecycle ============

    /**
     * @dev Checks if the rollup is corrupted by examining the oldest non-finalized batch.
     *      Corruption occurs when any of the following deadlines are exceeded:
     *      - `submitBlobsWindow`: blob hashes not submitted in time (HeadersSubmitted).
     *      - `challengeWindow`: open challenge not resolved before its deadline (Challenged).
     */
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        // Check only the oldest non-finalized batch — corruption is sequential
        uint256 batchIndex = uint256($._lastFinalizedBatchIndex) + 1;
        // If all batches are finalized (or none exist), the rollup is healthy
        if (batchIndex >= $._nextBatchIndex) return false;

        BatchRecord storage batch = $._batches[batchIndex];
        BatchStatus status = batch.status;
        // Cache the L1 block at which this batch was accepted — all deadlines anchor here
        uint256 accepted = uint256(batch.acceptedAtBlock);

        // Deadline 1: sequencer failed to submit blobs within the allowed window
        // (window value of 0 means this deadline is disabled)
        if (status == BatchStatus.HeadersSubmitted && $._submitBlobsWindow != 0 && block.number > accepted + $._submitBlobsWindow) return true;
        // Deadline 2: a challenge exists whose resolution deadline has passed
        // Peek at the min-heap root — the challenge with the earliest deadline
        if (status == BatchStatus.Challenged && !$._challengeQueue.isEmpty()) {
            return $._challenges[$._challengeQueue.peek()].deadline < block.number;
        }
        // No deadline violated — rollup is healthy
        return false;
    }

    /**
     * @dev Attempts to finalize a single batch if the finalization delay has passed.
     *      Returns true if finalized (now or previously), false if not yet eligible.
     */
    function _tryFinalizeBatch(uint256 batchIndex) internal returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $._batches[batchIndex];

        // Already done — allow the caller loop to continue to the next batch
        if (batch.status == BatchStatus.Finalized) return true;
        // Only preconfirmed batches are eligible; anything else stops the loop
        // (HeadersSubmitted, Accepted, Challenged batches cannot be finalized)
        if (batch.status != BatchStatus.Preconfirmed) return false;
        // Batches must finalize in order — gap means a predecessor is not ready yet
        if (batchIndex != uint256($._lastFinalizedBatchIndex) + 1) return false;
        // Delay not elapsed — batch needs to age before finalization is allowed
        // This gives challengers time to dispute before the batch becomes irreversible
        if (block.number - uint256(batch.acceptedAtBlock) <= $._finalizationDelay) return false;

        // State transition: Preconfirmed → Finalized (irreversible)
        batch.status = BatchStatus.Finalized;
        // Advance the finalization watermark so the next batch becomes eligible
        if (batchIndex > type(uint64).max) return false;
        // casting to 'uint64' is safe because we guard the bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._lastFinalizedBatchIndex = uint64(batchIndex);
        emit BatchFinalized(batchIndex);
        return true;
    }

    // ============ Internal — verification ============

    /**
     * @dev Validates that the commitment is challenged, not yet proven, and present in the batch root.
     */
    function _validateChallenge(uint256 batchIndex, bytes32 commitment, MerkleTree.MerkleProof calldata blockProof) private view {
        RollupStorage storage $ = _getRollupStorage();
        ChallengeRecord storage challenged = $._challenges[commitment];
        // A batchIndex of 0 means no challenge record exists (index 0 is reserved for genesis)
        require(challenged.batchIndex != 0, BlockNotChallenged(commitment));
        // Cannot re-prove a block that has already been proven — prevents double reward
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        // Verify the challenged block is actually part of the batch's Merkle tree
        // (prevents a prover from submitting a proof for a different block)
        require(
            MerkleTree.verifyMerkleProof($._batches[batchIndex].batchRoot, commitment, blockProof.nonce, blockProof.proof),
            InvalidBlockProof()
        );

        // Enforce the recorded per-challenge resolution deadline —
        // if the prover misses this deadline, the rollup enters corrupted state
        require(block.number <= challenged.deadline, ChallengeResolutionTooLate(batchIndex, challenged.deadline, block.number));
    }

    /**
     * @dev Verifies both Nitro and SP1 proofs for an L2 block.
     */
    function _verifyNitroAndSp1(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address nitroVerifier,
        bytes calldata nitroSignature,
        bytes calldata sp1Proof
    ) private view {
        // First verify the Nitro verifier is on the admin whitelist
        _validateNitroVerifier(nitroVerifier);
        RollupStorage storage $ = _getRollupStorage();
        // Copy blob hashes to memory — passed to both verifiers to bind proofs to on-chain DA
        bytes32[] memory blobHashes = $._batchBlobHashes[batchIndex];

        // Verification path 1: Nitro enclave attestation — proves the TEE processed this block
        // External call to a trusted (whitelisted) verifier; reverts if signature is invalid
        INitroVerifier(nitroVerifier).verifyBlock(
            blockHeader.previousBlockHash,
            blockHeader.blockHash,
            blockHeader.withdrawalRoot,
            blockHeader.depositRoot,
            nitroSignature,
            blobHashes
        );
        // Verification path 2: SP1 ZK proof — mathematically proves block execution correctness
        // Both paths must succeed for a challenge to be resolved
        _proveBlockWithSp1(sp1Verifier(), blobHashes, blockHeader, sp1Proof);
    }

    /**
     * @dev Validates that `verifier` is whitelisted.
     */
    function _validateNitroVerifier(address verifier) private view {
        RollupStorage storage $ = _getRollupStorage();
        // Only admin-whitelisted Nitro verifier contracts are trusted;
        // prevents callers from passing a malicious verifier that always returns true
        require($._enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
    }

    /**
     * @dev Verifies an L2 block header with SP1 ZK proof. Reverts on invalid proof.
     */
    function _proveBlockWithSp1(
        address verifier,
        bytes32[] memory blobHashes,
        L2BlockHeader calldata header,
        bytes memory sp1Proof
    ) private view {
        // Construct the public values that the ZK circuit committed to:
        // block header fields + blob hashes — binds the proof to specific on-chain data
        bytes memory publicValues = abi.encodePacked(
            abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot),
            blobHashes
        );
        // External call to the SP1 verifier contract — reverts if the ZK proof is invalid
        // or if publicValues don't match what the prover circuit committed to
        ISP1Verifier(verifier).verifyProof(_getRollupStorage()._programVKey, publicValues, sp1Proof);
    }

    /**
     * @dev Computes the commitment hash for an L2 block header.
     */
    function _computeCommitment(L2BlockHeader calldata header) private pure returns (bytes32) {
        // Hash all four header fields into a single commitment — serves as the Merkle leaf
        // and the unique key for challenge/proof records
        return keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
    }

    // ============ Internal — helpers ============

    /**
     * @dev Verifies that L1 deposits match the depositRoot in the block header and records
     *      the popped deposit IDs against `batchIndex` so they can be restored by
     *      {_cleanupForceRevertBatch} on force-revert.
     *      Called after all state writes in acceptNextBatch (CEI pattern) and within
     *      a nonReentrant guard — reentrancy warning is a false positive.
     */
    function _checkDeposits(uint256 batchIndex, L2BlockHeader calldata header) private {
        RollupStorage storage $ = _getRollupStorage();
        // Cache the deposit freshness deadline to avoid repeated storage reads in the loop
        uint256 deadline = $._acceptDepositDeadline;
        // Allocate in-memory array for the root verification at the end of the loop
        bytes32[] memory depositIds = new bytes32[](header.depositCount);
        // Storage array to append popped IDs for force-revert restoration
        bytes32[] storage persisted = $._batchDepositIds[batchIndex];
        for (uint256 i = 0; i < header.depositCount; ++i) {
            // External call to the bridge: pops the next deposit from the FIFO queue
            // Called after all state writes in acceptNextBatch (CEI) under nonReentrant guard
            (bytes32 depositId, uint256 depositBlockNumber) = IL1FluentBridge($._bridge).popSentMessage(); // wake-disable-line reentrancy
            // Ensure the deposit is not stale — prevents sequencers from including very old deposits
            require(block.number <= depositBlockNumber + deadline, AcceptDepositDeadlineExceeded(depositBlockNumber + deadline, block.number));
            depositIds[i] = depositId;
            // Persist so force-revert can restore this exact hash back to the queue front
            persisted.push(depositId);
        }
        // Final integrity check: the hash of all popped deposit IDs must match the header's
        // depositRoot — ensures the sequencer included exactly these deposits in the L2 block
        require(keccak256(abi.encodePacked(depositIds)) == header.depositRoot, DepositRootMismatch(header.blockHash));
    }

    /**
     * @dev Removes a commitment from the challenge heap and cleans up its priority entry.
     */
    function _removeChallengeFromQueue(bytes32 commitment) private {
        RollupStorage storage $ = _getRollupStorage();
        // Remove from the min-heap; returns true if the element was found and removed
        // If removal succeeds, also clean up the priority mapping to avoid stale entries
        if ($._challengeQueue.remove($._challengePriority, $._challengeQueueIndex, commitment)) {
            delete $._challengePriority[commitment];
        }
    }

    /**
     * @dev Calculates the Merkle root of a batch of L2 block headers.
     */
    function _calculateBatchRoot(L2BlockHeader[] calldata headers) private pure returns (bytes32) {
        // Allocate a flat byte array for all leaf hashes (32 bytes each)
        bytes memory leafs = new bytes(headers.length * 32);
        for (uint256 i = 0; i < headers.length; ++i) {
            // Each leaf is the keccak commitment of the block header's four fields
            bytes32 hash = keccak256(
                abi.encodePacked(headers[i].previousBlockHash, headers[i].blockHash, headers[i].withdrawalRoot, headers[i].depositRoot)
            );
            // Direct memory write avoids the overhead of abi.encodePacked in a loop;
            // offset: skip the 32-byte length prefix of `leafs`, then write at slot i
            assembly ("memory-safe") {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }
        // Build the Merkle tree from the flat leaf array and return the root
        return MerkleTree.calculateMerkleRoot(leafs);
    }

    /**
     * @dev Returns the blob hash for the given index using the BLOBHASH opcode.
     */
    function _getBlobHash(uint256 index) private view returns (bytes32 blobHash) {
        // EIP-4844 BLOBHASH opcode: returns the versioned hash of the blob at `index`
        // in the current transaction; returns bytes32(0) if index is out of range
        assembly ("memory-safe") {
            blobHash := blobhash(index)
        }
    }
}
