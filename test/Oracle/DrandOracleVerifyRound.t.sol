// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOracleVerifyRoundTest is Test {
    /// drand quicknet round 8191 is live at this timestamp.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
    }

    /// R17: the round's randomness is recoverable from its signature without
    /// changing any state — afterwards the round is still unpublished.
    function test_verifyRound_returnsRandomnessWithoutChangingState() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();

        assertEq(oracle.verifyRound(v.round, v.uncompressed), v.randomness, "must return drand's randomness");

        assertFalse(oracle.isPublished(v.round), "verifyRound must not publish");
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, v.round));
        oracle.randomnessOf(v.round);
    }

    /// R17: any age — a round long gone from the retention window still verifies.
    function test_verifyRound_worksForRoundOutsideRetentionWindow() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);

        assertLt(v.round, oracle.oldestRetainedRound(), "round must be outside the window");
        assertEq(oracle.verifyRound(v.round, v.uncompressed), v.randomness, "age must not matter");
    }
}
