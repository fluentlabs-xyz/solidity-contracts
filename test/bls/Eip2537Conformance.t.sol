// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Eip2537ConformanceVectors as V} from "./Eip2537ConformanceVectors.sol";

/// @notice Tier-3 authoritative conformance gate: runs Rust-produced
///         (fluentbase-bls::encoding) EIP-2537 bytes through the REAL
///         EIP-2537 pairing precompile (0x0f) and asserts the on-chain
///         result matches the expected boolean. evm_version=prague.
contract Eip2537ConformanceTest is Test {
    address internal constant PAIRING = address(0x0f);

    uint256 internal constant PUBKEY_LEN = 256;
    uint256 internal constant G1_LEN = 128; // sig and hm

    function _assemblePairingInput(bytes memory sig, bytes memory negG2gen, bytes memory hm, bytes memory pubkey)
        internal
        pure
        returns (bytes memory)
    {
        // 2-pair input: (sig‖-G2gen) ‖ (hm‖pubkey) = 768 bytes.
        // Equation: e(sig, -G2gen) · e(hm, pubkey) == 1  (Commonware MinSig::verify).
        return bytes.concat(sig, negG2gen, hm, pubkey);
    }

    function _pairing(bytes memory input) internal view returns (bool callOk, bytes32 result) {
        bytes memory out;
        (callOk, out) = PAIRING.staticcall(input);
        if (callOk && out.length == 32) {
            result = abi.decode(out, (bytes32));
        }
    }

    function test_Eip2537Conformance_AllVectors() public view {
        V.Vector[] memory vs = V.all();
        assertGt(vs.length, 0, "no conformance vectors compiled in");

        for (uint256 i = 0; i < vs.length; i++) {
            V.Vector memory v = vs[i];

            // Size guards — catch a hand-mirror paste error early.
            assertEq(v.pubkey.length, PUBKEY_LEN, v.label);
            assertEq(v.sig.length, G1_LEN, v.label);
            assertEq(v.hm.length, G1_LEN, v.label);

            bytes memory input = _assemblePairingInput(v.sig, V.NEG_G2_GENERATOR, v.hm, v.pubkey);
            assertEq(input.length, 768, v.label);

            (bool callOk, bytes32 result) = _pairing(input);

            if (v.expectedValid) {
                // Valid signature: precompile succeeds and returns 1.
                assertTrue(callOk, string.concat("staticcall reverted: ", v.label));
                assertEq(result, bytes32(uint256(1)), string.concat("not valid: ", v.label));
            } else {
                // Invalid: either the precompile reverts (malformed/off-curve/
                // not-in-subgroup point) OR it succeeds with 0. Both are "not valid".
                bool rejected = (!callOk) || (result == bytes32(uint256(0)));
                assertTrue(rejected, string.concat("forged vector accepted: ", v.label));
            }
        }
    }

    /// Sanity: the precompile address is actually populated at Prague
    /// (guards against a wrong evm_version silently making every call a
    /// no-op success returning empty data).
    function test_Eip2537_PairingPrecompile_IsPresent() public view {
        // Empty input is invalid per EIP-2537 (len 0 not a multiple of 384)
        // → a real precompile reverts; an absent precompile "succeeds" empty.
        (bool ok, bytes memory out) = PAIRING.staticcall("");
        assertFalse(
            ok && out.length == 0, "EIP-2537 pairing precompile not present at 0x0f (check evm_version=prague)"
        );
    }
}
