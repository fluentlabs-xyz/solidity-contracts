// SPDX-License-Identifier: MIT
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
 * @dev Rollup contract serves as a Optimistic Rollup in a relation with FluentBridge with two verifier paths: AWS Nitro Enclave for preconfirmation
 * and SP1 for ZK proof-based challenge resolution.
 *
 * Batches progress through five statuses: HeadersSubmitted → Accepted → Preconfirmed →
 * Finalized, with Challenged as a transient branch from Preconfirmed that resolves back
 * to Preconfirmed once all disputes are settled.
 *
 * All timing windows are measured from the block in which `acceptNextBatch` was called
 * ({BatchRecord-acceptedAtBlock}). The windows are:
 * - {RollupStorage-submitBlobsWindow}: deadline for the sequencer to submit blob hashes.
 * - {RollupStorage-preconfirmWindow}: deadline for the preconfirmation service to confirm.
 * - {RollupStorage-challengeWindow}: deadline by which open challenges must be resolved.
 * - {RollupStorage-finalizationDelay}: minimum wait before a batch can be finalized.
 *
 * If any deadline is exceeded, {isRollupCorrupted} returns true and all state-changing
 * functions revert with {RollupCorrupted} until the corrupted batch is cleared via
 * {forceRevertBatch}.
 */
