// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// @title drand quicknet beacon verification (BLS12-381 MinSig over EIP-2537, Prague).
/// @author Fluent Labs
/// @notice Verifies a drand quicknet round signature against the beacon's hardcoded
///         public key, and recovers the 48-byte compressed form drand publishes.
/// @dev Adapted from the in-house `BLS12381Verifier` (Apache-2.0): the crypto core —
///      hash-to-G1, the pairing input layout, the compression rule and the field
///      constants — is carried over unchanged. The single semantic change is the
///      message: drand signs the bare `sha256(uint64_be(round))` digest, so the
///      namespaced `union_unique` prefix is gone, and the DST and public key are
///      compile-time constants rather than caller-supplied parameters.
///      All functions are `internal`, so the library is inlined into its importer
///      and never deployed on its own.
library DrandQuicknetVerifier {
    address private constant MODEXP = address(0x05);
    address private constant G1ADD = address(0x0b);
    address private constant G1MSM = address(0x0c);
    address private constant MAP_FP_TO_G1 = address(0x10);
    address private constant PAIRING = address(0x0f);

    // BLS12-381 base field prime p (48 B), split into a high uint256 (top
    // 16 bytes) and a low uint256 (low 32 bytes) for a 384-bit unsigned
    // compare with no modmul. Conformance-pinned (a wrong constant => a
    // liveness revert, not a forge).
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    // (p-1)/2, split the same way (top 16 bytes / low 32 bytes). Used by
    // the y-sign rule: sign bit set iff y is the lexicographically-greater
    // of {y, p-y}, i.e. y > (p-1)/2.
    // (p-1)/2 = 0d0088f51cbff34d258dd3db21a5d66b (top 16 B)
    //          ‖ b23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555 (low 32 B)
    uint256 private constant HALF_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 private constant HALF_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;

    /// Negated G2 generator in EIP-2537 form (256 B) — fixed protocol
    /// constant, identical to Eip2537ConformanceVectors.NEG_G2_GENERATOR.
    bytes private constant NEG_G2_GENERATOR =
        hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb80000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    /// drand quicknet's RFC 9380 domain separation tag — scheme
    /// `bls-unchained-g1-rfc9380`, chain
    /// `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971` — in the
    /// form expand_message_xmd consumes it: DST' = DST ‖ I2OSP(len(DST), 1), 43 + 1 bytes.
    /// 43 is inside RFC 9380's short-DST path, so the §5.3.3 oversize workaround is absent.
    bytes private constant DST_PRIME =
        hex"424c535f5349475f424c53313233383147315f584d443a5348412d3235365f535357555f524f5f4e554c5f2b";

    /// drand quicknet's group public key, a G2 point in EIP-2537 form (256 B,
    /// `pad‖x.c0‖pad‖x.c1‖pad‖y.c0‖pad‖y.c1`). Validated against live beacons
    /// by the pinned-vector conformance suite.
    bytes private constant PUBLIC_KEY =
        hex"000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f045152730000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    error InfinityPoint();
    error PrecompileFailed();
    error InvalidPointLength(); // EIP-2537 width mismatch (G1=128 B, G2=256 B)

    /// @notice Verify one drand quicknet round: e(sig,-G2gen)·e(H,pk) == 1.
    /// @dev The signed message is derived here from `round`, never taken from the
    ///      caller, so a signature valid for a different round cannot be replayed
    ///      under this one.
    /// @param round drand round number, big-endian in the digest drand signs
    /// @param sigUncompressed 128 B EIP-2537 G1 (caller-supplied)
    function verify(uint64 round, bytes calldata sigUncompressed) internal view returns (bool) {
        // Pin exact EIP-2537 widths: any deviation shifts the 384-byte
        // per-pair boundary inside the 2-pair PAIRING input below.
        if (sigUncompressed.length != 128) revert InvalidPointLength();
        _rejectInfinity(sigUncompressed);

        bytes memory h = _hashToG1(sha256(abi.encodePacked(round)));
        _rejectInfinity(h);
        return _pairingHolds(sigUncompressed, h);
    }

    /// @notice Verify several rounds under one pairing:
    ///         e(Σ rᵢ·sigᵢ, -G2gen) · e(Σ rᵢ·H(roundᵢ), pk) == 1, the rᵢ drawn from a hash
    ///         of the whole input.
    /// @dev The coefficients are what make one pairing sound for many signatures: with
    ///      every rᵢ == 1 the pair `sig₀ + δ, sig₁ - δ` passes while neither point is
    ///      drand's. Here a forgery needs Σ rᵢδᵢ == 0 with each rᵢ depending on every δᵢ
    ///      through the hash, a 2⁻¹²⁸ event. A single round takes the plain pairing path,
    ///      where the multiplications would cost more than they save. A point off the
    ///      curve or outside the subgroup makes MSM refuse the input, which reads as "does
    ///      not verify" — the same answer PAIRING gives it.
    /// @param rounds drand round numbers, one per signature
    /// @param signatures the rounds' beacons, 128 B EIP-2537 G1 each, concatenated in order
    function verifyBatch(uint64[] memory rounds, bytes memory signatures) internal view returns (bool) {
        uint256 n = rounds.length;
        if (n == 0 || signatures.length != n * 128) revert InvalidPointLength();
        if (n == 1) {
            _rejectInfinity(signatures);
            bytes memory h = _hashToG1(sha256(abi.encodePacked(rounds[0])));
            _rejectInfinity(h);
            return _pairingHolds(signatures, h);
        }

        bytes32 seed = keccak256(abi.encodePacked(rounds, signatures));
        bytes memory sigTerms = new bytes(n * 160);
        bytes memory hashTerms = new bytes(n * 160);
        for (uint256 i = 0; i < n; ++i) {
            if (_isZero128(signatures, i * 128)) revert InfinityPoint();
            bytes memory h = _hashToG1(sha256(abi.encodePacked(rounds[i])));
            _rejectInfinity(h);
            bytes32 coefficient = bytes32(uint256(uint128(uint256(keccak256(abi.encode(seed, i))))));
            _writeTerm(sigTerms, i, signatures, i * 128, coefficient);
            _writeTerm(hashTerms, i, h, 0, coefficient);
        }

        bytes memory aggregateSig = _g1Msm(sigTerms);
        bytes memory aggregateHash = _g1Msm(hashTerms);
        if (aggregateSig.length == 0 || aggregateHash.length == 0) return false;
        // PAIRING accepts a pair at infinity as 1; both aggregates there would pass an
        // input that verifies nothing.
        if (_isZero128(aggregateSig, 0) || _isZero128(aggregateHash, 0)) return false;
        return _pairingHolds(aggregateSig, aggregateHash);
    }

    /// @notice Compress a 128 B EIP-2537 G1 to the 48 B zcash form drand publishes.
    /// @dev Pure; on-curve/subgroup membership is left to PAIRING, so callers must
    ///      have run {verify} on the same bytes before treating the result as drand's.
    ///      The compressed form is x with the top three bits as flags: `1` for
    ///      compressed, `0` for not-infinity, and the sign of y — set iff y is the
    ///      lexicographically greater of {y, p-y}, i.e. y > (p-1)/2. x < p < 2^381, so
    ///      the bits are free.
    function compressG1(bytes calldata uncompressed128) internal pure returns (bytes memory) {
        if (uncompressed128.length != 128) revert InvalidPointLength();
        // x = uncompressed[16:64], y = uncompressed[80:128]: 48-byte big-endian field
        // elements, each read as a 32-byte head and a 16-byte tail.
        bytes32 xHead = bytes32(uncompressed128[16:48]);
        bytes16 xTail = bytes16(uncompressed128[48:64]);
        uint128 yHi = uint128(bytes16(uncompressed128[80:96]));
        uint256 yLo = uint256(bytes32(uncompressed128[96:128]));
        // Reject the EIP-2537 infinity encoding: compressing it would yield a
        // valid-looking 0x80… reference, defeating the trust-anchor bind.
        if (xHead == 0 && xTail == 0 && yHi == 0 && yLo == 0) revert InfinityPoint();

        bool yGreaterHalf = yHi != HALF_HI ? yHi > HALF_HI : yLo > HALF_LO;
        bytes32 flags = bytes32(uint256(yGreaterHalf ? 0xa0 : 0x80) << 248);
        return abi.encodePacked(xHead | flags, xTail);
    }

    /// 2-pair input: (sig‖-G2gen) ‖ (H‖pk) = 768 bytes.
    /// Equation: e(sig, -G2gen) · e(H, pk) == 1.
    function _pairingHolds(bytes memory sig, bytes memory h) internal view returns (bool) {
        bytes memory input = bytes.concat(sig, NEG_G2_GENERATOR, h, PUBLIC_KEY);
        (bool ok, bytes memory out) = PAIRING.staticcall(input);
        return ok && out.length == 32 && bytes32(out) == bytes32(uint256(1));
    }

    /// G1MSM(k × (point ‖ scalar)) -> 128 B G1, or empty when the precompile refuses the
    /// input.
    function _g1Msm(bytes memory terms) internal view returns (bytes memory) {
        (bool ok, bytes memory out) = G1MSM.staticcall(terms);
        if (!ok || out.length != 128) return "";
        return out;
    }

    /// terms[index] = point[offset:offset+128] ‖ coefficient, the 160-byte MSM term layout.
    function _writeTerm(bytes memory terms, uint256 index, bytes memory point, uint256 offset, bytes32 coefficient)
        internal
        pure
    {
        assembly ("memory-safe") {
            let dest := add(add(terms, 32), mul(index, 160))
            mcopy(dest, add(add(point, 32), offset), 128)
            mstore(add(dest, 128), coefficient)
        }
    }

    /// Whether points[offset:offset+128] is the EIP-2537 infinity encoding, all zero.
    function _isZero128(bytes memory points, uint256 offset) internal pure returns (bool) {
        bytes32 acc;
        for (uint256 word = 0; word < 128; word += 32) {
            bytes32 chunk;
            assembly ("memory-safe") {
                chunk := mload(add(add(points, 32), add(offset, word)))
            }
            acc |= chunk;
        }
        return acc == 0;
    }

    /// hash_to_curve(digest) for BLS12-381 G1 per RFC 9380: expand_message_xmd(SHA-256)
    /// to 128 uniform bytes, two field elements from them, MAP_FP_TO_G1 on each and their
    /// sum. The map precompile clears the cofactor (see {_mapToG1}).
    function _hashToG1(bytes32 digest) internal view returns (bytes memory h) {
        // expand_message_xmd(SHA-256): b_in=32, s_in=64, ell=4, len_in_bytes=128.
        // b_0 = H(Z_pad ‖ msg ‖ I2OSP(128, 2) ‖ I2OSP(0, 1) ‖ DST'), Z_pad = 64 × 0x00.
        bytes32 b0 = sha256(abi.encodePacked(bytes32(0), bytes32(0), digest, uint16(128), uint8(0), DST_PRIME));
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), DST_PRIME));
        bytes32 b2 = sha256(abi.encodePacked(b0 ^ b1, uint8(2), DST_PRIME));
        bytes32 b3 = sha256(abi.encodePacked(b0 ^ b2, uint8(3), DST_PRIME));
        bytes32 b4 = sha256(abi.encodePacked(b0 ^ b3, uint8(4), DST_PRIME));

        // uniform = b1 ‖ b2 ‖ b3 ‖ b4; u_0 from its first 64 bytes, u_1 from the rest.
        bytes memory points = new bytes(256);
        _mapToG1(b1, b2, points, 0);
        _mapToG1(b3, b4, points, 128);

        h = new bytes(128);
        address g1Add = G1ADD;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), g1Add, add(points, 32), 256, add(h, 32), 128)
            ok := and(ok, eq(returndatasize(), 128))
        }
        if (!ok) revert PrecompileFailed();
    }

    /// points[offset:offset+128] = MAP_FP_TO_G1((hi ‖ lo) mod p), the 64-to-48-byte
    /// reduction done by MODEXP(base, 1, p) and written straight into the 16-byte-padded
    /// input the map takes.
    /// @dev Security note: the map precompile is expected to clear the BLS12-381 G1
    ///      cofactor per RFC 9380 §6.6.3 (the EIP-2537 field-to-curve annex prescribes
    ///      `map_to_curve_simple_swu → iso_map → clear_cofactor`).
    ///      As of this audit (2026-05-25):
    ///        - reth/revm:    cleared (blst `src/map_to_g1.c`
    ///                        `POINTonE1_times_minus_z` + `_dadd`)
    ///        - go-ethereum:  cleared (gnark-crypto
    ///                        `ecc/bls12-381/hash_to_g1.go::MapToG1`)
    ///      If Fluent's L2 EVM client changes, re-verify cofactor clearing in the new
    ///      implementation. Drift fails closed (PAIRING rejects non-prime-order point →
    ///      verify returns false → nothing is published).
    function _mapToG1(bytes32 hi, bytes32 lo, bytes memory points, uint256 offset) internal view {
        // MODEXP ABI: I2OSP(64,32) ‖ I2OSP(1,32) ‖ I2OSP(48,32) ‖ base(64) ‖ 0x01 ‖ p(48).
        bytes memory reduction = abi.encodePacked(uint256(64), uint256(1), uint256(48), hi, lo, uint8(1), P);
        bytes memory fp = new bytes(64);
        address modexp = MODEXP;
        address mapFpToG1 = MAP_FP_TO_G1;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), modexp, add(reduction, 32), mload(reduction), add(fp, 48), 48)
            ok := and(ok, eq(returndatasize(), 48))
        }
        if (!ok) revert PrecompileFailed();
        assembly ("memory-safe") {
            ok := staticcall(gas(), mapFpToG1, add(fp, 32), 64, add(add(points, 32), offset), 128)
            ok := and(ok, eq(returndatasize(), 128))
        }
        if (!ok) revert PrecompileFailed();
    }

    /// @notice Revert InfinityPoint if every byte of the EIP-2537 point is
    ///         zero (PAIRING silently skips infinity pairs ⇒ forgeable).
    function _rejectInfinity(bytes memory point) internal pure {
        for (uint256 i = 0; i < point.length; i++) {
            if (point[i] != 0) return;
        }
        revert InfinityPoint();
    }
}
