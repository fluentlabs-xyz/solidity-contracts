// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

contract DrandOracleCommitTest is DrandOracleFixture {
    /// drand quicknet round 8191 is live at this timestamp.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;
    address internal consumer = makeAddr("consumer");

    function setUp() public {
        vm.warp(NOW);
        oracle = _deployOracle();
    }

    /// The round a bare `commit()` binds to is not yet published by drand
    /// at the timestamp of the very block that included the commit.
    function test_commit_bindsToRoundNotYetPublished() public {
        vm.prank(consumer);
        uint64 round = oracle.commit();
        assertGt(oracle.publishTimeOf(round), block.timestamp, "committed round must still be unpublished");
    }

    /// Round 0 is not a drand round: a commit to it could never be served, so it is refused
    /// by name rather than recorded and silently left behind.
    function test_RevertIf_commitTo_roundIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidRound.selector, 0));
        vm.prank(consumer);
        oracle.commitTo(0);
    }

    /// `commit()` measures on the chain's clock alone: `currentRound() + minFutureRounds()`.
    function test_commit_bindsToClockPlusOffset() public {
        uint64 expected = oracle.currentRound() + oracle.minFutureRounds();

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(expected, consumer);
        vm.prank(consumer);
        assertEq(oracle.commit(), expected, "commit binds to the clock plus the offset");
    }

    /// Committing again to an already-committed round creates no state
    /// record — the call cannot afford one, since a fresh storage slot alone
    /// costs 20,000 gas.
    function test_commitTo_repeatCreatesNoStateRecord() public {
        uint64 round = oracle.currentRound() + oracle.minFutureRounds();
        vm.prank(consumer);
        oracle.commitTo(round);

        vm.prank(makeAddr("otherConsumer"));
        uint256 before = gasleft();
        oracle.commitTo(round);
        uint256 spent = before - gasleft();

        assertLt(spent, 20_000, "a repeat commit must not write state");
    }

    /// Any round after the chain's clock is accepted and recorded for its caller as given,
    /// from the very next round on.
    function testFuzz_commitTo_acceptsEveryRoundAfterTheClock(uint64 round) public {
        uint64 next = oracle.currentRound() + 1;
        round = uint64(bound(round, next, type(uint64).max));

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(next, consumer);
        vm.prank(consumer);
        oracle.commitTo(next);

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(round, consumer);
        vm.prank(consumer);
        oracle.commitTo(round);
    }

    /// Any round up to and including the chain's clock is refused: its beacon is public
    /// before the commit lands.
    function testFuzz_RevertIf_commitTo_roundNotAfterTheClock(uint64 round) public {
        uint64 current = oracle.currentRound();
        round = uint64(bound(round, 1, current));

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundAlreadyEmitted.selector, current, current));
        vm.prank(consumer);
        oracle.commitTo(current);

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundAlreadyEmitted.selector, round, current));
        vm.prank(consumer);
        oracle.commitTo(round);
    }
}
