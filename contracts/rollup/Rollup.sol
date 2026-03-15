// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {Heap} from "../libraries/Heap.sol";
import {RollupVerifier} from "./RollupVerifier.sol";

import {IRollupWrite, IRollupEmergency} from "../interfaces/IRollup.sol";
import {L2BlockHeader, BatchStatus, BatchRecord, ChallengeRecord} from "../interfaces/IRollupTypes.sol";
import {IFluentBridge} from "../interfaces/IFluentBridge.sol";

/**
 * @title Rollup Contract
 * @dev Rollup with two verifier paths: AWS Nitro Enclave (preconfirmation) and SP1 (ZK proof).
 *
 * ## Batch lifecycle
 * None → HeadersSubmitted → Accepted → Preconfirmed → Finalized
 *                                       ↕
 *                                  Challenged (if deadline exceeded → corrupted state)
 *
 * 1. **HeadersSubmitted**: Sequencer publishes L2 block headers via `acceptNextBatch`.
 * 2. **Accepted**: Sequencer submits blob hashes via `submitBlobs`.
 * 3. **Preconfirmed**: PRECONFIRMATION_ROLE calls `preconfirmBatch` with Nitro signature.
 * 4. **Finalized**: After `approveBlockCount` blocks, anyone calls `tryFinalizeBatch`.
 *
 * Challenged branches from Preconfirmed when a block is disputed.
 * Corrupted is a computed state — triggered by DA/preconfirm/challenge deadline expiry.
 * All state-changing functions check `_rollupCorrupted()` and revert if true.
 */
