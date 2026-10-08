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
     * @notice Zero address given where a contract address is required.
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
     * @notice Signature is not an EIP-2537 uncompressed G1 point — or, for a batch, the
     *         signatures are not exactly 128 bytes per round.
     * @dev selector: 0xd615d706
     */
    error InvalidSignatureLength(uint256 provided, uint256 expected);

    /**
     * @notice A batch names no round.
     * @dev selector: 0xc2e5347d
     */
    error EmptyBatch();

    /**
     * @notice A batch names more rounds than one transaction admits.
     * @dev selector: 0xbb1cb70b
     */
    error BatchTooLarge(uint256 provided, uint256 maximum);

    /**
     * @notice A batch's rounds are not strictly ascending, so it repeats or reorders a round.
     * @dev selector: 0x129ae351
     */
    error RoundsNotAscending(uint64 previous, uint64 round);

    /**
     * @notice Every round in the batch is already published; there is nothing to write.
     * @dev selector: 0x3ae8386c
     */
    error NothingToPublish();

    /**
     * @notice The batch does not verify as a whole: at least one signature is not drand's
     *         for its round, and the check cannot say which.
     * @dev selector: 0x37b16e87
     */
    error InvalidBatchSignature();

    /**
     * @notice Signature does not verify against drand quicknet's key for this round.
     * @dev selector: 0xdc5fdae5
     */
    error InvalidSignature(uint64 round);

    /// @dev Emitted when a consumer binds itself to a future round. Carries no state:
    ///      this is the feed publishers subscribe to.
    event RoundCommitted(uint64 indexed round, address indexed committer);

    /// @dev Emitted when a round's beacon is published; the value never changes afterwards
    event RoundPublished(uint64 indexed round, address indexed publisher, bytes32 randomness);

    /**
     * @notice Binds the caller to the earliest round whose beacon is not public yet
     * @dev The round is `currentRound() + minFutureRounds()`, measured on the chain's clock.
     *      A caller that does not trust that clock picks its own round with {commitTo}.
     * @return round The committed round, which the caller must keep
     */
    function commit() external returns (uint64 round);

    /**
     * @notice Binds the caller to a round of its own choosing
     * @dev Nothing about the round's timing is checked: the round is the caller's claim, and
     *      a round whose beacon is already public yields a value anyone could have predicted.
     *      The caller keeps the round and picks it far enough ahead for the clock it trusts.
     *      Round 0 is not a drand round and reverts {InvalidRound}, as everywhere else.
     * @param round The round to commit to
     */
    function commitTo(uint64 round) external;

    /**
     * @notice Stops {publish} and {publishBatch}; commits and reads go on. Emergency role.
     * @dev For a verifier found to accept what it should not, until an upgrade lands. A
     *      pause that outlives the retention window costs the rounds it covers: they age
     *      out unpublished and are recoverable only through {verifyRound}.
     */
    function pause() external;

    /// @notice Lifts {pause}. Emergency role.
    function unpause() external;

    /**
     * @notice Publishes a round's drand beacon. Permissionless while not paused.
     * @dev A signature that is well-formed in length but not a usable G1 point surfaces the
     *      verifier's own errors rather than the ones below: `InfinityPoint`,
     *      `InvalidPointLength` or `PrecompileFailed`. They are declared in
     *      {DrandQuicknetVerifier} and reach the deployed ABI from there, not from here.
     * @param round The drand round the signature belongs to
     * @param signature The round's beacon as a 128-byte EIP-2537 uncompressed G1 point
     */
    function publish(uint64 round, bytes calldata signature) external;

    /**
     * @notice Publishes several rounds' beacons under one signature check. Permissionless.
     * @dev Rounds must be strictly ascending and every one inside the retention window.
     *      Rounds already published are skipped rather than refused, so two publishers
     *      racing do not fail each other's batch. The check is one pairing over a random
     *      linear combination of the signatures, so a failure reverts
     *      {InvalidBatchSignature} without naming a round: publish the rounds one at a time
     *      to find it. Carries the same verifier-side errors as {IDrandOracle-publish}.
     * @param rounds The drand rounds, strictly ascending, at most `MAX_BATCH_ROUNDS` of them
     * @param signatures The rounds' beacons as 128-byte EIP-2537 uncompressed G1 points,
     *                   concatenated in the order of `rounds`
     * @return published How many rounds this call wrote
     */
    function publishBatch(uint64[] calldata rounds, bytes calldata signatures) external returns (uint256 published);

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
     *      Carries the same verifier-side errors as {IDrandOracle-publish}.
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
     * @notice How many rounds past the chain's clock {commit} binds to
     */
    function minFutureRounds() external pure returns (uint64);
}
