// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IRollupEvents, IRollupErrors, IRollupRead, IRollupConfig, IRollupAdmin} from "../interfaces/IRollup.sol";
import {BatchStatus, BatchRecord, ChallengeRecord, L2BlockHeader, InitConfiguration} from "../interfaces/IRollupTypes.sol";
import {Heap} from "../libraries/Heap.sol";

contract RollupStorageLayout is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    IRollupEvents,
    IRollupErrors,
    IRollupRead,
    IRollupConfig,
    IRollupAdmin
{
    using Heap for Heap.HeapStorage;

    // ============ Roles ============

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");
    bytes32 public constant PRECONFIRMATION_ROLE = keccak256("PRECONFIRMATION_ROLE");
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");
    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    /// @dev keccak256 of empty bytes — used to detect zero-message roots.
    bytes32 public constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /**
     * @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.RollupStorageLayout")) - 1)) & ~bytes32(uint256(0xff))
     * @custom:storage-location erc7201:fluent.storage.RollupStorageLayout
     */
    bytes32 private constant ROLLUP_STORAGE_LOCATION = 0x3c5cb8ff22ae9906a910cecced8ac84ef594b2ee1cab438e85f81b70bddcc700;

    // ============ Storage ============

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
        // ─── Per-batch records ───
        mapping(uint256 => BatchRecord) batches;
        mapping(uint256 => bytes32) lastBlockHashInBatch;
        mapping(uint256 => bytes32[]) batchBlobHashes;
        mapping(uint256 => bytes32[]) batchProvenBlocks;
        mapping(uint256 => bytes32[]) batchChallengedBlocks;
        // ─── Challenge state (keyed by commitment) ───
        mapping(bytes32 => bool) provenBlocks;
        mapping(bytes32 => ChallengeRecord) challenges;
        Heap.HeapStorage challengeQueue;
        /// @dev Heap priority map: commitment → deadline
        mapping(bytes32 => uint256) challengePriority;
        /// @dev Heap position map: commitment → queue index
        mapping(bytes32 => uint256) challengeQueueIndex;
        // ─── Reward balances ───
        mapping(address => uint256) challengerRewards;
        mapping(address => uint256) proverRewards;
        // ─── Verifier whitelist ───
        mapping(address => bool) enabledNitroVerifiers;
        // ─── Upgrade gap ───
        uint256[28] __gap;
    }

    // ============ Initializer ============

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
        _grantRole(EMERGENCY_ROLE, params.emergency != address(0) ? params.emergency : params.admin);
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

        if (params.nitroVerifier != address(0)) {
            $.enabledNitroVerifiers[params.nitroVerifier] = true;
            emit NitroVerifierEnabled(params.nitroVerifier);
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ IRollupConfig ============

    /// @inheritdoc IRollupConfig
    function bridge() public view returns (address) {
        return _getRollupStorage().bridge;
    }

    /// @inheritdoc IRollupConfig
    function sp1Verifier() public view returns (address) {
        return _getRollupStorage().sp1Verifier;
    }

    /// @inheritdoc IRollupConfig
    function programVKey() public view returns (bytes32) {
        return _getRollupStorage().programVKey;
    }

    /// @inheritdoc IRollupConfig
    function approveBlockCount() public view returns (uint256) {
        return uint256(_getRollupStorage().approveBlockCount);
    }

    /// @inheritdoc IRollupConfig
    function challengeBlockCount() public view returns (uint256) {
        return uint256(_getRollupStorage().challengeBlockCount);
    }

    /// @inheritdoc IRollupConfig
    function challengeDepositAmount() public view returns (uint256) {
        return _getRollupStorage().challengeDepositAmount;
    }

    /// @inheritdoc IRollupConfig
    function incentiveFee() public view returns (uint256) {
        return _getRollupStorage().incentiveFee;
    }

    /// @inheritdoc IRollupConfig
    function acceptDepositDeadline() public view returns (uint256) {
        return uint256(_getRollupStorage().acceptDepositDeadline);
    }

    /// @inheritdoc IRollupConfig
    function daDeadlineBlocks() public view returns (uint256) {
        return uint256(_getRollupStorage().daDeadlineBlocks);
    }

    /// @inheritdoc IRollupConfig
    function preconfirmDeadlineBlocks() public view returns (uint256) {
        return uint256(_getRollupStorage().preconfirmDeadlineBlocks);
    }

    // ============ IRollupRead ============

    /// @inheritdoc IRollupRead
    function isRollupCorrupted() external view returns (bool) {
        return _rollupCorrupted();
    }

    /// @inheritdoc IRollupRead
    function getBatch(uint256 batchIndex) public view returns (BatchRecord memory) {
        return _getRollupStorage().batches[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function nextBatchIndex() public view returns (uint256) {
        return uint256(_getRollupStorage().nextBatchIndex);
    }

    /// @inheritdoc IRollupRead
    function lastFinalizedBatchIndex() public view returns (uint256) {
        return uint256(_getRollupStorage().lastFinalizedBatchIndex);
    }

    /// @inheritdoc IRollupRead
    function lastBlockHashInBatch(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage().lastBlockHashInBatch[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function isBatchFinalized(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage().batches[batchIndex].status == BatchStatus.Finalized;
    }

    /// @inheritdoc IRollupRead
    function isBatchPreconfirmed(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage().batches[batchIndex].status == BatchStatus.Preconfirmed;
    }

    /// @inheritdoc IRollupRead
    function getChallenge(bytes32 commitment) public view returns (ChallengeRecord memory) {
        return _getRollupStorage().challenges[commitment];
    }

    /// @inheritdoc IRollupRead
    function challengeQueue() public view returns (bytes32[] memory) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 size = $.challengeQueue.length();
        if (size == 0) return new bytes32[](0);

        bytes32[] memory queue = new bytes32[](size);
        for (uint256 i = 0; i < size; ++i) {
            queue[i] = $.challengeQueue.at(i);
        }
        return queue;
    }

    /// @inheritdoc IRollupRead
    function batchBlobHashes(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchBlobHashes[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function batchChallengedBlocks(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchChallengedBlocks[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function batchProvenBlocks(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage().batchProvenBlocks[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function isBlockProven(bytes32 commitment) public view returns (bool) {
        return _getRollupStorage().provenBlocks[commitment];
    }

    /// @inheritdoc IRollupRead
    function claimableChallengerReward(address challenger) public view returns (uint256) {
        return _getRollupStorage().challengerRewards[challenger];
    }

    /// @inheritdoc IRollupRead
    function claimableProofReward(address prover) public view returns (uint256) {
        return _getRollupStorage().proverRewards[prover];
    }

    // ============ IRollupAdmin ============

    /// @inheritdoc IRollupAdmin
    function setBridge(address newBridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBridge(newBridge);
    }

    /// @inheritdoc IRollupAdmin
    function setSp1Verifier(address newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVerifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        RollupStorage storage $ = _getRollupStorage();
        emit SP1VerifierUpdated($.sp1Verifier, newVerifier);
        $.sp1Verifier = newVerifier;
    }

    /// @inheritdoc IRollupAdmin
    function setProgramVKey(bytes32 newVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RollupStorage storage $ = _getRollupStorage();
        require(newVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        emit ProgramVKeyUpdated($.programVKey, newVKey);
        $.programVKey = newVKey;
    }

    /// @inheritdoc IRollupAdmin
    function setNitroVerifier(address newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVerifier != address(0), ZeroAddressNotAllowed("nitroVerifier"));
        _getRollupStorage().enabledNitroVerifiers[newVerifier] = true;
        emit NitroVerifierEnabled(newVerifier);
    }

    /// @inheritdoc IRollupAdmin
    function setGasLeft(uint32 gasLeft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getRollupStorage().gasLeft = gasLeft;
    }

    // ============ Internal helpers ============

    function _setBridge(address _bridge) internal {
        RollupStorage storage $ = _getRollupStorage();
        require(_bridge != address(0), ZeroAddressNotAllowed("bridge"));
        emit BridgeUpdated($.bridge, _bridge);
        $.bridge = _bridge;
    }

    /// @dev Checks if the rollup is corrupted by examining the oldest non-finalized batch.
    ///      Corruption occurs when: DA deadline exceeded (HeadersSubmitted), preconfirm deadline
    ///      exceeded (Accepted), or challenge deadline exceeded (Challenged).
    function _rollupCorrupted() internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($.lastFinalizedBatchIndex) + 1;
        if (batchIndex >= $.nextBatchIndex) return false;

        BatchRecord storage batch = $.batches[batchIndex];
        BatchStatus status = batch.status;
        uint256 accepted = uint256(batch.acceptedAtBlock);

        if (status == BatchStatus.HeadersSubmitted && $.daDeadlineBlocks != 0 && block.number > accepted + $.daDeadlineBlocks) return true;
        if (status == BatchStatus.Accepted && $.preconfirmDeadlineBlocks != 0 && block.number > accepted + $.preconfirmDeadlineBlocks)
            return true;
        if (status == BatchStatus.Challenged) {
            if (!$.challengeQueue.isEmpty()) {
                bytes32 oldest = $.challengeQueue.peek();
                return $.challenges[oldest].deadline < block.number;
            }
        }
        return false;
    }

    /// @dev Auto-finalizes the batch at lastFinalizedBatchIndex + 1 if eligible.
    function _finalizeBatch() internal {
        RollupStorage storage $ = _getRollupStorage();
        uint256 batchIndex = uint256($.lastFinalizedBatchIndex) + 1;

        BatchRecord storage batch = $.batches[batchIndex];
        if (batch.status != BatchStatus.Preconfirmed) return;

        if (block.number - uint256(batch.acceptedAtBlock) > $.approveBlockCount) {
            batch.status = BatchStatus.Finalized;
            $.lastFinalizedBatchIndex = uint64(batchIndex);
            emit BatchFinalized(batchIndex);
        }
    }

    /// @dev Encodes L2BlockHeader fields + blob hashes as SP1 public values.
    function _getPublicValuesFromHeaderAndBlobs(
        L2BlockHeader calldata header,
        bytes32[] memory blobHashes
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot),
                blobHashes
            );
    }

    /// @notice Calculates the Merkle root of a batch of L2 block headers.
    function calculateBatchRoot(L2BlockHeader[] calldata headers) public pure returns (bytes32) {
        bytes memory leafs = new bytes(headers.length * 32);

        for (uint256 i = 0; i < headers.length; ++i) {
            bytes32 hash = keccak256(
                abi.encodePacked(headers[i].previousBlockHash, headers[i].blockHash, headers[i].withdrawalRoot, headers[i].depositRoot)
            );
            assembly {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }

        return _calculateMerkleRoot(leafs);
    }

    /// @notice Calculates the hash of a blob for DA verification.
    function calculateBlobHash(bytes memory blob) public pure returns (bytes32) {
        bytes32 hash = sha256(blob);
        hash &= 0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        hash |= 0x0100000000000000000000000000000000000000000000000000000000000000;
        return hash;
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

    /// @dev Returns the blob hash for the given index using the BLOBHASH opcode.
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
