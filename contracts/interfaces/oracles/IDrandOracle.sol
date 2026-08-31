// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IDrandOracle
 * @author Fluent Labs
 * @notice Interface for the DrandOracle contract
 * @dev Publishes drand quicknet beacons on-chain and serves them to consumers that
 *      committed to a round before its beacon existed.
 */
interface IDrandOracle {
    /**
     * @notice Zero address not allowed for the initial owner.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Block timestamp precedes the drand chain's genesis, so no round exists yet.
     * @dev selector: 0x8f4711c2
     */
    error TimestampBeforeGenesis(uint256 timestamp, uint64 genesis);

    /**
     * @notice Round number is not a valid drand round (rounds start at 1).
     * @dev selector: 0xf897bbf5
     */
    error InvalidRound(uint64 round);

    /**
     * @notice Committed round is closer than the minimum future offset, so its beacon
     *         may already be public.
     * @dev selector: 0xf4d6ffd3
     */
    error RoundTooSoon(uint64 round, uint64 earliestAllowed);

    /**
     * @notice Round has fallen out of the retention window and can no longer be published.
     * @dev selector: 0x395f4fd6
     */
    error RoundTooOld(uint64 round, uint64 oldestRetained);

    /**
     * @notice Round has not been reached by the chain's clock yet.
     * @dev selector: 0x21a99841
     */
    error RoundInFuture(uint64 round, uint64 currentRound);

    /**
     * @notice Round has aged out of the ring; use {IDrandOracle-verifyRound} instead.
     * @dev selector: 0x2e6131bb
     */
    error RoundEvicted(uint64 round, uint64 oldestRetained);

    /**
     * @notice Round is inside the retention window but nobody has published it yet.
     * @dev selector: 0x3cbe3bf6
     */
    error RoundNotPublished(uint64 round);

    /**
     * @notice Round already carries a published value, which never changes.
     * @dev selector: 0xaffe132d
     */
    error RoundAlreadyPublished(uint64 round);

    /**
     * @notice Signature is not an EIP-2537 uncompressed G1 point.
     * @dev selector: 0xd615d706
     */
    error InvalidSignatureLength(uint256 provided, uint256 expected);

    /**
     * @notice Signature does not verify against drand quicknet's key for this round.
     * @dev selector: 0xdc5fdae5
     */
    error InvalidSignature(uint64 round);

    /**
     * @notice Proposed minimum future offset is below the protocol floor.
     * @dev selector: 0x3f797271
     */
    error MinFutureRoundsTooLow(uint64 provided, uint64 minimum);

    /**
     * @notice Proposed minimum future offset is above the protocol maximum.
     * @dev selector: 0x6b64a23b
     */
    error MinFutureRoundsTooHigh(uint64 provided, uint64 maximum);

    /// @dev Emitted when a consumer binds itself to a future round. Carries no state:
    ///      this is the feed publishers subscribe to.
    event RoundCommitted(uint64 indexed round, address indexed committer);

    /// @dev Emitted when a round's beacon is published; the value never changes afterwards
    event RoundPublished(uint64 indexed round, address indexed publisher, bytes32 randomness);

    /// @dev Emitted when the minimum future-round offset is updated
    event MinFutureRoundsUpdated(uint64 oldValue, uint64 newValue);

    /**
     * @notice Binds the caller to the earliest round whose beacon is not public yet
     * @return round The committed round, which the caller must keep
     */
    function commit() external returns (uint64 round);

    /**
     * @notice Binds the caller to an explicit future round
     * @param round The round to commit to; must be at least `currentRound() + minFutureRounds()`
     */
    function commitTo(uint64 round) external;

    /**
     * @notice Publishes a round's drand beacon. Permissionless.
     * @param round The drand round the signature belongs to
     * @param signature The round's beacon as a 128-byte EIP-2537 uncompressed G1 point
     */
    function publish(uint64 round, bytes calldata signature) external;

    /**
     * @notice Returns a published round's randomness, as drand publishes it
     * @dev Reverts rather than returning zero for an unpublished or evicted round.
     */
    function randomnessOf(uint64 round) external view returns (bytes32);

    /**
     * @notice Returns a round's randomness scoped to the calling consumer and a domain
     * @param round The published round to read
     * @param domain Caller-chosen separator between its own uses of the same round
     */
    function randomnessFor(uint64 round, bytes32 domain) external view returns (bytes32);

    /**
     * @notice Recovers any round's randomness from its beacon without touching storage
     * @dev Advanced path, for rounds outside the retention window. The caller must have
     *      committed to `round` before its beacon was public; this function cannot check that.
     */
    function verifyRound(uint64 round, bytes calldata signature) external view returns (bytes32);

    /**
     * @notice Reproduces {randomnessFor} off-chain from a round's published value
     */
    function deriveRandomness(bytes32 roundRandomness, address consumer, bytes32 domain) external pure returns (bytes32);

    /**
     * @notice Whether a round is currently readable from the ring
     */
    function isPublished(uint64 round) external view returns (bool);

    /**
     * @notice The oldest round the ring still retains
     */
    function oldestRetainedRound() external view returns (uint64);

    /**
     * @notice The drand round matching the current block timestamp
     */
    function currentRound() external view returns (uint64);

    /**
     * @notice The timestamp at which drand publishes a round's beacon
     */
    function publishTimeOf(uint64 round) external pure returns (uint256);

    /**
     * @notice The minimum number of rounds a commit must reach into the future
     */
    function minFutureRounds() external view returns (uint64);

    /**
     * @notice Updates the minimum future-round offset
     * @param value The new offset, inside `[MIN_FUTURE_ROUNDS_FLOOR, MAX_FUTURE_ROUNDS]`
     */
    function setMinFutureRounds(uint64 value) external;
}
