// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IVerifier.sol";
import "../restaker/libraries/BlobHashGetter.sol";
import {Bridge} from "../Bridge.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";

/**
 * @title Rollup Contract
 * @dev This contract implements a rollup system with features such as batch acceptance, deposit verification,
 * proof submission, and challenge mechanisms. It interacts with a Bridge contract and a verifier for zk-SNARK proof validation.
 */
contract Rollup is Ownable2Step, ReentrancyGuard, BlobHashGetterDeployer, Pausable {
    error RollupCorrupted();
    error WrongPreviousBlockHash(bytes32 expected, bytes32 provided);
    error DepositVerificationFailed(bytes32 blockHash);
    error AcceptDepositDeadlineExceeded(uint256 deadline, uint256 currentBlock);
    error BatchNotAccepted(uint256 batchIndex);
    error BatchAlreadyApproved(uint256 batchIndex);
    error BlockCommitmentAlreadyProofed(bytes32 commitmentHash);
    error BatchAlreadyChallenged(uint256 batchIndex);
    error InsufficientChallengeDeposit(uint256 required, uint256 provided);
    error ExcessiveChallengeDeposit(uint256 required, uint256 provided);
    error EthTransferFailed(address recipient, uint256 amount);
    error InvalidRevertIndex(uint256 index);
    error BlockHashMismatch(bytes32 expected, bytes32 provided);
    error InvalidBatchIndex(uint256 expected, uint256 provided);
    error InvalidBatchSize(uint256 expected, uint256 provided);
    error InvalidBlockSequence(
        uint256 index,
        bytes32 currentHash,
        bytes32 nextPrevHash
    );
    error NoLeavesProvided();
    error NothingToWithdraw();
    error NotEnoughValueIncentiveFee(uint256 value, uint256 incentiveFee);
    error InvalidBlockProof();
    error ContractPaused();
    error BlobHashGetterNotConfigured();
    error DaBlobHashMismatch(bytes32 expected, bytes32 provided);
    error ZeroAddressNotAllowed(string field);
    error ZeroValueNotAllowed(string field);

    modifier onlySequencer() {
        require(msg.sender == sequencer, "call only by sequencer");
        _;
    }

    /// @notice Address of the sequencer. Responsible for accepting new batches.
    address public sequencer;

    /// @notice Address of the Bridge contract. Responsible for exchanging messages between L1 and L2.
    address public bridge;

    /// @notice Program verification key for zk-SNARK proof verification.
    bytes32 public programVKey;

    /// @notice Next batch index to be accepted.
    uint256 public nextBatchIndex;

    /// @notice Block delay required before a batch can be approved
    uint256 public approveBlockCount;

    /// @notice Required ETH deposit for a challenge.
    uint256 public immutable challengeDepositAmount;

    /// @notice Incentive fee for successful challengers.
    uint256 public incentiveFee;

    /// @notice Number of blocks within which a challenge must be resolved.
    uint256 public challengeBlockCount;

    /// @notice Address of the blob hash getter contract.
    address public blobHashGetter;

    /// @notice Number of blocks in each batch.
    uint256 public batchSize;

    /// @notice Mapping from batch index to the last block hash in that batch.
    mapping(uint256 => bytes32) public lastBlockHashInBatch;

    /// @notice Block number of the last accepted deposit.
    uint256 public lastDepositAcceptedBlockNumber;

    /// @notice Deadline in blocks for accepting deposits.
    uint256 public acceptDepositDeadline;

    /// @notice Mapping from batch index to batch root hash.
    mapping(uint256 => bytes32) public acceptedBatchHash;

    /// @notice Tracks whether a batch has been explicitly marked as approved.
    /// @dev Used to cache approval status after conditions are met in `_approvedBatch`.
    mapping(uint256 => bool) public alreadyApprovedBatch;

    /// @notice Mapping from batch index to the block number when it was accepted.
    mapping(uint256 => uint256) public acceptedBlock;

    /// @notice Mapping to track proven block commitments.
    mapping(bytes32 => bool) public provenBlockCommitment;

    /// @notice Mapping from address to their challenge deposit.
    mapping(address => uint256) public challengerDeposit;

    /// @notice Mapping from address to challenge deposit available for withdrawal.
    mapping(address => uint256) public challengerReadyForWithdrawal;

    /// @notice Mapping from address to proof reward available for withdrawal.
    mapping(address => uint256) public proverReadyForWithdrawal;

    /// @notice Mapping from block commitment hash to challenger address.
    mapping(bytes32 => address) public blockCommitmentChallenger;

    /// @notice Mapping from block commitment hash to challenge deadline block number.
    mapping(bytes32 => uint256) public challengeDeadline;

    /// @notice Queue of challenged block commitment hashes.
    bytes32[] private challengeQueue;

    /// @notice Start index of the challenge queue.
    uint private challengeQueueStart;

    /// @notice 1-based index in challenge queue by commitment hash.
    mapping(bytes32 => uint256) private challengeQueueIndex;

    /// @notice Toggle for enabling data availability checks.
    bool private daCheck;

    /// @dev Constant representing an empty deposit hash.
    bytes32 public constant ZERO_BYTES_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @dev zk-SNARK verifier instance.
    IVerifier private verifier;

    /// @dev Structure representing a committed block.
    struct BlockCommitment {
        /// @dev The hash of the previous block in the batch. Enforces correct block sequencing.
        bytes32 previousBlockHash;

        /// @dev The hash of the current block's contents (e.g., state transition data).
        bytes32 blockHash;

        /// @dev The Merkle root of all withdrawal operations in the current block.
        /// A withdrawal represents a message sent from the bridge on the L2 side.
        /// Each leaf in the Merkle tree is the message hash, calculated individually for each message.
        bytes32 withdrawalHash;

        /// @dev The Merkle root of all deposit operations included in the current block.
        /// A deposit represents a message received on L2 from L1 via the bridge.
        /// Each deposit is hashed individually to form a message hash.
        bytes32 depositHash;
    }

    /// @dev Represents metadata about deposits included in a block.
    struct DepositsInBlock {
        /// @notice The hash of the block containing the deposits.
        bytes32 blockHash;

        /// @notice The number of deposit entries in the block.
        uint256 depositCount;
    }

    /// @notice Mapping from batch index to array of challenged block commitment hashes.
    mapping(uint256 => bytes32[]) public batchChallengedCommitments;

    /// @notice Mapping from batch index to array of proven block commitment hashes.
    mapping(uint256 => bytes32[]) public provenCommitmentInBatch;

    /// @notice Emitted when the verifier is updated.
    event UpdateVerifier(address oldVerifier, address newVerifier);

    /// @notice Emitted when a batch is accepted.
    event BatchAccepted(uint256 batchIndex, bytes32 batchRoot);

    /// @notice Emitted when a batch is proven.
    event BatchProofed(uint256 batchIndex);

    /// @notice Emitted when a batch is force reverted.
    /// @param batchIndex The index of the batch that was reverted to.
    event ForceRevertBatch(uint256 batchIndex);

    event ChallengeDepositWithdrawn(
        address indexed challenger,
        uint256 amount
    );

    event ProofRewardWithdrawn(address indexed prover, uint256 amount);

    event DaCheckUpdated(
        bool oldValue,
        bool newValue
    );

    event BlobHashGetterUpdated(
        address indexed oldBlobHashGetter,
        address indexed newBlobHashGetter
    );

    event BridgeUpdated(
        address indexed oldBridge,
        address indexed newBridge
    );

    /**
     * @dev Initializes the Rollup contract with initial configuration.
     */
    constructor(
        address _sequencer,
        uint256 _challengeDepositAmount,
        uint256 _challengeBlockCount,
        uint256 _approveBlockCount,
        address _verifier,
        bytes32 _programVKey,
        bytes32 _genesisHash,
        address _bridge,
        uint256 _batchSize,
        uint256 _acceptDepositDeadline,
        uint256 _incentiveFee
    ) Ownable(msg.sender) {
        if (_sequencer == address(0)) revert ZeroAddressNotAllowed("sequencer");
        if (_verifier == address(0)) revert ZeroAddressNotAllowed("verifier");
        if (_programVKey == bytes32(0)) revert ZeroValueNotAllowed("programVKey");
        if (_genesisHash == bytes32(0)) revert ZeroValueNotAllowed("genesisHash");
        if (_batchSize == 0) revert ZeroValueNotAllowed("batchSize");

        sequencer = _sequencer;
        challengeDepositAmount = _challengeDepositAmount;
        challengeBlockCount = _challengeBlockCount;
        approveBlockCount = _approveBlockCount;
        verifier = IVerifier(_verifier);
        daCheck = true;
        programVKey = _programVKey;
        lastBlockHashInBatch[0] = _genesisHash;
        bridge = _bridge;
        batchSize = _batchSize;
        acceptDepositDeadline = _acceptDepositDeadline;
        incentiveFee = _incentiveFee;
        nextBatchIndex = 1;
        blobHashGetter = deploy();
    }

    /**
     * @notice Toggle data availability check.
     * @param isCheck Whether to enable the check.
     */
    function setDaCheck(bool isCheck) external payable onlyOwner {
        bool oldValue = daCheck;
        daCheck = isCheck;
        emit DaCheckUpdated(oldValue, isCheck);
    }

    /**
     * @notice Set a new blob hash getter contract used for DA checks.
     * @param _blobHashGetter The new blob hash getter contract address.
     */
    function setBlobHashGetter(address _blobHashGetter) external onlyOwner {
        if (_blobHashGetter == address(0)) {
            revert ZeroAddressNotAllowed("blobHashGetter");
        }

        address oldBlobHashGetter = blobHashGetter;
        blobHashGetter = _blobHashGetter;
        emit BlobHashGetterUpdated(oldBlobHashGetter, _blobHashGetter);
    }

    /**
     * @notice Set a new bridge contract address.
     * @param _bridge The new bridge address.
     */
    function setBridge(address _bridge) external payable onlyOwner {
        address oldBridge = bridge;
        bridge = _bridge;
        emit BridgeUpdated(oldBridge, _bridge);
    }

    /**
     * @notice Updates the verifier contract.
     * @param _newVerifier The address of the new verifier.
     */
    function updateVerifier(address _newVerifier) external onlyOwner {
        if (_newVerifier == address(0)) revert ZeroAddressNotAllowed("verifier");
        address _oldVerifier = address(verifier);
        verifier = IVerifier(_newVerifier);

        emit UpdateVerifier(_oldVerifier, _newVerifier);
    }

    /**
     * @notice Pauses the contract, preventing all non-owner functions from being called
     * @dev Only callable by the owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing all functions to be called again
     * @dev Only callable by the owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Forces reversion of batches starting from a given index.
     * @dev This function should be called only in emergency situations where the rollup needs to be reverted to a previous valid state.
     *      It will clean up all state variables associated with the reverted batches to ensure the system can continue operating correctly.
     * @param _revertedBatchIndex The batch index to revert from.
     */
    function forceRevertBatch(
        uint256 _revertedBatchIndex
    ) external payable onlyOwner nonReentrant {
        if (!_acceptedBatch(_revertedBatchIndex)) {
            revert BatchNotAccepted(_revertedBatchIndex);
        }
        if (_revertedBatchIndex == 0) {
            revert InvalidRevertIndex(_revertedBatchIndex);
        }

        uint256 incentiveFees = 0;

        // Clean up state for all reverted batches
        for (uint256 i = _revertedBatchIndex; i < nextBatchIndex; i++) {
            // Handle challenged commitments for this batch
            bytes32[] storage challengedCommitments = batchChallengedCommitments[i];
            for (uint256 j = 0; j < challengedCommitments.length; j++) {
                bytes32 commitmentHash = challengedCommitments[j];
                address challenger = blockCommitmentChallenger[commitmentHash];
                if (challenger != address(0)) {
                    blockCommitmentChallenger[commitmentHash] = address(0);
                    if (challengerDeposit[challenger] >= challengeDepositAmount) {
                        challengerDeposit[challenger] -= challengeDepositAmount;
                        challengerReadyForWithdrawal[challenger] += challengeDepositAmount + incentiveFee;
                        incentiveFees += incentiveFee;
                    }
                }
                _removeChallengeFromQueue(commitmentHash);

                delete challengeDeadline[commitmentHash];
            }

            // Clean up proven commitments for this batch
            bytes32[] storage provenCommitments = provenCommitmentInBatch[i];
            for (uint256 j = 0; j < provenCommitments.length; j++) {
                delete provenBlockCommitment[provenCommitments[j]];
            }

            delete acceptedBatchHash[i];
            delete provenCommitmentInBatch[i];
            delete acceptedBlock[i];
            delete batchChallengedCommitments[i];
        }

        if (msg.value < incentiveFees) {
            revert NotEnoughValueIncentiveFee(msg.value, incentiveFees);
        }

        _cleanQueue();

        // Update the next batch index
        nextBatchIndex = _revertedBatchIndex;

        emit ForceRevertBatch(_revertedBatchIndex);
    }

    /**
     * @notice Calculates the hash of a blob for DA check.
     * @param blob The blob data.
     * @return hash The resulting blob hash.
     */
    function calculateBlobHash(bytes memory blob) public pure returns (bytes32) {
        bytes32 hash = sha256(blob);

        hash &= 0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        hash |= 0x0100000000000000000000000000000000000000000000000000000000000000;

        return hash;
    }

    /**
     * @notice Calculates the Merkle root of a batch of block commitments.
     * @dev Each commitment is hashed using keccak256 and used as a leaf in the Merkle tree.
     *      The resulting Merkle root represents the batch's integrity and can be used to verify inclusion.
     * @param commitmentBatch An array of BlockCommitment structs representing the batch.
     * @return The Merkle root (batch root) derived from the block commitments.
     */
    function calculateBatchRoot(
        BlockCommitment[] calldata commitmentBatch
    ) public pure returns (bytes32) {
        bytes memory leafs = new bytes(commitmentBatch.length * 32);

        for (uint256 i = 0; i < commitmentBatch.length; ++i) {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    commitmentBatch[i].previousBlockHash,
                    commitmentBatch[i].blockHash,
                    commitmentBatch[i].withdrawalHash,
                    commitmentBatch[i].depositHash
                )
            );
            assembly {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }

        return _calculateMerkleRoot(leafs);
    }
    
    /**
     * @notice Accepts the next batch of block commitments.
     * @param _batchIndex The batch index.
     * @param _commitmentBatch The batch of block commitments.
     * @param depositsInBlocks Deposits per block for validation.
     */
    function acceptNextBatch(
        uint256 _batchIndex,
        BlockCommitment[] calldata _commitmentBatch,
        DepositsInBlock[] calldata depositsInBlocks
    ) external payable onlySequencer whenNotPaused {
        if (depositsInBlocks.length > _commitmentBatch.length) {
            revert("depositsInBlocks length cannot exceed commitmentBatch length");
        }

        if (_rollupCorrupted()) {
            revert RollupCorrupted();
        }

        if (_batchIndex != nextBatchIndex) {
            revert InvalidBatchIndex(nextBatchIndex, _batchIndex);
        }

        if (_commitmentBatch.length != batchSize) {
            revert InvalidBatchSize(batchSize, _commitmentBatch.length);
        }

        if (_batchIndex > 0) {
            if (_commitmentBatch[0].previousBlockHash != lastBlockHashInBatch[_batchIndex - 1]) {
                revert WrongPreviousBlockHash(
                    lastBlockHashInBatch[_batchIndex - 1],
                    _commitmentBatch[0].previousBlockHash
                );
            }
        }

        uint256 depositIndex = 0;
        uint256 queueSize = Bridge(bridge).getQueueSize();

        for (uint256 i = 0; i < batchSize - 1; ++i) {
            if (
                _commitmentBatch[i].blockHash !=
                _commitmentBatch[i + 1].previousBlockHash
            ) {
                revert InvalidBlockSequence(
                    i,
                    _commitmentBatch[i].blockHash,
                    _commitmentBatch[i + 1].previousBlockHash
                );
            }
            if (_commitmentBatch[i].depositHash != ZERO_BYTES_HASH) {
                if (
                    !_checkDeposit(
                        _commitmentBatch[i],
                        depositsInBlocks[depositIndex]
                    )
                ) {
                    revert DepositVerificationFailed(
                        _commitmentBatch[i].blockHash
                    );
                }
                depositIndex += 1;
            }
        }
        if (_commitmentBatch[batchSize - 1].depositHash != ZERO_BYTES_HASH) {
            if (
                !_checkDeposit(
                    _commitmentBatch[batchSize - 1],
                    depositsInBlocks[depositIndex]
                )
            ) {
                revert DepositVerificationFailed(
                    _commitmentBatch[batchSize - 1].blockHash
                );
            }
        }

        if (Bridge(bridge).getQueueSize() == 0) {
            lastDepositAcceptedBlockNumber = 0;
        } else if (
            queueSize > Bridge(bridge).getQueueSize() ||
            (queueSize != 0 && lastDepositAcceptedBlockNumber == 0)
        ) {
            lastDepositAcceptedBlockNumber = block.number;
        } else if (
            lastDepositAcceptedBlockNumber + acceptDepositDeadline <
            block.number
        ) {
            revert AcceptDepositDeadlineExceeded(
                lastDepositAcceptedBlockNumber + acceptDepositDeadline,
                block.number
            );
        }

        bytes32 batchRoot = calculateBatchRoot(_commitmentBatch);
        if (daCheck) {
            if (blobHashGetter == address(0)) {
                revert BlobHashGetterNotConfigured();
            }

            bytes32 requiredBlobHash = calculateBlobHash(
                abi.encodePacked(batchRoot)
            );
            bytes32 submittedBlobHash = BlobHashGetter.getBlobHash(
                blobHashGetter,
                0
            );
            if (submittedBlobHash != requiredBlobHash) {
                revert DaBlobHashMismatch(requiredBlobHash, submittedBlobHash);
            }
        }

        acceptedBatchHash[_batchIndex] = batchRoot;
        nextBatchIndex = _batchIndex + 1;
        lastBlockHashInBatch[_batchIndex] = _commitmentBatch[batchSize - 1].blockHash;
        acceptedBlock[_batchIndex] = block.number;

        emit BatchAccepted(_batchIndex, batchRoot);
    }

    /**
     * @notice Returns the challenge queue.
     */
    function getChallengeQueue() public view returns (bytes32[] memory) {
        return challengeQueue;
    }

    /**
     * @notice Checks if rollup is corrupted.
     */
    function rollupCorrupted() external view returns (bool) {
        return _rollupCorrupted();
    }

    /**
     * @dev Checks if the rollup is in a corrupted state.
     * @return True if the earliest challenged batch has exceeded its challenge deadline without resolution.
     *
     * A rollup is considered corrupted when:
     * - There is at least one challenged batch in the challenge queue, AND
     * - The current block number has exceeded the challenge deadline for the first challenged batch in queue.
     */
    function _rollupCorrupted() internal view returns (bool) {
        if (
            challengeQueue.length == 0 ||
            challengeQueueStart >= challengeQueue.length
        ) {
            return false;
        }

        bytes32 oldestChallenge = challengeQueue[challengeQueueStart];
        if (oldestChallenge == bytes32(0)) {
            return false;
        }

        return challengeDeadline[oldestChallenge] < block.number;
    }

    /**
     * @notice Checks if a batch has been accepted.
     * @param _batchIndex The index of the batch to check.
     * @return True if the batch has been accepted (i.e., its index is less than the next expected batch index).
     */
    function acceptedBatch(uint256 _batchIndex) external view returns (bool) {
        return _acceptedBatch(_batchIndex);
    }

    function _acceptedBatch(uint256 _batchIndex) internal view returns (bool) {
        return _batchIndex < nextBatchIndex;
    }

    /**
     * @notice Checks if a batch has been approved.
     * @param _batchIndex The index of the batch to check.
     * @return True if the batch has been approved, either because enough blocks have passed since acceptance,
     *         or the batch has already been proven.
     */
    function approvedBatch(uint256 _batchIndex) external view returns (bool) {
        return _approvedBatch(_batchIndex);
    }

    /**
     * @dev Internal helper to determine whether a batch is approved.
     * @param _batchIndex The index of the batch.
     * @return True if:
     *         - The batch has been accepted, AND
     *         - Either `approveBlockCount` blocks have passed since the batch was accepted, OR
     *           the batch has already been proven via zk-SNARK proof.
     */
    function _approvedBatch(uint256 _batchIndex) internal view returns (bool) {
        if (!_acceptedBatch(_batchIndex)) {
            return false;
        }

        if (alreadyApprovedBatch[_batchIndex]) {
            return true;
        }

        for (uint256 idx = _batchIndex; idx > 0 && !alreadyApprovedBatch[idx]; --idx) {
            bytes32[] storage challengedCommitments = batchChallengedCommitments[idx];
            for (uint256 j = 0; j < challengedCommitments.length; j++) {
                if (blockCommitmentChallenger[challengedCommitments[j]] != address(0)) {
                    return false;
                }
            }
        }

        bytes32[] storage challengedCommitments = batchChallengedCommitments[_batchIndex];
        for (uint256 j = 0; j < challengedCommitments.length; j++) {
            bytes32 commitmentHash = challengedCommitments[j];
            if (blockCommitmentChallenger[commitmentHash] != address(0)) {
                return false;
            }
        }

        return block.number - acceptedBlock[_batchIndex] > approveBlockCount;
    }

    /**
     * @notice Ensures a batch is marked as approved if eligible.
     * @dev Calls `_approvedBatch` to determine eligibility, and if true,
     *      sets the approval flag in `alreadyApprovedBatch` for caching.
     * @param _batchIndex The index of the batch to evaluate.
     * @return True if the batch is approved (either previously or by this call); false otherwise.
     */
    function ensureBatchApproved(uint256 _batchIndex) external returns (bool) {
        return _ensureBatchApproved(_batchIndex);
    }

    /**
     * @dev Internal version of `ensureBatchApproved`.
     *      Caches the result of `_approvedBatch` by updating `alreadyApprovedBatch` if approved.
     * @param _batchIndex The index of the batch.
     * @return True if the batch is approved and cached; false otherwise.
     */
    function _ensureBatchApproved(uint256 _batchIndex) internal returns (bool) {
        if (_approvedBatch(_batchIndex)) {
            alreadyApprovedBatch[_batchIndex] = true;
            return true;
        }
        return false;
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
    ) external payable nonReentrant whenNotPaused {
        if (!_acceptedBatch(_batchIndex)) {
            revert BatchNotAccepted(_batchIndex);
        }

        bytes32 batchHash = acceptedBatchHash[_batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                _commitmentBatch.previousBlockHash,
                _commitmentBatch.blockHash,
                _commitmentBatch.withdrawalHash,
                _commitmentBatch.depositHash
            )
        );

        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(
            batchHash,
            commitmentHash,
            _block_proof.nonce,
            _block_proof.proof
        );
        if (!blockValid) revert InvalidBlockProof();

        if (_ensureBatchApproved(_batchIndex)) {
            revert BatchAlreadyApproved(_batchIndex);
        }
        if (provenBlockCommitment[commitmentHash]) {
            revert BlockCommitmentAlreadyProofed(commitmentHash);
        }
        if (blockCommitmentChallenger[commitmentHash] != address(0)) {
            revert BatchAlreadyChallenged(_batchIndex);
        }

        if (msg.value < challengeDepositAmount) {
            revert InsufficientChallengeDeposit(
                challengeDepositAmount,
                msg.value
            );
        }
        if (msg.value > challengeDepositAmount) {
            revert ExcessiveChallengeDeposit(
                challengeDepositAmount,
                msg.value
            );
        }

        challengerDeposit[msg.sender] += msg.value;
        blockCommitmentChallenger[commitmentHash] = msg.sender;
        challengeDeadline[commitmentHash] = block.number + challengeBlockCount;
        challengeQueue.push(commitmentHash);
        challengeQueueIndex[commitmentHash] = challengeQueue.length;
        batchChallengedCommitments[_batchIndex].push(commitmentHash);
    }

    /**
     * @notice Submits a zk-SNARK proof to finalize and approve a previously accepted block commitment.
     * @dev Verifies the proof using the configured zk-SNARK verifier and marks the block commitment as proven.
     *      If the batch was challenged, the challenger's deposit is unlocked for withdrawal.
     * @param _batchIndex The index of the batch containing the block commitment.
     * @param _commitmentBatch The block commitment to prove.
     * @param _proof The zk-SNARK proof data.
     * @param _block_proof Merkle proof showing the block commitment is part of the accepted batch.
     */
    function proofBlockCommitment(
        uint256 _batchIndex,
        BlockCommitment calldata _commitmentBatch,
        bytes calldata _proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable nonReentrant whenNotPaused {
        bytes32 batchHash = acceptedBatchHash[_batchIndex];
        bytes32 commitmentHash = keccak256(
            abi.encodePacked(
                _commitmentBatch.previousBlockHash,
                _commitmentBatch.blockHash,
                _commitmentBatch.withdrawalHash,
                _commitmentBatch.depositHash
            )
        );
        if (provenBlockCommitment[commitmentHash]) {
            revert BlockCommitmentAlreadyProofed(commitmentHash);
        }
        
        // Verify block commitment is part of the batch
        bool blockValid = MerkleTree.verifyMerkleProof(
            batchHash,
            commitmentHash,
            _block_proof.nonce,
            _block_proof.proof
        );
        if (!blockValid) revert InvalidBlockProof();

        verifier.verifyProof(
            programVKey, 
            _getPublicValuesFromCommitment(_commitmentBatch),
            _proof
        );

        address challenger = blockCommitmentChallenger[commitmentHash];
        provenBlockCommitment[commitmentHash] = true;
        delete challengeDeadline[commitmentHash];
        provenCommitmentInBatch[_batchIndex].push(commitmentHash);

        if (challenger != address(0)) {
            blockCommitmentChallenger[commitmentHash] = address(0);
            if (challengerDeposit[challenger] >= challengeDepositAmount) {
                challengerDeposit[challenger] -= challengeDepositAmount;
                proverReadyForWithdrawal[msg.sender] += challengeDepositAmount;
            }

            _removeChallengeFromQueue(commitmentHash);

            // Remove from batch challenged commitments
            bytes32[] storage challengedCommitments = batchChallengedCommitments[_batchIndex];
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
     * @dev Encodes all block commitment fields as public values for proof verification.
     * @param _commitment The block commitment structure.
     * @return The encoded public values.
     */
    function _getPublicValuesFromCommitment(
        BlockCommitment calldata _commitment
    ) internal pure returns (bytes memory) {
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
     * @notice Withdraws the challenge deposit and incentive (if any) for a given challenger.
     * @dev Only withdraws if the challenger has a non-zero withdrawable balance. Resets the balance after transfer.
     * @param challenger The address of the challenger requesting the withdrawal.
     */
    function withdrawChallengeDeposit(
        address payable challenger
    ) external payable nonReentrant whenNotPaused {
        uint256 amount = challengerReadyForWithdrawal[challenger];

        if (amount == 0) revert NothingToWithdraw();

        challengerReadyForWithdrawal[challenger] = 0;

        (bool success, ) = challenger.call{value: amount}("");
        if (!success) revert EthTransferFailed(challenger, amount);

        emit ChallengeDepositWithdrawn(challenger, amount);
    }

    /**
     * @notice Withdraws pending proof reward for the caller.
     */
    function withdrawProofReward() external nonReentrant whenNotPaused {
        uint256 amount = proverReadyForWithdrawal[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        proverReadyForWithdrawal[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert EthTransferFailed(msg.sender, amount);

        emit ProofRewardWithdrawn(msg.sender, amount);
    }

    function _checkDeposit(
        BlockCommitment calldata _commitmentBatch,
        DepositsInBlock calldata depositInBlock
    ) private returns (bool) {
        if (_commitmentBatch.blockHash != depositInBlock.blockHash) {
            revert BlockHashMismatch(
                _commitmentBatch.blockHash,
                depositInBlock.blockHash
            );
        }

        bytes32[] memory depositIds = new bytes32[](
            depositInBlock.depositCount
        );
        for (uint256 i = 0; i < depositInBlock.depositCount; ++i) {
            bytes32 depositId = Bridge(bridge).popSentMessage();
            depositIds[i] = depositId;
        }

        return
            keccak256(abi.encodePacked(depositIds)) ==
            _commitmentBatch.depositHash;
    }

    function _cleanQueue() internal {
        while (
            challengeQueue.length != 0 &&
            challengeQueue[challengeQueueStart] == bytes32(0)
        ) {
            ++challengeQueueStart;
            if (challengeQueueStart >= challengeQueue.length) {
                challengeQueueStart = 0;
                delete challengeQueue;
                return;
            }
        }
    }

    function _removeChallengeFromQueue(bytes32 commitmentHash) internal {
        uint256 indexPlusOne = challengeQueueIndex[commitmentHash];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        delete challengeQueue[index];
        delete challengeQueueIndex[commitmentHash];
        if (index == challengeQueueStart) {
            _cleanQueue();
        }
    }

    function _calculateMerkleRoot(
        bytes memory _leafs
    ) internal pure returns (bytes32) {
        uint256 count = _leafs.length / 32;

        if (count == 0) {
            revert NoLeavesProvided();
        }

        while (count > 0) {
            bytes32 hash;
            bytes32 left;
            bytes32 right;
            for (uint256 i = 0; i < count / 2; i++) {
                assembly {
                    left := mload(add(add(_leafs, 32), mul(mul(i, 2), 32)))
                    right := mload(
                        add(add(_leafs, 32), mul(add(mul(i, 2), 1), 32))
                    )
                }
                hash = _efficientHash(left, right);
                assembly {
                    mstore(add(add(_leafs, 32), mul(i, 32)), hash)
                }
            }

            if (count % 2 == 1 && count > 1) {
                assembly {
                    left := mload(add(add(_leafs, 32), mul(sub(count, 1), 32)))
                }
                hash = _efficientHash(left, left);

                assembly {
                    mstore(
                        add(add(_leafs, 32), mul(div(sub(count, 1), 2), 32)),
                        hash
                    )
                }
                count += 1;
            }

            count = count / 2;
        }
        bytes32 root;
        assembly {
            root := mload(add(_leafs, 32))
        }

        return root;
    }

    function _efficientHash(
        bytes32 a,
        bytes32 b
    ) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