contract Rollup is RollupVerifier, IRollupWrite, IRollupEmergency {
    using Heap for Heap.HeapStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable rollup (replaces constructor when used behind a proxy).
    /// @param data ABI-encoded InitConfiguration.
    function initialize(bytes memory data) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __initRollupStorage(data);
    }

    // ============ Sequencer ============

    /// @inheritdoc IRollupWrite
    // TODO(d1r1): what happens if we send incorrect blobs for the batch? We need to allow sequencer
    // to fix it before the batch is accepted, otherwise we can end up in a situation where the batch
    // is stuck in HeadersSubmitted status and cannot move forward.
    function acceptNextBatch(L2BlockHeader[] calldata blockHeaders, uint256 expectedBlobsCount) external onlyRole(SEQUENCER_ROLE) whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();

        uint256 batchIndex = $.nextBatchIndex;
        require(!_rollupCorrupted(), RollupCorrupted());

        _finalizeBatch();

        uint256 batchSize = blockHeaders.length;
        require(
            blockHeaders[0].previousBlockHash == $.lastBlockHashInBatch[batchIndex - 1],
            WrongPreviousBlockHash($.lastBlockHashInBatch[batchIndex - 1], blockHeaders[0].previousBlockHash)
        );

        uint256 gasLeft = $.gasLeft;
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            require(
                blockHeaders[i].blockHash == blockHeaders[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockHeaders[i].blockHash, blockHeaders[i + 1].previousBlockHash)
            );
            if (blockHeaders[i].depositRoot != ZERO_BYTES_HASH) _checkDeposits(blockHeaders[i]);
        }

        if (blockHeaders[batchSize - 1].depositRoot != ZERO_BYTES_HASH) _checkDeposits(blockHeaders[batchSize - 1]);

        bytes32 batchRoot = calculateBatchRoot(blockHeaders);
        BatchRecord storage batch = $.batches[batchIndex];
        batch.batchRoot = batchRoot;
        batch.acceptedAtBlock = uint64(block.number);
        batch.expectedBlobs = uint32(expectedBlobsCount);
        batch.status = BatchStatus.HeadersSubmitted;
        $.lastBlockHashInBatch[batchIndex] = blockHeaders[batchSize - 1].blockHash;
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        $.nextBatchIndex = uint96(batchIndex + 1);

        emit BatchHeadersSubmitted(batchIndex, batchRoot, expectedBlobsCount);
    }

    /// @inheritdoc IRollupWrite
    function submitBlobs(uint256 batchIndex, uint256 numBlobs) external onlyRole(SEQUENCER_ROLE) whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        bytes32[] storage blobHashes = $.batchBlobHashes[batchIndex];
        BatchRecord storage batch = $.batches[batchIndex];
        require(blobHashes.length + numBlobs <= batch.expectedBlobs, InvalidBlobCount(batch.expectedBlobs, blobHashes.length + numBlobs));
        require(batch.status == BatchStatus.HeadersSubmitted, InvalidBatchStatus(batchIndex, uint8(batch.status)));

        if ($.daDeadlineBlocks != 0) {
            require(
                block.number <= uint256(batch.acceptedAtBlock) + $.daDeadlineBlocks,
                DADeadlineExceeded(uint256(batch.acceptedAtBlock) + $.daDeadlineBlocks, block.number)
            );
        }

        for (uint256 i = 0; i < numBlobs; ++i) {
            bytes32 blobHash = _getBlobHash(i);
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
    function preconfirmBatch(address nitroVerifier, uint256 batchIndex, bytes32 signature) external onlyRole(PRECONFIRMATION_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $.batches[batchIndex];

        require(batch.status == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(_proveBatchWithNitro(nitroVerifier, batch.batchRoot, $.batchBlobHashes[batchIndex], signature), InvalidNitroSignature());

        batch.status = BatchStatus.Preconfirmed;

        emit BatchPreconfirmed(batchIndex);
    }

    // ============ Challenger ============

    /// @inheritdoc IRollupWrite
    /// @dev Caller must send exactly `challengeDepositAmount` in ETH as a deposit.
    function challengeBlock(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $.batches[batchIndex];

        require(batch.status == BatchStatus.Preconfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(msg.value == $.challengeDepositAmount, IncorrectChallengeDeposit($.challengeDepositAmount, msg.value));

        bytes32 commitment = _computeCommitment(blockHeader);

        require(MerkleTree.verifyMerkleProof(batch.batchRoot, commitment, blockProof.nonce, blockProof.proof), InvalidBlockProof());
        require(!$.provenBlocks[commitment], BlockAlreadyProven(commitment));
        require($.challenges[commitment].batchIndex == 0, BlockAlreadyChallenged(commitment));

        batch.status = BatchStatus.Challenged;
        $.batchChallengedBlocks[batchIndex].push(commitment);

        uint256 deadline = block.number + $.challengeBlockCount;
        $.challenges[commitment] = ChallengeRecord({deposit: msg.value, challenger: _msgSender(), deadline: deadline, batchIndex: batchIndex});
        /// @dev Write deadline as heap priority so the queue is ordered by earliest expiry
        $.challengePriority[commitment] = deadline;
        $.challengeQueue.push($.challengePriority, $.challengeQueueIndex, commitment);

        emit BlockChallenged(batchIndex, commitment, _msgSender());
    }

    // ============ Prover ============

    /// @inheritdoc IRollupWrite
    function resolveChallenge(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) external payable nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 commitment = _verifyAndResolve(batchIndex, blockHeader, blockProof, nitroVerifier, nitroSignature, sp1Proof);

        $.provenBlocks[commitment] = true;
        $.batchProvenBlocks[batchIndex].push(commitment);

        $.proverRewards[_msgSender()] += $.challenges[commitment].deposit;

        delete $.challenges[commitment];
        _removeChallengeFromQueue(commitment);

        $.batches[batchIndex].status = BatchStatus.Preconfirmed;

        emit ChallengeResolved(batchIndex, commitment, _msgSender());
    }

    // ============ Anyone ============

    /// @inheritdoc IRollupWrite
    function tryFinalizeBatch(uint256 batchIndex) external returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $.batches[batchIndex];

        if (batch.status == BatchStatus.Finalized) return true;
        if (batch.status != BatchStatus.Preconfirmed) return false;
        /// @dev Sequential finalization: batch N can only finalize after batch N-1
        if (batchIndex != uint256($.lastFinalizedBatchIndex) + 1) return false;
        if (block.number - uint256(batch.acceptedAtBlock) <= $.approveBlockCount) return false;

        batch.status = BatchStatus.Finalized;
        $.lastFinalizedBatchIndex = uint64(batchIndex);
        emit BatchFinalized(batchIndex);
        return true;
    }

    /// @inheritdoc IRollupWrite
    function withdrawChallengerReward() external nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        address payable challenger = payable(_msgSender());
        uint256 amount = $.challengerRewards[challenger];
        require(amount != 0, NothingToWithdraw());

        $.challengerRewards[challenger] = 0;

        (bool success, ) = challenger.call{value: amount}("");
        require(success, EthTransferFailed(challenger, amount));

        emit ChallengerRewardClaimed(challenger, amount);
    }

    /// @inheritdoc IRollupWrite
    function withdrawProofReward() external nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        address payable prover = payable(_msgSender());
        uint256 amount = $.proverRewards[prover];
        require(amount != 0, NothingToWithdraw());

        $.proverRewards[prover] = 0;

        (bool success, ) = prover.call{value: amount}("");
        require(success, EthTransferFailed(prover, amount));

        emit ProofRewardClaimed(prover, amount);
    }

    // ============ IRollupEmergency ============

    /// @inheritdoc IRollupEmergency
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @inheritdoc IRollupEmergency
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /// @inheritdoc IRollupEmergency
    function forceRevertBatch(uint256 fromBatchIndex) external payable onlyRole(EMERGENCY_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();

        for (uint256 i = fromBatchIndex; i < $.nextBatchIndex; i++) {
            require($.batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        uint256 depositAmount = $.challengeDepositAmount;
        uint256 fee = $.incentiveFee;
        uint256 totalIncentiveFees = 0;

        for (uint256 i = fromBatchIndex; i < $.nextBatchIndex; i++) {
            bytes32[] storage challengedBlocks = $.batchChallengedBlocks[i];
            for (uint256 j = 0; j < challengedBlocks.length; j++) {
                bytes32 commitment = challengedBlocks[j];
                ChallengeRecord storage challenge = $.challenges[commitment];
                address challenger = challenge.challenger;
                if (challenger != address(0)) {
                    if (challenge.deposit >= depositAmount) {
                        $.challengerRewards[challenger] += depositAmount + fee;
                        totalIncentiveFees += fee;
                    }
                }
                _removeChallengeFromQueue(commitment);
                delete $.challenges[commitment];
            }

            bytes32[] storage provenBlocks = $.batchProvenBlocks[i];
            for (uint256 j = 0; j < provenBlocks.length; j++) {
                delete $.provenBlocks[provenBlocks[j]];
            }

            delete $.batches[i];
            delete $.batchProvenBlocks[i];
            delete $.batchChallengedBlocks[i];
            delete $.batchBlobHashes[i];
            delete $.lastBlockHashInBatch[i];
        }

        require(msg.value >= totalIncentiveFees, NotEnoughValueIncentiveFee(msg.value, totalIncentiveFees));

        $.nextBatchIndex = uint96(fromBatchIndex);

        emit BatchReverted(fromBatchIndex);
    }

    // ============ Internal helpers ============

    /// @dev Verifies that L1 deposits match the depositRoot in the block header.
    function _checkDeposits(L2BlockHeader calldata header) private {
        RollupStorage storage $ = _getRollupStorage();

        uint256 deadline = $.acceptDepositDeadline;
        bytes32[] memory depositIds = new bytes32[](header.depositCount);
        for (uint256 i = 0; i < header.depositCount; ++i) {
            (bytes32 depositId, uint256 depositBlockNumber) = IFluentBridge($.bridge).popSentMessage();
            require(depositBlockNumber + deadline >= block.number, AcceptDepositDeadlineExceeded(depositBlockNumber + deadline, block.number));
            depositIds[i] = depositId;
        }
        require(keccak256(abi.encodePacked(depositIds)) == header.depositRoot, DepositRootMismatch(header.blockHash));
    }

    function _removeChallengeFromQueue(bytes32 commitment) internal {
        RollupStorage storage $ = _getRollupStorage();
        if ($.challengeQueue.remove($.challengePriority, $.challengeQueueIndex, commitment)) {
            delete $.challengePriority[commitment];
        }
    }
}
