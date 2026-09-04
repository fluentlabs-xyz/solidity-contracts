// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IDrandOracle} from "../interfaces/oracles/IDrandOracle.sol";

/**
 * @title DrandTower
 * @author Fluent Labs
 * @notice A climb up a tower whose every floor is decided by a drand beacon that did not
 *         exist when the climber chose to take it. Survive and the run grows; fall and
 *         everything the run had accumulated is gone. Banking a run is what turns it into
 *         score, so the only real decision in the game — one more floor, or stop — is
 *         taken strictly before the number that answers it is knowable by anybody.
 * @dev The reference consumer for {IDrandOracle}: the oracle's address is the only thing
 *      this contract knows about drand. One step is `climb()` to commit and `resolve()`
 *      to settle, and the two cannot be collapsed into one call — a step that committed
 *      and settled in the same transaction would be deciding its own outcome from a
 *      beacon that already exists, which is the mistake the whole oracle exists to
 *      prevent.
 *
 *      Two climbers on the same round get different floors: the oracle's value for this
 *      game is split per climber by {valueFor}, so the round that ends one run can leave
 *      the next one standing. Every outcome is still reproducible by a third party from
 *      public data — the round is in the {Climbed} event, its beacon is on `api.drand.sh`,
 *      and {stepOf} returns the raw and the derived value side by side, so every step of
 *      the derivation can be checked by hand. See `docs/DrandRandomness.md`.
 */
