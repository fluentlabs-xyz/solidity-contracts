// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IRollupEvents, IRollupErrors, IRollupRead} from "../interfaces/IRollup.sol";
import {Heap} from "../libraries/Heap.sol";

/**
 *
 */
contract RollupStorageLayout is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    IRollupEvents,
    IRollupErrors,
    IRollupRead
{
    using Heap for Heap.HeapStorage;

    // ============ Roles ============

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 public constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");

    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");

    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    bytes32 public constant PRECONFIRMATION_ROLE = keccak256("PRECONFIRMATION_ROLE");

    /// @dev Constant representing an empty deposit hash.
    bytes32 public constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /**
     * @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.RollupStorage")) - 1)) & ~bytes32(uint256(0xff))
     * @custom:storage-location erc7201:fluent.storage.RollupStorage
     */
    bytes32 private constant ROLLUP_STORAGE_LOCATION = 0x3c5cb8ff22ae9906a910cecced8ac84ef594b2ee1cab438e85f81b70bddcc700;

    struct BlockCommitmentChallenge {
        uint256 batchIndex;
        uint256 challengeDeposit;
        address challenger;
        uint256 challengeDeadline;
    }

    /// @dev Batch lifecycle: None → Accepted → DAReady → PreConfirmed → Finalized.
    ///      Challenged branches from PreConfirmed; Corrupted is terminal (DA/preconfirm deadline or challenge timeout).
    enum BatchStatus {
        None,
        Accepted,
        DAReady,
        PreConfirmed,
        Challenged,
        Finalized,
        Corrupted
    }

    /// @dev Packed per-batch state. 2 slots per batch entry.
    struct BatchRecord {
        /// @dev Merkle root of block commitments for this batch
        bytes32 batchRoot;
        /// @dev L1 block number when the batch was accepted via acceptNextBatch
        uint64 acceptedBlock;
        /// @dev number of blobs the sequencer committed to at acceptance time
        uint32 expectedBlobs;
        /// @dev current lifecycle state of this batch
        BatchStatus status;
    }

    /// @dev Storage layout — WARNING: breaking change, incompatible with previous layout.
    struct RollupStorage {
        // ─── Slot 1: address(20) + uint96(12) = 32 ───
        address bridge;
        uint96 nextBatchIndex;
        // ─── Slot 2: address(20) + 12 bytes padding ───
        address sp1Verifier;
        // ─── Slot 3: bytes32(32) ───
        bytes32 programVKey;
        // ─── Slot 4: 4 × uint64 = 32 ───
        uint64 approveBlockCount;
        uint64 challengeBlockCount;
        uint64 daDeadlineBlocks;
        uint64 preconfirmDeadlineBlocks;
        // ─── Slot 5: uint256(32) ───
        uint256 challengeDepositAmount;
        // ─── Slot 6: uint256(32) ───
        uint256 incentiveFee;
        // ─── Slot 7: uint64(8) + uint64(8) + uint32(4) + uint32(4) = 24 bytes ───
        uint64 lastFinalizedBatchIndex;
        uint64 lastDepositAcceptedBlockNumber;
        uint32 gasLeft;
        uint32 acceptDepositDeadline;
        // ─── Per-batch record ───
        mapping(uint256 => BatchRecord) batches;
        // ─── Per-batch chain linking ───
        mapping(uint256 => bytes32) lastBlockHashInBatch;
        // ─── Per-batch dynamic arrays ───
        mapping(uint256 => bytes32[]) batchBlobHashes;
        mapping(uint256 => bytes32[]) batchProvenCommitments;
        mapping(uint256 => bytes32[]) batchChallengedCommitments;
        // ─── Challenge state (keyed by commitment hash) ───
        mapping(bytes32 => bool) provenBlockCommitment;
        mapping(bytes32 => BlockCommitmentChallenge) blockCommitmentChallenges;
        Heap.HeapStorage challengeQueue;
        /// @dev Heap priority map: commitment hash → batch index
        mapping(bytes32 => uint256) challengeBatchIndex;
        /// @dev Heap position map: commitment hash → queue index
        mapping(bytes32 => uint256) commitmentQueueIndex;
        // ─── Withdrawal balances ───
        mapping(address => uint256) challengerReadyForWithdrawal;
        mapping(address => uint256) proverReadyForWithdrawal;
        // ─── Verifier whitelist ───
        mapping(address => bool) enabledNitroVerifiers;
        // ─── Upgrade gap ───
        uint256[28] __gap;
    }

    /// @dev Structure representing a committed block from L2 -> L1
    struct BlockCommitment {
        /// @dev The hash of the previous block in the batch. Enforces correct block sequencing.
        bytes32 previousBlockHash;
        /// @dev The hash of the current block's contents (e.g., state transition data).
        bytes32 blockHash;
        /// @dev The Merkle root of all sent messages on L2 in the current block.
        /// A sent message represents a message sent from L1 to L2 via the bridge.
        /// Each leaf in the Merkle tree is the message hash, calculated individually for each message.
        bytes32 sentMessageRoot;
        /// @dev The Merkle root of all received messages on L2 in the current block.
        /// A received message represents a message received on L2 from L1 via the bridge.
        /// Each received message is hashed individually to form a message hash.
        bytes32 receivedMessageRoot;
        /// @dev The number of received messages on L2 in the block.
        /// @dev this number must be equal or less than the number of sent messages from L1 -> L2
        uint256 receivedMessageCount;
    }

    struct InitConfiguration {
        address admin;
        address sequencer;
        address pauser;
        uint256 challengeDepositAmount;
        uint256 challengeBlockCount;
        uint256 approveBlockCount;
        address sp1Verifier;
        bytes32 programVKey;
        bytes32 genesisHash;
        address bridge;
        uint256 acceptDepositDeadline;
        uint256 incentiveFee;
        address challenger;
        address prover;
        address nitroVerifier;
        address preconfirmationRole;
        uint256 daDeadlineBlocks;
        uint256 preconfirmDeadlineBlocks;
    }

    function __initRollupStorage(bytes memory data) internal {
        RollupStorage storage $ = _getRollupStorage();

        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        require(params.admin != address(0), ZeroAddressNotAllowed("admin"));
        require(params.sp1Verifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        require(params.programVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        require(params.genesisHash != bytes32(0), ZeroValueNotAllowed("genesisHash"));
        require(params.approveBlockCount <= type(uint64).max, ZeroValueNotAllowed("approveBlockCount"));
        require(params.challengeBlockCount <= type(uint64).max, ZeroValueNotAllowed("challengeBlockCount"));
        require(params.acceptDepositDeadline <= type(uint32).max, ZeroValueNotAllowed("acceptDepositDeadline"));
        require(params.daDeadlineBlocks <= type(uint64).max, ZeroValueNotAllowed("daDeadlineBlocks"));
        require(params.preconfirmDeadlineBlocks <= type(uint64).max, ZeroValueNotAllowed("preconfirmDeadlineBlocks"));

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(PAUSER_ROLE, params.pauser != address(0) ? params.pauser : params.admin);
        _grantRole(CHALLENGER_ROLE, params.challenger != address(0) ? params.challenger : params.admin);
        _grantRole(PROVER_ROLE, params.prover != address(0) ? params.prover : params.admin);
        _grantRole(SEQUENCER_ROLE, params.sequencer != address(0) ? params.sequencer : params.admin);
        _grantRole(PRECONFIRMATION_ROLE, params.preconfirmationRole != address(0) ? params.preconfirmationRole : params.admin);

        $.challengeDepositAmount = params.challengeDepositAmount;
        $.challengeBlockCount = uint64(params.challengeBlockCount);
        $.approveBlockCount = uint64(params.approveBlockCount);
        $.sp1Verifier = params.sp1Verifier;
        $.programVKey = params.programVKey;
        $.lastBlockHashInBatch[0] = params.genesisHash;
        $.bridge = params.bridge;
        $.acceptDepositDeadline = uint32(params.acceptDepositDeadline);
        $.incentiveFee = params.incentiveFee;
        $.nextBatchIndex = 1;
        $.daDeadlineBlocks = uint64(params.daDeadlineBlocks);
        $.preconfirmDeadlineBlocks = uint64(params.preconfirmDeadlineBlocks);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ========= Storage View Getters =========

    function bridge() public view returns (address) {
        return _getRollupStorage().bridge;
    }

    function sp1Verifier() public view returns (address) {
        return _getRollupStorage().sp1Verifier;
    }

    function programVKey() public view returns (bytes32) {
        return _getRollupStorage().programVKey;
    }

    function nextBatchIndex() public view returns (uint256) {
        return uint256(_getRollupStorage().nextBatchIndex);
    }

    function approveBlockCount() public view returns (uint256) {
        return uint256(_getRollupStorage().approveBlockCount);
    }

    function challengeDepositAmount() public view returns (uint256) {
        return _getRollupStorage().challengeDepositAmount;
    }

    function incentiveFee() public view returns (uint256) {
        return _getRollupStorage().incentiveFee;
    }

    function challengeBlockCount() public view returns (uint256) {
        return uint256(_getRollupStorage().challengeBlockCount);
    }

    function lastBlockHashInBatch(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage().lastBlockHashInBatch[batchIndex];
    }

    function lastDepositAcceptedBlockNumber() public view returns (uint256) {
        return uint256(_getRollupStorage().lastDepositAcceptedBlockNumber);
    }

    function acceptDepositDeadline() public view returns (uint256) {
        return uint256(_getRollupStorage().acceptDepositDeadline);
    }

    function acceptedBatchRoot(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage().batches[batchIndex].batchRoot;
    }

    function alreadyApprovedBatch(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage().batches[batchIndex].status == BatchStatus.Finalized;
    }

    function acceptedBlock(uint256 batchIndex) public view returns (uint256) {
        return uint256(_getRollupStorage().batches[batchIndex].acceptedBlock);
    }

    function expectedBlobs(uint256 batchIndex) public view returns (uint256) {
        return uint256(_getRollupStorage().batches[batchIndex].expectedBlobs);
    }

    function provenBlockCommitment(bytes32 commitmentHash) public view returns (bool) {
        return _getRollupStorage().provenBlockCommitment[commitmentHash];
    }

    function challengerReadyForWithdrawal(address challenger) public view returns (uint256) {
        return _getRollupStorage().challengerReadyForWithdrawal[challenger];
    }

    function proverReadyForWithdrawal(address prover) public view returns (uint256) {
        return _getRollupStorage().proverReadyForWithdrawal[prover];
    }

    function batchBlobHashes(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchBlobHashes[batchIndex];
    }

    function batchChallengedCommitments(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchChallengedCommitments[batchIndex];
    }

    function batchProvenCommitments(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchProvenCommitments[batchIndex];
    }

    function batchStatus(uint256 batchIndex) public view returns (BatchStatus) {
        return _getRollupStorage().batches[batchIndex].status;
    }

    /// @notice Checks if a batch is in Accepted status.
    function isBatchAccepted(uint256 batchIndex) public view returns (bool) {
        return batchStatus(batchIndex) == BatchStatus.Accepted;
    }

    /// @notice Checks if a batch is PreConfirmed (eligible for challenge or finalization).
    function isBatchPreConfirmed(uint256 batchIndex) public view returns (bool) {
        return batchStatus(batchIndex) == BatchStatus.PreConfirmed;
    }

    /**
     * @notice Returns the challenge queue.
     */
    function getChallengeQueue() public view returns (bytes32[] memory) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 size = $.challengeQueue.length();
        if (size == 0) {
            return new bytes32[](0);
        }

        bytes32[] memory queue = new bytes32[](size);
        for (uint256 i = 0; i < size; ++i) {
            queue[i] = $.challengeQueue.at(i);
        }
        return queue;
    }

    /**
     * @notice Checks if rollup is corrupted.
     */
    function rollupCorrupted() external view returns (bool) {
        return _rollupCorrupted();
    }

    /// @dev Checks if the rollup is corrupted by examining the oldest non-finalized batch.
    ///      Corruption occurs when: DA deadline exceeded (Accepted), preconfirm deadline exceeded (DAReady),
    ///      or challenge deadline exceeded (Challenged).
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($.lastFinalizedBatchIndex) + 1;
        if (batchIndex >= $.nextBatchIndex) return false;

        BatchRecord storage batch = $.batches[batchIndex];
        BatchStatus status = batch.status;
        uint256 accepted = uint256(batch.acceptedBlock);

        if (status == BatchStatus.Accepted && $.daDeadlineBlocks != 0 && block.number > accepted + $.daDeadlineBlocks) return true;
        if (status == BatchStatus.DAReady && $.preconfirmDeadlineBlocks != 0 && block.number > accepted + $.preconfirmDeadlineBlocks) return true;
        if (status == BatchStatus.Challenged) {
            if (!$.challengeQueue.isEmpty()) {
                bytes32 oldest = $.challengeQueue.peek();
                return $.blockCommitmentChallenges[oldest].challengeDeadline < block.number;
            }
        }
        return false;
    }

    /// @dev Auto-finalizes the batch at lastFinalizedBatchIndex + 1 if eligible.
    function _finalizeBatch() internal {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($.lastFinalizedBatchIndex) + 1;

        BatchRecord storage batch = $.batches[batchIndex];
        if (batch.status != BatchStatus.PreConfirmed) return;

        if (block.number - uint256(batch.acceptedBlock) > $.approveBlockCount) {
            batch.status = BatchStatus.Finalized;
            $.lastFinalizedBatchIndex = uint64(batchIndex);
            emit BatchFinalized(batchIndex);
        }
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
            publicValues[88 + i] = _commitment.sentMessageRoot[i];
            publicValues[128 + i] = _commitment.receivedMessageRoot[i];
        }

        return publicValues;
    }

    /// @dev Layout: previousBlockHash || blockHash || withdrawalHash || depositHash || blobHashes(max 14 blobs)
    /// @dev Layout: previousBlockHash || blockHash || sentMessageRoot || receivedMessageRoot || blobHashes(max 14 blobs)
    function _getPublicValuesFromCommitmentAndBlob(
        BlockCommitment calldata commitment,
        bytes32[] memory blobHashes
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                abi.encodePacked(commitment.previousBlockHash, commitment.blockHash, commitment.sentMessageRoot, commitment.receivedMessageRoot),
                blobHashes
            );
    }

    // ========= Storage Setters =========

    /**
     * @notice Pauses the contract, preventing all non-pauser functions from being called
     * @dev Only callable by the owner
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing all functions to be called again
     * @dev Only callable by the pauser
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Set a new program verification key.
     * @param _programVKey The new program verification key.
     */
    function setProgramVKey(bytes32 _programVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(_programVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        emit ProgramVKeyUpdated($.programVKey, _programVKey);
        $.programVKey = _programVKey;
    }

    /// @notice Set minimum gas threshold per block commitment iteration.
    function setGasLeft(uint32 _gasLeft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getRollupStorage().gasLeft = _gasLeft;
    }

    function setNitroVerifier(address _newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newVerifier != address(0), ZeroAddressNotAllowed("nitroVerifier"));
        _getRollupStorage().enabledNitroVerifiers[_newVerifier] = true;
    }

    /**
     * @notice Set a new bridge contract address.
     * @param newBridge The new bridge address.
     */
    function setBridge(address newBridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBridge(newBridge);
    }

    function _setBridge(address _bridge) internal {
        RollupStorage storage $ = _getRollupStorage();
        require(_bridge != address(0), ZeroAddressNotAllowed("bridge"));
        emit BridgeUpdated($.bridge, _bridge);
        $.bridge = _bridge;
    }

    /**
     * @notice Set a new verifier contract address.
     * @param _newVerifier The address of the new verifier.
     */
    function setSp1Verifier(address _newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newVerifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        RollupStorage storage $ = _getRollupStorage();
        emit VerifierUpdated($.sp1Verifier, _newVerifier);
        $.sp1Verifier = _newVerifier;
    }

    // ========= Internal Helpers =========

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
    function calculateBatchRoot(BlockCommitment[] calldata commitmentBatch) public pure returns (bytes32) {
        bytes memory leafs = new bytes(commitmentBatch.length * 32);

        for (uint256 i = 0; i < commitmentBatch.length; ++i) {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    commitmentBatch[i].previousBlockHash,
                    commitmentBatch[i].blockHash,
                    commitmentBatch[i].sentMessageRoot,
                    commitmentBatch[i].receivedMessageRoot
                )
            );
            assembly {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }

        return _calculateMerkleRoot(leafs);
    }

    function _calculateMerkleRoot(bytes memory _leafs) internal pure returns (bytes32) {
        uint256 count = _leafs.length / 32;

        require(count != 0, NoLeavesProvided());

        while (count > 0) {
            bytes32 hash;
            bytes32 left;
            bytes32 right;
            for (uint256 i = 0; i < count / 2; i++) {
                assembly {
                    left := mload(add(add(_leafs, 32), mul(mul(i, 2), 32)))
                    right := mload(add(add(_leafs, 32), mul(add(mul(i, 2), 1), 32)))
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
                    mstore(add(add(_leafs, 32), mul(div(sub(count, 1), 2), 32)), hash)
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

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Returns the blob hash for the given blob index using the BLOBHASH opcode.
     * @param index The blob index for the current transaction.
     */
    function _getBlobHash(uint256 index) internal view returns (bytes32 blobHash) {
        assembly {
            blobHash := blobhash(index)
        }
    }

    function _getRollupStorage() internal pure returns (RollupStorage storage $) {
        assembly {
            $.slot := ROLLUP_STORAGE_LOCATION
        }
    }
}
