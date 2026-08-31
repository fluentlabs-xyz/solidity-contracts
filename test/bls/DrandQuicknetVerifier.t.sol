// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DrandQuicknetVerifier} from "../../contracts/libraries/DrandQuicknetVerifier.sol";
import {DrandQuicknetVectors} from "./DrandQuicknetVectors.sol";

/// @dev The library's surface is `internal` and takes `calldata`, so the suite
///      reaches it through external wrappers on itself — no harness contract.
contract DrandQuicknetVerifierTest is Test {
    function verifyExternal(uint64 round, bytes calldata signature) external view returns (bool) {
        return DrandQuicknetVerifier.verify(round, signature);
    }

    function compressExternal(bytes calldata signature) external pure returns (bytes memory) {
        return DrandQuicknetVerifier.compressG1(signature);
    }

    /// R11: real quicknet beacons verify against the hardcoded public key.
    function test_verify_acceptsRealQuicknetBeacons() public view {
        DrandQuicknetVectors.Vector[] memory vectors = DrandQuicknetVectors.all();
        for (uint256 i = 0; i < vectors.length; ++i) {
            assertTrue(this.verifyExternal(vectors[i].round, vectors[i].uncompressed), "real beacon must verify");
        }
    }

    /// R1: a signature that does not satisfy the pairing for this round is rejected —
    /// here a genuine drand signature presented under someone else's round number.
    function test_verify_rejectsSignatureOfAnotherRound() public view {
        DrandQuicknetVectors.Vector memory one = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory other = DrandQuicknetVectors.round10M();
        assertFalse(this.verifyExternal(one.round, other.uncompressed), "round binding must be part of the pairing");
    }

    /// R10: the value derives from the point, not from the caller's bytes —
    /// compressing the submitted 128-byte form reproduces drand's own 48-byte
    /// signature, whose sha256 is drand's published randomness.
    function test_compressG1_reproducesDrandRandomness() public view {
        DrandQuicknetVectors.Vector[] memory vectors = DrandQuicknetVectors.all();
        for (uint256 i = 0; i < vectors.length; ++i) {
            bytes memory compressed = this.compressExternal(vectors[i].uncompressed);
            assertEq(compressed, vectors[i].compressed, "compressed form must match drand");
            assertEq(sha256(compressed), vectors[i].randomness, "randomness must match drand");
        }
    }
}
