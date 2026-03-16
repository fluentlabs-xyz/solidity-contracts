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
import {MerkleTree} from "../libraries/MerkleTree.sol";

/**
 * @title RollupStorageLayout
 * @dev ERC-7201 namespaced storage base for {Rollup}. Contains all storage fields,
 *      view getters, admin setters, and initialization logic.
 */
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

    // ============ Constants ============

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");
    bytes32 public constant PRECONFIRMATION_ROLE = keccak256("PRECONFIRMATION_ROLE");
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");
    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    /// @dev keccak256 of empty bytes — used to detect zero-message roots.
    bytes32 public constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /**
     * @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.RollupStorage")) - 1)) & ~bytes32(uint256(0xff))
     * @custom:storage-location erc7201:fluent.storage.RollupStorageLayout
     */
    bytes32 private constant ROLLUP_STORAGE_LOCATION = 0x3c5cb8ff22ae9906a910cecced8ac84ef594b2ee1cab438e85f81b70bddcc700;

    // ============ Storage ============

    /// @dev Storage layout — WARNING: breaking change, incompatible with previous layout.
    struct RollupStorage {
        // ─── Slot 1: address(20) + uint96(12) = 32 ───
        /// @dev L1 FluentBridge contract; source of deposit messages consumed during batch acceptance
        address _bridge;
        /// @dev incremented on each acceptNextBatch; starts at 1 (index 0 holds the genesis hash)
        uint96 _nextBatchIndex;
        // ─── Slot 2: address(20) + 12 bytes padding ───
        /// @dev SP1 verifier contract used for ZK proof validation during challenge resolution
        address _sp1Verifier;
        // ─── Slot 3: bytes32(32) ───
        /// @dev SP1 program verification key; binds proofs to the current rollup program
        bytes32 _programVKey;
        // ─── Slot 4: 4 × uint64 = 32 ───
        /// @dev Number of L1 blocks after batch acceptance during which challenges can be submitted
        ///      and proofs verified. After this window elapses, the batch becomes eligible for
        ///      finalization via `finalizeBatches`. Must be greater than `challengeWindow` to
        ///      guarantee challengers always have a full `challengeWindow` to respond.
        uint64 _finalizationDelay;
        /// @dev Number of L1 blocks a prover has to resolve a challenge after it is opened.
        ///      A challenge may only be submitted if `block.number + challengeWindow <= acceptedAtBlock
        ///      + finalizationDelay`, ensuring the prover always has the full window to respond and
        ///      finalization is never delayed beyond `acceptedAtBlock + finalizationDelay + challengeWindow`.
        ///      Must be strictly less than `finalizationDelay`.
        uint64 _challengeWindow;
        /// @dev Maximum number of L1 blocks after batch acceptance for the sequencer to submit
        ///      all expected blob hashes via `submitBlobs`. Exceeding this deadline without
        ///      completing DA submission triggers the corrupted state. Set to 0 to disable.
        uint64 _submitBlobsWindow;
        /// @dev Maximum number of L1 blocks after batch acceptance for the preconfirmation service
        ///      to call `preconfirmBatch`. Both `submitBlobsWindow` and this deadline are measured
        ///      from `acceptedAtBlock`, so this value must exceed `submitBlobsWindow` to give the
        ///      preconfirmation service time to act after DA submission completes. Set to 0 to disable.
        uint64 _preconfirmWindow;
        // ─── Slot 5: uint256(32) ───
        /// @dev ETH deposit required to open a challenge; awarded to prover on resolution
        uint256 _challengeDepositAmount;
        // ─── Slot 6: uint256(32) ───
        /// @dev ETH reward paid to challengers during force revert (on top of deposit refund)
        uint256 _incentiveFee;
        // ─── Slot 7: uint64(8) + uint64(8) + uint32(4) + uint32(4) = 24 bytes ───
        /// @dev highest batch index with Finalized status; enforces sequential finalization
        uint64 _lastFinalizedBatchIndex;
        /// @dev TODO: remove if unused or document purpose — not currently written
        uint64 _lastDepositAcceptedBlockNumber;
        /// @dev minimum gasleft() required per block header iteration in acceptNextBatch
        uint32 _gasLeft;
        /// @dev max L1 blocks between deposit creation and its inclusion in a batch
        uint32 _acceptDepositDeadline;
        // ─── Per-batch records ───
        /// @dev packed per-batch state (root, accepted block, expected blobs, status)
        mapping(uint256 => BatchRecord) _batches;
        /// @dev chain-linking hash; index 0 holds genesis, index N holds last block hash of batch N
        mapping(uint256 => bytes32) _lastBlockHashInBatch;
        /// @dev EIP-4844 versioned blob hashes recorded per batch for proof binding
        mapping(uint256 => bytes32[]) _batchBlobHashes;
        /// @dev commitments proven during challenge resolution; cleaned on force revert
        mapping(uint256 => bytes32[]) _batchProvenBlocks;
        /// @dev commitments challenged per batch; used for refund iteration in force revert
        mapping(uint256 => bytes32[]) _batchChallengedBlocks;
        // ─── Challenge state (keyed by commitment) ───
        /// @dev tracks which block commitments have been proven; prevents duplicate proofs
        mapping(bytes32 => bool) _provenBlocks;
        /// @dev active challenge records keyed by block commitment hash
        mapping(bytes32 => ChallengeRecord) _challenges;
        /// @dev min-heap of challenged commitments ordered by deadline for corruption detection
        Heap.HeapStorage _challengeQueue;
        /// @dev heap priority map: commitment → deadline (used by Heap for ordering)
        mapping(bytes32 => uint256) _challengePriority;
        /// @dev heap position map: commitment → 1-based index (used by Heap for O(1) removal)
        mapping(bytes32 => uint256) _challengeQueueIndex;
        // ─── Reward balances ───
        /// @dev ETH balances claimable by challengers after force revert
        mapping(address => uint256) _challengerRewards;
        /// @dev ETH balances claimable by provers after resolving challenges
        mapping(address => uint256) _proverRewards;
        // ─── Verifier whitelist ───
        /// @dev whitelist of Nitro enclave verifier contracts allowed for preconfirmation
        mapping(address => bool) _enabledNitroVerifiers;
        // ─── Upgrade gap ───
        /// @dev reserved storage slots for future upgrades
        uint256[28] __gap;
    }

    // ============ Initializer ============

    /**
     * @dev Initializes rollup storage from ABI-encoded {InitConfiguration}.
     *      Called once from {Rollup.initialize} via the UUPS proxy.
     */
    function __initRollupStorage(bytes memory data) internal onlyInitializing {
        RollupStorage storage $ = _getRollupStorage();

        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        // ─── Address validation ───
        require(params.admin != address(0), ZeroAddressNotAllowed("admin"));
        require(params.sp1Verifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        require(params.bridge != address(0), ZeroAddressNotAllowed("bridge"));

        // ─── Value validation ───
        require(params.programVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        require(params.genesisHash != bytes32(0), ZeroValueNotAllowed("genesisHash"));

        // ─── Deadline invariants ───
        if (params.submitBlobsWindow != 0 && params.preconfirmWindow != 0) {
            require(params.preconfirmWindow > params.submitBlobsWindow, InvalidWindowConfig("preconfirmWindow must exceed submitBlobsWindow"));
        }
        require(params.challengeWindow < params.finalizationDelay, InvalidWindowConfig("challengeWindow must be less than finalizationDelay"));

        // ─── Role setup ───
        address emergency = params.emergency != address(0) ? params.emergency : params.admin;
        address challenger = params.challenger != address(0) ? params.challenger : params.admin;
        address prover = params.prover != address(0) ? params.prover : params.admin;
        address sequencer = params.sequencer != address(0) ? params.sequencer : params.admin;
        address preconfirmation = params.preconfirmationRole != address(0) ? params.preconfirmationRole : params.admin;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(EMERGENCY_ROLE, emergency);
        _grantRole(CHALLENGER_ROLE, challenger);
        _grantRole(PROVER_ROLE, prover);
        _grantRole(SEQUENCER_ROLE, sequencer);
        _grantRole(PRECONFIRMATION_ROLE, preconfirmation);

        // ─── Storage setup ───
        $._bridge = params.bridge;
        $._sp1Verifier = params.sp1Verifier;
        $._programVKey = params.programVKey;
        $._lastBlockHashInBatch[0] = params.genesisHash;
        $._nextBatchIndex = 1;
        $._challengeDepositAmount = params.challengeDepositAmount;
        $._challengeWindow = uint64(params.challengeWindow);
        $._finalizationDelay = uint64(params.finalizationDelay);
        $._acceptDepositDeadline = uint32(params.acceptDepositDeadline);
        $._incentiveFee = params.incentiveFee;
        $._submitBlobsWindow = uint64(params.submitBlobsWindow);
        $._preconfirmWindow = uint64(params.preconfirmWindow);

        if (params.nitroVerifier != address(0)) {
            $._enabledNitroVerifiers[params.nitroVerifier] = true;
            emit NitroVerifierEnabled(params.nitroVerifier);
        }
    }

    // ============ IRollupConfig ============

    /// @inheritdoc IRollupConfig
    function bridge() public view returns (address) {
        return _getRollupStorage()._bridge;
    }

    /// @inheritdoc IRollupConfig
    function sp1Verifier() public view returns (address) {
        return _getRollupStorage()._sp1Verifier;
    }

    /// @inheritdoc IRollupConfig
    function programVKey() public view returns (bytes32) {
        return _getRollupStorage()._programVKey;
    }

    /// @inheritdoc IRollupConfig
    function finalizationDelay() public view returns (uint256) {
        return uint256(_getRollupStorage()._finalizationDelay);
    }

    /// @inheritdoc IRollupConfig
    function challengeWindow() public view returns (uint256) {
        return uint256(_getRollupStorage()._challengeWindow);
    }

    /// @inheritdoc IRollupConfig
    function challengeDepositAmount() public view returns (uint256) {
        return _getRollupStorage()._challengeDepositAmount;
    }

    /// @inheritdoc IRollupConfig
    function incentiveFee() public view returns (uint256) {
        return _getRollupStorage()._incentiveFee;
    }

    /// @inheritdoc IRollupConfig
    function acceptDepositDeadline() public view returns (uint256) {
        return uint256(_getRollupStorage()._acceptDepositDeadline);
    }

    /// @inheritdoc IRollupConfig
    function submitBlobsWindow() public view returns (uint256) {
        return uint256(_getRollupStorage()._submitBlobsWindow);
    }

    /// @inheritdoc IRollupConfig
    function preconfirmWindow() public view returns (uint256) {
        return uint256(_getRollupStorage()._preconfirmWindow);
    }

    // ============ IRollupRead ============

    /// @inheritdoc IRollupRead
    function getBatch(uint256 batchIndex) public view returns (BatchRecord memory) {
        return _getRollupStorage()._batches[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function nextBatchIndex() public view returns (uint256) {
        return uint256(_getRollupStorage()._nextBatchIndex);
    }

    /// @inheritdoc IRollupRead
    function lastFinalizedBatchIndex() public view returns (uint256) {
        return uint256(_getRollupStorage()._lastFinalizedBatchIndex);
    }

    /// @inheritdoc IRollupRead
    function lastBlockHashInBatch(uint256 batchIndex) public view returns (bytes32) {
        return _getRollupStorage()._lastBlockHashInBatch[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function isBatchFinalized(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage()._batches[batchIndex].status == BatchStatus.Finalized;
    }

    /// @inheritdoc IRollupRead
    function isBatchPreconfirmed(uint256 batchIndex) public view returns (bool) {
        return _getRollupStorage()._batches[batchIndex].status == BatchStatus.Preconfirmed;
    }

    /// @inheritdoc IRollupRead
    function getChallenge(bytes32 commitment) public view returns (ChallengeRecord memory) {
        return _getRollupStorage()._challenges[commitment];
    }

    /// @inheritdoc IRollupRead
    /// @dev Elements are in heap-internal order — only index 0 is guaranteed to be the
    ///      earliest deadline. Sort off-chain by getChallenge(commitment).deadline if
    ///      ordered traversal is needed.
    function challengeQueue() public view returns (bytes32[] memory) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 size = $._challengeQueue.length();
        if (size == 0) return new bytes32[](0);

        bytes32[] memory queue = new bytes32[](size);
        for (uint256 i = 0; i < size; ++i) {
            queue[i] = $._challengeQueue.at(i);
        }
        return queue;
    }

    /// @inheritdoc IRollupRead
    function batchBlobHashes(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage()._batchBlobHashes[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function batchChallengedBlocks(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage()._batchChallengedBlocks[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function batchProvenBlocks(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage()._batchProvenBlocks[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function isBlockProven(bytes32 commitment) public view returns (bool) {
        return _getRollupStorage()._provenBlocks[commitment];
    }

    /// @inheritdoc IRollupRead
    function claimableChallengerReward(address challenger) public view returns (uint256) {
        return _getRollupStorage()._challengerRewards[challenger];
    }

    /// @inheritdoc IRollupRead
    function claimableProofReward(address prover) public view returns (uint256) {
        return _getRollupStorage()._proverRewards[prover];
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
        emit SP1VerifierUpdated($._sp1Verifier, newVerifier);
        $._sp1Verifier = newVerifier;
    }

    /// @inheritdoc IRollupAdmin
    function setProgramVKey(bytes32 newVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        RollupStorage storage $ = _getRollupStorage();
        emit ProgramVKeyUpdated($._programVKey, newVKey);
        $._programVKey = newVKey;
    }

    /// @inheritdoc IRollupAdmin
    function setNitroVerifier(address newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVerifier != address(0), ZeroAddressNotAllowed("nitroVerifier"));
        _getRollupStorage()._enabledNitroVerifiers[newVerifier] = true;
        emit NitroVerifierEnabled(newVerifier);
    }

    /// @inheritdoc IRollupAdmin
    function setGasLeft(uint32 newGasLeft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getRollupStorage()._gasLeft = newGasLeft;
    }

    // ============ Internal helpers ============

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Updates the bridge address after validating it is non-zero.
     */
    function _setBridge(address newBridge) internal {
        RollupStorage storage $ = _getRollupStorage();
        require(newBridge != address(0), ZeroAddressNotAllowed("bridge"));
        emit BridgeUpdated($._bridge, newBridge);
        $._bridge = newBridge;
    }

    /**
     * @dev Returns a storage pointer to the ERC-7201 namespaced rollup storage slot.
     */
    function _getRollupStorage() internal pure returns (RollupStorage storage $) {
        assembly {
            $.slot := ROLLUP_STORAGE_LOCATION
        }
    }
}
