// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IVerifier} from "../interfaces/IVerifier.sol";
import {IRollupEvents, IRollupErrors} from "../interfaces/IRollup.sol";

/**
 *
 */
contract RollupStorageLayout is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    IRollupEvents,
    IRollupErrors
{
    // ============ Roles ============

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");

    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    /// @dev Constant representing an empty deposit hash.
    bytes32 public constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /**
     * @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.RollupStorage")) - 1)) & ~bytes32(uint256(0xff))
     * @custom:storage-location erc7201:fluent.storage.RollupStorage
     */
    bytes32 private constant ROLLUP_STORAGE_LOCATION = 0x3c5cb8ff22ae9906a910cecced8ac84ef594b2ee1cab438e85f81b70bddcc700;

    struct RollupStorage {
        address sequencer;
        address bridge;
        /// @dev zk-SNARK verifier instance.
        address verifier;
        bytes32 programVKey;
        uint256 nextBatchIndex;
        uint256 approveBlockCount;
        uint256 challengeDepositAmount;
        uint256 incentiveFee;
        uint256 challengeBlockCount;
        uint256 batchSize;
        mapping(uint256 => bytes32) lastBlockHashInBatch;
        uint256 lastDepositAcceptedBlockNumber;
        uint256 acceptDepositDeadline;
        mapping(uint256 => bytes32) acceptedBatchHash;
        mapping(uint256 => bool) alreadyApprovedBatch;
        mapping(uint256 => uint256) acceptedBlock;
        mapping(bytes32 => bool) provenBlockCommitment;
        mapping(address => uint256) challengerDeposit;
        mapping(address => uint256) challengerReadyForWithdrawal;
        mapping(address => uint256) proverReadyForWithdrawal;
        mapping(bytes32 => address) blockCommitmentChallenger;
        mapping(bytes32 => uint256) challengeDeadline;
        bytes32[] challengeQueue;
        uint256 challengeQueueStart;
        mapping(bytes32 => uint256) challengeQueueIndex;
        mapping(uint256 => bytes32[]) batchBlobHashes;
        bool daCheck;
        mapping(uint256 => bytes32[]) batchChallengedCommitments;
        mapping(uint256 => bytes32[]) provenCommitmentInBatch;
        uint256[30] __gap;
    }

    /// @dev Structure representing a committed block.
    struct BlockCommitment {
        bytes32 previousBlockHash;
        bytes32 blockHash;
        bytes32 withdrawalHash;
        bytes32 depositHash;
    }

    /// @dev Represents metadata about deposits included in a block.
    struct DepositsInBlock {
        bytes32 blockHash;
        uint256 depositCount;
    }

    struct InitConfiguration {
        address admin;
        address pauser;
        address sequencer;
        uint256 challengeDepositAmount;
        uint256 challengeBlockCount;
        uint256 approveBlockCount;
        address verifier;
        bytes32 programVKey;
        bytes32 genesisHash;
        address bridge;
        uint256 batchSize;
        uint256 acceptDepositDeadline;
        uint256 incentiveFee;
        address challenger;
        address prover;
    }

    function __initRollupStorage(bytes memory data) internal {
        RollupStorage storage $ = _getRollupStorage();

        (InitConfiguration memory params) = abi.decode(data, (InitConfiguration));

        require(params.admin != address(0), ZeroAddressNotAllowed("admin"));
        require(params.sequencer != address(0), ZeroAddressNotAllowed("sequencer"));
        require(params.verifier != address(0), ZeroAddressNotAllowed("verifier"));
        require(params.programVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        require(params.genesisHash != bytes32(0), ZeroValueNotAllowed("genesisHash"));
        require(params.batchSize != 0, ZeroValueNotAllowed("batchSize"));

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(PAUSER_ROLE, params.pauser != address(0) ? params.pauser : params.admin);
        _grantRole(CHALLENGER_ROLE, params.challenger != address(0) ? params.challenger : params.admin);
        _grantRole(PROVER_ROLE, params.prover != address(0) ? params.prover : params.admin);

        $.sequencer = params.sequencer;
        $.challengeDepositAmount = params.challengeDepositAmount;
        $.challengeBlockCount = params.challengeBlockCount;
        $.approveBlockCount = params.approveBlockCount;
        $.verifier = params.verifier;
        $.programVKey = params.programVKey;
        $.lastBlockHashInBatch[0] = params.genesisHash;
        $.bridge = params.bridge;
        $.batchSize = params.batchSize;
        $.acceptDepositDeadline = params.acceptDepositDeadline;
        $.incentiveFee = params.incentiveFee;
        $.nextBatchIndex = 1;
        $.daCheck = true;
    }

    // ========= Storage View Getters =========

    function sequencer() public view returns (address) {
        return _getRollupStorage().sequencer;
    }

    function bridge() public view returns (address) {
        return _getRollupStorage().bridge;
    }

    function verifier() public view returns (address) {
        return _getRollupStorage().verifier;
    }

    function programVKey() public view returns (bytes32) {
        return _getRollupStorage().programVKey;
    }

    function nextBatchIndex() public view returns (uint256) {
        return _getRollupStorage().nextBatchIndex;
    }

    function approveBlockCount() public view returns (uint256) {
        return _getRollupStorage().approveBlockCount;
    }

    function challengeDepositAmount() public view returns (uint256) {
        return _getRollupStorage().challengeDepositAmount;
    }

    function incentiveFee() public view returns (uint256) {
        return _getRollupStorage().incentiveFee;
    }

    function challengeBlockCount() public view returns (uint256) {
        return _getRollupStorage().challengeBlockCount;
    }

    function batchSize() public view returns (uint256) {
        return _getRollupStorage().batchSize;
    }

    function lastBlockHashInBatch(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage().lastBlockHashInBatch[batchIndex];
    }

    function lastDepositAcceptedBlockNumber() public view returns (uint256) {
        return _getRollupStorage().lastDepositAcceptedBlockNumber;
    }

    function acceptDepositDeadline() public view returns (uint256) {
        return _getRollupStorage().acceptDepositDeadline;
    }

    function acceptedBatchHash(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage().acceptedBatchHash[batchIndex];
    }

    function alreadyApprovedBatch(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage().alreadyApprovedBatch[batchIndex];
    }

    function acceptedBlock(uint256 batchIndex) public view returns (uint256) {
        return _getRollupStorage().acceptedBlock[batchIndex];
    }

    function provenBlockCommitment(bytes32 commitmentHash) public view returns (bool) {
        return _getRollupStorage().provenBlockCommitment[commitmentHash];
    }

    function challengerDeposit(address challenger) public view returns (uint256) {
        return _getRollupStorage().challengerDeposit[challenger];
    }

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

    function provenCommitmentInBatch(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().provenCommitmentInBatch[batchIndex];
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
        RollupStorage storage $ = _getRollupStorage();
        return _batchIndex < $.nextBatchIndex;
    }

    /**
     * @notice Returns the challenge queue.
     */
    function getChallengeQueue() public view returns (bytes32[] memory) {
        RollupStorage storage $ = _getRollupStorage();
        return $.challengeQueue;
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
        if ($.challengeQueue.length == 0 || $.challengeQueueStart >= $.challengeQueue.length) {
            return false;
        }

        bytes32 oldestChallenge = $.challengeQueue[$.challengeQueueStart];
        if (oldestChallenge == bytes32(0)) return false;

        return $.challengeDeadline[oldestChallenge] < block.number;
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
        RollupStorage storage $ = _getRollupStorage();
        if (_approvedBatch(_batchIndex)) {
            $.alreadyApprovedBatch[_batchIndex] = true;
            return true;
        }
        return false;
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
        RollupStorage storage $ = _getRollupStorage();

        if (!_acceptedBatch(_batchIndex)) return false;
        if ($.alreadyApprovedBatch[_batchIndex]) return true;

        for (uint256 idx = _batchIndex; idx > 0 && !$.alreadyApprovedBatch[idx]; --idx) {
            bytes32[] storage earlierChallenged = $.batchChallengedCommitments[idx];
            for (uint256 j = 0; j < earlierChallenged.length; j++) {
                if ($.blockCommitmentChallenger[earlierChallenged[j]] != address(0)) return false;
            }
        }

        bytes32[] storage challengedCommitments = $.batchChallengedCommitments[_batchIndex];
        for (uint256 j = 0; j < challengedCommitments.length; j++) {
            if ($.blockCommitmentChallenger[challengedCommitments[j]] != address(0)) return false;
        }

        return block.number - $.acceptedBlock[_batchIndex] > $.approveBlockCount;
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

    /**
     * @notice Set a new bridge contract address.
     * @param _bridge The new bridge address.
     */
    function setBridge(address _bridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(_bridge != address(0), ZeroAddressNotAllowed("bridge"));
        emit BridgeUpdated($.bridge, _bridge);
        $.bridge = _bridge;
    }

    /**
     * @notice Set a new verifier contract address.
     * @param _newVerifier The address of the new verifier.
     */
    function setVerifier(address _newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newVerifier != address(0), ZeroAddressNotAllowed("verifier"));
        RollupStorage storage $ = _getRollupStorage();
        emit VerifierUpdated($.verifier, _newVerifier);
        $.verifier = _newVerifier;
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
