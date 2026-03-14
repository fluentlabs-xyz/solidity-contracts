// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {Heap} from "../libraries/Heap.sol";
import {RollupStorageLayout} from "./RollupStorageLayout.sol";

import {IRollupWrite} from "../interfaces/IRollup.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IFluentBridge} from "../interfaces/IFluentBridge.sol";
import {INitroEnclaveVerifier} from "../interfaces/INitroEnclaveVerifier.sol";

/**
 * @title Rollup Contract
 * @dev Rollup with two verifier paths: AWS Nitro Enclave (pre-confirmation) and SP1 (ZK proof).
 *
 * ## Batch lifecycle
 * None → Accepted → DAReady → PreConfirmed → Finalized
 *                                    ↕
 *                               Challenged → Corrupted (if deadline exceeded)
 *
 * 1. **Accepted**: Sequencer publishes block commitments via `acceptNextBatch`.
 * 2. **DAReady**: Sequencer submits blob hashes via `submitDAProof`.
 * 3. **PreConfirmed**: PRECONFIRMATION_ROLE calls `commitPreConfirmation` with Nitro signature.
 * 4. **Finalized**: After `approveBlockCount` blocks, anyone calls `ensureBatchFinalized`.
 *
 * Challenged branches from PreConfirmed when a block commitment is disputed.
 * Corrupted is terminal — triggered by DA/preconfirm/challenge deadline expiry.
 * All state-changing functions check `_rollupCorrupted()` and revert if true.
 */
