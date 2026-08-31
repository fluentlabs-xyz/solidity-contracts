// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOracleReadTest is Test {
    /// drand quicknet round 8191 is live at this timestamp, so round 1 is still retained.
    uint256 internal constant NOW = 1_692_827_937;
    bytes32 internal constant DOMAIN = "lottery";

    DrandOracle internal oracle;
    DrandQuicknetVectors.Vector internal v;
    address internal consumerA = makeAddr("consumerA");
    address internal consumerB = makeAddr("consumerB");

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
        v = DrandQuicknetVectors.round1();
        vm.prank(makeAddr("anyone"));
        oracle.publish(v.round, v.uncompressed);
    }

    /// R8: two consumers on the same round read different domain-separated values,
    /// each reproducible off-chain from the round's published value.
    function test_randomnessFor_differsPerConsumer() public {
        vm.prank(consumerA);
        bytes32 a = oracle.randomnessFor(v.round, DOMAIN);
        vm.prank(consumerB);
        bytes32 b = oracle.randomnessFor(v.round, DOMAIN);

        assertTrue(a != b, "consumers on one round must not share a value");
        assertEq(a, oracle.deriveRandomness(v.randomness, consumerA, DOMAIN), "must be reproducible off-chain");
    }

    /// R16: a round that has aged out of the ring reverts — it reads neither as
    /// zero nor as the value of whoever now occupies its slot.
    function test_RevertIf_randomnessOf_roundEvicted() public {
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);

        assertFalse(oracle.isPublished(v.round), "an evicted round is not published");
        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.RoundEvicted.selector, v.round, oracle.oldestRetainedRound())
        );
        oracle.randomnessOf(v.round);
    }

    /// R16: round 0 — the value a consumer holds before it has ever committed —
    /// reverts as well, instead of reading the untouched slot as zero.
    function test_RevertIf_randomnessOf_roundZero() public {
        assertFalse(oracle.isPublished(0), "round 0 is never published");
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundEvicted.selector, 0, oracle.oldestRetainedRound()));
        oracle.randomnessOf(0);
    }
}