contract Rollup is RollupStorageLayout, IRollupWrite, IRollupEmergency {
    using Heap for Heap.HeapStorage;

    // ============ Constructor ============

    /// @dev https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#initializing_the_implementation_contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the upgradeable rollup (replaces constructor when used behind a proxy).
     * @param data ABI-encoded {InitConfiguration}.
     */
    function initialize(bytes memory data) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        __RollupStorage_init(data);
    }

    // ============ IRollupEmergency ============

    /// @inheritdoc IRollupEmergency
    function isRollupCorrupted() external view returns (bool) {
        return _rollupCorrupted();
    }

    /// @inheritdoc IRollupEmergency
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @inheritdoc IRollupEmergency
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /// @inheritdoc IRollupEmergency
    function forceRevertBatch(uint256 toBatchIndex) external payable onlyRole(EMERGENCY_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        uint256 lastAcceptedBatchIndex = $._nextBatchIndex - 1;
        require(toBatchIndex > 0, ZeroValueNotAllowed(bytes32(toBatchIndex)));
        require(lastAcceptedBatchIndex - toBatchIndex <= $._maxForceRevertBatchSize, InvalidBatchIndex(toBatchIndex, lastAcceptedBatchIndex));

        for (uint256 i = lastAcceptedBatchIndex; i > toBatchIndex; i--) {
            require($._batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        // If we are calling this function - it means we must incentivize challengers and pay fees.
        uint256 totalIncentiveFees = 0;
        uint256 fee = $._incentiveFee;

        for (uint256 i = lastAcceptedBatchIndex; i > toBatchIndex; i--) {
            totalIncentiveFees += _processForceRevertChallenged($._batchChallengedBlocks[i], fee);
            _cleanupForceRevertBatch(i);
        }

        require(msg.value >= totalIncentiveFees, NotEnoughValueIncentiveFee(msg.value, totalIncentiveFees));
        $._nextBatchIndex = uint96(toBatchIndex + 1);

        emit BatchReverted(toBatchIndex);
    }

    function _processForceRevertChallenged(bytes32[] storage challengedBlocks, uint256 fee) internal returns (uint256 totalFees) {
        RollupStorage storage $ = _getRollupStorage();
        for (uint256 i = 0; i < challengedBlocks.length; i++) {
            bytes32 commitment = challengedBlocks[i];
            ChallengeRecord storage challenge = $._challenges[commitment];
            address challenger = challenge.challenger;

            if (challenger != address(0)) {
                // Refund the actual locked deposit and pay an incentive fee.
                $._challengerRewards[challenger] += challenge.deposit + fee;
                totalFees += fee;
            }

            _removeChallengeFromQueue(commitment);

            delete $._challenges[commitment];
            delete $._provenBlocks[commitment];
        }
    }

    function _cleanupForceRevertBatch(uint256 batchIndex) internal {
        RollupStorage storage $ = _getRollupStorage();
        delete $._batches[batchIndex];
        delete $._batchProvenBlocks[batchIndex];
        delete $._batchChallengedBlocks[batchIndex];
        delete $._batchBlobHashes[batchIndex];
        delete $._lastBlockHashInBatch[batchIndex];
    }

    // ============ Sequencer ============

    /// @inheritdoc IRollupWrite
    function acceptNextBatch(
        L2BlockHeader[] calldata blockHeaders,
        uint256 expectedBlobsCount
    ) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        RollupStorage storage $ = _getRollupStorage();

        uint256 batchIndex = $._nextBatchIndex;
        require(!_rollupCorrupted(), RollupCorrupted());

        uint256 batchSize = blockHeaders.length;
        require(batchSize > 0, NoLeavesProvided());
        require(
            blockHeaders[0].previousBlockHash == $._lastBlockHashInBatch[batchIndex - 1],
            WrongPreviousBlockHash($._lastBlockHashInBatch[batchIndex - 1], blockHeaders[0].previousBlockHash)
        );

        uint256 gasLeft = $._gasLeft;

        // Phase 1: validate header chain and deposit metadata only (adjacent pairs; single-block batches skip).
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            require(
                blockHeaders[i].blockHash == blockHeaders[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockHeaders[i].blockHash, blockHeaders[i + 1].previousBlockHash)
            );
        }

        if (blockHeaders[batchSize - 1].depositRoot == ZERO_BYTES_HASH) {
            require(blockHeaders[batchSize - 1].depositCount == 0, InvalidDepositRootWithNonZeroCount(blockHeaders[batchSize - 1].depositCount));
        }

        bytes32 batchRoot = _calculateBatchRoot(blockHeaders);

        // Effects
        BatchRecord storage batch = $._batches[batchIndex];
        batch.batchRoot = batchRoot;
        batch.acceptedAtBlock = uint64(block.number);
        batch.expectedBlobs = uint32(expectedBlobsCount);
        batch.status = BatchStatus.HeadersSubmitted;
        $._lastBlockHashInBatch[batchIndex] = blockHeaders[batchSize - 1].blockHash;
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        $._nextBatchIndex = uint96(batchIndex + 1);

        // Phase 2: external bridge interactions after validation/state writes.
        for (uint256 i = 0; i < batchSize; ++i) {
            if (blockHeaders[i].depositRoot != ZERO_BYTES_HASH) _checkDeposits(blockHeaders[i]);
        }

        emit BatchHeadersSubmitted(batchIndex, batchRoot, expectedBlobsCount);
    }

    /// @inheritdoc IRollupWrite
    function submitBlobs(uint256 batchIndex, uint256 numBlobs) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        BatchRecord storage batch = $._batches[batchIndex];
        bytes32[] storage blobHashes = $._batchBlobHashes[batchIndex];

        require(numBlobs > 0, ZeroValueNotAllowed("numBlobs"));
        require(blobHashes.length + numBlobs <= batch.expectedBlobs, InvalidBlobCount(batch.expectedBlobs, blobHashes.length + numBlobs));
        require(batch.status == BatchStatus.HeadersSubmitted, InvalidBatchStatus(batchIndex, uint8(batch.status)));

        if ($._submitBlobsWindow != 0) {
            require(
                block.number <= uint256(batch.acceptedAtBlock) + $._submitBlobsWindow,
                SubmitBlobsWindowExceeded(uint256(batch.acceptedAtBlock) + $._submitBlobsWindow, block.number)
            );
        }

        for (uint256 i = 0; i < numBlobs; ++i) {
            bytes32 blobHash = _getBlobHash(i);
            // we check whether we're still reading the blobs
            require(blobHash != bytes32(0), ZeroValueNotAllowed("blobHash"));
            blobHashes.push(blobHash);
        }

        emit BatchBlobsSubmitted(batchIndex, numBlobs, blobHashes.length);

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
        _validateNitroVerifier(nitroVerifier);

        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        require(batch.status == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        address verifier = INitroVerifier(nitroVerifier).verifyBatch(batch.batchRoot, $._batchBlobHashes[batchIndex], signature);

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
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        require(batch.status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(msg.value == $._challengeDepositAmount, IncorrectChallengeDeposit($._challengeDepositAmount, msg.value));
        require(block.number < uint256(batch.acceptedAtBlock) + $._challengeWindow, ChallengeTooLate(batchIndex));

        bytes32 commitment = _computeCommitment(blockHeader);
        require(MerkleTree.verifyMerkleProof(batch.batchRoot, commitment, blockProof.nonce, blockProof.proof), InvalidBlockProof());
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        // batchIndex is greater 0 anytime
        require($._challenges[commitment].batchIndex == 0, BlockAlreadyChallenged(commitment));

        batch.status = BatchStatus.Challenged;
        $._batchChallengedBlocks[batchIndex].push(commitment);

        uint256 deadline = uint256(batch.acceptedAtBlock) + $._challengeWindow;
        $._challenges[commitment] = ChallengeRecord({deposit: msg.value, challenger: _msgSender(), deadline: deadline, batchIndex: batchIndex});
        // deadline written as heap priority — queue ordered by earliest expiry
        $._challengePriority[commitment] = deadline;
        $._challengeQueue.push($._challengePriority, $._challengeQueueIndex, commitment);

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
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        bytes32 commitment = _computeCommitment(blockHeader);

        _validateChallenge(batchIndex, commitment, blockProof);
        _verifyNitroAndSp1(batchIndex, blockHeader, nitroVerifier, nitroSignature, sp1Proof);

        ChallengeRecord storage challenged = $._challenges[commitment];
        uint256 deposit = challenged.deposit;

        $._provenBlocks[commitment] = true;
        $._batchProvenBlocks[batchIndex].push(commitment);
        $._proverRewards[_msgSender()] += deposit;

        delete $._challenges[commitment];
        _removeChallengeFromQueue(commitment);

        // TODO: remove
        _maybeReturnBatchToPreconfirmed(batchIndex);
        emit ChallengeResolved(batchIndex, commitment, _msgSender());
    }

    /// @dev When every challenged commitment in the batch has a corresponding proof, status returns to Preconfirmed.
    function _maybeReturnBatchToPreconfirmed(uint256 batchIndex) private {
        RollupStorage storage $ = _getRollupStorage();
        if ($._batchChallengedBlocks[batchIndex].length == $._batchProvenBlocks[batchIndex].length) {
            $._batches[batchIndex].status = BatchStatus.Preconfirmed;
        }
    }

    // ============ Anyone ============

    /// @inheritdoc IRollupWrite
    function finalizeBatches(uint256 toBatchIndex) external whenNotPaused returns (uint256 finalized) {
        RollupStorage storage $ = _getRollupStorage();
        require(toBatchIndex < $._nextBatchIndex, InvalidBatchIndex(toBatchIndex, $._nextBatchIndex));

        uint256 from = uint256($._lastFinalizedBatchIndex) + 1;
        for (uint256 i = from; i <= toBatchIndex; ++i) {
            if (!_tryFinalizeBatch(i)) break;
            ++finalized;
        }
    }

    /// @inheritdoc IRollupWrite
    function finalizeWithProofs(uint256 batchIndex, L2BlockHeader[] calldata blockHeaders) external whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $._batches[batchIndex];

        require(batch.status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(batchIndex == uint256($._lastFinalizedBatchIndex) + 1, InvalidBatchIndex(batchIndex, uint256($._lastFinalizedBatchIndex) + 1));

        // verify supplied headers reconstruct the accepted batchRoot
        require(_calculateBatchRoot(blockHeaders) == batch.batchRoot, InvalidBlockProof());

        // verify every block commitment has been proven
        for (uint256 i = 0; i < blockHeaders.length; ++i) {
            bytes32 commitment = _computeCommitment(blockHeaders[i]);
            require($._provenBlocks[commitment], BlockNotProven(commitment));
        }

        batch.status = BatchStatus.Finalized;
        $._lastFinalizedBatchIndex = uint64(batchIndex);
        emit BatchFinalized(batchIndex);
    }

    /// @inheritdoc IRollupWrite
    function withdrawChallengerReward() external nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        address payable challenger = payable(_msgSender());
        uint256 amount = $._challengerRewards[challenger];
        require(amount != 0, NothingToWithdraw());

        $._challengerRewards[challenger] = 0;
        // Balance zeroed before transfer (CEI) and nonReentrant guard is active — false positive
        (bool success, ) = challenger.call{value: amount}(""); // wake-disable-line reentrancy
        require(success, EthTransferFailed(challenger, amount));

        emit ChallengerRewardClaimed(challenger, amount);
    }

    /// @inheritdoc IRollupWrite
    function withdrawProofReward() external nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        address payable prover = payable(_msgSender());
        uint256 amount = $._proverRewards[prover];
        require(amount != 0, NothingToWithdraw());

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
     *      - `preconfirmWindow`: batch not preconfirmed in time (Accepted).
     *      - `challengeWindow`: open challenge not resolved before its deadline (Challenged).
     */
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($._lastFinalizedBatchIndex) + 1;
        if (batchIndex >= $._nextBatchIndex) return false;

        BatchRecord storage batch = $._batches[batchIndex];
        BatchStatus status = batch.status;
        uint256 accepted = uint256(batch.acceptedAtBlock);

        if (status == BatchStatus.HeadersSubmitted && $._submitBlobsWindow != 0 && block.number > accepted + $._submitBlobsWindow) return true;
        if (status == BatchStatus.Accepted && $._preconfirmWindow != 0 && block.number > accepted + $._preconfirmWindow) return true;
        if (status == BatchStatus.Challenged && !$._challengeQueue.isEmpty()) {
            return $._challenges[$._challengeQueue.peek()].deadline < block.number;
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

        if (batch.status == BatchStatus.Finalized) return true;
        if (batch.status != BatchStatus.Preconfirmed) return false;
        if (batchIndex != uint256($._lastFinalizedBatchIndex) + 1) return false;
        if (block.number - uint256(batch.acceptedAtBlock) <= $._finalizationDelay) return false;

        batch.status = BatchStatus.Finalized;
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
        require(challenged.batchIndex != 0, BlockNotChallenged(commitment));
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        require(
            MerkleTree.verifyMerkleProof($._batches[batchIndex].batchRoot, commitment, blockProof.nonce, blockProof.proof),
            InvalidBlockProof()
        );

        // Enforce the recorded per-challenge resolution deadline.
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
        _validateNitroVerifier(nitroVerifier);
        RollupStorage storage $ = _getRollupStorage();
        bytes32[] memory blobHashes = $._batchBlobHashes[batchIndex];

        INitroVerifier(nitroVerifier).verifyBlock(
            blockHeader.previousBlockHash,
            blockHeader.blockHash,
            blockHeader.withdrawalRoot,
            blockHeader.depositRoot,
            nitroSignature,
            blobHashes
        );
        _proveBlockWithSp1(sp1Verifier(), blobHashes, blockHeader, sp1Proof);
    }

    /**
     * @dev Validates that `verifier` is whitelisted.
     */
    function _validateNitroVerifier(address verifier) private view {
        RollupStorage storage $ = _getRollupStorage();
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
        bytes memory publicValues = abi.encodePacked(
            abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot),
            blobHashes
        );
        ISP1Verifier(verifier).verifyProof(_getRollupStorage()._programVKey, publicValues, sp1Proof);
    }

    /**
     * @dev Computes the commitment hash for an L2 block header.
     */
    function _computeCommitment(L2BlockHeader calldata header) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
    }

    // ============ Internal — helpers ============

    /**
     * @dev Verifies that L1 deposits match the depositRoot in the block header.
     *      Called after all state writes in acceptNextBatch (CEI pattern) and within
     *      a nonReentrant guard — reentrancy warning is a false positive.
     */
    function _checkDeposits(L2BlockHeader calldata header) private {
        RollupStorage storage $ = _getRollupStorage();
        uint256 deadline = $._acceptDepositDeadline;
        bytes32[] memory depositIds = new bytes32[](header.depositCount);
        for (uint256 i = 0; i < header.depositCount; ++i) {
            (bytes32 depositId, uint256 depositBlockNumber) = IL1FluentBridge($._bridge).popSentMessage(); // wake-disable-line reentrancy
            require(block.number <= depositBlockNumber + deadline, AcceptDepositDeadlineExceeded(depositBlockNumber + deadline, block.number));
            depositIds[i] = depositId;
        }
        require(keccak256(abi.encodePacked(depositIds)) == header.depositRoot, DepositRootMismatch(header.blockHash));
    }

    /**
     * @dev Removes a commitment from the challenge heap and cleans up its priority entry.
     */
    function _removeChallengeFromQueue(bytes32 commitment) private {
        RollupStorage storage $ = _getRollupStorage();
        if ($._challengeQueue.remove($._challengePriority, $._challengeQueueIndex, commitment)) {
            delete $._challengePriority[commitment];
        }
    }

    /**
     * @dev Calculates the Merkle root of a batch of L2 block headers.
     */
    function _calculateBatchRoot(L2BlockHeader[] calldata headers) private pure returns (bytes32) {
        bytes memory leafs = new bytes(headers.length * 32);
        for (uint256 i = 0; i < headers.length; ++i) {
            bytes32 hash = keccak256(
                abi.encodePacked(headers[i].previousBlockHash, headers[i].blockHash, headers[i].withdrawalRoot, headers[i].depositRoot)
            );
            assembly {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }
        return MerkleTree.calculateMerkleRoot(leafs);
    }

    /**
     * @dev Returns the blob hash for the given index using the BLOBHASH opcode.
     */
    function _getBlobHash(uint256 index) private view returns (bytes32 blobHash) {
        assembly {
            blobHash := blobhash(index)
        }
    }
}