contract Rollup is RollupStorageLayout, IRollupWrite {
    using Heap for Heap.HeapStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable rollup (replaces constructor when used behind a proxy).
     * @param data ABI-encoded InitConfiguration.
     */
    function initialize(bytes memory data) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __initRollupStorage(data);
    }

    /// @notice Accepts the next batch of block commitments (sequencer only).
    /// @param blockCommitments The batch of block commitments.
    /// @param numBlobs The number of blobs the sequencer commits to submitting via submitDAProof.
    function acceptNextBatch(
        BlockCommitment[] calldata blockCommitments,
        uint256 numBlobs
    ) external payable onlyRole(SEQUENCER_ROLE) whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();

        uint256 batchIndex = $.nextBatchIndex;
        require(!_rollupCorrupted(), RollupCorrupted());

        /// @dev finalize the previous batch
        _finalizeBatch();

        uint256 batchSize = blockCommitments.length;
        /// @dev even if the block are empty we need to pass it in the acceptNextBatch
        require(
            blockCommitments[0].previousBlockHash == $.lastBlockHashInBatch[batchIndex - 1],
            WrongPreviousBlockHash($.lastBlockHashInBatch[batchIndex - 1], blockCommitments[0].previousBlockHash)
        );

        uint256 gasLeft = $.gasLeft;
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            require(
                blockCommitments[i].blockHash == blockCommitments[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockCommitments[i].blockHash, blockCommitments[i + 1].previousBlockHash)
            );

            if (blockCommitments[i].receivedMessageRoot != ZERO_BYTES_HASH) _checkDeposit(blockCommitments[i]);
        }

        if (blockCommitments[batchSize - 1].receivedMessageRoot != ZERO_BYTES_HASH) _checkDeposit(blockCommitments[batchSize - 1]);

        bytes32 batchRoot = calculateBatchRoot(blockCommitments);
        BatchRecord storage batch = $.batches[batchIndex];
        batch.batchRoot = batchRoot;
        batch.acceptedBlock = uint64(block.number);
        batch.expectedBlobs = uint32(numBlobs);
        batch.status = BatchStatus.Accepted;
        $.lastBlockHashInBatch[batchIndex] = blockCommitments[blockCommitments.length - 1].blockHash;
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        $.nextBatchIndex = uint96(batchIndex + 1);

        emit BatchAccepted(batchIndex, batchRoot);
    }

    /// @inheritdoc IRollupWrite
    function submitDAProof(
        uint256 batchIndex,
        uint256 numBlobs
    ) external onlyRole(SEQUENCER_ROLE) whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $.batches[batchIndex];

        require(batch.status == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(numBlobs == batch.expectedBlobs, InvalidBlobCount(batch.expectedBlobs, numBlobs));

        if ($.daDeadlineBlocks != 0) {
            require(
                block.number <= uint256(batch.acceptedBlock) + $.daDeadlineBlocks,
                DADeadlineExceeded(uint256(batch.acceptedBlock) + $.daDeadlineBlocks, block.number)
            );
        }

        bytes32[] storage blobHashes = $.batchBlobHashes[batchIndex];
        for (uint256 i = 0; i < numBlobs; ++i) {
            bytes32 submittedBlobHash = _getBlobHash(i);
            require(submittedBlobHash != bytes32(0), ZeroValueNotAllowed("blobHash"));
            blobHashes.push(submittedBlobHash);
        }

        batch.status = BatchStatus.DAReady;

        emit BatchDAReady(batchIndex);
    }

    function commitPreConfirmation(
        address nitroVerifier,
        uint256 batchIndex,
        bytes32 signature
    ) external onlyRole(PRECONFIRMATION_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $.batches[batchIndex];

        require(batch.status == BatchStatus.DAReady, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(
            _proveBatchWithNitro(nitroVerifier, batch.batchRoot, $.batchBlobHashes[batchIndex], signature),
            InvalidNitroSignature()
        );

        batch.status = BatchStatus.PreConfirmed;

        emit BatchPreConfirmed(batchIndex);
    }

    /**
     * @notice Challenges non-finalized block commitment by providing a deposit.
     * @dev A block commitment can be challenged only if it is part of an accepted batch and not yet proven.
     *      The caller must send at least `challengeDepositAmount` in ETH as a deposit.
     * @param batchIndex The index of the batch containing the block commitment.
     * @param blockCommitment The block commitment being challenged.
     * @param blockProof Merkle proof showing the block commitment is part of the accepted batch.
     */
    function challengeBlockCommitment(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $.batches[batchIndex];

        require(batch.status == BatchStatus.PreConfirmed, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(msg.value == $.challengeDepositAmount, IncorrectChallengeDeposit($.challengeDepositAmount, msg.value));

        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot
            )
        );
        require(MerkleTree.verifyMerkleProof(batch.batchRoot, commitmentHash, blockProof.nonce, blockProof.proof), InvalidBlockProof());
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        require($.blockCommitmentChallenges[commitmentHash].batchIndex == 0, BlockCommitmentAlreadyChallenged(commitmentHash));

        batch.status = BatchStatus.Challenged;
        $.batchChallengedCommitments[batchIndex].push(commitmentHash);
        uint256 deadline = block.number + $.challengeBlockCount;
        $.blockCommitmentChallenges[commitmentHash] = BlockCommitmentChallenge({
            challengeDeposit: msg.value,
            challenger: _msgSender(),
            challengeDeadline: deadline,
            batchIndex: batchIndex
        });
        /// @dev Write deadline as heap priority so the queue is ordered by earliest expiry
        $.challengeBatchIndex[commitmentHash] = deadline;
        $.challengeQueue.push($.challengeBatchIndex, $.commitmentQueueIndex, commitmentHash);

        emit BlockCommitmentChallenged(batchIndex, commitmentHash, _msgSender());
    }

    /// @notice Proves a challenged block commitment with both Nitro and SP1 proofs.
    function proofBlockCommitmentWithNitroAndSp1(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) external payable nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 commitmentHash = _verifyAndProveCommitment(
            batchIndex, blockCommitment, blockProof, nitroVerifier, nitroSignature, sp1Proof
        );

        $.provenBlockCommitment[commitmentHash] = true;
        $.batchProvenCommitments[batchIndex].push(commitmentHash);

        {
            uint256 challengeDeposit = $.blockCommitmentChallenges[commitmentHash].challengeDeposit;
            $.proverReadyForWithdrawal[_msgSender()] += challengeDeposit;
        }

        delete $.blockCommitmentChallenges[commitmentHash];
        _removeChallengeFromQueue(commitmentHash);

        $.batches[batchIndex].status = BatchStatus.PreConfirmed;

        emit BlockCommitmentProved(batchIndex, commitmentHash, _msgSender());
    }

    function _verifyAndProveCommitment(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) internal view returns (bytes32) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot
            )
        );
        require($.blockCommitmentChallenges[commitmentHash].batchIndex != 0, BlockCommitmentNotChallenged(commitmentHash));
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        require(MerkleTree.verifyMerkleProof($.batches[batchIndex].batchRoot, commitmentHash, blockProof.nonce, blockProof.proof), InvalidBlockProof());

        _verifyNitroAndSp1(batchIndex, blockCommitment, nitroVerifier, nitroSignature, sp1Proof);

        return commitmentHash;
    }

    function _verifyNitroAndSp1(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) internal view {
        RollupStorage storage $ = _getRollupStorage();
        bytes32[] memory blobHashes = $.batchBlobHashes[batchIndex];

        require(
            _proveBlockWithNitro(
                nitroVerifier,
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot,
                nitroSignature,
                blobHashes
            ),
            InvalidNitroSignature()
        );

        _proveBlockWithSp1(sp1Verifier(), blobHashes, blockCommitment, sp1Proof);
    }

    /**
     * @notice Forces reversion of batches starting from a given index.
     * @dev This function should be called only in emergency situations where the rollup needs to be reverted to a previous valid state.
     *      It will clean up all state variables associated with the reverted batches to ensure the system can continue operating correctly.
     * @param _revertedBatchIndex The batch index to revert from.
     */
    function forceRevertBatch(uint256 _revertedBatchIndex) external payable onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();

        // Verify no batch in the revert range is finalized
        for (uint256 i = _revertedBatchIndex; i < $.nextBatchIndex; i++) {
            require($.batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        uint256 depositAmount = $.challengeDepositAmount;
        uint256 fee = $.incentiveFee;
        uint256 incentiveFees = 0;

        for (uint256 i = _revertedBatchIndex; i < $.nextBatchIndex; i++) {
            bytes32[] storage challengedCommitments = $.batchChallengedCommitments[i];
            for (uint256 j = 0; j < challengedCommitments.length; j++) {
                bytes32 commitmentHash = challengedCommitments[j];
                BlockCommitmentChallenge storage challenge = $.blockCommitmentChallenges[commitmentHash];
                address challenger = challenge.challenger;
                if (challenger != address(0)) {
                    if (challenge.challengeDeposit >= depositAmount) {
                        $.challengerReadyForWithdrawal[challenger] += depositAmount + fee;
                        incentiveFees += fee;
                    }
                }
                _removeChallengeFromQueue(commitmentHash);
                delete $.blockCommitmentChallenges[commitmentHash];
            }

            bytes32[] storage provenCommitments = $.batchProvenCommitments[i];
            for (uint256 j = 0; j < provenCommitments.length; j++) {
                delete $.provenBlockCommitment[provenCommitments[j]];
            }

            delete $.batches[i];
            delete $.batchProvenCommitments[i];
            delete $.batchChallengedCommitments[i];
            delete $.batchBlobHashes[i];
            delete $.lastBlockHashInBatch[i];
        }

        require(msg.value >= incentiveFees, NotEnoughValueIncentiveFee(msg.value, incentiveFees));

        $.nextBatchIndex = uint96(_revertedBatchIndex);

        emit ForceRevertBatch(_revertedBatchIndex);
    }

    /**
     * @notice Withdraws the challenge deposit and incentive (if any) for a given challenger.
     * @dev Only withdraws if the challenger has a non-zero withdrawable balance. Resets the balance after transfer.
     * @param challenger The address of the challenger requesting the withdrawal.
     */
    function withdrawChallengeDeposit(address payable challenger) external payable nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        uint256 amount = $.challengerReadyForWithdrawal[challenger];
        require(amount != 0, NothingToWithdraw());

        $.challengerReadyForWithdrawal[challenger] = 0;

        (bool success, ) = challenger.call{value: amount}("");
        require(success, EthTransferFailed(challenger, amount));

        emit ChallengeDepositWithdrawn(challenger, amount);
    }

    /**
     * @notice Withdraws pending proof reward for the caller.
     */
    function withdrawProofReward() external nonReentrant whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        address prover = _msgSender();
        uint256 amount = $.proverReadyForWithdrawal[prover];
        require(amount != 0, NothingToWithdraw());

        $.proverReadyForWithdrawal[prover] = 0;

        (bool success, ) = payable(prover).call{value: amount}("");
        require(success, EthTransferFailed(prover, amount));

        emit ProofRewardWithdrawn(prover, amount);
    }

    // Internal functions

    /// @inheritdoc IRollupWrite
    function ensureBatchFinalized(uint256 _batchIndex) external returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        BatchRecord storage batch = $.batches[_batchIndex];

        if (batch.status == BatchStatus.Finalized) return true;
        if (batch.status != BatchStatus.PreConfirmed) return false;
        /// @dev Sequential finalization: batch N can only finalize after batch N-1
        if (_batchIndex != uint256($.lastFinalizedBatchIndex) + 1) return false;
        if (block.number - uint256(batch.acceptedBlock) <= $.approveBlockCount) return false;

        batch.status = BatchStatus.Finalized;
        $.lastFinalizedBatchIndex = uint64(_batchIndex);
        emit BatchFinalized(_batchIndex);
        return true;
    }

    /**
     * @dev The function checks whether L2 received messages have been accepted by the bridge on L1.
     */
    function _checkDeposit(BlockCommitment calldata _blockCommitments) private {
        RollupStorage storage $ = _getRollupStorage();

        uint256 acceptDepositDeadline = $.acceptDepositDeadline;
        bytes32[] memory depositIds = new bytes32[](_blockCommitments.receivedMessageCount);
        for (uint256 i = 0; i < _blockCommitments.receivedMessageCount; ++i) {
            /// @dev we remove deposits from the bridge(L1 -> L2)
            (bytes32 depositId, uint256 depositBlockNumber) = IFluentBridge($.bridge).popSentMessage();
            require(
                depositBlockNumber + acceptDepositDeadline >= block.number,
                AcceptDepositDeadlineExceeded(depositBlockNumber + acceptDepositDeadline, block.number)
            );
            depositIds[i] = depositId;
        }
        /// @dev we verify that we've received all the messages the have been send through the $.bridge
        require(
            keccak256(abi.encodePacked(depositIds)) == _blockCommitments.receivedMessageRoot,
            DepositVerificationFailed(_blockCommitments.blockHash)
        );
    }

    function _removeChallengeFromQueue(bytes32 commitmentHash) internal {
        RollupStorage storage $ = _getRollupStorage();
        if ($.challengeQueue.remove($.challengeBatchIndex, $.commitmentQueueIndex, commitmentHash)) {
            delete $.challengeBatchIndex[commitmentHash];
        }
    }

    function _proveBatchWithNitro(
        address verifier,
        bytes32 batchHash,
        bytes32[] memory blobHashes,
        bytes32 signature
    ) internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();

        require($.enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        require(INitroEnclaveVerifier(verifier).isAttestationVerified(), InvalidNitroSignature());

        return INitroEnclaveVerifier(verifier).verifyBatch(batchHash, blobHashes, signature);
    }

    function _proveBlockWithNitro(
        address verifier,
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes32 signature,
        bytes32[] memory blobHashes
    ) internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();

        require($.enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        require(INitroEnclaveVerifier(verifier).isAttestationVerified(), InvalidNitroSignature());

        return INitroEnclaveVerifier(verifier).verifyBlock(parentHash, blockHash, withdrawalHash, depositHash, signature, blobHashes);
    }

    /// @dev Proves a block commitment with SP1 proof. Reverts on invalid proof.
    function _proveBlockWithSp1(
        address verifier,
        bytes32[] memory blobHashes,
        BlockCommitment calldata blockCommitment,
        bytes memory sp1Proof
    ) internal view {
        bytes memory publicValues = _getPublicValuesFromCommitmentAndBlob(blockCommitment, blobHashes);
        IVerifier(verifier).verifyProof(_getRollupStorage().programVKey, publicValues, sp1Proof);
    }
}
