// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {Heap} from "../libraries/Heap.sol";
import {RollupStorageLayout} from "./RollupStorageLayout.sol";

import {IRollupWrite, IRollupEmergency} from "../interfaces/IRollup.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {INitroEnclaveVerifier} from "../interfaces/INitroEnclaveVerifier.sol";
import {IFluentBridge} from "../interfaces/IFluentBridge.sol";
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
    function forceRevertBatch(uint256 fromBatchIndex) external payable onlyRole(EMERGENCY_ROLE) nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(fromBatchIndex > 0 && fromBatchIndex < $._nextBatchIndex, InvalidBatchIndex(fromBatchIndex, $._nextBatchIndex));

        for (uint256 i = fromBatchIndex; i < $._nextBatchIndex; i++) {
            require($._batches[i].status != BatchStatus.Finalized, BatchAlreadyFinalized(i));
        }

        uint256 depositAmount = $._challengeDepositAmount;
        uint256 fee = $._incentiveFee;
        uint256 totalIncentiveFees = 0;

        for (uint256 i = fromBatchIndex; i < $._nextBatchIndex; i++) {
            bytes32[] storage challengedBlocks = $._batchChallengedBlocks[i];
            for (uint256 j = 0; j < challengedBlocks.length; j++) {
                bytes32 commitment = challengedBlocks[j];
                ChallengeRecord storage challenge = $._challenges[commitment];
                address challenger = challenge.challenger;
                if (challenger != address(0) && challenge.deposit >= depositAmount) {
                    $._challengerRewards[challenger] += depositAmount + fee;
                    totalIncentiveFees += fee;
                }
                _removeChallengeFromQueue(commitment);
                delete $._challenges[commitment];
            }

            bytes32[] storage provenBlocks = $._batchProvenBlocks[i];
            for (uint256 j = 0; j < provenBlocks.length; j++) {
                delete $._provenBlocks[provenBlocks[j]];
            }

            delete $._batches[i];
            delete $._batchProvenBlocks[i];
            delete $._batchChallengedBlocks[i];
            delete $._batchBlobHashes[i];
            delete $._lastBlockHashInBatch[i];
        }

        require(msg.value >= totalIncentiveFees, NotEnoughValueIncentiveFee(msg.value, totalIncentiveFees));
        $._nextBatchIndex = uint96(fromBatchIndex);

        emit BatchReverted(fromBatchIndex);
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
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            require(gasleft() >= gasLeft, InsufficientGas());
            require(
                blockHeaders[i].blockHash == blockHeaders[i + 1].previousBlockHash,
                InvalidBlockSequence(i, blockHeaders[i].blockHash, blockHeaders[i + 1].previousBlockHash)
            );
        }

        bytes32 batchRoot = _calculateBatchRoot(blockHeaders);

        // ─── Effects: write state before any external calls (CEI pattern) ───
        BatchRecord storage batch = $._batches[batchIndex];
        batch.batchRoot = batchRoot;
        batch.acceptedAtBlock = uint64(block.number);
        batch.expectedBlobs = uint32(expectedBlobsCount);
        batch.status = BatchStatus.HeadersSubmitted;
        $._lastBlockHashInBatch[batchIndex] = blockHeaders[batchSize - 1].blockHash;
        require(batchIndex + 1 <= type(uint96).max, NextBatchIndexOverflow());
        $._nextBatchIndex = uint96(batchIndex + 1);

        // ─── Interactions: external calls to bridge after state is finalized ───
        for (uint256 i = 0; i < batchSize - 1; ++i) {
            if (blockHeaders[i].depositRoot != ZERO_BYTES_HASH) _checkDeposits(blockHeaders[i]);
        }
        if (blockHeaders[batchSize - 1].depositRoot != ZERO_BYTES_HASH) _checkDeposits(blockHeaders[batchSize - 1]);

        emit BatchHeadersSubmitted(batchIndex, batchRoot, expectedBlobsCount);
    }

    /// @inheritdoc IRollupWrite
    function submitBlobs(uint256 batchIndex, uint256 numBlobs) external onlyRole(SEQUENCER_ROLE) whenNotPaused nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        bytes32[] storage blobHashes = $._batchBlobHashes[batchIndex];
        BatchRecord storage batch = $._batches[batchIndex];
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
        bytes32 signature
    ) external onlyRole(PRECONFIRMATION_ROLE) whenNotPaused nonReentrant {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());
        BatchRecord storage batch = $._batches[batchIndex];

        require(batch.status == BatchStatus.Accepted, InvalidBatchStatus(batchIndex, uint8(batch.status)));
        require(_proveBatchWithNitro(nitroVerifier, batch.batchRoot, $._batchBlobHashes[batchIndex], signature), InvalidNitroSignature());

        batch.status = BatchStatus.Preconfirmed;
        emit BatchPreconfirmed(batchIndex);
    }

    // ============ Challenger ============

    /// @inheritdoc IRollupWrite
    /// @dev Caller must send exactly `challengeDepositAmount` in ETH as a deposit.
    ///      Challenges are accepted while `block.number < acceptedAtBlock + challengeWindow`.
    ///      The deadline is fixed at acceptance time — all windows are measured from
    ///      `acceptedAtBlock`, not from challenge creation.
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
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) external nonReentrant whenNotPaused onlyRole(PROVER_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(!_rollupCorrupted(), RollupCorrupted());

        bytes32 commitment = _computeCommitment(blockHeader);
        _verifyChallenge(batchIndex, commitment, blockProof);
        _verifyNitroAndSp1(batchIndex, blockHeader, nitroVerifier, nitroSignature, sp1Proof);

        uint256 deposit = $._challenges[commitment].deposit;

        $._provenBlocks[commitment] = true;
        $._batchProvenBlocks[batchIndex].push(commitment);
        $._proverRewards[_msgSender()] += deposit;

        delete $._challenges[commitment];
        _removeChallengeFromQueue(commitment);

        // return to Preconfirmed only when all challenges in this batch are resolved
        if ($._batchChallengedBlocks[batchIndex].length == $._batchProvenBlocks[batchIndex].length) {
            $._batches[batchIndex].status = BatchStatus.Preconfirmed;
        }
        emit ChallengeResolved(batchIndex, commitment, _msgSender());
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
    function _verifyChallenge(uint256 batchIndex, bytes32 commitment, MerkleTree.MerkleProof calldata blockProof) private view {
        RollupStorage storage $ = _getRollupStorage();
        require($._challenges[commitment].batchIndex != 0, BlockNotChallenged(commitment));
        require(!$._provenBlocks[commitment], BlockAlreadyProven(commitment));
        require(
            MerkleTree.verifyMerkleProof($._batches[batchIndex].batchRoot, commitment, blockProof.nonce, blockProof.proof),
            InvalidBlockProof()
        );
    }

    /**
     * @dev Verifies both Nitro and SP1 proofs for an L2 block.
     */
    function _verifyNitroAndSp1(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) private view {
        RollupStorage storage $ = _getRollupStorage();
        bytes32[] memory blobHashes = $._batchBlobHashes[batchIndex];

        require(_proveBlockWithNitro(nitroVerifier, blockHeader, nitroSignature, blobHashes), InvalidNitroSignature());
        _proveBlockWithSp1(sp1Verifier(), blobHashes, blockHeader, sp1Proof);
    }

    /**
     * @dev Validates that `verifier` is whitelisted and its attestation is current.
     */
    function _validateNitroVerifier(address verifier) private view {
        RollupStorage storage $ = _getRollupStorage();
        require($._enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        require(INitroEnclaveVerifier(verifier).isAttestationVerified(), InvalidNitroSignature());
    }

    /**
     * @dev Proves a batch with a Nitro enclave signature.
     */
    function _proveBatchWithNitro(
        address verifier,
        bytes32 batchRoot,
        bytes32[] memory blobHashes,
        bytes32 signature
    ) private view returns (bool) {
        _validateNitroVerifier(verifier);
        return INitroEnclaveVerifier(verifier).verifyBatch(batchRoot, blobHashes, signature);
    }

    /**
     * @dev Proves an L2 block with a Nitro enclave signature.
     */
    function _proveBlockWithNitro(
        address verifier,
        L2BlockHeader calldata header,
        bytes32 signature,
        bytes32[] memory blobHashes
    ) private view returns (bool) {
        _validateNitroVerifier(verifier);
        return
            INitroEnclaveVerifier(verifier).verifyBlock(
                header.previousBlockHash,
                header.blockHash,
                header.withdrawalRoot,
                header.depositRoot,
                signature,
                blobHashes
            );
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
        IVerifier(verifier).verifyProof(_getRollupStorage()._programVKey, publicValues, sp1Proof);
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
            (bytes32 depositId, uint256 depositBlockNumber) = IFluentBridge($._bridge).popSentMessage(); // wake-disable-line reentrancy
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
