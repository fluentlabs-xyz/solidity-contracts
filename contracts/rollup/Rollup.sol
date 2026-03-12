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
 * 1. **Accepted**: Sequencer publishes block commitments via `acceptNextBatch`. Batch status = Accepted.
 * 2. **PreConfirmed** (Nitro path): A role with PRECONFIRMATION_ROLE calls `commitPreConfirmation` with a
 *    Nitro enclave signature and Merkle proof for one block in the batch. Batch status = PreConfirmed.
 * 3. **Finalized**: Once `approveBlockCount` blocks have passed since acceptance (and, when Nitro is configured,
 *    the batch is PreConfirmed), anyone may call `ensureBatchApproved(batchIndex)` to set status = Finalized.
 *    The bridge only processes messages for finalized batches.
 *
 * ## Verifiers
 * - **Nitro**: Used for batch pre-confirmation. When `nitroVerifier` is set, a batch must reach PreConfirmed
 *   before it can be approved/finalized. Pre-confirmation is done by the PRECONFIRMATION_ROLE with a
 *   signature from the Nitro enclave.
 * - **SP1**: Used to prove individual block commitments (e.g. when challenged). `proofBlockCommitment` submits
 *   an SP1 ZK proof; when Nitro is not set, batches can be finalized after `approveBlockCount` without
 *   pre-confirmation.
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

    /**
     * TODO: check whether we should pass system transaction like EIP-2935
     * @notice Accepts the next batch of block commitments (sequencer only).
     * @dev Publishes block commitments and sets batch status to Accepted. Required before pre-confirmation or finalization.
     * @param blockCommitments The batch of block commitments.
     * @param numBlobs The number of blob commitments attached to this transaction.
     */
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

        /// @dev will be removed 'if' in the future making the daCheck mandatory
        if ($.daCheck) {
            // require at least one blob is provided
            require(numBlobs != 0, ZeroValueNotAllowed("numBlobs"));

            // `blobhash(i)` is the versioned hash of the KZG commitment (EIP-4844),
            // so it cannot be derived as sha256(batchRoot). We only assert each requested
            // blob hash is present and store it for proof binding in proofBlockCommitment.
            bytes32[] storage blobHashes = $.batchBlobHashes[batchIndex];
            for (uint256 i = 0; i < numBlobs; ++i) {
                bytes32 submittedBlobHash = _getBlobHash(i);
                require(submittedBlobHash != bytes32(0), ZeroValueNotAllowed("blobHash"));
                blobHashes.push(submittedBlobHash);
            }
        }

        bytes32 batchRoot = calculateBatchRoot(blockCommitments);
        $.acceptedBatchRoot[batchIndex] = batchRoot;
        $.lastBlockHashInBatch[batchIndex] = blockCommitments[$.batchSize - 1].blockHash;
        /// @dev start the timer for the batch to be finalized
        $.acceptedBlock[batchIndex] = block.number;
        $.batchStatus[batchIndex] = BatchStatus.Accepted;
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        $.nextBatchIndex = uint96(batchIndex + 1);

        emit BatchAccepted(batchIndex, batchRoot);
    }

    function commitPreConfirmation(
        address nitroVerifier,
        uint256 batchIndex,
        bytes32 signature
    ) external onlyRole(PRECONFIRMATION_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();

        require($.batchStatus[batchIndex] == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8($.batchStatus[batchIndex])));
        require(
            _proveBatchWithNitro(nitroVerifier, $.acceptedBatchRoot[batchIndex], $.batchBlobHashes[batchIndex], signature),
            InvalidNitroSignature()
        );

        $.batchStatus[batchIndex] = BatchStatus.PreConfirmed;

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

        uint256 providedDeposit = msg.value;
        address challenger = _msgSender();
        bytes32 batchRoot = $.acceptedBatchRoot[batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot
            )
        );
        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(batchRoot, commitmentHash, blockProof.nonce, blockProof.proof);

        require(blockValid, InvalidBlockProof());
        require(providedDeposit == $.challengeDepositAmount, IncorrectChallengeDeposit($.challengeDepositAmount, providedDeposit));
        require(isBatchAcceptedOrPreConfirmed(batchIndex), InvalidBatchStatus(batchIndex, uint8($.batchStatus[batchIndex])));
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        require(!$.batchChallenged[batchIndex], BatchAlreadyChallenged(batchIndex));
        require($.blockCommitmentChallenges[commitmentHash].batchIndex == 0, BlockCommitmentAlreadyChallenged(commitmentHash));

        $.batchStatus[batchIndex] = BatchStatus.Challenged;
        $.blockCommitmentChallenges[commitmentHash] = BlockCommitmentChallenge({
            challengeDeposit: providedDeposit,
            challenger: challenger,
            challengeDeadline: block.number + $.challengeBlockCount,
            batchIndex: batchIndex
        });
        $.challengeQueue.push($.challengeBatchIndex, $.commitmentQueueIndex, commitmentHash);

        emit BlockCommitmentChallenged(batchIndex, commitmentHash, challenger);
    }

    /**
     * Batch can be either Accepted or PreConfirmed
     * - If it's Accepted -> has not been proven with SP1 or Nitro
     * - >>> Got a challenge ->
     *
     *
     * - If it's PreConfirmed -> has been proven with Nitro but not yet with SP1
     *
     */

    /**
     * @notice Proves the challenged block commitment with SP1 proof
     */
    function proofBlockCommitmentWithNitroAndSp1(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) external payable nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 batchRoot = $.acceptedBatchRoot[batchIndex];
        address prover = _msgSender();

        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot
            )
        );
        // Check the block commitment is challenged and not yet proven
        require($.blockCommitmentChallenges[commitmentHash].batchIndex != 0, BlockCommitmentNotChallenged(commitmentHash));
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        // Verify block commitment is part of the batch
        require(MerkleTree.verifyMerkleProof(batchRoot, commitmentHash, blockProof.nonce, blockProof.proof), InvalidBlockProof());

        // verify nitro signature
        require(
            _proveBlockWithNitro(
                nitroVerifier,
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot,
                nitroSignature,
                $.batchBlobHashes[batchIndex]
            ),
            InvalidNitroSignature()
        );

        // verify SP1 proof
        require(_proveBlockWithSp1(sp1Verifier(), $.batchBlobHashes[batchIndex], blockCommitment, sp1Proof), InvalidSP1Proof());

        $.provenBlockCommitment[commitmentHash] = true;
        $.batchProvenCommitments[batchIndex].push(commitmentHash);

        // Reward the prover with the challenge deposit
        uint256 challengeDeposit = $.blockCommitmentChallenges[commitmentHash].challengeDeposit;
        $.proverReadyForWithdrawal[prover] += challengeDeposit;

        // Clean up challenge state
        // TODO: clean up the flow and make one function to clean up the challenge state to avoid code duplication with forceRevertBatch
        delete $.blockCommitmentChallenges[commitmentHash];
        _removeChallengeFromQueue(commitmentHash);

        // Restore status to PreConfirmed. Finalization happens only after `approveBlockCount` blocks,
        // so we don't want to allow finalization while a block in the batch is might be challenged.
        $.batchStatus[batchIndex] = BatchStatus.PreConfirmed;

        emit BlockCommitmentProved(batchIndex, commitmentHash, prover);
    }

    /**
     * @notice Forces reversion of batches starting from a given index.
     * @dev This function should be called only in emergency situations where the rollup needs to be reverted to a previous valid state.
     *      It will clean up all state variables associated with the reverted batches to ensure the system can continue operating correctly.
     * @param _revertedBatchIndex The batch index to revert from.
     */
    function forceRevertBatch(uint256 _revertedBatchIndex) external payable onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        // Accept, PreConfirmed and Challenged batches can be reverted, but not finalized ones. Finalized batches are considered valid and irreversible.
        require($.batchStatus[_revertedBatchIndex] != BatchStatus.Finalized, BatchAlreadyFinalized(_revertedBatchIndex));

        uint256 challengeDepositAmount = $.challengeDepositAmount;
        uint256 incentiveFee = $.incentiveFee;
        // If the contract doesn't have enough balance to cover the incentive fees for challengers, we should revert to avoid getting into a corrupted state where challengers cannot be incentivized to challenge invalid batches.
        uint256 incentiveFees = 0;

        // Clean up state for all reverted batches
        for (uint256 i = _revertedBatchIndex; i < $.nextBatchIndex; i++) {
            // Handle challenged commitments for this batch
            bytes32[] storage challengedCommitments = $.batchChallengedCommitments[i];
            for (uint256 j = 0; j < challengedCommitments.length; j++) {
                bytes32 commitmentHash = challengedCommitments[j];
                BlockCommitmentChallenge storage challenge = $.blockCommitmentChallenges[commitmentHash];
                address challenger = challenge.challenger;
                if (challenger != address(0)) {
                    challenge.challenger = address(0);
                    if (challenge.challengeDeposit >= $.challengeDepositAmount) {
                        challenge.challengeDeposit -= $.challengeDepositAmount;
                        $.challengerReadyForWithdrawal[challenger] += challengeDepositAmount + $.incentiveFee;
                        incentiveFees += $.incentiveFee;
                    }
                }
                // TODO(d1r1): validate that we remove all info about challenge.
                _removeChallengeFromQueue(commitmentHash);
            }

            // Clean up proven commitments for this batch
            bytes32[] storage provenCommitments = $.batchProvenCommitments[i];
            for (uint256 j = 0; j < provenCommitments.length; j++) {
                delete $.provenBlockCommitment[provenCommitments[j]];
            }

            delete $.acceptedBatchRoot[i];
            delete $.batchProvenCommitments[i];
            delete $.acceptedBlock[i];
            delete $.batchChallengedCommitments[i];
            delete $.batchStatus[i];
        }

        require(msg.value >= incentiveFees, NotEnoughValueIncentiveFee(msg.value, incentiveFees));

        // Update the next batch index
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

        if ($.batchStatus[_batchIndex] == BatchStatus.Finalized) return true;
        if ($.batchStatus[_batchIndex] != BatchStatus.PreConfirmed) return false;
        if (block.number - $.acceptedBlock[_batchIndex] <= $.approveBlockCount) return false;

        $.batchStatus[_batchIndex] = BatchStatus.Finalized;
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
            delete $.challengeDeadline[commitmentHash];
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

    /// @dev proves a BLOCK commitment with SP1 proof
    function _proveBlockWithSp1(
        address verifier,
        bytes32[] memory blobHashes,
        BlockCommitment calldata blockCommitment,
        bytes memory sp1Proof
    ) internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();

        bytes memory publicValues = _getPublicValuesFromCommitmentAndBlob(blockCommitment, blobHashes);
        IVerifier(verifier).verifyProof($.programVKey, publicValues, sp1Proof);
        return true;
    }
}
