// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

contract DrandOracleCommitTest is Test {
    /// drand quicknet round 8191 is live at this timestamp.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;
    address internal consumer = makeAddr("consumer");

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
    }

    /// R3: the round a bare `commit()` binds to is not yet published by drand
    /// at the timestamp of the very block that included the commit.
    function test_commit_bindsToRoundNotYetPublished() public {
        vm.prank(consumer);
        uint64 round = oracle.commit();
        assertGt(oracle.publishTimeOf(round), block.timestamp, "committed round must still be unpublished");
    }

    /// R4: an explicit round closer than the minimum offset is rejected; the
    /// round exactly at the floor is accepted.
    function test_commitTo_enforcesMinimumOffset() public {
        uint64 current = oracle.currentRound();
        uint64 floorRound = current + oracle.minFutureRounds();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooSoon.selector, floorRound - 1, floorRound));
        vm.prank(consumer);
        oracle.commitTo(floorRound - 1);

        vm.expectEmit(true, true, false, false, address(oracle));
        emit IDrandOracle.RoundCommitted(floorRound, consumer);
        vm.prank(consumer);
        oracle.commitTo(floorRound);
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
