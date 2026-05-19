// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {BLS12381VerifierHarness} from "./BLS12381VerifierHarness.sol";

/// @notice Tier-3 authoritative conformance gate for on-chain hash-to-G1 +
///         the end-to-end BLS verify equation. Vectors are hand-mirrored
///         from the canonical Rust corpus
///         `crates/bls/tests/hash_to_g1_conformance.rs` (EXPECTED_H +
///         VERIFY_EXPECTED). Any change to the Rust constants MUST be
///         mirrored here in the same PR — divergence IS the conformance
///         failure this gate exists to surface. evm_version=prague.
contract BlsHashToG1ConformanceTest is Test {
    BLS12381VerifierHarness internal v = new BLS12381VerifierHarness();

    // DSTs (43 B each), mirrored from MinSig::PROOF_OF_POSSESSION / MESSAGE.
    bytes internal constant DST_POP = bytes("BLS_POP_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_");
    bytes internal constant DST_SIG = bytes("BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_");

    /// hashToG1 corpus row: ns, msg, dst, expected H (128 B EIP-2537 G1).
    struct HRow {
        string label;
        bytes ns;
        bytes msg;
        bytes dst;
        bytes expectedH;
    }

    function _hRows() internal pure returns (HRow[] memory r) {
        r = new HRow[](6);
        r[0] = HRow({
            label: "pop_main_pk96",
            ns: hex"464c55454e545f44504f535f56315f0000000000005202",
            msg: hex"7f6f2ccdb23f2abb7b69278e947c01c6160a31cf02c19d06d0f6e5ab1d768b95117be1de549d1d4322c4711f11efa0c5137903124f85fc37c761ffc91ace30cbac7f0d9eaea4d4bf5438b887e34d0cf87e7f98d97da70eff001850487b2cae23",
            dst: DST_POP,
            expectedH: hex"000000000000000000000000000000001123a1bf57c9b9c44a80d453d11f3a006e69f8a76447a77ae5b12151e2f77f175212264b1f247f14854b4228134e26030000000000000000000000000000000005dff48ee582b254859f3ae7c6517cca20a765d443f0ff3570a020710340036b8132985936811892140df3254d826651"
        });
        r[1] = HRow({
            label: "pop_chain0_empty",
            ns: hex"464c55454e545f44504f535f56315f0000000000000000",
            msg: hex"",
            dst: DST_POP,
            expectedH: hex"0000000000000000000000000000000008946433018a17d3063648f3619d43df7decab5af6c2386f6f1c521619dcda4225be0b22ef926b6d1ceaead5cc6ffc340000000000000000000000000000000002af7b8ada472e08de992fa07603f51a1a3af99dbd5c0a5238c3f28a7e0990ba4e57b9bb174af6b5826db77f55472007"
        });
        r[2] = HRow({
            label: "notarize_main_proposal",
            ns: hex"464c55454e545f44504f535f56315f00000000000052025f4e4f544152495a45",
            msg: hex"1fbec814b18b1d4c3eaa7cec41007e04bf0a98453b06ec7582aa29882c52eb7eb232b4635812333125e8b5ae3d8e7e4599a0df8274e488fc58e06320e32f28cb1ade3723ec82323d52a514862f455448",
            dst: DST_SIG,
            expectedH: hex"000000000000000000000000000000000721ba0b4e1ad4d630bcc7e1058b6d35572c7993014060b677957b9975a5d65de1cd082e499c245659af92a2d7f195000000000000000000000000000000000002fc749cccd738bd027e4d60d6cfe5e903ded681795313979c0260e467da04c129b90a62750a6e4804d0856780e96f20"
        });
        r[3] = HRow({
            label: "nullify_main_round",
            ns: hex"464c55454e545f44504f535f56315f00000000000052025f4e554c4c494659",
            msg: hex"ecd9c4a53ea15f18447b08",
            dst: DST_SIG,
            expectedH: hex"00000000000000000000000000000000159ae2356a8ea6b357ec562d1e1fa31ca0165c1c9bac4ef67603f7f3a40361a92d2ec5b39447fcb9699f7ce53b4b859e0000000000000000000000000000000001f630e8b43cebf3b42e647571b7136b2d4279903c3c6c5f88d23bba5d3a71ea2822dfea45c024bb5f1044311004b44e"
        });
        r[4] = HRow({
            label: "finalize_chainmax_long",
            ns: hex"464c55454e545f44504f535f56315fffffffffffffffff5f46494e414c495a45",
            msg: hex"e463bcb1a6e57288ffd4671503082fa8656e3eacb78fb1925f8a7c76400e8e95a7f53b0a4c9a629f54f43236705c34fa16939e67c38551aa301a8d033d345b50f2b2784efafffd6198e583bc60b1b95cc0b4fbf40dcaab6f409acd7f52e325e22c5ef269071e7d1141732b89e285899985e169ac8b7f50e69e8621b35b3c9f55044083e1fe124bfc5b54460d97ff270415566b4e965b3c24e322e8ad473432c519a1177ff508029d14ea9e63fcf2c39fc45156e9898ce7a605aa23614dcad9b8269848939263d7a0",
            dst: DST_SIG,
            expectedH: hex"000000000000000000000000000000000124d66d4398ab8e1c815ff26a6fd5ba8d40e033c47ac97e6063db6c0145987c27efe6d505776543c74d754b4fd20f6800000000000000000000000000000000047535cc58be29cb65abc68f10c67b26d860c22c28aab281e7dffc98b54692c871a8eba60256cabbe2e18e73d0f998de"
        });
        r[5] = HRow({
            label: "sig_chain0_short",
            ns: hex"464c55454e545f44504f535f56315f00000000000000005f4e4f544152495a45",
            msg: hex"7a",
            dst: DST_SIG,
            expectedH: hex"000000000000000000000000000000000d55c8664d8df37c52c4d54e7d9d3c768dfdade91cf7ebe817b0cd5a672fa80a30bc2098a59cf1bf87238d1392f9337500000000000000000000000000000000049cd5bb24ceea9cf25370adefd2bbb91aea9121d213543c4b11541b818b86ef817b020e966d07fc5134f0e50e1a9033"
        });
    }

    function test_hashToG1_matchesCommonware() public view {
        HRow[] memory rows = _hRows();
        for (uint256 i = 0; i < rows.length; i++) {
            HRow memory row = rows[i];
            bytes memory got = v.hashToG1Exposed(v.unionUnique(row.ns, row.msg), row.dst);
            assertEq(got, row.expectedH, row.label);
        }
    }

    // ---- end-to-end verify corpus (PoP DST, real keys) ---- //
    // PoP message == the pubkey, so a valid PoP signature is a complete
    // verify tuple. ns = fluent_namespace(C_MAIN), dst = POP.

    bytes internal constant VERIFY_NS = hex"464c55454e545f44504f535f56315f0000000000005202";

    // verify_pop_valid
    bytes internal constant SIG_UNC_VALID =
        hex"00000000000000000000000000000000027ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e00000000000000000000000000000000109a4722abb94b2ffb8685abe75b4fc8336d2f6534b64fee49baa07ab7357de65036fb93ee119860768cc65daa4c7b1e";
    bytes internal constant SIG_REF_VALID =
        hex"a27ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e";

    // verify_pop_tampered_sig (valid sig for a DIFFERENT key — well-formed
    // G1 point, so encoding/pairing run and return ≠ 1).
    bytes internal constant SIG_UNC_TAMPERED =
        hex"000000000000000000000000000000001733f7c8769099b3c5f2601d80aec5f35b4e0086b9d4f2092140e0f40002c328ceb71b469d9456ed4caa27e340a78d9b00000000000000000000000000000000058d6642e4126b5d37407dcb4a34911ceab3992b1524ce67bf5fdd2688374a692839dba9ac3ba6ab3305cf51200d49ca";
    bytes internal constant SIG_REF_TAMPERED =
        hex"9733f7c8769099b3c5f2601d80aec5f35b4e0086b9d4f2092140e0f40002c328ceb71b469d9456ed4caa27e340a78d9b";

    bytes internal constant PK_UNC =
        hex"000000000000000000000000000000000727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d550000000000000000000000000000000012b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb000000000000000000000000000000000f9da5ef5089f62dc55ec91c2459f6ed3fd9981f8d4926ad90dca0314603ae4af86c8fa12bdd2569867f05a24908b7fc0000000000000000000000000000000009ac1ba2c6341d99ba0d6bfab8ea6a3a58726e787ab22b899cd95acfec350c1fc09f5fcbbef992106b61e45eb9158354";
    bytes internal constant PK_REF =
        hex"92b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb0727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d55";

    function test_verify_endToEnd() public view {
        // On-chain compression must equal the corpus compressed vectors.
        assertEq(v.compressG2(PK_UNC), PK_REF, "compressG2(PK_UNC)");
        assertEq(v.compressG1(SIG_UNC_VALID), SIG_REF_VALID, "compressG1(SIG_UNC_VALID)");

        // pkRef is also the message for both verify rows.
        bool valid = v.verify(VERIFY_NS, PK_REF, DST_POP, SIG_UNC_VALID, PK_UNC);
        assertTrue(valid, "verify_pop_valid");

        // Tampered sig: PAIRING != 1, must NOT revert — assert false.
        bool tampered = v.verify(VERIFY_NS, PK_REF, DST_POP, SIG_UNC_TAMPERED, PK_UNC);
        assertFalse(tampered, "verify_pop_tampered_sig");
    }

    // ---- negative tests ---- //

    function test_verify_revertsInfinity_sig() public {
        bytes memory zeroSig = new bytes(128);
        vm.expectRevert(BLS12381Verifier.InfinityPoint.selector);
        v.verify(VERIFY_NS, PK_REF, DST_POP, zeroSig, PK_UNC);
    }

    function test_verify_revertsInfinity_pk() public {
        bytes memory zeroPk = new bytes(256);
        vm.expectRevert(BLS12381Verifier.InfinityPoint.selector);
        v.verify(VERIFY_NS, PK_REF, DST_POP, SIG_UNC_VALID, zeroPk);
    }

    // ---- precompile presence guards ---- //
    // Mirror Eip2537Conformance.t.sol's present-guard: an absent precompile
    // "succeeds" with empty output; a real one rejects malformed input.

    function test_Bls_Precompiles_Present() public view {
        // PAIRING 0x0f: empty input invalid (not a multiple of 384) → reverts.
        (bool okPair, bytes memory oPair) = address(0x0f).staticcall("");
        assertFalse(okPair && oPair.length == 0, "PAIRING 0x0f absent (check evm_version=prague)");

        // MAP_FP_TO_G1 0x10: empty input invalid (needs 64 B) → reverts.
        (bool okMap, bytes memory oMap) = address(0x10).staticcall("");
        assertFalse(okMap && oMap.length == 0, "MAP_FP_TO_G1 0x10 absent");

        // G1ADD 0x0b: empty input invalid (needs 256 B) → reverts.
        (bool okAdd, bytes memory oAdd) = address(0x0b).staticcall("");
        assertFalse(okAdd && oAdd.length == 0, "G1ADD 0x0b absent");

        // SHA-256 0x02: present iff sha256("") == the known digest.
        (bool okSha, bytes memory oSha) = address(0x02).staticcall("");
        assertTrue(okSha, "SHA-256 0x02 absent");
        assertEq(
            bytes32(oSha), bytes32(0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855), "SHA-256 wrong"
        );

        // MODEXP 0x05: modexp(0,0,0) with zero lengths → succeeds, empty out.
        // Use a real reduction to confirm it computes: 5 mod 3 == 2.
        bytes memory mxIn = bytes.concat(
            bytes32(uint256(1)), bytes32(uint256(1)), bytes32(uint256(1)), bytes1(uint8(5)), bytes1(uint8(1)), bytes1(uint8(3))
        );
        (bool okMx, bytes memory oMx) = address(0x05).staticcall(mxIn);
        assertTrue(okMx && oMx.length == 1 && uint8(oMx[0]) == 2, "MODEXP 0x05 absent or wrong");
    }
}
