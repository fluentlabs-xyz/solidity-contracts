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

/// @dev `verifyBatch` takes memory, so the wrappers below are the calldata edge only for
///      the sake of a uniform `this.` call shape.
contract DrandQuicknetVerifierBatchTest is Test {
    address internal constant G1ADD = address(0x0b);

    /// BLS12-381 base field prime, split as the library splits it: top 16 bytes, low 32.
    uint256 internal constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    function verifyBatchExternal(uint64[] memory rounds, bytes memory signatures) external view returns (bool) {
        return DrandQuicknetVerifier.verifyBatch(rounds, signatures);
    }

    function verifyExternal(uint64 round, bytes calldata signature) external view returns (bool) {
        return DrandQuicknetVerifier.verify(round, signature);
    }

    function _batch(DrandQuicknetVectors.Vector[] memory vectors)
        internal
        pure
        returns (uint64[] memory rounds, bytes memory signatures)
    {
        rounds = new uint64[](vectors.length);
        for (uint256 i = 0; i < vectors.length; ++i) {
            rounds[i] = vectors[i].round;
            signatures = bytes.concat(signatures, vectors[i].uncompressed);
        }
    }

    /// G1ADD over two EIP-2537 points.
    function _add(bytes memory a, bytes memory b) internal view returns (bytes memory out) {
        bool ok;
        (ok, out) = G1ADD.staticcall(bytes.concat(a, b));
        assertTrue(ok && out.length == 128, "G1ADD must answer");
    }

    /// -P: the same x with y replaced by p - y, in the 128-byte EIP-2537 layout where
    /// y occupies bytes 80..128 as 16 bytes of padding-free high word and a 32-byte low word.
    function _negate(bytes memory point) internal pure returns (bytes memory out) {
        out = bytes.concat(point);
        uint256 yHi;
        uint256 yLo;
        assembly ("memory-safe") {
            yHi := shr(128, mload(add(out, 112)))
            yLo := mload(add(out, 128))
        }
        uint256 lo;
        uint256 hi;
        unchecked {
            lo = P_LO - yLo;
            hi = P_HI - yHi - (P_LO < yLo ? 1 : 0);
        }
        assembly ("memory-safe") {
            mstore(add(out, 112), or(shl(128, hi), shr(128, lo)))
            mstore(add(out, 128), lo)
        }
    }

    /// Consecutive rounds — the shape a publisher sends — verify under one pairing.
    function test_verifyBatch_acceptsConsecutiveRounds() public view {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        assertTrue(this.verifyBatchExternal(rounds, signatures), "five real beacons must verify");
    }

    /// The check does not depend on adjacency: any set of real rounds verifies.
    function test_verifyBatch_acceptsAnySetOfRounds() public view {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.all());
        assertTrue(this.verifyBatchExternal(rounds, signatures), "nine real beacons must verify");
    }

    /// A batch of one is the plain pairing and agrees with `verify`.
    function test_verifyBatch_ofOneAgreesWithVerify() public view {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1000();
        uint64[] memory rounds = new uint64[](1);
        rounds[0] = v.round;
        assertTrue(this.verifyBatchExternal(rounds, v.uncompressed), "one real beacon must verify");
        assertTrue(this.verifyExternal(v.round, v.uncompressed), "verify agrees");

        DrandQuicknetVectors.Vector memory other = DrandQuicknetVectors.round1001();
        assertFalse(this.verifyBatchExternal(rounds, other.uncompressed), "another round's beacon must not");
    }

    /// Two genuine signatures under each other's round numbers: every point is drand's, the
    /// binding to the round is what fails.
    function test_verifyBatch_rejectsSwappedPair() public view {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        (rounds[1], rounds[2]) = (rounds[2], rounds[1]);
        assertFalse(this.verifyBatchExternal(rounds, signatures), "swapped rounds must not verify");
    }

    /// The forgery the random coefficients exist for: `sig₀ + δ` and `sig₁ - δ` sum to
    /// exactly `sig₀ + sig₁`, so a check on the plain sum cannot tell the pair from the
    /// real one — while neither point is drand's signature.
    function test_verifyBatch_rejectsPairThatSumsToTheRealSum() public view {
        DrandQuicknetVectors.Vector memory a = DrandQuicknetVectors.round1000();
        DrandQuicknetVectors.Vector memory b = DrandQuicknetVectors.round1001();
        bytes memory delta = DrandQuicknetVectors.round10M().uncompressed;

        bytes memory forgedA = _add(a.uncompressed, delta);
        bytes memory forgedB = _add(b.uncompressed, _negate(delta));

        assertEq(_add(forgedA, forgedB), _add(a.uncompressed, b.uncompressed), "the naive sum is unchanged");
        assertFalse(this.verifyExternal(a.round, forgedA), "the forged point is not drand's");
        assertFalse(this.verifyExternal(b.round, forgedB), "the forged point is not drand's");

        uint64[] memory rounds = new uint64[](2);
        rounds[0] = a.round;
        rounds[1] = b.round;
        assertFalse(
            this.verifyBatchExternal(rounds, bytes.concat(forgedA, forgedB)), "the coefficients must catch the pair"
        );
    }

    /// The pairing accepts a pair at infinity as 1, so an all-zero element is refused by
    /// name before it reaches the precompile.
    function test_RevertIf_verifyBatch_elementIsInfinity() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        for (uint256 i = 128; i < 256; ++i) {
            signatures[i] = 0;
        }
        vm.expectRevert(DrandQuicknetVerifier.InfinityPoint.selector);
        this.verifyBatchExternal(rounds, signatures);
    }

    function test_RevertIf_verifyBatch_lengthsDisagree() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        vm.expectRevert(DrandQuicknetVerifier.InvalidPointLength.selector);
        this.verifyBatchExternal(rounds, bytes.concat(signatures, hex"00"));

        vm.expectRevert(DrandQuicknetVerifier.InvalidPointLength.selector);
        this.verifyBatchExternal(new uint64[](0), "");
    }
}
