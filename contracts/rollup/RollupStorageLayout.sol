// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IRollupEvents, IRollupErrors, IRollupRead, IRollupConfig, IRollupAdmin} from "../interfaces/IRollup.sol";
import {BatchStatus, BatchRecord, ChallengeRecord, InitConfiguration} from "../interfaces/IRollupTypes.sol";
import {Heap} from "../libraries/Heap.sol";

/**
 * @title RollupStorageLayout
 * @author Fluent Labs
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

    /**
     * @notice Role that can perform emergency actions. Should be Timelock Contract
     */
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /**
     * @notice Role that can submit batches.
     */
    bytes32 public constant SEQUENCER_ROLE = keccak256("SEQUENCER_ROLE");

    /**
     * @notice Role that can preconfirm batches.
     */
    bytes32 public constant PRECONFIRMATION_ROLE = keccak256("PRECONFIRMATION_ROLE");

    /**
     * @notice Role that can challenge batches.
     */
    bytes32 public constant CHALLENGER_ROLE = keccak256("CHALLENGER_ROLE");

    /**
     * @notice Role that can prove batches.
     */
    bytes32 public constant PROVER_ROLE = keccak256("PROVER_ROLE");

    /**
     * @dev Default gas left per block header iteration in acceptNextBatch.
     */
    uint32 public constant DEFAULT_GAS_LEFT = 1_000_000;

    /**
     * @dev Upper bound on {incentiveFee} so `challenge.deposit + fee` cannot overflow uint256
     *      during {forceRevertBatch} reward crediting.
     */
    uint256 public constant MAX_INCENTIVE_FEE = 1000 ether;

    /// @dev keccak256 of empty bytes — used to detect zero-message roots.
    bytes32 public constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /**
     * @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.RollupStorage")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant ROLLUP_STORAGE_LOCATION = 0x3c5cb8ff22ae9906a910cecced8ac84ef594b2ee1cab438e85f81b70bddcc700;

    // ============ Storage ============

    /**
     * @dev Packed rollup state. All mutable storage is in this struct, accessed via
     *      {_getRollupStorage}. Fields are append-only for upgrade safety.
     */
    /// @custom:storage-location erc7201:fluent.storage.RollupStorage
    struct RollupStorage {
        // ─── Slot 1: address(20) + uint96(12) = 32 ───
        /**
         * @dev L1 FluentBridge contract; source of deposit messages consumed during batch acceptance
         */
        address _bridge;
        /**
         * @dev incremented on each acceptNextBatch; starts at 1 (index 0 holds the genesis hash)
         */
        uint96 _nextBatchIndex;
        // ─── Slot 2: address(20) + 12 bytes padding ───
        /**
         * @dev SP1 verifier contract used for ZK proof validation during challenge resolution
         */
        address _sp1Verifier;
        // ─── Slot 3: bytes32(32) ───
        /**
         * @dev SP1 program verification key; binds proofs to the current rollup program
         */
        bytes32 _programVKey;
        // ─── Slot 4: 4 × uint64 = 32 ───
        /**
         * @dev Number of L1 blocks after batch acceptance during which challenges can be submitted
         *          and proofs verified. After this window elapses, the batch becomes eligible for
         *          finalization via `finalizeBatches`. Must be greater than `challengeWindow` to
         *          guarantee challengers always have a full `challengeWindow` to respond.
         */
        uint64 _finalizationDelay;
        /**
         * @dev Batch-wide challenge window measured from acceptance: all challenges for a batch
         *      must be submitted AND resolved before `acceptedAtBlock + _challengeWindow`.
         *      The deadline is shared — a late challenge leaves the prover less time to respond.
         *      Must be strictly less than {_finalizationDelay}.
         */
        uint64 _challengeWindow;
        /**
         * @dev Maximum number of L1 blocks after batch acceptance for the sequencer to submit
         *      all expected blob hashes via `submitBlobs`. Exceeding this deadline without
         *      completing DA submission triggers the corrupted state. Set to 0 to disable.
         */
        uint64 _submitBlobsWindow;
        /**
         * @dev Maximum number of L1 blocks after batch acceptance for the preconfirmation service
         *      to call `preconfirmBatch`. Both `submitBlobsWindow` and this deadline are measured
         *      from `acceptedAtBlock`, so this value must exceed `submitBlobsWindow` to give the
         *      preconfirmation service time to act after DA submission completes. Set to 0 to disable.
         */
        uint64 _preconfirmWindow;
        // ─── Slot 5: uint256(32) ───
        /**
         * @dev ETH deposit required to open a challenge; awarded to prover on resolution
         */
        uint256 _challengeDepositAmount;
        // ─── Slot 6: uint256(32) ───
        /**
         * @dev ETH reward paid to challengers during force revert (on top of deposit refund)
         */
        uint256 _incentiveFee;
        // ─── Slot 7: uint64(8) + uint64(8) + uint32(4) + uint32(4) + uint32(4) = 28 bytes ───
        /**
         * @dev highest batch index with Finalized status; enforces sequential finalization
         */
        uint64 _lastFinalizedBatchIndex;
        /**
         * @dev Reserved for future deposit-tracking upgrades. Kept in storage to avoid layout churn.
         */
        uint64 _lastDepositAcceptedBlockNumber;
        /**
         * @dev minimum gasleft() required per block header iteration in acceptNextBatch
         */
        uint32 _gasLeft;
        /**
         * @dev max L1 blocks between deposit creation and its inclusion in a batch
         */
        uint32 _acceptDepositDeadline;
        // ============ Emergency revert pagination ============
        /**
         * @dev Max batch size to prevent OOG during paginated force revert. Should be >= 1.
         */
        uint32 _maxForceRevertBatchSize;
        // ============ Per-batch records ============
        /**
         * @dev packed per-batch state (root, accepted block, expected blobs, status)
         */
        mapping(uint256 => BatchRecord) _batches;
        /**
         * @dev chain-linking hash; index 0 holds genesis, index N holds last block hash of batch N
         */
        mapping(uint256 => bytes32) _lastBlockHashInBatch;
        /**
         * @dev EIP-4844 versioned blob hashes recorded per batch for proof binding
         */
        mapping(uint256 => bytes32[]) _batchBlobHashes;
        /**
         * @dev commitments proven during challenge resolution; cleaned on force revert
         */
        mapping(uint256 => bytes32[]) _batchProvenBlocks;
        /**
         * @dev commitments challenged per batch; used for refund iteration in force revert
         */
        mapping(uint256 => bytes32[]) _batchChallengedBlocks;
        // ============ Challenge state (keyed by commitment) ============
        /**
         * @dev tracks which block commitments have been proven; prevents duplicate proofs
         */
        mapping(bytes32 => bool) _provenBlocks;
        /**
         * @dev active challenge records keyed by block commitment hash
         */
        mapping(bytes32 => ChallengeRecord) _challenges;
        /**
         * @dev min-heap of challenged commitments ordered by deadline for corruption detection
         */
        Heap.HeapStorage _challengeQueue;
        /**
         * @dev heap priority map: commitment → deadline (used by Heap for ordering)
         */
        mapping(bytes32 => uint256) _challengePriority;
        /**
         * @dev Heap position map: commitment hash to 1-based index within {_challengeQueue}.
         *      Zero means not in heap. Used by {Heap} for O(log n) removal.
         */
        mapping(bytes32 => uint256) _challengeQueueIndex;
        // ============ Reward balances ============
        /**
         * @dev ETH balances claimable by challengers after force revert
         */
        mapping(address => uint256) _challengerRewards;
        /**
         * @dev ETH balances claimable by provers after resolving challenges
         */
        mapping(address => uint256) _proverRewards;
        // ============ Verifier whitelist ============
        /**
         * @dev whitelist of Nitro enclave verifier contracts allowed for preconfirmation
         */
        mapping(address => bool) _enabledNitroVerifiers;
        // ============ Deposit tracking for force-revert restoration ============
        /**
         * @dev deposit message hashes consumed per batch during acceptNextBatch; restored to
         *      the bridge queue on force-revert via {L1FluentBridge-pushSentMessage}
         */
        mapping(uint256 => bytes32[]) _batchDepositIds;
        // ============ Upgrade gap ============
        /// @dev Reserved storage slots for future upgrades.
        uint256[24] __gap;
    }

    // ============ Storage Initializer ============

    /**
     * @dev Initializes rollup storage from ABI-encoded {InitConfiguration}.
     *      Called once from {Rollup.initialize} via the UUPS proxy.
     *      Parent initializers (ReentrancyGuard, Pausable, AccessControl, UUPS)
     *      are called in {Rollup.initialize} before this function.
     */
    /// @custom:oz-upgrades-unsafe-allow missing-initializer-call
    function __RollupStorage_init(bytes memory data) internal onlyInitializing {
        RollupStorage storage $ = _getRollupStorage();

        // ABI-decode the monolithic init struct passed by the proxy deployer
        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        // ─── Deadline invariants ───
        // all window values are stored as uint64/uint32; reject values that would silently truncate
        require(params.submitBlobsWindow <= type(uint64).max, InvalidWindowConfig("submitBlobsWindow out of range"));
        require(params.preconfirmWindow <= type(uint64).max, InvalidWindowConfig("preconfirmWindow out of range"));
        require(params.challengeWindow <= type(uint64).max, InvalidWindowConfig("challengeWindow out of range"));
        require(params.finalizationDelay <= type(uint64).max, InvalidWindowConfig("finalizationDelay out of range"));
        require(params.acceptDepositDeadline <= type(uint32).max, InvalidWindowConfig("acceptDepositDeadline out of range"));
        require(params.maxForceRevertBatchSize <= type(uint32).max, InvalidWindowConfig("maxForceRevertBatchSize out of range"));
        // preconfirmation must happen after blob submission completes (when both are enabled)
        if (params.submitBlobsWindow != 0 && params.preconfirmWindow != 0) {
            require(params.preconfirmWindow > params.submitBlobsWindow, InvalidWindowConfig("preconfirmWindow must exceed submitBlobsWindow"));
        }
        // set blob submission and preconfirmation windows before challenge/finalization
        // because the setters cross-validate against each other
        _setSubmitBlobsWindow(uint64(params.submitBlobsWindow));
        _setPreconfirmWindow(uint64(params.preconfirmWindow));
        // challenge window must be strictly less to guarantee full finalization delay
        require(params.challengeWindow < params.finalizationDelay, InvalidWindowConfig("challengeWindow must be less than finalizationDelay"));
        _setChallengeWindow(uint64(params.challengeWindow));
        _setFinalizationDelay(uint64(params.finalizationDelay));

        _setAcceptDepositDeadline(uint32(params.acceptDepositDeadline));

        // ─── Role setup ───
        // admin is the only required address; other roles fall back to admin if unset
        require(params.admin != address(0), ZeroAddressNotAllowed("admin"));
        address emergencyRole = params.emergency != address(0) ? params.emergency : params.admin;
        address challengerRole = params.challenger != address(0) ? params.challenger : params.admin;
        address proverRole = params.prover != address(0) ? params.prover : params.admin;
        address sequencerRole = params.sequencer != address(0) ? params.sequencer : params.admin;
        address preconfirmationRole = params.preconfirmationRole != address(0) ? params.preconfirmationRole : params.admin;

        // grant all required roles; DEFAULT_ADMIN_ROLE controls role management
        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(EMERGENCY_ROLE, emergencyRole);
        _grantRole(CHALLENGER_ROLE, challengerRole);
        _grantRole(PROVER_ROLE, proverRole);
        _grantRole(SEQUENCER_ROLE, sequencerRole);
        _grantRole(PRECONFIRMATION_ROLE, preconfirmationRole);

        // ─── Storage setup ───
        // genesis hash anchors the chain-linking hash at batch index 0
        require(params.genesisHash != bytes32(0), ZeroValueNotAllowed("genesisHash"));
        $._lastBlockHashInBatch[0] = params.genesisHash;
        // first real batch starts at index 1; index 0 is reserved for genesis
        $._nextBatchIndex = 1;
        _setMaxForceRevertBatchSize(uint32(params.maxForceRevertBatchSize));

        // external dependency addresses validated within their respective setters
        _setBridge(params.bridge);
        _setSp1Verifier(params.sp1Verifier);
        _setProgramVKey(params.programVKey);
        // nitro verifier is optional at init time; can be added later via admin
        if (params.nitroVerifier != address(0)) _enableNitroVerifier(params.nitroVerifier);

        // economic parameters for the challenge/incentive mechanism
        _setChallengeDepositAmount(params.challengeDepositAmount);
        _setIncentiveFee(params.incentiveFee);
        // default gas threshold prevents unbounded iteration in acceptNextBatch
        _setGasLeft(DEFAULT_GAS_LEFT);
    }

    // ============ IRollupConfig ============

    /// @inheritdoc IRollupConfig
    function bridge() public view returns (address) {
        // FluentBridge address used as the message source during batch acceptance
        return _getRollupStorage()._bridge;
    }

    /// @inheritdoc IRollupConfig
    function sp1Verifier() public view returns (address) {
        // verifier contract called during ZK proof validation in challenge resolution
        return _getRollupStorage()._sp1Verifier;
    }

    /// @inheritdoc IRollupConfig
    function programVKey() public view returns (bytes32) {
        // ties SP1 proofs to the specific rollup state-transition program
        return _getRollupStorage()._programVKey;
    }

    /// @inheritdoc IRollupConfig
    function finalizationDelay() public view returns (uint256) {
        // widened to uint256 for external callers; stored as uint64 for slot packing
        return uint256(_getRollupStorage()._finalizationDelay);
    }

    /// @inheritdoc IRollupConfig
    function challengeWindow() public view returns (uint256) {
        // widened to uint256 for external callers; stored as uint64 for slot packing
        return uint256(_getRollupStorage()._challengeWindow);
    }

    /// @inheritdoc IRollupConfig
    function challengeDepositAmount() public view returns (uint256) {
        // ETH amount challengers must lock when opening a dispute
        return _getRollupStorage()._challengeDepositAmount;
    }

    /// @inheritdoc IRollupConfig
    function incentiveFee() public view returns (uint256) {
        // bonus ETH paid on top of deposit refund during force revert
        return _getRollupStorage()._incentiveFee;
    }

    /// @inheritdoc IRollupConfig
    function acceptDepositDeadline() public view returns (uint256) {
        // widened to uint256; stored as uint32 since L1 block counts fit in 32 bits
        return uint256(_getRollupStorage()._acceptDepositDeadline);
    }

    /// @inheritdoc IRollupConfig
    function submitBlobsWindow() public view returns (uint256) {
        // zero means the DA submission deadline is disabled
        return uint256(_getRollupStorage()._submitBlobsWindow);
    }

    /// @inheritdoc IRollupConfig
    function preconfirmWindow() public view returns (uint256) {
        // zero means the preconfirmation deadline is disabled
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
    function challengeQueue() public view returns (bytes32[] memory) {
        RollupStorage storage $ = _getRollupStorage();
        uint256 size = $._challengeQueue.length();
        if (size == 0) return new bytes32[](0);

        // copy heap contents into a memory array for external consumption
        bytes32[] memory queue = new bytes32[](size);
        for (uint256 i = 0; i < size; ++i) {
            queue[i] = $._challengeQueue.at(i);
        }

        return queue;
    }

    /// @inheritdoc IRollupRead
    function challengeQueueLength() public view returns (uint256) {
        return _getRollupStorage()._challengeQueue.length();
    }

    /// @inheritdoc IRollupRead
    function challengeQueueAt(uint256 index) public view returns (bytes32) {
        return _getRollupStorage()._challengeQueue.at(index);
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
    function batchDepositIds(uint256 batchIndex) public view returns (bytes32[] memory) {
        return _getRollupStorage()._batchDepositIds[batchIndex];
    }

    /// @inheritdoc IRollupRead
    function isBlockProven(bytes32 commitment) public view returns (bool) {
        // true once an SP1 proof has been verified for this block commitment
        return _getRollupStorage()._provenBlocks[commitment];
    }

    /// @inheritdoc IRollupRead
    function claimableChallengerReward(address challenger) public view returns (uint256) {
        // accrued from deposit refunds + incentive fees after force revert
        return _getRollupStorage()._challengerRewards[challenger];
    }

    /// @inheritdoc IRollupRead
    function claimableProofReward(address prover) public view returns (uint256) {
        // accrued from forfeited challenger deposits after successful proof
        return _getRollupStorage()._proverRewards[prover];
    }

    // ============ IRollupAdmin ============

    /// @inheritdoc IRollupAdmin
    function setBridge(address newBridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBridge(newBridge);
    }

    /** @dev Validates and stores a new bridge address. Reverts on zero address. */
    function _setBridge(address newBridge) internal {
        RollupStorage storage $ = _getRollupStorage();
        require(newBridge != address(0), ZeroAddressNotAllowed("bridge"));
        // emit old -> new for off-chain indexers before writing storage
        emit BridgeUpdated($._bridge, newBridge);
        $._bridge = newBridge;
    }

    /// @inheritdoc IRollupAdmin
    function setSp1Verifier(address newVerifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSp1Verifier(newVerifier);
    }

    /** @dev Validates and stores a new SP1 verifier address. Reverts on zero address or non-contract. */
    function _setSp1Verifier(address newVerifier) internal {
        require(newVerifier != address(0), ZeroAddressNotAllowed("sp1Verifier"));
        RollupStorage storage $ = _getRollupStorage();
        // must be a deployed contract to prevent calls to an EOA during proof verification
        require(newVerifier.code.length != 0, NotAContract("sp1Verifier"));
        emit SP1VerifierUpdated($._sp1Verifier, newVerifier);
        $._sp1Verifier = newVerifier;
    }

    /// @inheritdoc IRollupAdmin
    function setProgramVKey(bytes32 newVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setProgramVKey(newVKey);
    }

    /** @dev Stores a new SP1 program verification key. Reverts on zero value. */
    function _setProgramVKey(bytes32 newVKey) internal {
        // zero vKey would cause all SP1 proofs to be trivially accepted or rejected
        require(newVKey != bytes32(0), ZeroValueNotAllowed("programVKey"));
        RollupStorage storage $ = _getRollupStorage();
        emit ProgramVKeyUpdated($._programVKey, newVKey);
        $._programVKey = newVKey;
    }

    /// @inheritdoc IRollupAdmin
    function enableNitroVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _enableNitroVerifier(verifier);
    }

    /** @dev Adds a Nitro verifier to the enabled set. Reverts on zero address, non-contract, or already enabled. */
    function _enableNitroVerifier(address verifier) internal {
        require(verifier != address(0), ZeroAddressNotAllowed("nitroVerifier"));
        // must be a deployed contract — EOAs cannot verify Nitro attestations
        require(verifier.code.length != 0, NotAContract("nitroVerifier"));
        // prevent duplicate enables that would emit misleading events
        require(!_getRollupStorage()._enabledNitroVerifiers[verifier], NitroVerifierAlreadyEnabled(verifier));
        _getRollupStorage()._enabledNitroVerifiers[verifier] = true;
        emit NitroVerifierEnabled(verifier);
    }

    /// @inheritdoc IRollupAdmin
    function disableNitroVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _disableNitroVerifier(verifier);
    }

    /** @dev Removes a Nitro verifier from the enabled set. Reverts if not currently enabled. */
    function _disableNitroVerifier(address verifier) internal {
        require(verifier != address(0), ZeroAddressNotAllowed("verifier"));
        // only disable verifiers that are actually in the enabled set
        require(_getRollupStorage()._enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        _getRollupStorage()._enabledNitroVerifiers[verifier] = false;
        emit NitroVerifierDisabled(verifier);
    }

    /// @inheritdoc IRollupAdmin
    function setGasLeft(uint32 newGasLeft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setGasLeft(newGasLeft);
    }

    /** @dev Stores the minimum gasleft threshold. Reverts on zero value. */
    function _setGasLeft(uint32 newGasLeft) internal {
        RollupStorage storage $ = _getRollupStorage();
        // zero would allow unbounded iteration in acceptNextBatch, risking OOG
        require(newGasLeft != 0, ZeroValueNotAllowed("gasLeft"));
        emit GasLeftUpdated($._gasLeft, newGasLeft);
        $._gasLeft = newGasLeft;
    }

    /// @inheritdoc IRollupAdmin
    function setAcceptDepositDeadline(uint32 newAcceptDepositDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAcceptDepositDeadline(newAcceptDepositDeadline);
    }

    /** @dev Stores the deposit acceptance deadline in L1 blocks. */
    function _setAcceptDepositDeadline(uint32 newAcceptDepositDeadline) internal {
        RollupStorage storage $ = _getRollupStorage();
        // zero deadline would allow deposits to remain unincluded indefinitely
        require(newAcceptDepositDeadline != 0, ZeroValueNotAllowed("acceptDepositDeadline"));
        emit AcceptDepositDeadlineUpdated($._acceptDepositDeadline, newAcceptDepositDeadline);
        $._acceptDepositDeadline = newAcceptDepositDeadline;
    }

    /// @inheritdoc IRollupAdmin
    function setSubmitBlobsWindow(uint64 newSubmitBlobsWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSubmitBlobsWindow(newSubmitBlobsWindow);
    }

    /** @dev Stores the blob submission window in L1 blocks. */
    function _setSubmitBlobsWindow(uint64 newSubmitBlobsWindow) internal {
        RollupStorage storage $ = _getRollupStorage();
        // blob submission must complete before preconfirmation can start
        if ($._preconfirmWindow != 0) {
            require(newSubmitBlobsWindow < $._preconfirmWindow, InvalidWindowConfig("submitBlobsWindow >= preconfirmWindow"));
        }
        emit SubmitBlobsWindowUpdated($._submitBlobsWindow, newSubmitBlobsWindow);
        $._submitBlobsWindow = newSubmitBlobsWindow;
    }

    /// @inheritdoc IRollupAdmin
    function setPreconfirmWindow(uint64 newPreconfirmWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPreconfirmWindow(newPreconfirmWindow);
    }

    /** @dev Stores the preconfirmation window. Must not exceed submitBlobsWindow. */
    function _setPreconfirmWindow(uint64 newPreconfirmWindow) internal {
        RollupStorage storage $ = _getRollupStorage();
        // preconfirmation must allow time for blob submission to complete first
        if (newPreconfirmWindow != 0 && $._submitBlobsWindow != 0) {
            require(newPreconfirmWindow > $._submitBlobsWindow, InvalidWindowConfig("preconfirmWindow <= submitBlobsWindow"));
        }
        emit PreconfirmWindowUpdated($._preconfirmWindow, newPreconfirmWindow);
        $._preconfirmWindow = newPreconfirmWindow;
    }

    /// @inheritdoc IRollupAdmin
    function setChallengeWindow(uint64 newChallengeWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setChallengeWindow(newChallengeWindow);
    }

    /** @dev Stores the challenge window. Must not exceed preconfirmWindow. */
    function _setChallengeWindow(uint64 newChallengeWindow) internal {
        RollupStorage storage $ = _getRollupStorage();
        // challenge window must end before finalization to give challengers full response time
        if ($._finalizationDelay != 0) {
            require(newChallengeWindow < $._finalizationDelay, InvalidWindowConfig("challengeWindow >= finalizationDelay"));
        }
        emit ChallengeWindowUpdated($._challengeWindow, newChallengeWindow);
        $._challengeWindow = newChallengeWindow;
    }

    /// @inheritdoc IRollupAdmin
    function setFinalizationDelay(uint64 newFinalizationDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFinalizationDelay(newFinalizationDelay);
    }

    /** @dev Stores the finalization delay. Must exceed challengeWindow. */
    function _setFinalizationDelay(uint64 newFinalizationDelay) internal {
        RollupStorage storage $ = _getRollupStorage();
        // strict ordering ensures challenges always have time to be submitted and resolved
        require(newFinalizationDelay > $._challengeWindow, InvalidWindowConfig("finalizationDelay <= challengeWindow"));
        emit FinalizationDelayUpdated($._finalizationDelay, newFinalizationDelay);
        $._finalizationDelay = newFinalizationDelay;
    }

    /// @inheritdoc IRollupAdmin
    function setChallengeDepositAmount(uint256 newChallengeDepositAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setChallengeDepositAmount(newChallengeDepositAmount);
    }

    /** @dev Stores the ETH deposit required per challenge. */
    function _setChallengeDepositAmount(uint256 newChallengeDepositAmount) internal {
        RollupStorage storage $ = _getRollupStorage();
        // non-zero deposit required to prevent spam challenges
        require(newChallengeDepositAmount > 0, ZeroValueNotAllowed("challengeDepositAmount"));
        emit ChallengeDepositAmountUpdated($._challengeDepositAmount, newChallengeDepositAmount);
        $._challengeDepositAmount = newChallengeDepositAmount;
    }

    /// @inheritdoc IRollupAdmin
    function setIncentiveFee(uint256 newIncentiveFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setIncentiveFee(newIncentiveFee);
    }

    /** @dev Stores the incentive fee paid to force-revert callers. */
    function _setIncentiveFee(uint256 newIncentiveFee) internal {
        require(newIncentiveFee <= MAX_INCENTIVE_FEE, IncentiveFeeTooLarge(newIncentiveFee, MAX_INCENTIVE_FEE));
        RollupStorage storage $ = _getRollupStorage();
        emit IncentiveFeeUpdated($._incentiveFee, newIncentiveFee);
        $._incentiveFee = newIncentiveFee;
    }

    /// @inheritdoc IRollupAdmin
    function setMaxForceRevertBatchSize(uint32 newMaxForceRevertBatchSize) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxForceRevertBatchSize(newMaxForceRevertBatchSize);
    }

    /** @dev Stores the maximum force revert batch size. */
    function _setMaxForceRevertBatchSize(uint32 newMaxForceRevertBatchSize) internal {
        RollupStorage storage $ = _getRollupStorage();
        require(newMaxForceRevertBatchSize != 0, ZeroValueNotAllowed("maxForceRevertBatchSize"));
        emit MaxForceRevertBatchSizeUpdated($._maxForceRevertBatchSize, newMaxForceRevertBatchSize);
        $._maxForceRevertBatchSize = newMaxForceRevertBatchSize;
    }

    // ============ Emergency role management ============

    /// @inheritdoc IRollupAdmin
    function emergencyRevokeRole(bytes32 role, address account) external onlyRole(EMERGENCY_ROLE) {
        require(
            role == SEQUENCER_ROLE || role == PRECONFIRMATION_ROLE || role == CHALLENGER_ROLE || role == PROVER_ROLE,
            InvalidOperationalRole(role)
        );
        _revokeRole(role, account);
    }

    // ============ Internal helpers ============

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Returns a storage pointer to the ERC-7201 namespaced rollup storage slot.
     */
    function _getRollupStorage() internal pure returns (RollupStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ROLLUP_STORAGE_LOCATION
        }
    }
}
