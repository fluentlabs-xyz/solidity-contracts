// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {RollupStorageLayout} from "./RollupStorage.sol";

import {IRollup} from "../interfaces/IRollup.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IFluentBridge} from "../interfaces/IFluentBridge.sol";

/**
 * @title Rollup Contract
 * @dev This contract implements a rollup system with features such as batch acceptance, deposit verification,
 * proof submission, and challenge mechanisms. It interacts with a Bridge contract and a verifier for SP1 proof validation.
 */
contract Rollup is RollupStorageLayout, IRollup {
    modifier onlySequencer() {
        RollupStorage storage $ = _getRollupStorage();
        require(msg.sender == $.sequencer, OnlySequencer());
        _;
    }

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
        __initRollupStorage(data);
    }

    /**
     * @notice Accepts the next batch of block commitments.
     * @param _commitmentBatch The batch of block commitments.
     * @param depositsInBlocks Deposits per block for validation.
     * @param _numBlobs The number of blob commitments attached to this transaction.
     */
    function acceptNextBatch(
        BlockCommitment[] calldata _commitmentBatch,
        DepositsInBlock[] calldata depositsInBlocks,
        uint256 _numBlobs
    ) external payable onlySequencer whenNotPaused {
        RollupStorage storage $ = _getRollupStorage();
        require(depositsInBlocks.length <= _commitmentBatch.length, InvalidDepositsArrayLength());
        uint256 _batchIndex = $.nextBatchIndex;
        require(!_rollupCorrupted(), RollupCorrupted());
        require(_commitmentBatch.length == $.batchSize, InvalidBatchSize($.batchSize, _commitmentBatch.length));

        if (_batchIndex > 0) {
            require(
                _commitmentBatch[0].previousBlockHash == $.lastBlockHashInBatch[_batchIndex - 1],
                WrongPreviousBlockHash($.lastBlockHashInBatch[_batchIndex - 1], _commitmentBatch[0].previousBlockHash)
            );
        }

        uint256 depositIndex = 0;
        uint256 queueSize = IFluentBridge($.bridge).getQueueSize();

        for (uint256 i = 0; i < $.batchSize - 1; ++i) {
            require(
                _commitmentBatch[i].blockHash == _commitmentBatch[i + 1].previousBlockHash,
                InvalidBlockSequence(i, _commitmentBatch[i].blockHash, _commitmentBatch[i + 1].previousBlockHash)
            );
            if (_commitmentBatch[i].depositHash != ZERO_BYTES_HASH) {
                _checkDeposit(_commitmentBatch[i], depositsInBlocks[depositIndex]);
                depositIndex += 1;
            }
        }

        if (_commitmentBatch[$.batchSize - 1].depositHash != ZERO_BYTES_HASH) {
            _checkDeposit(_commitmentBatch[$.batchSize - 1], depositsInBlocks[depositIndex]);
        }

        /// @dev we check
        if (IFluentBridge($.bridge).getQueueSize() == 0) {
            $.lastDepositAcceptedBlockNumber = 0;
        } else if (queueSize > IFluentBridge($.bridge).getQueueSize() || (queueSize != 0 && $.lastDepositAcceptedBlockNumber == 0)) {
            $.lastDepositAcceptedBlockNumber = block.number;
        } else {
            require(
                $.lastDepositAcceptedBlockNumber + $.acceptDepositDeadline >= block.number,
                AcceptDepositDeadlineExceeded($.lastDepositAcceptedBlockNumber + $.acceptDepositDeadline, block.number)
            );
        }

        bytes32 batchRoot = calculateBatchRoot(_commitmentBatch);

        if ($.daCheck) {
            // Verify at least one blob is provided
            require(_numBlobs != 0, ZeroValueNotAllowed("numBlobs"));

            // `blobhash(i)` is the versioned hash of the KZG commitment (EIP-4844),
            // so it cannot be derived as sha256(batchRoot). We only assert each requested
            // blob hash is present and store it for proof binding in proofBlockCommitment.
            bytes32[] storage blobHashes = $.batchBlobHashes[_batchIndex];
            for (uint256 i = 0; i < _numBlobs; ++i) {
                bytes32 submittedBlobHash = _getBlobHash(i);
                require(submittedBlobHash != bytes32(0), ZeroValueNotAllowed("blobHash"));
                blobHashes.push(submittedBlobHash);
            }
        }

        $.acceptedBatchHash[_batchIndex] = batchRoot;
        $.nextBatchIndex = _batchIndex + 1;
        $.lastBlockHashInBatch[_batchIndex] = _commitmentBatch[$.batchSize - 1].blockHash;
        $.acceptedBlock[_batchIndex] = block.number;

        emit BatchAccepted(_batchIndex, batchRoot);
    }

    /**
     * @notice Challenges an unapproved block commitment by providing a deposit.
     * @dev A block commitment can be challenged only if it is part of an accepted batch and not yet proven.
     *      The caller must send at least `challengeDepositAmount` in ETH as a deposit.
     * @param _batchIndex The index of the batch containing the block commitment.
     * @param _commitmentBatch The block commitment being challenged.
     * @param _block_proof Merkle proof showing the block commitment is part of the accepted batch.
     */
    function challengeBlockCommitment(
        uint256 _batchIndex,
        BlockCommitment calldata _commitmentBatch,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable nonReentrant whenNotPaused onlyRole(CHALLENGER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(_acceptedBatch(_batchIndex), BatchNotAccepted(_batchIndex));

        bytes32 batchHash = $.acceptedBatchHash[_batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                _commitmentBatch.previousBlockHash,
                _commitmentBatch.blockHash,
                _commitmentBatch.withdrawalHash,
                _commitmentBatch.depositHash
            )
        );

        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(batchHash, commitmentHash, _block_proof.nonce, _block_proof.proof);
        require(blockValid, InvalidBlockProof());

        require(!_ensureBatchApproved(_batchIndex), BatchAlreadyApproved(_batchIndex));
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));
        require($.blockCommitmentChallenger[commitmentHash] == address(0), BatchAlreadyChallenged(_batchIndex));

        require(msg.value >= $.challengeDepositAmount, InsufficientChallengeDeposit($.challengeDepositAmount, msg.value));
        require(msg.value <= $.challengeDepositAmount, ExcessiveChallengeDeposit($.challengeDepositAmount, msg.value));

        $.challengerDeposit[msg.sender] += msg.value;
        $.blockCommitmentChallenger[commitmentHash] = msg.sender;
        $.challengeDeadline[commitmentHash] = block.number + $.challengeBlockCount;
        $.challengeQueue.push(commitmentHash);
        $.challengeQueueIndex[commitmentHash] = $.challengeQueue.length;
        $.batchChallengedCommitments[_batchIndex].push(commitmentHash);

        /// emit event
    }

    /**
     * @notice Submits an SP1 proof to finalize and approve a previously accepted block commitment.
     * @dev Verifies the proof using the configured SP1 verifier and marks the block commitment as proven.
     *      If the batch was challenged, the challenger's deposit is unlocked for withdrawal.
     *      This variant verifies the block against the data-availability blob used during batch acceptance.
     * @param _batchIndex The index of the batch containing the block commitment.
     * @param _commitmentBatch The block commitment to prove.
     * @param _blobIndex Index of the blob in the batch's blob list that was used to prove this block.
     * @param _proof The SP1 proof data.
     * @param _block_proof Merkle proof showing the block commitment is part of the accepted batch.
     */
    function proofBlockCommitment(
        uint256 _batchIndex,
        BlockCommitment calldata _commitmentBatch,
        uint256 _blobIndex,
        bytes calldata _proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        bytes32 batchHash = $.acceptedBatchHash[_batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                _commitmentBatch.previousBlockHash,
                _commitmentBatch.blockHash,
                _commitmentBatch.withdrawalHash,
                _commitmentBatch.depositHash
            )
        );
        require(!$.provenBlockCommitment[commitmentHash], BlockCommitmentAlreadyProofed(commitmentHash));

        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(batchHash, commitmentHash, _block_proof.nonce, _block_proof.proof);
        require(blockValid, InvalidBlockProof());

        if ($.daCheck) {
            // Ensure the provided blob index is within the bounds of the batch's blob hashes
            bytes32[] storage blobHashes = $.batchBlobHashes[_batchIndex];
            require(_blobIndex < blobHashes.length, DaBlobHashMismatch(bytes32(0), bytes32(0)));

            // Bind the SP1 proof to the DA blob that was used for this batch
            bytes32 blobHash = blobHashes[_blobIndex];

            IVerifier($.verifier).verifyProof($.programVKey, _getPublicValuesFromCommitmentAndBlob(_commitmentBatch, blobHash), _proof);
        } else {
            // Legacy mode: verify proof only against the block commitment without DA binding.
            IVerifier($.verifier).verifyProof($.programVKey, _getPublicValuesFromCommitment(_commitmentBatch), _proof);
        }

        address challenger = $.blockCommitmentChallenger[commitmentHash];
        $.provenBlockCommitment[commitmentHash] = true;
        delete $.challengeDeadline[commitmentHash];
        $.provenCommitmentInBatch[_batchIndex].push(commitmentHash);

        if (challenger != address(0)) {
            $.blockCommitmentChallenger[commitmentHash] = address(0);
            if ($.challengerDeposit[challenger] >= $.challengeDepositAmount) {
                $.challengerDeposit[challenger] -= $.challengeDepositAmount;
                $.proverReadyForWithdrawal[msg.sender] += $.challengeDepositAmount;
            }

            _removeChallengeFromQueue(commitmentHash);

            // Remove from batch challenged commitments
            bytes32[] storage challengedCommitments = $.batchChallengedCommitments[_batchIndex];
            for (uint256 i = 0; i < challengedCommitments.length; i++) {
                if (challengedCommitments[i] == commitmentHash) {
                    // Replace with last element and pop
                    challengedCommitments[i] = challengedCommitments[challengedCommitments.length - 1];
                    challengedCommitments.pop();
                    break;
                }
            }
        }

        emit BatchProofed(_batchIndex);
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
                    if ($.challengerDeposit[challenger] >= $.challengeDepositAmount) {
                        $.challengerDeposit[challenger] -= $.challengeDepositAmount;
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
        }

        require(msg.value >= incentiveFees, NotEnoughValueIncentiveFee(msg.value, incentiveFees));

        _cleanQueue();

        // Update the next batch index
        $.nextBatchIndex = _revertedBatchIndex;

        emit ForceRevertBatch(_revertedBatchIndex);
    }

    /**
     * @dev Encodes all block commitment fields as public values for proof verification.
     * @param _commitment The block commitment structure.
     * @return The encoded public values.
     */
    function _getPublicValuesFromCommitment(BlockCommitment calldata _commitment) internal pure returns (bytes memory) {
        bytes memory publicValues = new bytes(160); // 4 * 32 bytes + 4 * 8 bytes for length

        publicValues[0] = 0x20;
        publicValues[40] = 0x20;
        publicValues[80] = 0x20;
        publicValues[120] = 0x20;

        for (uint256 i = 0; i < 32; i++) {
            publicValues[8 + i] = _commitment.previousBlockHash[i];
            publicValues[48 + i] = _commitment.blockHash[i];
            publicValues[88 + i] = _commitment.withdrawalHash[i];
            publicValues[128 + i] = _commitment.depositHash[i];
        }

        return publicValues;
    }

    /**
     * @dev Encodes blob hash together with all block commitment fields as public values for SP1 proof verification.
     * @param _commitment The block commitment structure.
     * @param _blobHash The blob hash used for this block's data availability.
     * @return The encoded public values.
     */
    function _getPublicValuesFromCommitmentAndBlob(
        BlockCommitment calldata _commitment,
        bytes32 _blobHash
    ) internal pure returns (bytes memory) {
        // Layout: blobHash || previousBlockHash || blockHash || withdrawalHash || depositHash
        bytes memory publicValues = new bytes(160);

        for (uint256 i = 0; i < 32; i++) {
            publicValues[i] = _blobHash[i];
            publicValues[32 + i] = _commitment.previousBlockHash[i];
            publicValues[64 + i] = _commitment.blockHash[i];
            publicValues[96 + i] = _commitment.withdrawalHash[i];
            publicValues[128 + i] = _commitment.depositHash[i];
        }

        return publicValues;
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
        uint256 amount = $.proverReadyForWithdrawal[msg.sender];
        require(amount != 0, NothingToWithdraw());

        $.proverReadyForWithdrawal[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, EthTransferFailed(msg.sender, amount));

        emit ProofRewardWithdrawn(msg.sender, amount);
    }

    function _checkDeposit(BlockCommitment calldata _commitmentBatch, DepositsInBlock calldata depositInBlock) private {
        RollupStorage storage $ = _getRollupStorage();
        require(_commitmentBatch.blockHash == depositInBlock.blockHash, BlockHashMismatch(_commitmentBatch.blockHash, depositInBlock.blockHash));

        bytes32[] memory depositIds = new bytes32[](depositInBlock.depositCount);
        for (uint256 i = 0; i < depositInBlock.depositCount; ++i) {
            bytes32 depositId = IFluentBridge($.bridge).popSentMessage();
            depositIds[i] = depositId;
        }

        require(keccak256(abi.encodePacked(depositIds)) == _commitmentBatch.depositHash, DepositVerificationFailed(_commitmentBatch.blockHash));
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
