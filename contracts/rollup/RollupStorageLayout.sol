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

    /// @dev Storage layout is packed to use fewer slots (~5 slots saved vs. unpacked).
    ///      WARNING: This layout is incompatible with the previous unpacked layout. Do not upgrade an existing
    ///      proxy to this implementation without a storage migration.
    struct RollupStorage {
        // Slot 1: address (20) + uint96 (12) = 32
        address bridge;
        uint96 nextBatchIndex;
        address sp1Verifier;
        bytes32 programVKey;
        // Slot: 4 x uint64 = 32 (block-related config and state; uint64 is sufficient for block numbers and counts)
        uint64 approveBlockCount;
        uint64 challengeBlockCount;
        uint64 acceptDepositDeadline;
        uint64 lastDepositAcceptedBlockNumber;
        uint256 challengeDepositAmount;
        uint256 incentiveFee;
        // Slot: uint32 (4) + bool (1) = 5 bytes, rest padding
        uint32 batchSize;
        bool daCheck;
        mapping(uint256 => bytes32) lastBlockHashInBatch;
        mapping(uint256 => bytes32) acceptedBatchRoot;
        mapping(uint256 => uint256) acceptedBlock;
        mapping(bytes32 => bool) provenBlockCommitment;
        /// @dev commitment hash -> challenger -> challenge deposit
        //  mapping(bytes32 => mapping(address => uint256)) blockCommitmentChallenges;
        mapping(address => uint256) challengerReadyForWithdrawal;
        mapping(address => uint256) proverReadyForWithdrawal;
        mapping(bytes32 => address) blockCommitmentChallenger;
        // Challenge queue implemented as a min-heap based on challenge deadline for efficient retrieval of the earliest challenged batch.
        Heap.HeapStorage challengeQueue;
        mapping(bytes32 => uint256) challengeDeadline;
        /// @dev commitment hash -> batch index (priority in min-heap)
        mapping(bytes32 => uint256) challengeBatchIndex;
        mapping(bytes32 => uint256) commitmentQueueIndex;
        mapping(uint256 => bytes32[]) batchBlobHashes;
        mapping(uint256 => bytes32[]) batchChallengedCommitments;
        mapping(uint256 => bytes32[]) batchProvenCommitments;
        mapping(uint256 => BatchStatus) batchStatus;
        mapping(uint256 => bool) batchChallenged;
        mapping(address => bool) enabledNitroVerifiers;
        /**
         * @dev commitment hash -> challenge
         */
        mapping(bytes32 => BlockCommitmentChallenge) blockCommitmentChallenges;
        uint96 gasLeft;
        uint64 lastFinalizedBatchIndex;
        uint256[28] __gap;
    }

    /// @dev Batch state: None → Accepted (acceptNextBatch) → PreConfirmed (commitPreConfirmation, Nitro) → Finalized (ensureBatchApproved after approveBlockCount).
    ///      Challenged is a side branch from Accepted when a block is challenged; resolution returns to Accepted or stays Challenged.
    enum BatchStatus {
        None,
        Accepted,
        PreConfirmed,
        Challenged,
        Finalized
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
        uint256 batchSize;
        uint256 acceptDepositDeadline;
        uint256 incentiveFee;
        address challenger;
        address prover;
        /// @dev Optional. If set, batches must be pre-confirmed via commitPreConfirmation before finalization.
        address nitroVerifier;
        /// @dev Optional. Address allowed to call commitPreConfirmation. If zero, admin is granted PRECONFIRMATION_ROLE.
        address preconfirmationRole;
    }

    function __initRollupStorage(bytes memory data) internal {
        RollupStorage storage $ = _getRollupStorage();

        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        require(params.admin != address(0), ZeroAddressNotAllowed("admin"));
        require(params.sp1Verifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        require(params.programVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        require(params.genesisHash != bytes32(0), ZeroValueNotAllowed("genesisHash"));
        require(params.batchSize != 0, ZeroValueNotAllowed("batchSize"));
        require(params.batchSize <= type(uint32).max, ZeroValueNotAllowed("batchSize"));
        require(params.approveBlockCount <= type(uint64).max, ZeroValueNotAllowed("approveBlockCount"));
        require(params.challengeBlockCount <= type(uint64).max, ZeroValueNotAllowed("challengeBlockCount"));
        require(params.acceptDepositDeadline <= type(uint64).max, ZeroValueNotAllowed("acceptDepositDeadline"));

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
        $.batchSize = uint32(params.batchSize);
        $.acceptDepositDeadline = uint64(params.acceptDepositDeadline);
        $.incentiveFee = params.incentiveFee;
        $.nextBatchIndex = 1;
        $.daCheck = true;
        // if (params.nitroVerifier != address(0)) {
        //     $.nitroVerifier = params.nitroVerifier;
        // }
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

    function batchSize() public view returns (uint256) {
        return uint256(_getRollupStorage().batchSize);
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
        return _getRollupStorage().acceptedBatchRoot[batchIndex];
    }

    function alreadyApprovedBatch(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage().batchStatus[batchIndex] == BatchStatus.Finalized;
    }

    function acceptedBlock(uint256 batchIndex) public view returns (uint256) {
        return _getRollupStorage().acceptedBlock[batchIndex];
    }

    function provenBlockCommitment(bytes32 commitmentHash) public view returns (bool) {
        return _getRollupStorage().provenBlockCommitment[commitmentHash];
    }

    // function challengerDeposit(address challenger) public view returns (uint256) {
    //     return _getRollupStorage().challengerDeposit[challenger];
    // }

    function challengerReadyForWithdrawal(address challenger) public view returns (uint256) {
        return _getRollupStorage().challengerReadyForWithdrawal[challenger];
    }

    function proverReadyForWithdrawal(address prover) public view returns (uint256) {
        return _getRollupStorage().proverReadyForWithdrawal[prover];
    }

    function blockCommitmentChallenger(bytes32 commitmentHash) public view returns (address) {
        return _getRollupStorage().blockCommitmentChallenger[commitmentHash];
    }

    function challengeDeadline(bytes32 commitmentHash) public view returns (uint256) {
        return _getRollupStorage().challengeDeadline[commitmentHash];
    }

    function batchBlobHashes(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchBlobHashes[batchIndex];
    }

    function daCheck() public view returns (bool) {
        return _getRollupStorage().daCheck;
    }

    function batchChallengedCommitments(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchChallengedCommitments[batchIndex];
    }

    function batchProvenCommitments(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchProvenCommitments[batchIndex];
    }

    function batchStatus(uint256 batchIndex) public view returns (BatchStatus) {
        return _getRollupStorage().batchStatus[batchIndex];
    }

    /**
     * @notice Checks if a batch has been accepted.
     * @param batchIndex The index of the batch to check.
     * @return True if the batch has been accepted (i.e., its index is less than the next expected batch index).
     */
    function isBatchAccepted(uint256 batchIndex) public view returns (bool) {
        return batchStatus(batchIndex) == BatchStatus.Accepted;
    }

    /**
     * @notice Checks if a batch has been accepted or pre-confirmed.
     * @param batchIndex The index of the batch to check.
     * @return True if the batch has been accepted (i.e., its index is less than the next expected batch index).
     */
    function isBatchAcceptedOrPreConfirmed(uint256 batchIndex) public view returns (bool) {
        return batchStatus(batchIndex) == BatchStatus.Accepted || batchStatus(batchIndex) == BatchStatus.PreConfirmed;
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

    /**
     * @dev Checks if the rollup is in a corrupted state.
     * @return True if the earliest challenged batch has exceeded its challenge deadline without resolution.
     *
     * A rollup is considered corrupted when:
     * - There is at least one challenged batch in the challenge queue, AND
     * - The current block number has exceeded the challenge deadline for the first challenged batch in queue.
     */
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        if ($.challengeQueue.isEmpty()) return false;

        return $.challengeDeadline[$.challengeQueue.peek()] < block.number;
    }

    /**
     * @notice Checks if a batch has been approved.
     * @param _batchIndex The index of the batch to check.
     * @return True if the batch has been approved, either because enough blocks have passed since acceptance,
     *         or the batch has already been proven.
     */
    // function finalizedBatch(uint256 _batchIndex) external view returns (bool) {
    //     return _finalizedBatch(_batchIndex);
    // }

    // function _approvedBatch(uint256 _batchIndex) internal view returns (bool) {
    //     if (!_acceptedBatch(_batchIndex)) {
    //         return false;
    //     }
    //     if (alreadyApprovedBatch[_batchIndex]) {
    //         return true;
    //     }

    //     for (uint256 idx = _batchIndex; idx > 0 && !alreadyApprovedBatch[idx]; --idx) {
    //         bytes32[] storage challengedCommitments = batchChallengedCommitments[idx];
    //         for (uint256 j = 0; j < challengedCommitments.length; j++) {
    //             if (blockCommitmentChallenger[challengedCommitments[j]] != address(0)) {
    //                 return false;
    //             }
    //         }
    //     }

    //     bytes32[] storage challengedCommitments = batchChallengedCommitments[_batchIndex];
    //     for (uint256 j = 0; j < challengedCommitments.length; j++) {
    //         bytes32 commitmentHash = challengedCommitments[j];
    //         if (blockCommitmentChallenger[commitmentHash] != address(0)) {
    //             return false;
    //         }
    //     }

    //     return block.number - acceptedBlock[_batchIndex] > approveBlockCount;
    // }

    /**
     * @dev Internal helper to determine whether a batch is approved (eligible for Finalized).
     * @param batchIndex The index of the batch.
     * @return True if: the batch is accepted; not already approved; when Nitro is set, status is PreConfirmed;
     *         no unresolved challenges in this or earlier batches; and approveBlockCount blocks have passed since acceptance.
     */
    // function _finalizeBatch(uint256 batchIndex) internal {
    //     RollupStorage storage $ = _getRollupStorage();

    //     if (!isBatchAccepted(batchIndex)) return false;
    //     if ($.batchStatus[batchIndex] == BatchStatus.Finalized) return true;
    //     // When Nitro verifier is configured, batch must be pre-confirmed before it can be finalized.
    //     if ($.batchStatus[batchIndex] != BatchStatus.PreConfirmed) return false;

    //     for (uint256 idx = batchIndex; idx > 0 && $.batchStatus[idx] != BatchStatus.Finalized; --idx) {
    //         bytes32[] storage earlierChallenged = $.batchChallengedCommitments[idx];
    //         for (uint256 j = 0; j < earlierChallenged.length; j++) {
    //             if ($.blockCommitmentChallenger[earlierChallenged[j]] != address(0)) return false;
    //         }
    //     }

    //     bytes32[] storage challengedCommitments = $.batchChallengedCommitments[batchIndex];
    //     for (uint256 j = 0; j < challengedCommitments.length; j++) {
    //         if ($.blockCommitmentChallenger[challengedCommitments[j]] != address(0)) return false;
    //     }
    // }

    /**
     * @dev We finalize a batch that has:
     * - been PreComfirmed AND
     * - there is no open challenges
     */
    function _finalizeBatch() internal {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($.lastFinalizedBatchIndex) + 1;

        if (batchStatus(batchIndex) != BatchStatus.PreConfirmed) return;

        if (block.number - $.acceptedBlock[batchIndex] > $.approveBlockCount) {
            $.batchStatus[batchIndex] = BatchStatus.Finalized;
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

    /**
     * @notice Toggle data availability check.
     * @param isCheck Whether to enable the check.
     */
    function setDaCheck(bool isCheck) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        emit DaCheckUpdated($.daCheck, isCheck);
        $.daCheck = isCheck;
    }

    function setNitroVerifier(address _newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newVerifier != address(0), ZeroAddressNotAllowed("nitroVerifier"));
        RollupStorage storage $ = _getRollupStorage();
        // TODO: emit event
        //   emit NitroVerifierUpdated(_newVerifier);
        $.enabledNitroVerifiers[_newVerifier] = true;
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