contract DrandTower {
    // ============ Types ============

    /**
     * @dev A climber's run in progress. `round == 0` means no step is pending, which is
     *      the only state {climb} and {bank} accept — drand rounds start at 1, so the tag
     *      cannot collide with a real round.
     */
    struct Run {
        uint32 floor;
        uint64 round;
    }

    // ============ Constants ============

    /// @dev Separates this game's view of a round from every other consumer's
    bytes32 internal constant DOMAIN = "tower";

    /**
     * @dev A floor holds unless the round's value is divisible by this, so three floors in
     *      four survive. With {pointsFor}'s triangular payout that puts the break-even at
     *      the sixth floor: banking a six-floor run is worth 21, and risking it for a
     *      seventh is worth `0.75 * 28`, the same 21. Below six, climbing on is the better
     *      play; above it, stopping is. The game has an answer, and it is not obvious
     *      until you work it out.
     */
    uint256 internal constant FALL_IN = 4;

    // ============ Storage ============

    /// @dev The oracle this tower reads its floors from
    IDrandOracle public immutable ORACLE;

    /// @dev Runs in progress, by climber
    mapping(address climber => Run run) internal _runs;

    /// @dev Points banked over every completed run, by climber
    mapping(address climber => uint256 points) internal _scores;

    /// @dev Longest run ever banked, by climber
    mapping(address climber => uint32 floors) internal _bests;

    /// @dev The climber holding the highest score, and that score
    address public champion;

    /// @dev The champion's score, kept beside the address so the pair is read in one call
    uint256 public championScore;

    // ============ Events ============

    /// @notice A climber committed to a floor, which the beacon of `round` will decide
    event Climbed(address indexed climber, uint32 indexed floor, uint64 indexed round, uint256 readyAt);

    /// @notice A floor was settled from its round's beacon
    event Resolved(address indexed climber, uint32 indexed floor, uint64 indexed round, bytes32 value, bool held);

    /// @notice A run was banked and became score
    event Banked(address indexed climber, uint32 floors, uint256 points, uint256 total);

    /// @notice A climber took the top of the leaderboard
    event ChampionChanged(address indexed climber, uint256 score);

    // ============ Errors ============

    /// @notice The climber has a floor awaiting its beacon; settle it first
    error StepPending(uint64 round);

    /// @notice The climber has no floor awaiting a beacon
    error NoStepPending();

    /// @notice Banking an empty run would be a no-op
    error NothingToBank();

    /**
     * @dev The oracle is fixed for the life of the game: a tower that could be repointed
     *      at another oracle could be repointed at one that answers to its owner.
     */
    constructor(address oracle) {
        if (oracle == address(0)) revert IDrandOracle.ZeroAddressNotAllowed("oracle");
        ORACLE = IDrandOracle(oracle);
    }

    // ============ Climbing ============

    /**
     * @notice Takes the next floor, binding it to a round drand has not reached yet
     * @dev The commit is the whole game: after this call the floor's outcome is fixed by a
     *      beacon nobody — the climber, this contract, the sequencer — can influence, and
     *      before it the climber knew nothing about the beacon at all.
     * @return round The round whose beacon decides this floor
     */
    function climb() external returns (uint64 round) {
        Run storage run = _runs[msg.sender];
        if (run.round != 0) revert StepPending(run.round);

        round = ORACLE.commit();
        run.round = round;
        emit Climbed(msg.sender, run.floor + 1, round, ORACLE.publishTimeOf(round));
    }

    /**
     * @notice Settles a climber's pending floor from its round's beacon
     * @dev Takes the climber as an argument rather than reading `msg.sender`, so a run can
     *      always be pushed forward by somebody: a climber who has looked at the beacon
     *      and does not like it gains nothing by refusing to call this, since an
     *      unresolved step blocks their own {climb} and {bank} until it is settled, and
     *      anybody may settle it for them. The outcome is a function of the round and the
     *      climber, never of the caller.
     * @param climber The climber whose floor is being settled
     * @return held Whether the floor held
     */
    function resolve(address climber) external returns (bool held) {
        Run storage run = _runs[climber];
        uint64 round = run.round;
        if (round == 0) revert NoStepPending();

        // Reverts `RoundNotPublished` while the beacon is not on chain yet, and
        // `RoundEvicted` once the round has aged out of the oracle's window — see
        // {resolveWith} for the second case. Neither is caught: a fallback that
        // substituted some other value for an unavailable beacon would be a fallback to a
        // number somebody can choose.
        bytes32 value = valueFor(ORACLE.randomnessFor(round, DOMAIN), climber);
        return _settle(climber, run, round, value);
    }

    /**
     * @notice Settles a pending floor whose round the oracle no longer retains, from the
     *         beacon itself
     * @dev The oracle keeps 8192 rounds, a little under seven hours; a run left standing
     *      longer than that can no longer be settled by {resolve}, and without this would
     *      be stuck forever, unable to climb or bank. `verifyRound` runs the same pairing
     *      check against the same hardcoded key and touches no storage, so the outcome is
     *      identical to the one {resolve} would have produced while the round was still
     *      retained.
     *
     *      Safe here for the reason the oracle's documentation gives: the round is read
     *      from this contract's own storage, where {climb} put it before the beacon
     *      existed. The caller supplies the signature, not the round — a signature for any
     *      other round fails the pairing and reverts `InvalidSignature`.
     * @param climber The climber whose floor is being settled
     * @param signature The round's beacon as a 128-byte EIP-2537 uncompressed G1 point
     * @return held Whether the floor held
     */
    function resolveWith(address climber, bytes calldata signature) external returns (bool held) {
        Run storage run = _runs[climber];
        uint64 round = run.round;
        if (round == 0) revert NoStepPending();

        bytes32 raw = ORACLE.verifyRound(round, signature);
        bytes32 value = valueFor(ORACLE.deriveRandomness(raw, address(this), DOMAIN), climber);
        return _settle(climber, run, round, value);
    }

    /**
     * @notice Turns a standing run into score and starts a fresh one
     * @dev The floors of a run count for nothing until they are banked, which is what puts
     *      a cost on climbing one more.
     * @return points The score this run added
     */
    function bank() external returns (uint256 points) {
        Run storage run = _runs[msg.sender];
        if (run.round != 0) revert StepPending(run.round);

        uint32 floors = run.floor;
        if (floors == 0) revert NothingToBank();

        points = pointsFor(floors);
        uint256 total = _scores[msg.sender] + points;
        _scores[msg.sender] = total;
        run.floor = 0;

        if (floors > _bests[msg.sender]) _bests[msg.sender] = floors;
        if (total > championScore) {
            champion = msg.sender;
            championScore = total;
            emit ChampionChanged(msg.sender, total);
        }
        emit Banked(msg.sender, floors, points, total);
    }

    /**
     * @dev The single place a floor's outcome is written, shared by both settle paths so
     *      the two cannot drift apart. Clears the pending round either way: a fallen run
     *      is over, and a held one is ready for the next commit.
     */
    function _settle(address climber, Run storage run, uint64 round, bytes32 value) internal returns (bool held) {
        // The floor this step was for, named before the run moves, so the event reports
        // the floor that fell as readily as the one that held.
        uint32 attempted = run.floor + 1;

        held = holds(value);
        run.round = 0;
        run.floor = held ? attempted : 0;

        emit Resolved(climber, attempted, round, value, held);
    }

    // ============ Views ============

    /**
     * @notice The value deciding `climber`'s floor, from this game's value for the round
     * @dev The second half of the derivation, and the reason two climbers waiting on the
     *      same round do not share a fate. {IDrandOracle-randomnessFor} separates this
     *      game from every other consumer of the same beacon; this separates one climber
     *      from the next inside the game. A contract serving many users wants both: the
     *      oracle hands out one stream per consumer, and splitting that stream per request
     *      is the consumer's own job — a player address here, an order hash or a request
     *      id elsewhere, whatever names the request.
     *
     *      This is a separation, not a defence. It does not make an outcome harder to
     *      foresee: a climber computes their own value as easily as anybody else's. What
     *      keeps the beacon unknowable at commit time is {IDrandOracle-commit} naming a
     *      round the chain clock has not reached, and nothing here substitutes for that.
     *
     *      Pure and public for the same reason as {holds}: the whole derivation is
     *      reproducible from a `curl` and two `keccak256`s, with this contract trusted for
     *      none of it.
     */
    function valueFor(bytes32 gameValue, address climber) public pure returns (bytes32) {
        return keccak256(abi.encode(gameValue, climber));
    }

    /**
     * @notice Whether a floor decided by `value` holds
     * @dev Pure and public so a climber can reproduce any past floor from the beacon
     *      alone, without trusting this contract's own account of it.
     */
    function holds(bytes32 value) public pure returns (bool) {
        return uint256(value) % FALL_IN != 0;
    }

    /**
     * @notice What banking a run of `floors` floors is worth
     * @dev Triangular rather than linear: the second floor is worth more than the first,
     *      so a longer run is worth disproportionately more than the sum of its parts —
     *      which is what makes stopping early a real sacrifice rather than an obvious one.
     */
    function pointsFor(uint32 floors) public pure returns (uint256) {
        return (uint256(floors) * (uint256(floors) + 1)) / 2;
    }

    /// @notice A climber's run in progress: floors standing, and the round of any pending floor
    function runOf(address climber) external view returns (uint32 floor, uint64 pendingRound) {
        Run storage run = _runs[climber];
        return (run.floor, run.round);
    }

    /// @notice A climber's banked score and longest banked run
    function scoreOf(address climber) external view returns (uint256 points, uint32 bestRun) {
        return (_scores[climber], _bests[climber]);
    }

    /**
     * @notice Everything needed to check a pending floor by hand, before or after it is settled
     * @dev The demonstration this game exists for. `raw` is byte-identical to the
     *      `randomness` field `api.drand.sh` serves for `round`, and `value` is
     *      `valueFor(deriveRandomness(raw, tower, "tower"), climber)` — so an outcome can be
     *      reproduced from a `curl` and two `keccak256`s, with this contract trusted for
     *      nothing.
     *
     *      `ready` false means the beacon is not on chain yet and the remaining fields are
     *      zero; `held` is what {resolve} would write, which for a published round is
     *      already determined and merely not recorded.
     * @param climber The climber whose pending floor is being described
     */
    function stepOf(address climber)
        external
        view
        returns (uint64 round, uint256 readyAt, bool ready, bytes32 raw, bytes32 value, bool held)
    {
        round = _runs[climber].round;
        if (round == 0) return (0, 0, false, bytes32(0), bytes32(0), false);

        readyAt = ORACLE.publishTimeOf(round);
        ready = ORACLE.isPublished(round);
        if (!ready) return (round, readyAt, false, bytes32(0), bytes32(0), false);

        raw = ORACLE.randomnessOf(round);
        value = valueFor(ORACLE.deriveRandomness(raw, address(this), DOMAIN), climber);
        held = holds(value);
    }
}
