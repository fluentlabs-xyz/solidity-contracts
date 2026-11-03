// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

/// The retention window at its edges: where the floor moves, what the clock's arithmetic
/// does at the ends of `uint64`, and what a clock that steps backwards can and cannot do
/// to the ring.
contract DrandOracleWindowTest is DrandOracleFixture {
    /// Far beyond any real chain, yet well inside `uint64` and `vm.warp`'s range.
    uint64 internal constant FUZZ_ROUND_MAX = 1e15;

    DrandOracle internal oracle;

    function setUp() public {
        oracle = _deployOracle();
    }

    /// The floor stays at 1 until the clock passes the ring's size, then follows it one
    /// round per round: at 8192 every round from 1 is still readable, at 8193 round 1 is
    /// the first to go.
    function test_oldestRetainedRound_movesOffOneExactlyWhenTheClockPassesTheRing() public {
        vm.warp(oracle.publishTimeOf(oracle.RING_ROUNDS()));
        assertEq(oracle.currentRound(), 8192);
        assertEq(oracle.oldestRetainedRound(), 1, "at a clock of 8192 the whole ring is one window");

        vm.warp(oracle.publishTimeOf(oracle.RING_ROUNDS() + 1));
        assertEq(oracle.currentRound(), 8193);
        assertEq(oracle.oldestRetainedRound(), 2, "at 8193 round 1 has left the window");
    }

    /// The clock's arithmetic holds at the top of the round space: a round number has a
    /// publish time, and the far end of `uint64` is refused as future, not miscomputed.
    function test_publishTimeOf_andPublish_holdAtTheTopOfUint64() public {
        uint64 top = type(uint64).max;
        assertEq(
            oracle.publishTimeOf(top),
            uint256(oracle.GENESIS_TIMESTAMP()) + uint256(top - 1) * oracle.PERIOD_SECONDS(),
            "the publish time is computed in uint256 and does not wrap"
        );

        vm.warp(oracle.publishTimeOf(8193));
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, top, oracle.currentRound()));
        oracle.publish(top, new bytes(128));
    }

    /// A clock that steps backwards cannot make the ring serve a wrong value: a round
    /// published under the faster clock keeps its slot and its tag, so a read under the
    /// slower clock still finds the round it asks for, and the slot's earlier occupant is
    /// gone rather than resurrected. What a backwards clock can do is admit a republish
    /// of the older round over the live one — the ring working as designed, never a value
    /// served for the wrong round — and that is exercised at the end.
    function test_aClockSteppingBackwardsCannotResurrectAnEvictedRoundOrMisreadASlot() public {
        DrandQuicknetVectors.Vector memory one = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory later = DrandQuicknetVectors.round8193();

        vm.warp(oracle.publishTimeOf(one.round));
        oracle.publish(one.round, one.uncompressed);
        vm.warp(oracle.publishTimeOf(later.round));
        oracle.publish(later.round, later.uncompressed);
        assertEq(oracle.randomnessOf(later.round), later.randomness);

        // The clock steps back to where round 1 was inside the window.
        vm.warp(oracle.publishTimeOf(8000));
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, one.round));
        oracle.randomnessOf(one.round);
        assertFalse(oracle.isPublished(one.round), "the slot carries 8193's tag, so round 1 reads as absent");
        assertEq(
            oracle.randomnessOf(later.round),
            later.randomness,
            "the round published under the faster clock still reads as itself"
        );

        // Under the backwards clock round 1 is inside the window and 8193 is not, so a
        // republish of round 1 takes the slot back: 8193 is gone, and every read says so.
        oracle.publish(one.round, one.uncompressed);
        assertEq(oracle.randomnessOf(one.round), one.randomness);
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, later.round));
        oracle.randomnessOf(later.round);

        // Once the clock is back where it was, the floor refuses round 1 again.
        vm.warp(oracle.publishTimeOf(later.round));
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, one.round, 2));
        oracle.publish(one.round, one.uncompressed);
    }

    /// The clock and the publish time invert each other: round `r` is current from its
    /// publish time for exactly one period, and its successor takes over after that.
    function testFuzz_currentRound_isTheRoundWhosePeriodContainsTheTimestamp(uint64 round, uint256 offset) public {
        round = uint64(bound(round, 1, FUZZ_ROUND_MAX));
        offset = bound(offset, 0, oracle.PERIOD_SECONDS() - 1);

        vm.warp(oracle.publishTimeOf(round) + offset);
        assertEq(oracle.currentRound(), round, "the round is current throughout its period");
        vm.warp(oracle.publishTimeOf(round) + oracle.PERIOD_SECONDS());
        assertEq(oracle.currentRound(), round + 1, "and its successor once the period ends");
    }

    /// The window is the last RING_ROUNDS rounds up to the clock, or every round when the
    /// clock has not yet reached RING_ROUNDS.
    function testFuzz_oldestRetainedRound_spansTheRingUpToTheClock(uint64 clock) public {
        clock = uint64(bound(clock, 1, FUZZ_ROUND_MAX));
        vm.warp(oracle.publishTimeOf(clock));

        uint64 oldest = oracle.oldestRetainedRound();
        uint64 ring = oracle.RING_ROUNDS();
        assertGe(oldest, 1, "the floor never reaches round 0");
        assertEq(clock - oldest + 1, clock < ring ? clock : ring, "the window is the ring, clipped at round 1");
    }

    /// Every round below the floor is refused by publish and reads as evicted.
    function testFuzz_RevertIf_roundBelowTheWindow(uint64 clock, uint64 round) public {
        clock = uint64(bound(clock, oracle.RING_ROUNDS() + 1, FUZZ_ROUND_MAX));
        vm.warp(oracle.publishTimeOf(clock));
        uint64 oldest = oracle.oldestRetainedRound();
        round = uint64(bound(round, 0, oldest - 1));

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, round, oldest));
        oracle.publish(round, new bytes(128));
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundEvicted.selector, round, oldest));
        oracle.randomnessOf(round);
        assertFalse(oracle.isPublished(round));
    }

    /// Every round past the clock is refused by publish, so no write can land ahead of it.
    function testFuzz_RevertIf_publish_roundPastTheClock(uint64 clock, uint64 round) public {
        clock = uint64(bound(clock, 1, FUZZ_ROUND_MAX));
        vm.warp(oracle.publishTimeOf(clock));
        round = uint64(bound(round, uint256(clock) + 1, type(uint64).max));

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, round, clock));
        oracle.publish(round, new bytes(128));
    }

    /// A round inside the window that nobody published reads as not published, never as
    /// the zero value of its untouched slot.
    function testFuzz_RevertIf_randomnessOf_roundInsideTheWindowUnpublished(uint64 clock, uint64 round) public {
        clock = uint64(bound(clock, 1, FUZZ_ROUND_MAX));
        vm.warp(oracle.publishTimeOf(clock));
        round = uint64(bound(round, oracle.oldestRetainedRound(), clock));

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, round));
        oracle.randomnessOf(round);
        assertFalse(oracle.isPublished(round));
    }

    /// Before drand's genesis there is no current round: the clock reverts by name.
    function testFuzz_RevertIf_currentRound_beforeGenesis(uint256 timestamp) public {
        timestamp = bound(timestamp, 0, oracle.GENESIS_TIMESTAMP() - 1);
        vm.warp(timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.TimestampBeforeGenesis.selector, timestamp, oracle.GENESIS_TIMESTAMP())
        );
        oracle.currentRound();
    }
}
