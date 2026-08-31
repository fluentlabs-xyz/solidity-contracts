// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandConsumerExample} from "../mocks/DrandConsumerExample.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOracleE2ETest is Test {
    /// currentRound() == 8191 here, so the consumer commits to 8193 while round 1
    /// is still retained; six seconds later currentRound() == 8193 and round 8193
    /// takes over round 1's ring slot (8193 % 8192 == 1).
    uint256 internal constant OPEN_AT = 1_692_827_937;
    bytes32 internal constant DOMAIN = "lottery";

    DrandOracle internal oracle;
    DrandConsumerExample internal lottery;
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(OPEN_AT);
        oracle = new DrandOracle(address(this));
        lottery = new DrandConsumerExample(address(oracle));
    }

    /// Commit → publish → read → evict → recover, on real quicknet beacons.
    function test_e2e_commitPublishReadEvictRecover() public {
        DrandQuicknetVectors.Vector memory one = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory later = DrandQuicknetVectors.round8193();

        vm.prank(alice);
        lottery.enter();
        vm.prank(bob);
        lottery.enter();
        assertEq(lottery.open(), later.round, "consumer must commit to a future round");

        // Anyone publishes; the stored value is drand's own randomness.
        vm.prank(keeper);
        oracle.publish(one.round, one.uncompressed);
        assertEq(oracle.randomnessOf(one.round), one.randomness, "round 1 must hold its vector value");

        vm.warp(later.publishTime);
        vm.prank(keeper);
        oracle.publish(later.round, later.uncompressed);

        // The consumer resolves, and its read is domain-separated from the raw value.
        address winner = lottery.draw();
        assertTrue(winner == alice || winner == bob, "winner must be an entrant");
        bytes32 raw = oracle.randomnessOf(later.round);
        vm.prank(address(lottery));
        bytes32 scoped = oracle.randomnessFor(later.round, DOMAIN);
        assertTrue(scoped != raw, "the consumer's value must not be the raw one");

        // Round 1 left the window and its slot; reading it errors...
        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.RoundEvicted.selector, one.round, oracle.oldestRetainedRound())
        );
        oracle.randomnessOf(one.round);

        // ...and the stateless path still recovers it from the same signature.
        assertEq(oracle.verifyRound(one.round, one.uncompressed), one.randomness, "evicted value stays recoverable");
    }
}
