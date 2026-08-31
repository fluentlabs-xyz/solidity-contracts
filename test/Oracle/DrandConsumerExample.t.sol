// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandConsumerExample} from "../mocks/DrandConsumerExample.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandConsumerExampleTest is Test {
    /// drand quicknet round 8191 is live here, so `commit()` binds to round 8193 —
    /// a pinned vector, publishable six seconds later.
    uint256 internal constant OPEN_AT = 1_692_827_937;

    DrandOracle internal oracle;
    DrandConsumerExample internal lottery;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(OPEN_AT);
        oracle = new DrandOracle(address(this));
        lottery = new DrandConsumerExample(address(oracle));
    }

    /// R13: an integrator contract that knows nothing about drand — only the
    /// oracle's address — commits, waits, and draws a winner.
    function test_draw_picksWinnerFromPublishedRandomness() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round8193();

        vm.prank(alice);
        lottery.enter();
        vm.prank(bob);
        lottery.enter();

        uint64 round = lottery.open();
        assertEq(round, v.round, "the pinned vector must be the committed round");

        vm.warp(v.publishTime);
        vm.prank(makeAddr("keeper"));
        oracle.publish(v.round, v.uncompressed);

        address winner = lottery.draw();
        assertTrue(winner == alice || winner == bob, "winner must be an entrant");
        assertEq(lottery.winner(), winner, "the draw must be recorded");
    }
}
