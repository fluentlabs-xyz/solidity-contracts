// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
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

        uint256 batchSize = blockCommitments.length;
        require(
            blockCommitments[0].previousBlockHash == $.lastBlockHashInBatch[batchIndex - 1],
            WrongPreviousBlockHash($.lastBlockHashInBatch[batchIndex - 1], blockCommitments[0].previousBlockHash)
        );

        // TODO: gasleft as a storage variable
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            require(
                blockCommitments[i].blockHash == blockCommitments[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockCommitments[i].blockHash, blockCommitments[i + 1].previousBlockHash)
            );

            if (blockCommitments[i].receivedMessageRoot != ZERO_BYTES_HASH) _checkDeposit(blockCommitments[i]);
            if (gasleft() < 100_000) revert InsufficientGas();
        }

        if (blockCommitments[batchSize - 1].receivedMessageRoot != ZERO_BYTES_HASH) _checkDeposit(blockCommitments[batchSize - 1]);

        bytes32 batchRoot = calculateBatchRoot(blockCommitments);

        if ($.daCheck) {
            // Verify at least one blob is provided
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

        $.acceptedBatchHash[batchIndex] = batchRoot;
        /// TODO: custom error
        require(batchIndex + 1 <= type(uint96).max, "nextBatchIndex overflow");
        $.nextBatchIndex = uint96(batchIndex + 1);
        $.lastBlockHashInBatch[batchIndex] = blockCommitments[$.batchSize - 1].blockHash;
        $.acceptedBlock[batchIndex] = block.number;
        $.batchStatus[batchIndex] = BatchStatus.Accepted;

        emit BatchAccepted(batchIndex, batchRoot);
    }

    function commitPreConfirmation(uint256 batchIndex, bytes32 signature) external onlyRole(PRECONFIRMATION_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();

        require(_acceptedBatch(batchIndex), BatchNotAccepted(batchIndex));
        require($.nitroVerifier != address(0), NitroVerifierNotSet());
        require(INitroEnclaveVerifier($.nitroVerifier).isAttestationVerified(), InvalidNitroSignature());

        if ($.batchStatus[batchIndex] != BatchStatus.Accepted) {
            revert InvalidBatchStatus(batchIndex, uint8($.batchStatus[batchIndex]), uint8(BatchStatus.Accepted));
        }

        require(
            _proveBatchWithNitro($.nitroVerifier, $.acceptedBatchHash[batchIndex], $.batchBlobHashes[batchIndex], signature),
            InvalidNitroSignature()
        );

        $.batchStatus[batchIndex] = BatchStatus.PreConfirmed;
        $.acceptedBlock[batchIndex] = block.number;

        emit BatchPreConfirmed(batchIndex);
    }

    function _proveBlockWithNitro(
        address verifier,
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes memory signature,
        bytes32[] memory blobHashes
    ) internal returns (bool) {
        return INitroEnclaveVerifier(verifier).verifyBlock(parentHash, blockHash, withdrawalHash, depositHash, signature, blobHashes);
    }

    function _proveBatchWithNitro(
        address verifier,
        bytes32 batchHash,
        bytes32[] memory blobHashes,
        bytes memory signature
    ) internal returns (bool) {
        return INitroEnclaveVerifier(verifier).verifyBatch(batchHash, blobHashes, signature);
    }

    /// @dev proves a BLOCK commitment with SP1 proof
    function _proveBlockWithSp1(
        address verifier,
        bytes32[] memory blobHashes,
        BlockCommitment calldata blockCommitment,
        bytes memory sp1Proof
    ) internal returns (bool) {
        RollupStorage storage $ = _getRollupStorage();

        bytes memory publicValues = _getPublicValuesFromCommitmentAndBlob(blockCommitment, blobHashes);
        return IVerifier(verifier).verifyProof($.programVKey, publicValues, sp1Proof);
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
        require(providedDeposit == $.challengeDepositAmount, IncorrectChallengeDeposit($.challengeDepositAmount, providedDeposit));
        require(_acceptedBatch(batchIndex), BatchNotAccepted(batchIndex));
        require($.batchChallenged[batchIndex], BatchAlreadyChallenged(batchIndex));

        address challenger = _msgSender();
        bytes32 batchRoot = $.acceptedBatchHash[batchIndex];

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

        require(!_ensureBatchFinalized(batchIndex), BatchAlreadyFinalized(batchIndex));
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        require($.blockCommitmentChallenger[commitmentHash] == address(0), BatchAlreadyChallenged(batchIndex));

        /// TODO: optimize this
        $.blockCommitmentChallenges[commitmentHash][challenger] = providedDeposit;
        $.blockCommitmentChallenger[commitmentHash] = challenger;

        $.challengeDeadline[commitmentHash] = block.number + $.challengeBlockCount;

        $.challengeQueue.push(commitmentHash);
        $.challengeQueueIndex[commitmentHash] = $.challengeQueue.length;

        //   $.batchChallengedCommitments[batchIndex].push(commitmentHash);

        /// TODO: check if we need this

        // if ($.batchStatus[batchIndex] == BatchStatus.PreConfirmed) {
        //     $.batchWasPreConfirmedBeforeChallenge[batchIndex] = true;
        // }

        $.batchStatus[batchIndex] = BatchStatus.Challenged;

        emit BlockCommitmentChallenged(batchIndex, commitmentHash, challenger);
    }

    function proofBlockCommitment(
        uint256 batchIndex,
        BlockCommitment calldata blockCommitment,
        uint256 startBlobIndex,
        uint256 endBlobIndex,
        bytes calldata sp1Proof,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 batchHash = $.acceptedBatchHash[batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                blockCommitment.previousBlockHash,
                blockCommitment.blockHash,
                blockCommitment.sentMessageRoot,
                blockCommitment.receivedMessageRoot
            )
        );
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));

        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(batchHash, commitmentHash, blockProof.nonce, blockProof.proof);
        require(blockValid, InvalidBlockProof());

        if ($.daCheck) {
            /// todo: $.batchBlobHashes[startBlobIndex:endBlobIndex] -- add a requirement on the number of blobs
            // bytes memory publicValues = _getPublicValuesFromCommitmentAndBlob(blockCommitment, $.batchBlobHashes[startBlobIndex:endBlobIndex]);
            // IVerifier($.verifier).verifyProof($.programVKey, publicValues, sp1Proof);
        }

        address challenger = $.blockCommitmentChallenger[commitmentHash];
        $.provenBlockCommitment[commitmentHash] = true;
        delete $.challengeDeadline[commitmentHash];
        $.provenCommitmentInBatch[batchIndex].push(commitmentHash);

        //$.blockCommitmentChallenger[commitmentHash] = address(0);
        if ($.blockCommitmentChallenges[commitmentHash][challenger] >= $.challengeDepositAmount) {
            $.blockCommitmentChallenges[commitmentHash][challenger] -= $.challengeDepositAmount;
            $.proverReadyForWithdrawal[msg.sender] += $.challengeDepositAmount;
        }

        _removeChallengeFromQueue(commitmentHash);

        // // Remove from batch challenged commitments
        // bytes32[] storage challengedCommitments = $.batchChallengedCommitments[batchIndex];
        // for (uint256 i = 0; i < challengedCommitments.length; i++) {
        //     if (challengedCommitments[i] == commitmentHash) {
        //         // Replace with last element and pop
        //         challengedCommitments[i] = challengedCommitments[challengedCommitments.length - 1];
        //         challengedCommitments.pop();
        //         break;
        //     }
        // }

        // Restore state after all challenges are resolved without minting pre-confirmation.
        if ($.batchStatus[batchIndex] == BatchStatus.Challenged) {
            if ($.batchWasPreConfirmedBeforeChallenge[batchIndex]) {
                $.batchStatus[batchIndex] = BatchStatus.PreConfirmed;
            } else {
                $.batchStatus[batchIndex] = BatchStatus.Accepted;
            }
            delete $.batchWasPreConfirmedBeforeChallenge[batchIndex];
        }

        emit BatchProofed(batchIndex);
    }
    /**
     * @notice Forces reversion of batches starting from a given index.
     * @dev This function should be called only in emergency situations where the rollup needs to be reverted to a previous valid state.
     *      It will clean up all state variables associated with the reverted batches to ensure the system can continue operating correctly.
     * @param _revertedBatchIndex The batch index to revert from.
     */
    function forceRevertBatch(uint256 _revertedBatchIndex) external payable onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(_acceptedBatch(_revertedBatchIndex), BatchNotAccepted(_revertedBatchIndex));
        require(_revertedBatchIndex != 0, InvalidRevertIndex(_revertedBatchIndex));

        uint256 incentiveFees = 0;

        // Clean up state for all reverted batches
        for (uint256 i = _revertedBatchIndex; i < $.nextBatchIndex; i++) {
            // Handle challenged commitments for this batch
            bytes32[] storage challengedCommitments = $.batchChallengedCommitments[i];
            for (uint256 j = 0; j < challengedCommitments.length; j++) {
                bytes32 commitmentHash = challengedCommitments[j];
                address challenger = $.blockCommitmentChallenger[commitmentHash];
                if (challenger != address(0)) {
                    $.blockCommitmentChallenger[commitmentHash] = address(0);
                    if ($.blockCommitmentChallenges[commitmentHash][challenger] >= $.challengeDepositAmount) {
                        $.blockCommitmentChallenges[commitmentHash][challenger] -= $.challengeDepositAmount;
                        $.challengerReadyForWithdrawal[challenger] += $.challengeDepositAmount + $.incentiveFee;
                        incentiveFees += $.incentiveFee;
                    }
                }
                _removeChallengeFromQueue(commitmentHash);

                delete $.challengeDeadline[commitmentHash];
            }

            // Clean up proven commitments for this batch
            bytes32[] storage provenCommitments = $.provenCommitmentInBatch[i];
            for (uint256 j = 0; j < provenCommitments.length; j++) {
                delete $.provenBlockCommitment[provenCommitments[j]];
            }

            delete $.acceptedBatchHash[i];
            delete $.provenCommitmentInBatch[i];
            delete $.acceptedBlock[i];
            delete $.batchChallengedCommitments[i];
            delete $.batchStatus[i];
            delete $.batchWasPreConfirmedBeforeChallenge[i];
        }

        require(msg.value >= incentiveFees, NotEnoughValueIncentiveFee(msg.value, incentiveFees));

        _cleanQueue();

        // Update the next batch index
        $.nextBatchIndex = uint96(_revertedBatchIndex);

        emit ForceRevertBatch(_revertedBatchIndex);
    }

    /**
     * @notice Ensures a batch is marked as finalized if eligible.
     * @dev Eligibility: batch accepted; when nitroVerifier is set, batch must be PreConfirmed;
     *      no unresolved challenges; and at least approveBlockCount blocks since acceptance.
     *      When eligible, sets batch status to Finalized. The bridge relies on this for processing messages.
     * @param _batchIndex The index of the batch to evaluate.
     * @return True if the batch is finalized (either previously or by this call); false otherwise.
     */
    function ensureBatchFinalized(uint256 _batchIndex) external returns (bool) {
        return _ensureBatchFinalized(_batchIndex);
    }

    /**
     * @dev Internal version of `ensureBatchFinalized`. Sets batch status to Finalized when eligible.
     * @param _batchIndex The index of the batch.
     * @return True if the batch is finalized (either previously or by this call); false otherwise.
     */
    function _ensureBatchFinalized(uint256 _batchIndex) internal returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        if (_finalizedBatch(_batchIndex)) {
            if ($.batchStatus[_batchIndex] != BatchStatus.Finalized) {
                $.batchStatus[_batchIndex] = BatchStatus.Finalized;
                emit BatchFinalized(_batchIndex);
            }
            return true;
        }
        return false;
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

    /**
     * @dev The function checks whether L2 received messages have been accepted by the bridge on L1.
     */
    function _checkDeposit(BlockCommitment calldata _blockCommitments) private {
        RollupStorage storage $ = _getRollupStorage();

        uint256 acceptDepositDeadline = $.acceptDepositDeadline;
        bytes32[] memory depositIds = new bytes32[](_blockCommitments.receivedMessageCount);
        for (uint256 i = 0; i < _blockCommitments.receivedMessageCount; ++i) {
            (bytes32 depositId, uint256 depositBlockNumber) = IFluentBridge($.bridge).popSentMessage();
            require(
                depositBlockNumber + acceptDepositDeadline >= block.number,
                AcceptDepositDeadlineExceeded(depositBlockNumber + acceptDepositDeadline, block.number)
            );
            depositIds[i] = depositId;
        }

        require(
            keccak256(abi.encodePacked(depositIds)) == _blockCommitments.receivedMessageRoot,
            DepositVerificationFailed(_blockCommitments.blockHash)
        );
    }

    function _cleanQueue() internal {
        RollupStorage storage $ = _getRollupStorage();
        while ($.challengeQueue.length != 0 && $.challengeQueue[$.challengeQueueStart] == bytes32(0)) {
            ++$.challengeQueueStart;
            if ($.challengeQueueStart >= $.challengeQueue.length) {
                $.challengeQueueStart = 0;
                delete $.challengeQueue;
                return;
            }
        }
    }

    function _removeChallengeFromQueue(bytes32 commitmentHash) internal {
        RollupStorage storage $ = _getRollupStorage();
        uint256 indexPlusOne = $.challengeQueueIndex[commitmentHash];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        delete $.challengeQueue[index];
        delete $.challengeQueueIndex[commitmentHash];
        if (index == $.challengeQueueStart) {
            _cleanQueue();
        }
    }
}
