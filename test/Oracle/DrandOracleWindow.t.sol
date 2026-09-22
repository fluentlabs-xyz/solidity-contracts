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
}
