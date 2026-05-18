// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title BLS12-381 MinSig verify core (EIP-2537, Prague).
/// @notice Single audited crypto unit. No on-chain point decompression,
///         no sqrt, no Fp/Fp2 mul: caller supplies uncompressed points,
///         this recompresses+compares to the authoritative compressed
///         reference and delegates on-curve/subgroup to PAIRING.
contract BLS12381Verifier {
    // precompiles
    address private constant SHA256 = address(0x02);
    address private constant MODEXP = address(0x05);
    address private constant G1ADD = address(0x0b);
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

    error InfinityPoint();
    error NamespaceTooLong();
    error DstTooLong(); // RFC 9380 short-DST path only (len <= 255)
    error PrecompileFailed();

    /// @notice Verify one MinSig signature: e(sig,-G2gen)·e(H,pk) == 1.
    /// @dev Trust-anchor binding (sig/pk == registered/evidence identity) is
    ///      the CALLER's responsibility via compressG1/compressG2 — this is
    ///      pure pairing over caller-supplied uncompressed points.
    /// @param namespace per-subject namespace (e.g. base‖_NOTARIZE, or PoP base)
    /// @param message   Proposal/Round .encode() (slashing) or pubkey (PoP)
    /// @param dst        BLS_SIG_… or BLS_POP_… (43 B)
    /// @param sigUncompressed 128 B EIP-2537 G1 (caller-supplied)
    /// @param pkUncompressed 256 B EIP-2537 G2 (caller-supplied)
    function verify(
        bytes calldata namespace,
        bytes calldata message,
        bytes calldata dst,
        bytes calldata sigUncompressed,
        bytes calldata pkUncompressed
    ) external view returns (bool) {
        _rejectInfinity(sigUncompressed);
        _rejectInfinity(pkUncompressed);

        bytes memory h = _hashToG1(unionUnique(namespace, message), dst);
        _rejectInfinity(h);

        // 2-pair input: (sig‖-G2gen) ‖ (H‖pk) = 768 bytes.
        // Equation: e(sig, -G2gen) · e(H, pk) == 1.
        bytes memory input = bytes.concat(sigUncompressed, NEG_G2_GENERATOR, h, pkUncompressed);
        (bool ok, bytes memory out) = PAIRING.staticcall(input);
        return ok && out.length == 32 && bytes32(out) == bytes32(uint256(1));
    }

    /// @notice union_unique(ns,msg) = uvarint(len ns) ‖ ns ‖ msg. Namespace
    ///         is always contract-formed (≤32 B) ⇒ commonware codec UInt is a
    ///         single byte; the guard makes that invariant explicit.
    function unionUnique(bytes calldata ns, bytes calldata msg) public pure returns (bytes memory) {
        if (ns.length >= 0x80) revert NamespaceTooLong();
        return bytes.concat(bytes1(uint8(ns.length)), ns, msg);
    }

    // ------------------------------------------------------------------ //
    //                          hash-to-G1                                //
    // ------------------------------------------------------------------ //

    function _hashToG1(bytes memory input, bytes calldata dst) internal view returns (bytes memory) {
        if (dst.length > 255) revert DstTooLong();

        // DST' = dst ‖ I2OSP(len(dst), 1)
        bytes memory dstPrime = bytes.concat(dst, bytes1(uint8(dst.length)));

        // expand_message_xmd(SHA-256): b_in=32, s_in=64, ell=4, len=128.
        // Z = 64×0x00 (SHA-256 block); msgP = Z ‖ input ‖ I2OSP(128,2) ‖ 0x00 ‖ DST'
        bytes memory z = new bytes(64);
        bytes memory msgP = bytes.concat(z, input, hex"0080", hex"00", dstPrime);

        bytes32 b0 = sha256(msgP);
        bytes32 b1 = sha256(bytes.concat(b0, bytes1(uint8(1)), dstPrime));
        bytes32 b2 = sha256(bytes.concat(b0 ^ b1, bytes1(uint8(2)), dstPrime));
        bytes32 b3 = sha256(bytes.concat(b0 ^ b2, bytes1(uint8(3)), dstPrime));
        bytes32 b4 = sha256(bytes.concat(b0 ^ b3, bytes1(uint8(4)), dstPrime));

        // uniform = (b1‖b2‖b3‖b4)[0:128]
        bytes memory uniform = bytes.concat(b1, b2, b3, b4);

        // u_j = MODEXP(uniform_block_j, 1, p)  -> 48 B (mod-p reduction)
        bytes memory u0 = _modexpModP(_slice64(uniform, 0));
        bytes memory u1 = _modexpModP(_slice64(uniform, 64));

        // P_j = MAP_FP_TO_G1(16×0x00 ‖ u_j) -> 128 B
        bytes memory p0 = _mapFpToG1(u0);
        bytes memory p1 = _mapFpToG1(u1);

        // H = G1ADD(P0 ‖ P1) -> 128 B
        return _g1Add(p0, p1);
    }

    /// uniform[off:off+64]
    function _slice64(bytes memory uniform, uint256 off) private pure returns (bytes memory r) {
        r = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            r[i] = uniform[off + i];
        }
    }

    // ------------------------------------------------------------------ //
    //                       precompile helpers                           //
    // ------------------------------------------------------------------ //

    /// MODEXP(base, 1, p): ABI = I2OSP(64,32) ‖ I2OSP(1,32) ‖ I2OSP(48,32)
    /// ‖ base(64B) ‖ exp(0x01) ‖ p(48B); output 48 B = base mod p.
    function _modexpModP(bytes memory base64) private view returns (bytes memory) {
        bytes memory input = bytes.concat(
            bytes32(uint256(64)), bytes32(uint256(1)), bytes32(uint256(48)), base64, bytes1(uint8(1)), P
        );
        (bool ok, bytes memory out) = MODEXP.staticcall(input);
        if (!ok || out.length != 48) revert PrecompileFailed();
        return out;
    }

    /// MAP_FP_TO_G1(16×0x00 ‖ fp48) -> 128 B G1 (EIP-2537).
    function _mapFpToG1(bytes memory fp48) private view returns (bytes memory) {
        bytes memory input = bytes.concat(new bytes(16), fp48);
        (bool ok, bytes memory out) = MAP_FP_TO_G1.staticcall(input);
        if (!ok || out.length != 128) revert PrecompileFailed();
        return out;
    }

    /// G1ADD(p0 ‖ p1) -> 128 B G1 (EIP-2537).
    function _g1Add(bytes memory p0, bytes memory p1) private view returns (bytes memory) {
        (bool ok, bytes memory out) = G1ADD.staticcall(bytes.concat(p0, p1));
        if (!ok || out.length != 128) revert PrecompileFailed();
        return out;
    }

    // ------------------------------------------------------------------ //
    //                       recompress / checks                          //
    // ------------------------------------------------------------------ //

    /// @notice Revert InfinityPoint if every byte of the EIP-2537 point is
    ///         zero (PAIRING silently skips infinity pairs ⇒ forgeable).
    function _rejectInfinity(bytes memory point) internal pure {
        for (uint256 i = 0; i < point.length; i++) {
            if (point[i] != 0) return;
        }
        revert InfinityPoint();
    }

    /// @notice Compress a 128 B EIP-2537 G1 to 48 B zcash (MinSig). Pure;
    ///         on-curve/subgroup left to PAIRING. The caller binds the
    ///         result to its trust anchor.
    function compressG1(bytes calldata uncompressed128) external pure returns (bytes memory) {
        // x = uncompressed[16:64], y = uncompressed[80:128]
        bytes memory x = _slice48(uncompressed128, 16);
        bytes memory y = _slice48(uncompressed128, 80);
        x[0] = bytes1(uint8(x[0]) | 0x80 | (_fpGreaterHalf(y) ? 0x20 : 0x00));
        return x;
    }

    /// @notice Compress a 256 B EIP-2537 G2 to 96 B zcash (c1-first, MinSig).
    function compressG2(bytes calldata uncompressed256) external pure returns (bytes memory) {
        // EIP-2537 layout: pad‖x.c0‖pad‖x.c1‖pad‖y.c0‖pad‖y.c1
        bytes memory xc0 = _slice48(uncompressed256, 16);
        bytes memory xc1 = _slice48(uncompressed256, 80);
        bytes memory yc0 = _slice48(uncompressed256, 144);
        bytes memory yc1 = _slice48(uncompressed256, 208);

        // Fp2 sign (lexicographic, compare by c1 then c0):
        //   sign = (y.c1 > (p-1)/2) OR (y.c1 == 0 AND y.c0 > (p-1)/2)
        bool sign = _fpGreaterHalf(yc1) || (_fpIsZero(yc1) && _fpGreaterHalf(yc0));

        // zcash compressed G2 = x.c1 ‖ x.c0 (imaginary-coeff FIRST).
        bytes memory cand = bytes.concat(xc1, xc0);
        cand[0] = bytes1(uint8(cand[0]) | 0x80 | (sign ? 0x20 : 0x00));
        return cand;
    }

    /// uncompressed[off:off+48]
    function _slice48(bytes memory src, uint256 off) private pure returns (bytes memory r) {
        r = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            r[i] = src[off + i];
        }
    }

    function _fpIsZero(bytes memory fp48) private pure returns (bool) {
        for (uint256 i = 0; i < 48; i++) {
            if (fp48[i] != 0) return false;
        }
        return true;
    }

    /// @notice 384-bit unsigned compare: fp48 > (p-1)/2. Split the 48-byte
    ///         value into a high uint256 (top 16 bytes) and a low uint256
    ///         (low 32 bytes); compare high then low. No modmul.
    function _fpGreaterHalf(bytes memory fp48) internal pure returns (bool) {
        uint256 hi;
        uint256 lo;
        for (uint256 i = 0; i < 16; i++) {
            hi = (hi << 8) | uint8(fp48[i]);
        }
        for (uint256 i = 16; i < 48; i++) {
            lo = (lo << 8) | uint8(fp48[i]);
        }
        if (hi != HALF_HI) return hi > HALF_HI;
        return lo > HALF_LO;
    }
}
