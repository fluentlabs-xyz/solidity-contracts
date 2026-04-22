// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {Heap} from "../libraries/Heap.sol";
import {RollupStorageLayout} from "./RollupStorageLayout.sol";

import {IRollupWrite, IRollupEmergency} from "../interfaces/rollup/IRollup.sol";
import {ISP1Verifier} from "../interfaces/verifiers/ISP1Verifier.sol";
import {INitroVerifier} from "../interfaces/verifiers/INitroVerifier.sol";
import {IL1FluentBridge} from "../interfaces/bridge/IL1FluentBridge.sol";
import {L2BlockHeader, BatchStatus, BatchRecord, ChallengeRecord, BlockDeposit} from "../interfaces/rollup/IRollupTypes.sol";

/**
 * @title Rollup
 * @author Fluent Labs
 * @dev Rollup contract serves as an Optimistic Rollup in a relation with FluentBridge with two verifier paths: AWS Nitro Enclave for preconfirmation
 * and SP1 for ZK proof-based challenge resolution.
 *
 * Batches progress through five statuses: Committed → Submitted → Preconfirmed →
 * Finalized, with Challenged as a transient branch from Preconfirmed that resolves back
 * to Preconfirmed once all disputes are settled.
 *
 * All timing windows are measured from the block in which {commitBatch} was called
 * ({BatchRecord-acceptedAtBlock}). The windows are:
 * - {RollupStorage-submitBlobsWindow}: deadline for the sequencer to submit blob hashes.
 * - {RollupStorage-preconfirmWindow}: deadline for the preconfirmation service to confirm.
 * - {RollupStorage-challengeWindow}: deadline by which open challenges must be resolved.
 * - {RollupStorage-finalizationDelay}: minimum wait before a batch can be finalized.
 *
 * If any deadline is exceeded, {isRollupCorrupted} returns true and all state-changing
 * functions revert with {RollupCorrupted} until the corrupted batch is cleared via
 * {revertBatches}.
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
 * regardless of when the challenge was created. If the prover cannot submit an SP1 proof
 * before that deadline, the rollup enters the corrupted (safety-halt) state. This is by design:
 *
 * - *No funds are at risk* — the corrupted state blocks all mutations until
 *   {EMERGENCY_ROLE} calls {revertBatches} to roll back the affected batch.
 * - The challenger's deposit remains locked in the reverted challenge record and is not
 *   returned, disincentivizing frivolous last-moment challenges.
 * - The sequencer can re-submit the batch after the corrupted state is cleared.
 *
 * Operators should therefore ensure the prover infrastructure can generate SP1 proofs
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
    function revertBatches(uint256 toBatchIndex) external payable onlyRole(EMERGENCY_ROLE) nonReentrant {
        // Access control: EMERGENCY_ROLE + nonReentrant guard (payable — receives ETH for incentive fees)
        RollupStorage storage $ = _getRollupStorage();
        // Identify the most recent batch so we know the revert range [toBatchIndex .. lastAccepted]
        uint256 lastAcceptedBatchIndex = $._nextBatchIndex - 1;
        // Index 0 holds the genesis hash and must never be reverted
        require(toBatchIndex > 0, ZeroToBatchIndex());
        // Reject indices beyond the latest accepted batch — prevents fat-fingered calls from
        // silently jumping _nextBatchIndex forward and creating unreachable gaps in batch indexing.
        require(toBatchIndex <= lastAcceptedBatchIndex, InvalidBatchIndex(toBatchIndex, $._nextBatchIndex));

        uint256 gasLeft = $._gasLeft;
        // Safety check: finalized batches are immutable and must never be rolled back
        for (uint256 i = lastAcceptedBatchIndex; i >= toBatchIndex; i--) {
            require(gasleft() >= gasLeft, InsufficientGas());
            require($._batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        // Incentive accounting: challengers who flagged bad batches get their deposit back + a fee
        uint256 totalIncentiveFees = 0;
        // Cache the per-challenge incentive fee to avoid repeated storage reads in the loop
        uint256 fee = $._incentiveFee;

        // Capture the rewind target before the cleanup loop deletes the BatchRecord.
        uint64 rewindTarget = $._batches[toBatchIndex].sentMessageCursorStart;

        // Process each batch in reverse order: refund both challenge families and wipe batch storage
        for (uint256 i = lastAcceptedBatchIndex; i >= toBatchIndex; i--) {
            totalIncentiveFees += _processRevertBlockChallenges($._batchChallengedBlocks[i], fee);
            totalIncentiveFees += _processRevertBatchRootChallenge(i, fee);
            _cleanupRevertedBatch(i);
        }

        // Single bridge call to rewind the consume cursor — replaces the per-deposit
        // pushSentMessage loop that the previous fix used. Safe under nonReentrant
        // (forceRevertBatch is nonReentrant) and against the trusted bridge.
        IL1FluentBridge($._bridge).rewindSentMessageCursor(rewindTarget); // wake-disable-line reentrancy

        // Caller must send enough ETH to cover all incentive fees owed to challengers
        require(msg.value >= totalIncentiveFees, NotEnoughValueIncentiveFee(msg.value, totalIncentiveFees));
        // Reset the batch counter so the next batch reuses the revert target index.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._nextBatchIndex = uint64(toBatchIndex);

        // Refund any overpayment back to the caller (underflow safe: require above guarantees msg.value >= totalIncentiveFees)
        uint256 refund = msg.value - totalIncentiveFees;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, EthTransferFailed(msg.sender, refund));
        }

        // Notify off-chain indexers that all batches from toBatchIndex onward have been rolled back
        emit BatchReverted(toBatchIndex);
    }

    /**
     * @dev Iterates open block challenges for `batchIndex` during {revertBatches}: refunds
     *      challenger deposit + incentive fee (credited via the pull pattern), and wipes
     *      per-commitment challenge state. Renamed from `_processRevertChallenged` per Q5+A2;
     *      sibling helper {_processRevertBatchRootChallenge} handles the batch-root family.
     * @return totalFees Sum of incentive fees credited to challengers in this batch.
     */
    function _processRevertBlockChallenges(bytes32[] storage challengedBlocks, uint256 fee) internal returns (uint256 totalFees) {
        RollupStorage storage $ = _getRollupStorage();
        // Iterate every challenged block commitment in this batch
        for (uint256 i = 0; i < challengedBlocks.length; i++) {
            bytes32 commitment = challengedBlocks[i];
            ChallengeRecord storage challenge = $._blockChallenges[commitment];
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
            delete $._blockChallenges[commitment];
            delete $._provenBlocks[commitment];
        }
    }

    /**
     * @dev Refunds the active batch-root challenger for `batchIndex` during {revertBatches}.
     *      Q5: closes G4 — previously the batch-root challenger deposit was silently slashed
     *      because the cleanup path used the wrong storage map and the wrong queue.
     * @return totalFees Incentive fee credited (0 if no batch-root challenge open).
     */
    function _processRevertBatchRootChallenge(uint256 batchIndex, uint256 fee) internal returns (uint256 totalFees) {
        RollupStorage storage $ = _getRollupStorage();
        if ($._batchRootChallenges[batchIndex].challenger != address(0)) {
            ChallengeRecord storage rec = $._batchRootChallenges[batchIndex];
            $._challengerRewards[rec.challenger] += uint256(rec.deposit) + fee;
            totalFees += fee;
            delete $._batchRootChallenges[batchIndex];
            delete $._provenBatchRoots[batchIndex];
        }
    }

    /**
     * @dev Deletes all per-batch storage associated with `batchIndex` during {revertBatches}:
     *      blob hashes, challenged blocks, proven blocks, batch record. Per-challenge state
     *      is wiped by the two refund helpers above before this is called.
     *
     *      Bridge cursor rewind happens once at the end of {revertBatches}, not per-batch,
     *      so this function does not touch the bridge.
     */
    function _cleanupRevertedBatch(uint256 batchIndex) internal {
        RollupStorage storage $ = _getRollupStorage();
        delete $._batches[batchIndex];
        delete $._batchProvenBlocks[batchIndex];
        delete $._batchChallengedBlocks[batchIndex];
        delete $._batchBlobHashes[batchIndex];
    }

    /// @inheritdoc IRollupEmergency
    function emergencyRevokeRole(bytes32 role, address account) external onlyRole(EMERGENCY_ROLE) {
        require(
            role == SEQUENCER_ROLE || role == PRECONFIRMATION_ROLE || role == CHALLENGER_ROLE || role == PROVER_ROLE,
            InvalidOperationalRole(role)
        );
        _revokeRole(role, account);
    }

    // ============ Sequencer ============

    /// @inheritdoc IRollupWrite
    function commitBatch(
        bytes32 batchRoot,
        bytes32 fromBlockHash,
        bytes32 toBlockHash,
        uint24 numberOfBlocks,
        BlockDeposit[] calldata blockDeposits,
        uint8 expectedBlobsCount
    ) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(batchRoot != bytes32(0), InvalidBatchRoot(batchRoot, bytes32(0)));
        require(fromBlockHash != bytes32(0), ZeroFromBlockHash());
        require(toBlockHash != bytes32(0), ZeroToBlockHash());
        require(numberOfBlocks > 0, ZeroNumberOfBlocks());
        require(expectedBlobsCount > 0, ZeroExpectedBlobsCount());
        require(!_rollupCorrupted(), RollupCorrupted());
        uint256 batchIndex = $._nextBatchIndex;
        if ($._batches[batchIndex - 1].toBlockHash != bytes32(0)) {
            require($._batches[batchIndex - 1].toBlockHash == fromBlockHash, InvalidBatchBlockRange());
        }

        uint64 cursor = IL1FluentBridge($._bridge).getSentMessageCursor();
        $._batches[batchIndex] = BatchRecord({
            batchRoot: batchRoot,
            status: BatchStatus.Committed,
            acceptedAtBlock: uint32(block.number),
            expectedBlobs: expectedBlobsCount,
            // Snapshot the bridge consume cursor at submission time.
            sentMessageCursorStart: cursor,
            submitBlobsWindowSnapshot: $._submitBlobsWindow,
            preconfirmationWindowSnapshot: $._preconfirmWindow,
            challengeWindowSnapshot: $._challengeWindow,
            finalizationDelaySnapshot: $._finalizationDelay,
            numberOfBlocks: numberOfBlocks,
            toBlockHash: toBlockHash
        });

        require(batchIndex + 1 <= type(uint64).max, NextBatchIndexOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        $._nextBatchIndex = uint64(batchIndex + 1);

        uint256 numberOfBlocksWithDeposits = blockDeposits.length;
        uint256 gasLeft = $._gasLeft;
        for (uint256 i = 0; i < numberOfBlocksWithDeposits; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            cursor = _checkDeposits(cursor, blockDeposits[i]);
        }

        emit BatchCommitted(batchIndex, batchRoot, fromBlockHash, toBlockHash, numberOfBlocks, expectedBlobsCount);
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

        // Packed arg: high byte = declared start index, low byte = count of blobs in this call.
        // Upper bits are reserved — reject anything outside the 16-bit envelope so a malformed
        // payload cannot be silently reinterpreted as a legacy-format first sidecar.
        require(numBlobs <= type(uint16).max, InvalidNumBlobs(numBlobs));
        uint8 declaredStartIndex = uint8(numBlobs >> 8);
        uint256 n = numBlobs & 0xFF;

        require(n > 0, ZeroNumBlobs());
        require(blobHashes.length + n <= batch.expectedBlobs, InvalidBlobCount(batch.expectedBlobs, blobHashes.length + n));
        require(batch.status == BatchStatus.Committed, InvalidBatchStatus(batchIndex, uint8(batch.status)));

        // Strict in-order guard. The caller pre-declares where this sidecar's blobs must start
        // in the array; the contract only accepts if that matches the current length. No extra
        // storage — blobHashes.length is already persisted as the array's length word. A plain
        // count (high byte = 0) is valid only for the first sidecar because declaredStartIndex=0
        // happens to equal the empty-array length.
        require(declaredStartIndex == blobHashes.length, OutOfOrderSidecar(declaredStartIndex, uint8(blobHashes.length)));

        uint256 deadline = uint256(batch.acceptedAtBlock) + uint256(batch.submitBlobsWindowSnapshot);
        require(block.number <= deadline, SubmitBlobsWindowExceeded(deadline, block.number));

        for (uint256 i = 0; i < n; ++i) {
            bytes32 blobHash = _getBlobHash(i);
            // Zero blobhash means the index is out of range — no more blobs in this tx
            require(blobHash != bytes32(0), ZeroBlobHash());
            // Append to persistent storage; later used by Nitro/SP1 verifiers for data binding
            blobHashes.push(blobHash);
        }

        emit BatchBlobsSubmitted(batchIndex, n, blobHashes.length);

        // Transition Committed → Submitted once all expected blobs are recorded
        if (blobHashes.length == batch.expectedBlobs) {
            batch.status = BatchStatus.Submitted;
            emit BatchSubmitted(batchIndex);
        }
    }

    // ============ Preconfirmation ============

    /// @inheritdoc IRollupWrite
    function preconfirmBatch(
        address nitroVerifier,
        uint256 batchIndex,
        bytes calldata signature
    ) external onlyRole(PRECONFIRMATION_ROLE) whenNotPaused nonReentrant {
        // Ensure the Nitro verifier contract is on the admin-maintained whitelist
        _validateNitroVerifier(nitroVerifier);

        RollupStorage storage $ = _getRollupStorage();
        // Halt if the rollup is in a corrupted state (deadline violation)
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        // Only batches with all blobs submitted (Submitted) can be preconfirmed
        require(batch.status == BatchStatus.Submitted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        // External call to the Nitro verifier: validates the enclave attestation signature
        // over the batch root and blob hashes; returns the signer address for the event
        address verifier = INitroVerifier(nitroVerifier).verifyBatch(batch.batchRoot, $._batchBlobHashes[batchIndex], signature);

        // State transition: Accepted → Preconfirmed; batch is now eligible for finalization or challenge
        batch.status = BatchStatus.Preconfirmed;
        emit BatchPreconfirmed(batchIndex, nitroVerifier, verifier);
    }

    // ============ Challenger ============

    /// @inheritdoc IRollupWrite
    function challengeBatchRoot(uint256 batchIndex) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        // batchIndex == 0 is the synthetic genesis batch (Finalized at init); it is rejected
        // by the status guard below. Real batches start at index 1.
        BatchRecord storage batch = $._batches[batchIndex];

        // Post-DA eligibility only — Committed (pre-blob) is excluded as DoS defense.
        // Already-Challenged batches cannot open another batch-root challenge.
        require(
            batch.status == BatchStatus.Submitted || batch.status == BatchStatus.Preconfirmed,
            InvalidBatchStatus(batchIndex, uint8(batch.status))
        );

        // Mutual exclusion: one batch-root challenge at a time, and not after it has been proven.
        require($._batchRootChallenges[batchIndex].challenger == address(0), BatchAlreadyChallenged(batchIndex));
        require(!$._provenBatchRoots[batchIndex], BatchRootAlreadyProven(batchIndex));
        // Exact deposit required — overpayment is not refunded, underpayment is rejected.
        require(msg.value == $._challengeDepositAmount, IncorrectChallengeDeposit($._challengeDepositAmount, msg.value));

        // Deadline from the snapshot captured at commit time; admin updates never affect in-flight batches.
        uint256 deadline = batch.acceptedAtBlock + batch.challengeWindowSnapshot;
        require(block.number < deadline, ChallengeTooLate(batchIndex));

        // Create the challenge record with the resolution deadline derived from the challenge window
        $._batchRootChallenges[batchIndex] = ChallengeRecord({
            batchIndex: batchIndex,
            deposit: msg.value,
            challenger: _msgSender(),
            deadline: deadline,
            previousStatus: batch.status
        });

        batch.status = BatchStatus.Challenged;

        // Notify off-chain watchers — provers monitor this event to begin generating proofs
        emit BatchRootChallenged(batchIndex);
    }

    /// @inheritdoc IRollupWrite
    function challengeBlock(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        // Cannot challenge when the rollup is already in a corrupted/halted state
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        // Challenges can only target Preconfirmed batches — not earlier or finalized ones
        // Note: We can't challenge a batch if its root has been challenged already
        require(batch.status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require($._batchRootChallenges[batchIndex].challenger == address(0), BatchRootChallengeOpen(batchIndex));
        // Exact deposit required — overpayment is not refunded, underpayment is rejected;
        // this deposit is forfeited to the prover if the challenge is resolved
        require(msg.value == $._challengeDepositAmount, IncorrectChallengeDeposit($._challengeDepositAmount, msg.value));
        // Challenge must be submitted before the challenge window closes (strict less-than)
        uint256 deadline = uint256(batch.acceptedAtBlock) + batch.challengeWindowSnapshot;
        // This is safe, since ChallengeWindowSnapshot is always less then (FinalizationDelay - MIN_CHALLENGE_RESOLUTION_WINDOW),
        // see `_setChallengeWindow` in RollupStorageLayout.sol
        require(block.number < deadline, ChallengeTooLate(batchIndex));

        // Compute the keccak commitment of the challenged block header
        bytes32 commitment = _computeCommitment(blockHeader);
        // Verify the block is actually part of this b`atch via Merkle inclusion proof
        require(MerkleTree.verifyMerkleProof(batch.batchRoot, commitment, blockProof.nonce, blockProof.proof), InvalidBlockProof());
        // A block that has already been proven correct cannot be challenged again
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        // Prevent duplicate challenges on the same block — batchIndex 0 is genesis (never used)
        require($._blockChallenges[commitment].batchIndex == 0, BlockAlreadyChallenged(commitment));

        // Record this commitment in the batch's challenged-blocks list
        $._batchChallengedBlocks[batchIndex].push(commitment);

        // Create the challenge record with the resolution deadline derived from the challenge window
        $._blockChallenges[commitment] = ChallengeRecord({
            deposit: msg.value,
            challenger: _msgSender(),
            deadline: deadline,
            batchIndex: batchIndex,
            previousStatus: batch.status
        });
        // State transition: Preconfirmed → Challenged (remains Challenged until all disputes resolve)
        batch.status = BatchStatus.Challenged;
        // Insert into the min-heap priority queue ordered by deadline — _rollupCorrupted()
        // peeks at the earliest deadline to detect expiry
        $._blockChallengePriority[commitment] = deadline;
        $._blockChallengeQueue.push($._blockChallengePriority, $._blockChallengeQueueIndex, commitment);

        // Notify off-chain watchers — provers monitor this event to begin generating proofs
        emit BlockChallenged(batchIndex, commitment, _msgSender());
    }

    // ============ Prover ============

    /// @inheritdoc IRollupWrite
    function resolveBatchRootChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata lastBlockHeaderInPreviousBatch,
        L2BlockHeader[] calldata blockHeaders,
        MerkleTree.MerkleProof calldata lastBlockProof
    ) external nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        // Cannot resolve challenges when the rollup is corrupted (must force-revert first)
        require(!_rollupCorrupted(), RollupCorrupted());

        BatchRecord storage batch = $._batches[batchIndex];
        require(batch.status == BatchStatus.Challenged, InvalidBatchStatus(batchIndex, uint8(batch.status)));

        ChallengeRecord storage challenged = $._batchRootChallenges[batchIndex];
        require(challenged.challenger != address(0), BatchRootNotChallenged(batchIndex));

        require(
            lastBlockHeaderInPreviousBatch.blockHash == blockHeaders[0].previousBlockHash,
            InvalidLastBlockHash(lastBlockHeaderInPreviousBatch.blockHash, blockHeaders[0].previousBlockHash)
        );
        bytes32 previousBatchRoot = $._batches[batchIndex - 1].batchRoot;
        // previousBatchNumberOfBlocks - 1 <-- last block number in the previous batch
        uint32 previousBatchNumberOfBlocks = $._batches[batchIndex - 1].numberOfBlocks;
        bytes32 lastBlockCommitment = _computeCommitment(lastBlockHeaderInPreviousBatch);
        // Verify the block is actually part of this batch via Merkle inclusion proof
        require(
            MerkleTree.verifyMerkleProof(previousBatchRoot, lastBlockCommitment, previousBatchNumberOfBlocks - 1, lastBlockProof.proof),
            InvalidBlockProof()
        );

        // Cache gas floor to prevent an out-of-gas DoS in the validation loop below
        uint256 gasLeft = $._gasLeft;
        uint256 batchSize = blockHeaders.length;

        // Phase 1: validate header chain linkage (adjacent block hash pairs; single-block batches skip).
        // Each header's blockHash must equal the next header's previousBlockHash
        require(
            blockHeaders[0].previousBlockHash == lastBlockHeaderInPreviousBatch.blockHash,
            WrongPreviousBlockHash(lastBlockHeaderInPreviousBatch.blockHash, blockHeaders[0].previousBlockHash)
        );

        for (uint256 i = 0; i < batchSize - 1; ++i) {
            // Ensure enough gas remains for each iteration to prevent partial execution
            require(gasleft() >= gasLeft, InsufficientGas());
            // Verify the sequential block hash chain — any break means corrupted or misordered headers
            require(
                blockHeaders[i].blockHash == blockHeaders[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockHeaders[i].blockHash, blockHeaders[i + 1].previousBlockHash)
            );
        }

        bytes32 batchRoot = _calculateBatchRoot(blockHeaders);
        require(batch.batchRoot == batchRoot, InvalidBatchRoot(batch.batchRoot, batchRoot));

        uint256 deposit = challenged.deposit;
        $._proverRewards[_msgSender()] += deposit;

        $._provenBatchRoots[batchIndex] = true;
        delete $._batchRootChallenges[batchIndex];
        batch.status = challenged.previousStatus;

        emit BatchRootChallengeResolved(batchIndex, _msgSender());
    }

    /// @inheritdoc IRollupWrite
    function resolveBlockChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        bytes calldata sp1Proof
    ) external nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        // Cannot resolve challenges when the rollup is corrupted (must force-revert first)
        require(!_rollupCorrupted(), RollupCorrupted());

        // Derive the commitment from the block header — this uniquely identifies the block
        bytes32 commitment = _computeCommitment(blockHeader);

        // Validate: challenge exists, not yet proven, and block is in the batch Merkle tree
        _validateChallenge(batchIndex, commitment, blockProof);
        // Verification: SP1 ZK proof must pass
        _proveBlockWithSp1(sp1Verifier(), $._batchBlobHashes[batchIndex], blockHeader, sp1Proof);

        ChallengeRecord storage challenged = $._blockChallenges[commitment];
        // Effects before interactions (CEI): credit reward before deleting challenge state
        // Mark the block as proven so it cannot be challenged again
        $._provenBlocks[commitment] = true;
        // Track proven blocks per batch — used to detect when all challenges are resolved
        $._batchProvenBlocks[batchIndex].push(commitment);
        // Transfer the challenger's deposit to the prover as a reward
        // (credited, not transferred — prover withdraws via withdrawProofReward)
        $._proverRewards[_msgSender()] += challenged.deposit;

        // When every challenged block in the batch has been proven, restore to Preconfirmed
        // so the batch can proceed toward finalization
        if ($._batchChallengedBlocks[batchIndex].length == $._batchProvenBlocks[batchIndex].length) {
            $._batches[batchIndex].status = challenged.previousStatus;
        }

        // Clean up: delete the challenge record and remove from the priority queue
        delete $._blockChallenges[commitment];
        _removeChallengeFromQueue(commitment);

        // Log resolution — off-chain systems track this to update batch confidence scores
        emit ChallengeResolved(batchIndex, commitment, _msgSender());
    }

    // ============ Anyone ============

    /// @inheritdoc IRollupWrite
    function finalizeBatches(uint256 toBatchIndex) external whenNotPaused returns (uint256 finalized) {
        RollupStorage storage $ = _getRollupStorage();
        // Target batch must exist (have been accepted at some point)
        require(toBatchIndex < $._nextBatchIndex, InvalidBatchIndex(toBatchIndex, $._nextBatchIndex));

        // Start from the batch right after the last finalized one (sequential finalization)
        uint256 from = uint256($._lastFinalizedBatchIndex) + 1;
        uint256 gasLeft = $._gasLeft;
        // Attempt to finalize each batch in order; stop at the first ineligible batch
        for (uint256 i = from; i <= toBatchIndex; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            // _tryFinalizeBatch returns false if the batch is not yet eligible (delay not met)
            if (!_tryFinalizeBatch(i)) break;
            ++finalized;
        }
    }

    /// @inheritdoc IRollupWrite
    function finalizeWithProofs(uint256 batchIndex, L2BlockHeader[] calldata blockHeaders) external whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $._batches[batchIndex];

        // Only Preconfirmed batches can be finalized (not Committed, Submitted, Challenged)
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

    /**
     * @dev Validates that `verifier` is whitelisted.
     */
    function isNitroVerifierEnabled(address verifier) external view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        return $._enabledNitroVerifiers[verifier];
    }

    // ============ Internal — lifecycle ============

    /**
     * @dev Checks if the rollup is corrupted. Two independent corruption signals:
     *      1. Deposit liveness: the bridge's oldest unconsumed sent message has missed its
     *         frozen processing deadline (Q6 defense 2). The bridge owns the timing parameter
     *         and snapshots; the rollup is a thin consumer reading one boolean.
     *      2. Batch staleness: deadlines on the oldest non-finalized batch have expired.
     *         - submitBlobsWindow: blob hashes not submitted in time (Committed).
     *         - challengeWindow: open challenge not resolved before its deadline (Challenged).
     *      Both window snapshots are frozen at commitBatch time and have a `> 0` invariant
     *      enforced at their setters (Q6 cleanup), so no `!= 0` defensive guard is needed.
     */
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();

        // deposit liveness — bridge owns timing
        if (IL1FluentBridge($._bridge).isOldestUnconsumedExpired()) return true;

        // Check only the oldest non-finalized batch — corruption is sequential
        uint256 batchIndex = uint256($._lastFinalizedBatchIndex) + 1;
        // If all batches are finalized (or none exist), the rollup is healthy
        if (batchIndex >= $._nextBatchIndex) return false;

        BatchRecord storage batch = $._batches[batchIndex];
        BatchStatus status = batch.status;
        // Cache the L1 block at which this batch was accepted — all deadlines anchor here
        uint256 accepted = uint256(batch.acceptedAtBlock);

        if (status == BatchStatus.Committed) {
            return block.number > accepted + uint256(batch.submitBlobsWindowSnapshot);
        }
        if (status == BatchStatus.Submitted) {
            return block.number > accepted + uint256(batch.preconfirmationWindowSnapshot);
        }
        if (status == BatchStatus.Challenged) {
            return block.number > accepted + uint256(batch.challengeWindowSnapshot);
        }
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
        // Only Preconfirmed batches are eligible; anything else stops the loop
        // (Committed, Submitted, Challenged batches cannot be finalized)
        if (batch.status != BatchStatus.Preconfirmed) return false;
        // Batches must finalize in order — gap means a predecessor is not ready yet
        if (batchIndex != uint256($._lastFinalizedBatchIndex) + 1) return false;
        // Delay not elapsed — batch needs to age before finalization is allowed.
        // This gives challengers time to dispute before the batch becomes irreversible.
        // Delay is read from the snapshot captured at acceptance time so admin updates
        // do not retroactively make already-accepted batches finalizable earlier.
        if (block.number - uint256(batch.acceptedAtBlock) <= uint256(batch.finalizationDelaySnapshot)) return false;

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
     *      The per-challenge deadline is no longer stored on {ChallengeRecord} — Q1+Q7 made the
     *      snapshot on {BatchRecord-challengeWindowSnapshot} the single source of truth, and the
     *      `!_rollupCorrupted()` check at the top of {resolveBlockChallenge} already enforces it
     *      via the corruption signal.
     */
    function _validateChallenge(uint256 batchIndex, bytes32 commitment, MerkleTree.MerkleProof calldata blockProof) private view {
        RollupStorage storage $ = _getRollupStorage();
        ChallengeRecord storage challenged = $._blockChallenges[commitment];
        // A batchIndex of 0 means no challenge record exists (index 0 is reserved for genesis)
        require(challenged.batchIndex != 0, BlockNotChallenged(commitment));
        // Caller must reference the same batch the challenge was opened against
        require(challenged.batchIndex == batchIndex, InvalidBatchIndex(batchIndex, challenged.batchIndex));
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
     * @dev Verifies that L1 deposits match the depositRoot in the block header.
     *      Called after all state writes in commitBatch (CEI pattern) and within
     *      a nonReentrant guard — reentrancy warning is a false positive.
     */
    function _checkDeposits(uint64 sentMessageCursor, BlockDeposit memory blockDeposit) private returns (uint64) {
        RollupStorage storage $ = _getRollupStorage();

        if (blockDeposit.depositRoot == ZERO_BYTES_HASH) {
            // If the block header claims an empty deposit tree, there must be zero deposits
            require(blockDeposit.depositCount == 0, InvalidDepositRootWithNonZeroCount(blockDeposit.depositCount));
        }

        // Allocate in-memory array for the root verification at the end of the loop
        bytes32[] memory depositIds = new bytes32[](blockDeposit.depositCount);

        for (uint256 i = 0; i < blockDeposit.depositCount; ++i) {
            // External call to the bridge: advances the consume cursor and returns the next hash.
            // Called after all state writes in commitBatch (CEI) under nonReentrant guard
            depositIds[i] = IL1FluentBridge($._bridge).getMessageAt(sentMessageCursor);
            unchecked {
                sentMessageCursor++;
            }
        }

        IL1FluentBridge($._bridge).advanceSentMessageCursor(blockDeposit.depositCount); // wake-disable-line reentrancy

        // Final integrity check: the hash of all popped deposit IDs must match the header's
        // depositRoot — ensures the sequencer included exactly these deposits in the L2 block
        bytes32 computedRoot = keccak256(abi.encodePacked(depositIds));
        require(computedRoot == blockDeposit.depositRoot, DepositRootMismatch(computedRoot, blockDeposit.depositRoot));

        return sentMessageCursor;
    }

    /**
     * @dev Removes a commitment from the challenge heap and cleans up its priority entry.
     */
    function _removeChallengeFromQueue(bytes32 commitment) private {
        RollupStorage storage $ = _getRollupStorage();
        // Remove from the min-heap; returns true if the element was found and removed
        // If removal succeeds, also clean up the priority mapping to avoid stale entries
        if ($._blockChallengeQueue.remove($._blockChallengePriority, $._blockChallengeQueueIndex, commitment)) {
            delete $._blockChallengePriority[commitment];
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
