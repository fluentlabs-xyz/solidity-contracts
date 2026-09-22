// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IDrandOracle} from "../interfaces/oracles/IDrandOracle.sol";
import {DrandQuicknetVerifier} from "../libraries/DrandQuicknetVerifier.sol";

/**
 * @title DrandOracle
 * @author Fluent Labs
 * @notice Public randomness from the drand quicknet beacon: consumers commit to a future
 *         round, anyone publishes that round's signature once drand emits it, and the
 *         verified value is served for as long as the ring retains it.
 * @dev Chain `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`,
 *      3-second rounds from genesis 1692803367. The stored value is byte-identical to
 *      drand's own `randomness` field, so any published round can be checked against
 *      `api.drand.sh` by round number. UUPS-upgradeable; storage is ERC-7201 namespaced.
 *      Two roles, held by timelocks in production: {DEFAULT_ADMIN_ROLE} may upgrade,
 *      {EMERGENCY_ROLE} may pause publishing. Nothing else is gated on anyone.
 */
contract DrandOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, IDrandOracle {
    // ============ Types ============

    /**
     * @dev `round == 0` marks an untouched slot: drand rounds start at 1, so the
     *      tag cannot collide with a real round and needs no companion flag.
     */
    struct RoundSlot {
        uint64 round;
        bytes32 randomness;
    }

    // ============ Constants ============

    /// @dev Seconds between drand quicknet rounds
    uint64 public constant PERIOD_SECONDS = 3;

    /// @dev Unix timestamp of drand quicknet round 1
    uint64 public constant GENESIS_TIMESTAMP = 1_692_803_367;

    /// @dev Size of the ring buffer of published rounds — 6 h 49 m 36 s of retention
    uint64 public constant RING_ROUNDS = 8192;

    /**
     * @dev Smallest commit offset that leaves a margin: `currentRound()` is already
     *      published and `currentRound() + 1` can be as little as one second away,
     *      while `+2` is at least four seconds away.
     */
    uint64 internal constant MIN_FUTURE_ROUNDS = 2;

    /// @dev EIP-2537 uncompressed G1 width
    uint256 internal constant SIGNATURE_LENGTH = 128;

    /// @dev Rounds one {publishBatch} may carry: about 8.3M gas at the top, a sixth of a block
    uint256 public constant MAX_BATCH_ROUNDS = 64;

    /// @dev May pause and unpause publishing; the short-delay timelock in production
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /**
     * @dev `OwnableUpgradeable`'s ERC-7201 slot, where the first implementation kept its
     *      owner. Read once by {initializeV2} to name who may seat the roles; never written.
     */
    bytes32 private constant LEGACY_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    /**
     * @dev The namespaces the first implementation's `Ownable2StepUpgradeable` declared, kept
     *      so the upgrade checker sees them retained rather than deleted; nothing writes them.
     */
    /// @custom:storage-location erc7201:openzeppelin.storage.Ownable
    struct OwnableStorage {
        address _owner;
    }

    /// @custom:storage-location erc7201:openzeppelin.storage.Ownable2Step
    struct Ownable2StepStorage {
        address _pendingOwner;
    }

    // ============ Storage ============

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.DrandOracleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DRAND_ORACLE_STORAGE_LOCATION =
        0xed95ba3d98fe6036296cb371ff010dc6f50a7eec81cf9c059f35f285d9b07900;

    /// @custom:storage-location erc7201:Fluent.storage.DrandOracleStorage
    struct DrandOracleStorage {
        /// @dev Published rounds, keyed by `round % RING_ROUNDS` and tagged with the round
        RoundSlot[RING_ROUNDS] _ring;
        uint256[50] __gap;
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the oracle behind a fresh proxy.
     * @param admin Holder of {DEFAULT_ADMIN_ROLE}: may upgrade, and administers both roles.
     * @param emergency Holder of {EMERGENCY_ROLE}: may pause publishing. Zero means `admin`.
     */
    function initialize(address admin, address emergency) external reinitializer(2) {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        _seatRoles(admin, emergency);
    }

    /**
     * @notice Seats the roles on a proxy that the first implementation initialized with an
     *         owner, as the call of the upgrade to this implementation.
     * @dev Only that owner may make the call, so an upgrade that omits it leaves nobody able
     *      to seat the roles but the account that could have upgraded in the first place.
     * @param admin Holder of {DEFAULT_ADMIN_ROLE}
     * @param emergency Holder of {EMERGENCY_ROLE}; zero means `admin`
     */
    function initializeV2(address admin, address emergency) external reinitializer(2) {
        if (msg.sender != _legacyOwner()) revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        __AccessControl_init();
        __Pausable_init();
        _seatRoles(admin, emergency);
    }

    function _seatRoles(address admin, address emergency) private {
        if (admin == address(0)) revert ZeroAddressNotAllowed("admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergency == address(0) ? admin : emergency);
    }

    function _legacyOwner() private view returns (address) {
        OwnableStorage storage $;
        assembly ("memory-safe") {
            $.slot := LEGACY_OWNER_SLOT
        }
        return $._owner;
    }

    // ============ Emergency ============

    /// @inheritdoc IDrandOracle
    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @inheritdoc IDrandOracle
    function unpause() external override onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // ============ Commit ============

    /// @inheritdoc IDrandOracle
    function commit() external override returns (uint64 round) {
        round = currentRound() + MIN_FUTURE_ROUNDS;
        emit RoundCommitted(round, msg.sender);
    }

    /// @inheritdoc IDrandOracle
    function commitTo(uint64 round) external override {
        if (round == 0) revert InvalidRound(0);
        emit RoundCommitted(round, msg.sender);
    }

    // ============ Publish ============

    /// @inheritdoc IDrandOracle
    function publish(uint64 round, bytes calldata signature) external override whenNotPaused {
        if (signature.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength(signature.length, SIGNATURE_LENGTH);
        }
        // Lower bound: without it the slot of round `round + RING_ROUNDS` — a live
        // entry — is overwritable by anyone holding an old, valid drand signature.
        // Upper bound: without it a chain clock lagging drand lets `C + k` be published
        // while the chain says `C`, overwriting the live round `C + k - RING_ROUNDS`.
        uint64 current = currentRound();
        uint64 oldest = _oldestRetained(current);
        if (round < oldest) revert RoundTooOld(round, oldest);
        if (round > current) revert RoundInFuture(round, current);

        RoundSlot storage slot = _getDrandOracleStorage()._ring[round % RING_ROUNDS];
        if (slot.round == round) revert RoundAlreadyPublished(round);
        if (!DrandQuicknetVerifier.verify(round, signature)) revert InvalidSignature(round);

        bytes32 value = sha256(DrandQuicknetVerifier.compressG1(signature));
        slot.round = round;
        slot.randomness = value;
        emit RoundPublished(round, msg.sender, value);
    }

    /// @inheritdoc IDrandOracle
    function publishBatch(uint64[] calldata rounds, bytes calldata signatures)
        external
        override
        whenNotPaused
        returns (uint256 published)
    {
        uint256 count = rounds.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH_ROUNDS) revert BatchTooLarge(count, MAX_BATCH_ROUNDS);
        uint256 expectedLength = count * SIGNATURE_LENGTH;
        if (signatures.length != expectedLength) revert InvalidSignatureLength(signatures.length, expectedLength);

        // Ascending order makes the two ends the whole window check, and a tail past the
        // clock names that clock in the revert, which is what lets a publisher trim to it.
        uint64 current = currentRound();
        uint64 oldest = _oldestRetained(current);
        if (rounds[0] < oldest) revert RoundTooOld(rounds[0], oldest);
        if (rounds[count - 1] > current) revert RoundInFuture(rounds[count - 1], current);

        // The rounds not in the ring yet, and where in `signatures` each one's beacon sits.
        RoundSlot[RING_ROUNDS] storage ring = _getDrandOracleStorage()._ring;
        uint64[] memory fresh = new uint64[](count);
        uint256[] memory positions = new uint256[](count);
        bytes memory freshSignatures = new bytes(expectedLength);
        uint64 previous;
        for (uint256 i = 0; i < count; ++i) {
            uint64 round = rounds[i];
            if (round <= previous) revert RoundsNotAscending(previous, round);
            previous = round;
            if (ring[round % RING_ROUNDS].round == round) continue;
            fresh[published] = round;
            positions[published] = i;
            _copySignature(freshSignatures, published, signatures, i);
            ++published;
        }
        if (published == 0) revert NothingToPublish();
        assembly ("memory-safe") {
            mstore(fresh, published)
            mstore(freshSignatures, mul(published, 128))
        }
        if (!DrandQuicknetVerifier.verifyBatch(fresh, freshSignatures)) revert InvalidBatchSignature();

        for (uint256 j = 0; j < published; ++j) {
            uint64 round = fresh[j];
            uint256 offset = positions[j] * SIGNATURE_LENGTH;
            bytes32 value = sha256(DrandQuicknetVerifier.compressG1(signatures[offset:offset + SIGNATURE_LENGTH]));
            RoundSlot storage slot = ring[round % RING_ROUNDS];
            slot.round = round;
            slot.randomness = value;
            emit RoundPublished(round, msg.sender, value);
        }
    }

    /// @dev dest[destIndex] = source[sourceIndex], 128-byte signatures on both sides.
    function _copySignature(bytes memory dest, uint256 destIndex, bytes calldata source, uint256 sourceIndex)
        private
        pure
    {
        assembly ("memory-safe") {
            calldatacopy(add(add(dest, 32), mul(destIndex, 128)), add(source.offset, mul(sourceIndex, 128)), 128)
        }
    }

    // ============ Views ============

    /// @inheritdoc IDrandOracle
    function randomnessOf(uint64 round) public view override returns (bytes32) {
        // Window first, tag second. oldestRetainedRound() is never below 1, so this
        // disposes of round 0 — whose slot is 0 and whose untouched tag is also 0 —
        // before any comparison a zero could satisfy. isPublished uses the same order.
        uint64 oldest = oldestRetainedRound();
        if (round < oldest) revert RoundEvicted(round, oldest);

        RoundSlot storage slot = _getDrandOracleStorage()._ring[round % RING_ROUNDS];
        if (slot.round != round) revert RoundNotPublished(round);
        return slot.randomness;
    }

    /// @inheritdoc IDrandOracle
    function randomnessFor(uint64 round, bytes32 domain) external view override returns (bytes32) {
        return deriveRandomness(randomnessOf(round), msg.sender, domain);
    }

    /// @inheritdoc IDrandOracle
    function verifyRound(uint64 round, bytes calldata signature) external view override returns (bytes32) {
        if (signature.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength(signature.length, SIGNATURE_LENGTH);
        }
        if (!DrandQuicknetVerifier.verify(round, signature)) revert InvalidSignature(round);
        return sha256(DrandQuicknetVerifier.compressG1(signature));
    }

    /// @inheritdoc IDrandOracle
    function deriveRandomness(bytes32 roundRandomness, address consumer, bytes32 domain)
        public
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encode(roundRandomness, consumer, domain));
    }

    /// @inheritdoc IDrandOracle
    function isPublished(uint64 round) external view override returns (bool) {
        // Same order as randomnessOf: the window bound disposes of round 0.
        if (round < oldestRetainedRound()) return false;
        return _getDrandOracleStorage()._ring[round % RING_ROUNDS].round == round;
    }

    /// @inheritdoc IDrandOracle
    function oldestRetainedRound() public view override returns (uint64) {
        return _oldestRetained(currentRound());
    }

    /**
     * @dev The retention window's lower bound for a given clock round. {publish} and
     *      {oldestRetainedRound} share it because the window being exactly RING_ROUNDS
     *      wide is what keeps a write from ever landing on a slot that is still readable:
     *      a slot can only be reused by `round + RING_ROUNDS`, which is publishable only
     *      once `round` has already dropped below this bound.
     */
    function _oldestRetained(uint64 current) private pure returns (uint64) {
        return current > RING_ROUNDS ? current - RING_ROUNDS + 1 : 1;
    }

    /**
     * @inheritdoc IDrandOracle
     * @dev The clock every other body reads. Guarded because a timestamp below
     *      genesis would underflow; unreachable on a live chain, reachable under
     *      `vm.warp` in tests, and a named error beats a panic either way.
     */
    function currentRound() public view override returns (uint64) {
        if (block.timestamp < GENESIS_TIMESTAMP) {
            revert TimestampBeforeGenesis(block.timestamp, GENESIS_TIMESTAMP);
        }
        return uint64((block.timestamp - GENESIS_TIMESTAMP) / PERIOD_SECONDS) + 1;
    }

    /**
     * @inheritdoc IDrandOracle
     * @dev drand rounds start at 1. Round 0 would underflow the formula in checked
     *      arithmetic, or — reordered to dodge that — yield a timestamp three seconds
     *      before genesis. Rejected by name, like every other round-taking entry point.
     */
    function publishTimeOf(uint64 round) public pure override returns (uint256) {
        if (round == 0) revert InvalidRound(0);
        return uint256(GENESIS_TIMESTAMP) + uint256(round - 1) * PERIOD_SECONDS;
    }

    /// @inheritdoc IDrandOracle
    function minFutureRounds() external pure override returns (uint64) {
        return MIN_FUTURE_ROUNDS;
    }

    // ============ Internal ============

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _getDrandOracleStorage() private pure returns (DrandOracleStorage storage $) {
        assembly ("memory-safe") {
            $.slot := DRAND_ORACLE_STORAGE_LOCATION
        }
    }
}
