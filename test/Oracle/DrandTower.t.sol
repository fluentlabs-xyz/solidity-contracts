// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandTower} from "../../contracts/examples/DrandTower.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

/**
 * @notice The reference consumer: that a floor is bound to a beacon before it exists, that
 *         settling it is nobody's privilege, and that a run is worth nothing until banked.
 * @dev The oracle under it is the real one. Outcomes are forced with `vm.mockCall` on
 *      `randomnessFor` where the test is about the tower's own bookkeeping; the two tests
 *      that are about the tower's reading of drand run on a pinned beacon with nothing
 *      mocked at all. Forcing an outcome means searching for a game value that splits to
 *      one, since {DrandTower-valueFor} stands between the oracle's answer and the floor.
 */
contract DrandTowerTest is Test {
    /// drand quicknet round 8191 is live at this timestamp, so the window reaches round 1.
    uint256 internal constant NOW = 1_692_827_937;

    /// @dev The tower's own domain separator, restated here so a change to it fails a test.
    bytes32 internal constant DOMAIN = "tower";

    DrandOracle internal oracle;
    DrandTower internal tower;

    address internal climber = makeAddr("climber");
    address internal bystander = makeAddr("bystander");

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
        tower = new DrandTower(address(oracle));
    }

    // ============ Climbing ============

    /// The commit is the game: the round it binds to has no beacon at the time it is taken.
    function test_climb_bindsToARoundWhoseBeaconDoesNotExistYet() public {
        uint64 expected = oracle.currentRound() + oracle.minFutureRounds();

        vm.expectEmit(true, true, true, true, address(tower));
        emit DrandTower.Climbed(climber, 1, expected, oracle.publishTimeOf(expected));
        vm.prank(climber);
        uint64 round = tower.climb();

        assertEq(round, expected, "the floor must be bound to the oracle's earliest safe round");
        assertGt(oracle.publishTimeOf(round), block.timestamp, "the beacon must still be in the future");
        assertFalse(oracle.isPublished(round), "the beacon must not exist at commit time");

        (uint32 floor, uint64 pending) = tower.runOf(climber);
        assertEq(floor, 0, "no floor is won by committing to one");
        assertEq(pending, round, "the run must carry the round it is waiting on");
    }

    /// One floor at a time: a second commit would be a second bet on the same step.
    function test_RevertIf_climb_whileAStepIsPending() public {
        vm.prank(climber);
        uint64 round = tower.climb();

        vm.expectRevert(abi.encodeWithSelector(DrandTower.StepPending.selector, round));
        vm.prank(climber);
        tower.climb();
    }

    // ============ Resolving ============

    /// A floor that holds moves the run up and frees the climber to take the next one.
    function test_resolve_holdsAndAdvancesTheRun() public {
        uint64 round = _climb(climber);
        bytes32 value = tower.valueFor(_force(round, climber, true), climber);

        vm.expectEmit(true, true, true, true, address(tower));
        emit DrandTower.Resolved(climber, 1, round, value, true);
        assertTrue(tower.resolve(climber), "a value not divisible by four holds");

        (uint32 floor, uint64 pending) = tower.runOf(climber);
        assertEq(floor, 1, "a held floor must raise the run");
        assertEq(pending, 0, "a settled step must leave nothing pending");
    }

    /// A fall costs the whole run, not the floor it fell on.
    function test_resolve_fallEndsTheRun() public {
        _hold(climber);
        _hold(climber);
        (uint32 standing,) = tower.runOf(climber);
        assertEq(standing, 2, "two floors must be standing before the fall");

        uint64 round = _climb(climber);
        bytes32 value = tower.valueFor(_force(round, climber, false), climber);

        vm.expectEmit(true, true, true, true, address(tower));
        emit DrandTower.Resolved(climber, 3, round, value, false);
        assertFalse(tower.resolve(climber), "a value divisible by four drops the floor");

        (uint32 floor, uint64 pending) = tower.runOf(climber);
        assertEq(floor, 0, "a fall must take the floors that were standing");
        assertEq(pending, 0, "a settled step must leave nothing pending");
    }

    /// The outcome is a function of the round and the climber, never of who settles it.
    function test_resolve_isPermissionless() public {
        uint64 round = _climb(climber);
        _force(round, climber, true);

        vm.prank(bystander);
        tower.resolve(climber);

        (uint32 floor,) = tower.runOf(climber);
        assertEq(floor, 1, "a stranger settling the step must produce the same run");
    }

    /// No fallback value: an unpublished beacon stops the game rather than inventing a number.
    function test_RevertIf_resolve_beforeTheBeaconIsPublished() public {
        uint64 round = _climb(climber);

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, round));
        tower.resolve(climber);
    }

    /// Nothing to settle is an error, not a silent no-op that would look like a fall.
    function test_RevertIf_resolve_withNoStepPending() public {
        vm.expectRevert(DrandTower.NoStepPending.selector);
        tower.resolve(climber);
    }

    // ============ Banking ============

    /// Floors become score only on the way out, which is what makes climbing on cost something.
    function test_bank_creditsTriangularPointsAndResetsTheRun() public {
        _hold(climber);
        _hold(climber);
        _hold(climber);

        vm.expectEmit(true, true, true, true, address(tower));
        emit DrandTower.Banked(climber, 3, 6, 6);
        vm.prank(climber);
        assertEq(tower.bank(), 6, "three floors must bank 1 + 2 + 3");

        (uint256 points, uint32 best) = tower.scoreOf(climber);
        assertEq(points, 6, "the run must be added to the score");
        assertEq(best, 3, "the run must be recorded as the longest banked");
        assertEq(tower.champion(), climber, "the only banked run must lead the board");
        assertEq(tower.championScore(), 6, "the leader's score must be the banked total");

        (uint32 floor,) = tower.runOf(climber);
        assertEq(floor, 0, "banking must start a fresh run");
    }

    /// A run lost before banking is worth nothing at all, which is the whole wager.
    function test_bank_afterAFallCreditsNothing() public {
        _hold(climber);
        _hold(climber);

        uint64 round = _climb(climber);
        _force(round, climber, false);
        tower.resolve(climber);

        vm.expectRevert(DrandTower.NothingToBank.selector);
        vm.prank(climber);
        tower.bank();

        (uint256 points,) = tower.scoreOf(climber);
        assertEq(points, 0, "a run that fell must add nothing to the score");
    }

    /// Banking mid-step would let a climber take the money after seeing the beacon.
    function test_RevertIf_bank_whileAStepIsPending() public {
        _hold(climber);
        uint64 round = _climb(climber);

        vm.expectRevert(abi.encodeWithSelector(DrandTower.StepPending.selector, round));
        vm.prank(climber);
        tower.bank();
    }

    // ============ Reading drand for real ============

    /// End to end on a pinned beacon, nothing mocked: the floor is decided by the bytes
    /// `api.drand.sh` serves for the round, folded with this tower's own address.
    function test_endToEnd_aRealBeaconDecidesTheFloor() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round31799517();
        uint64 round = _climbTo(climber, v.round);

        vm.warp(v.publishTime);
        oracle.publish(v.round, v.uncompressed);

        bytes32 expectedValue =
            tower.valueFor(oracle.deriveRandomness(v.randomness, address(tower), DOMAIN), climber);
        (,, bool ready, bytes32 raw, bytes32 value, bool wouldHold) = tower.stepOf(climber);
        assertTrue(ready, "the beacon must be on chain");
        assertEq(raw, v.randomness, "the raw value must be drand's own randomness for the round");
        assertEq(value, expectedValue, "the tower's value must be the documented derivation");

        assertEq(tower.resolve(climber), wouldHold, "settling must record what the beacon already decided");
        assertEq(tower.holds(value), wouldHold, "the outcome must be reproducible from the value alone");

        (uint32 floor,) = tower.runOf(climber);
        assertEq(floor, wouldHold ? 1 : 0, "the run must follow the beacon");
        assertEq(round, v.round, "the committed round must be the pinned one");
    }

    /// A run left standing past the oracle's window is settled from the beacon itself
    /// rather than stranded, and lands on the same outcome.
    function test_resolveWith_settlesAStepTheOracleNoLongerRetains() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round31799517();
        _climbTo(climber, v.round);

        // Past `round + RING_ROUNDS`, so the oracle's window no longer reaches it.
        vm.warp(oracle.publishTimeOf(v.round + oracle.RING_ROUNDS()));
        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.RoundEvicted.selector, v.round, oracle.oldestRetainedRound())
        );
        tower.resolve(climber);

        bool expected =
            tower.holds(tower.valueFor(oracle.deriveRandomness(v.randomness, address(tower), DOMAIN), climber));
        assertEq(tower.resolveWith(climber, v.uncompressed), expected, "the escape hatch must agree with the beacon");

        (, uint64 pending) = tower.runOf(climber);
        assertEq(pending, 0, "the stranded step must be settled");
    }

    /// The signature is checked against the round the tower committed to, not one the
    /// caller names, so a genuine beacon for another round cannot be substituted.
    function test_RevertIf_resolveWith_signatureIsForAnotherRound() public {
        DrandQuicknetVectors.Vector memory committed = DrandQuicknetVectors.round31799517();
        DrandQuicknetVectors.Vector memory other = DrandQuicknetVectors.round8193();
        _climbTo(climber, committed.round);

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidSignature.selector, committed.round));
        tower.resolveWith(climber, other.uncompressed);
    }

    /// The reason {DrandTower-valueFor} exists: one beacon, two climbers, two floors that
    /// are decided separately. A round that ends one run must be able to leave the other
    /// standing, or the game would settle every player at once on a single number.
    function test_valueFor_splitsOneRoundBetweenClimbers() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round31799517();
        _climbTo(climber, v.round);
        _climbTo(bystander, v.round);

        vm.warp(v.publishTime);
        oracle.publish(v.round, v.uncompressed);

        (,,,, bytes32 mine, bool mineHolds) = tower.stepOf(climber);
        (,,,, bytes32 theirs, bool theirsHolds) = tower.stepOf(bystander);

        bytes32 shared = oracle.deriveRandomness(v.randomness, address(tower), DOMAIN);
        assertEq(mine, tower.valueFor(shared, climber), "each floor must be the game's value split by its climber");
        assertEq(theirs, tower.valueFor(shared, bystander), "and the split must name that climber, not the caller");
        assertTrue(mine != theirs, "two climbers on one round must not share a value");
        assertTrue(mine != shared && theirs != shared, "and neither may be the game's unsplit value");

        assertEq(tower.resolve(climber), mineHolds, "the split value must be what settling writes");
        assertEq(tower.resolve(bystander), theirsHolds, "for each climber independently");
    }

    // ============ Pure rules ============

    /// The published rules, checked at the boundary the game turns on.
    function test_rules_holdThreeFloorsInFourAndPayTriangularly() public view {
        assertFalse(tower.holds(bytes32(uint256(0))), "a multiple of four drops");
        assertTrue(tower.holds(bytes32(uint256(1))), "one past a multiple holds");
        assertTrue(tower.holds(bytes32(uint256(3))), "three past a multiple holds");
        assertFalse(tower.holds(bytes32(uint256(8))), "the next multiple drops");

        assertEq(tower.pointsFor(0), 0, "an empty run is worth nothing");
        assertEq(tower.pointsFor(1), 1, "the first floor is worth one");
        assertEq(tower.pointsFor(6), 21, "the break-even run is worth twenty-one");
        // 0.75 * pointsFor(7) == pointsFor(6): the sixth floor is where climbing stops paying.
        assertEq((tower.pointsFor(7) * 3) / 4, tower.pointsFor(6), "the break-even must sit at the sixth floor");
    }

    /// A climber with no step pending has nothing to describe.
    function test_stepOf_isEmptyWithNoStepPending() public view {
        (uint64 round, uint256 readyAt, bool ready,,,) = tower.stepOf(climber);
        assertEq(round, 0, "no pending round");
        assertEq(readyAt, 0, "no time to wait for");
        assertFalse(ready, "nothing to be ready");
    }

    /// The oracle a tower reads cannot be absent; a zero there would make every floor revert.
    function test_RevertIf_constructor_oracleIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.ZeroAddressNotAllowed.selector, "oracle"));
        new DrandTower(address(0));
    }

    // ============ Helpers ============

    /// @dev One commit, from `who`.
    function _climb(address who) internal returns (uint64 round) {
        vm.prank(who);
        return tower.climb();
    }

    /// @dev Puts the clock where `commit()` lands exactly on `round`, then commits.
    function _climbTo(address who, uint64 round) internal returns (uint64 committed) {
        vm.warp(oracle.publishTimeOf(round - oracle.minFutureRounds()));
        committed = _climb(who);
        assertEq(committed, round, "the clock must place the commit on the pinned round");
    }

    /// @dev One floor that holds, without waiting on a beacon for it.
    function _hold(address who) internal {
        uint64 round = _climb(who);
        _force(round, who, true);
        tower.resolve(who);
        vm.clearMockedCalls();
    }

    /// @dev Makes the oracle answer, for the tower's read of `round`, a game value whose
    ///      split for `who` lands on `wantHold`. Searched rather than written down: the
    ///      split is a keccak, so a value with a chosen outcome cannot be picked by hand —
    ///      which is the property under test as much as a fixture for it.
    function _force(uint64 round, address who, bool wantHold) internal returns (bytes32 game) {
        for (uint256 salt = 0; salt < 256; salt++) {
            game = bytes32(salt);
            if (tower.holds(tower.valueFor(game, who)) == wantHold) {
                vm.mockCall(
                    address(oracle), abi.encodeCall(IDrandOracle.randomnessFor, (round, DOMAIN)), abi.encode(game)
                );
                return game;
            }
        }
        revert("no game value in 256 tries produced the requested outcome");
    }
}
