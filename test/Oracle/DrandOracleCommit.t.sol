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

    /// R3: the round a bare `commit()` binds to is not yet published by drand
    /// at the timestamp of the very block that included the commit.
    function test_commit_bindsToRoundNotYetPublished() public {
        vm.prank(consumer);
        uint64 round = oracle.commit();
        assertGt(oracle.publishTimeOf(round), block.timestamp, "committed round must still be unpublished");
    }

    /// R4: `commitTo` records the caller's round as given — the chain's clock is not
    /// consulted, so a round it has already passed is accepted as well as one far ahead.
    function test_commitTo_recordsTheRoundAsGiven() public {
        uint64 current = oracle.currentRound();

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(current - 1, consumer);
        vm.prank(consumer);
        oracle.commitTo(current - 1);

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(current + 1_000_000, consumer);
        vm.prank(consumer);
        oracle.commitTo(current + 1_000_000);
    }

    /// Round 0 is not a drand round: a commit to it could never be served, so it is refused
    /// by name rather than recorded and silently left behind.
    function test_RevertIf_commitTo_roundIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidRound.selector, 0));
        vm.prank(consumer);
        oracle.commitTo(0);
    }

    /// R4: `commit()` measures on the chain's clock alone: `currentRound() + minFutureRounds()`.
    function test_commit_bindsToClockPlusOffset() public {
        uint64 expected = oracle.currentRound() + oracle.minFutureRounds();

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(expected, consumer);
        vm.prank(consumer);
        assertEq(oracle.commit(), expected, "commit binds to the clock plus the offset");
    }

    /// R9: committing again to an already-committed round creates no state
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
}
