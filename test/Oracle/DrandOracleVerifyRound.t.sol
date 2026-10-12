// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVerifier} from "../../contracts/libraries/DrandQuicknetVerifier.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOracleVerifyRoundTest is DrandOracleFixture {
    /// drand quicknet round 8191 is live at this timestamp.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;

    function setUp() public {
        vm.warp(NOW);
        oracle = _deployOracle();
    }

    /// The round's randomness is recoverable from its signature without
    /// changing any state — afterwards the round is still unpublished.
    function test_verifyRound_returnsRandomnessWithoutChangingState() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();

        assertEq(oracle.verifyRound(v.round, v.uncompressed), v.randomness, "must return drand's randomness");

        assertFalse(oracle.isPublished(v.round), "verifyRound must not publish");
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundNotPublished.selector, v.round));
        oracle.randomnessOf(v.round);
    }

    /// Any age — a round long gone from the retention window still verifies.
    function test_verifyRound_worksForRoundOutsideRetentionWindow() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);

        assertLt(v.round, oracle.oldestRetainedRound(), "round must be outside the window");
        assertEq(oracle.verifyRound(v.round, v.uncompressed), v.randomness, "age must not matter");
    }

    /// The stateless path verifies rather than merely deriving — a genuine
    /// beacon presented for another round is refused, not hashed into an answer.
    function test_RevertIf_verifyRound_signatureBelongsToAnotherRound() public {
        DrandQuicknetVectors.Vector memory target = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory other = DrandQuicknetVectors.round8193();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidSignature.selector, target.round));
        oracle.verifyRound(target.round, other.uncompressed);
    }

    /// A precompile out of gas fails the way one refusing its input does; a genuine beacon
    /// sent with gas for the hashing but not for the pairing is reported as starved, not
    /// as a signature that does not verify.
    function test_RevertIf_verifyRound_gasCannotCoverThePairing() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();

        vm.expectRevert(DrandQuicknetVerifier.PrecompileFailed.selector);
        oracle.verifyRound{gas: 60_000}(v.round, v.uncompressed);
    }
}
