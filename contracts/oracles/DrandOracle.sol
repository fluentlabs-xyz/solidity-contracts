// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
 *      `api.drand.sh` by round number.
 */
contract DrandOracle is Ownable, IDrandOracle {
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
    uint64 public constant MIN_FUTURE_ROUNDS_FLOOR = 2;

    /**
     * @dev Ceiling for {minFutureRounds}: a default offset as long as the whole retention
     *      window already sits past any plausible commit horizon. It does not bound
     *      {commitTo}, which enforces the floor alone — retention runs from the committed
     *      round rather than from the commit, so a distant target is still served for the
     *      full window once its beacon lands.
     */
    uint64 public constant MAX_FUTURE_ROUNDS = RING_ROUNDS;

    /// @dev EIP-2537 uncompressed G1 width
    uint256 internal constant SIGNATURE_LENGTH = 128;

    // ============ Storage ============

    /// @dev Published rounds, keyed by `round % RING_ROUNDS` and tagged with the round
    RoundSlot[RING_ROUNDS] internal _ring;

    /**
     * @dev Never the storage default: the constructor sets it to MIN_FUTURE_ROUNDS_FLOOR
     *      and the setter keeps it inside [FLOOR, MAX_FUTURE_ROUNDS].
     */
    uint64 internal _minFutureRounds;

    /**
     * @dev Sets the contract owner and puts the commit offset at its floor, so no block
     *      of this contract's life allows a commit onto an already-published round.
     */
    constructor(address initialOwner) Ownable(_requireNonZeroOwner(initialOwner)) {
        _setMinFutureRounds(MIN_FUTURE_ROUNDS_FLOOR);
    }

    // ============ Commit ============

    /// @inheritdoc IDrandOracle
    function commit() external override returns (uint64 round) {
        round = currentRound() + _minFutureRounds;
        emit RoundCommitted(round, msg.sender);
    }

    /// @inheritdoc IDrandOracle
    function commitTo(uint64 round) external override {
        uint64 earliestAllowed = currentRound() + _minFutureRounds;
        if (round < earliestAllowed) revert RoundTooSoon(round, earliestAllowed);
        emit RoundCommitted(round, msg.sender);
    }

    // ============ Publish ============

    /// @inheritdoc IDrandOracle
    function publish(uint64 round, bytes calldata signature) external override {
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

        RoundSlot storage slot = _ring[round % RING_ROUNDS];
        if (slot.round == round) revert RoundAlreadyPublished(round);
        if (!DrandQuicknetVerifier.verify(round, signature)) revert InvalidSignature(round);

        bytes32 value = sha256(DrandQuicknetVerifier.compressG1(signature));
        slot.round = round;
        slot.randomness = value;
        emit RoundPublished(round, msg.sender, value);
    }

    // ============ Owner ============

    /// @inheritdoc IDrandOracle
    function setMinFutureRounds(uint64 value) external override onlyOwner {
        _setMinFutureRounds(value);
    }

    /**
     * @dev Validates and stores the commit offset. Shared by the constructor and the setter
     *      so the range holds at both write sites.
     */
    function _setMinFutureRounds(uint64 value) internal {
        if (value < MIN_FUTURE_ROUNDS_FLOOR) revert MinFutureRoundsTooLow(value, MIN_FUTURE_ROUNDS_FLOOR);
        if (value > MAX_FUTURE_ROUNDS) revert MinFutureRoundsTooHigh(value, MAX_FUTURE_ROUNDS);
        // emit before write so the event captures the previous offset
        emit MinFutureRoundsUpdated(_minFutureRounds, value);
        _minFutureRounds = value;
    }

    /**
     * @dev Runs before {Ownable}'s own zero check so the failure names this contract's field.
     */
    function _requireNonZeroOwner(address initialOwner) private pure returns (address) {
        if (initialOwner == address(0)) revert ZeroAddressNotAllowed("owner");
        return initialOwner;
    }

    // ============ Views ============

    /// @inheritdoc IDrandOracle
    function randomnessOf(uint64 round) public view override returns (bytes32) {
        // Window first, tag second. oldestRetainedRound() is never below 1, so this
        // disposes of round 0 — whose slot is 0 and whose untouched tag is also 0 —
        // before any comparison a zero could satisfy. isPublished uses the same order.
        uint64 oldest = oldestRetainedRound();
        if (round < oldest) revert RoundEvicted(round, oldest);

        RoundSlot storage slot = _ring[round % RING_ROUNDS];
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
        return _ring[round % RING_ROUNDS].round == round;
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
    function minFutureRounds() external view override returns (uint64) {
        return _minFutureRounds;
    }
}
