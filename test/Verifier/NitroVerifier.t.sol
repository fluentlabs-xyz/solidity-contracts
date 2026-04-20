// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {INitroVerifier} from "contracts/interfaces/verifiers/INitroVerifier.sol";
import {NitroVerifier} from "contracts/verifier/NitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

contract NitroVerifierTest is Test {
    address internal admin = makeAddr("admin");
    NitroVerifier internal verifier;
    MockSp1Verifier internal attestationVerifier;

    bytes32 internal constant INITIAL_VKEY = bytes32(uint256(0xDEADBEEF));

    function setUp() public {
        attestationVerifier = new MockSp1Verifier();
        verifier = new NitroVerifier(address(attestationVerifier), admin);
        vm.startPrank(admin);
        verifier.updateProgramVKey(INITIAL_VKEY);
        // {verifyAttestation} and {revokeAttestation} are gated by ENCLAVE_ATTESTER_ROLE,
        // a separate role from DEFAULT_ADMIN_ROLE. Grant it to admin so the tests can drive
        // the attestation flow with a single signer.
        verifier.grantRole(verifier.ENCLAVE_ATTESTER_ROLE(), admin);
        vm.stopPrank();
        // Warp past ATTESTATION_MAX_AGE so past-boundary tests do not underflow.
        vm.warp(block.timestamp + 1 days);
    }

    function _attest(address pubkey) internal {
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, uint64(block.timestamp), hex"1234");
    }

    function test_updateProgramVKey_rotatesImmediately() public {
        bytes32 newVKey = keccak256("new-vkey");

        vm.prank(admin);
        verifier.updateProgramVKey(newVKey);

        assertEq(verifier.getProgramVKey(), newVKey);
    }

    function test_verifyAttestation_whitelistsPubkey() public {
        address pubkey = makeAddr("pubkey");
        _attest(pubkey);
        assertTrue(verifier.verifiedPubkeys(pubkey));
    }

    function test_revokeAttestation_removesPubkey() public {
        address pubkey = makeAddr("pubkey");
        _attest(pubkey);
        vm.prank(admin);
        verifier.revokeAttestation(pubkey);
        assertFalse(verifier.verifiedPubkeys(pubkey));
    }

    function test_verifyBatch_requiresAttestedSigner() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);

        _attest(signer);

        bytes32 batchRoot = keccak256("batch");
        bytes32[] memory blobHashes = new bytes32[](2);
        blobHashes[0] = keccak256("blob0");
        blobHashes[1] = keccak256("blob1");

        bytes32 digest = sha256(abi.encode(block.chainid, address(verifier), batchRoot, blobHashes));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recovered = verifier.verifyBatch(batchRoot, blobHashes, signature);
        assertEq(recovered, signer, "recovered signer mismatch");
    }

    function test_RevertIf_verifyBatch_invalidSignatureLength() public {
        vm.expectRevert(INitroVerifier.InvalidSignatureLength.selector);
        verifier.verifyBatch(keccak256("batch"), new bytes32[](0), hex"0102");
    }

    function test_RevertIf_verifyBatch_signerNotAttested() public {
        uint256 signerKey = 0xA11CE;

        bytes32 batchRoot = keccak256("batch");
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = keccak256("blob0");

        bytes32 digest = sha256(abi.encode(block.chainid, address(verifier), batchRoot, blobHashes));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(INitroVerifier.SignerNotAttested.selector);
        verifier.verifyBatch(batchRoot, blobHashes, signature);
    }

    function test_RevertIf_verifyAttestation_pubkeyAlreadyVerified() public {
        address pubkey = makeAddr("pubkey");
        _attest(pubkey);
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.PubkeyAlreadyVerified.selector);
        verifier.verifyAttestation(pubkey, uint64(block.timestamp), hex"1234");
    }

    function test_RevertIf_updateProgramVKey_zeroVKey() public {
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.ZeroVKey.selector);
        verifier.updateProgramVKey(bytes32(0));
    }

    function test_RevertIf_revokeAttestation_pubkeyNotVerified() public {
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.PubkeyNotVerified.selector);
        verifier.revokeAttestation(makeAddr("unknown"));
    }

    // ============ Attestation freshness window ============

    function test_verifyAttestation_attestationTimeAtMaxAge() public {
        address pubkey = makeAddr("pubkey");
        uint64 atBoundary = uint64(block.timestamp - verifier.ATTESTATION_MAX_AGE());
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, atBoundary, hex"1234");
        assertTrue(verifier.verifiedPubkeys(pubkey), "pubkey should be attested at max-age boundary");
    }

    function test_verifyAttestation_acceptsFutureTimestamp() public {
        address pubkey = makeAddr("pubkey");
        uint64 future = uint64(block.timestamp + 1 days);
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, future, hex"1234");
        assertTrue(verifier.verifiedPubkeys(pubkey), "future timestamps should be accepted");
    }

    function test_RevertIf_verifyAttestation_attestationTooOld() public {
        address pubkey = makeAddr("pubkey");
        uint64 tooOld = uint64(block.timestamp - verifier.ATTESTATION_MAX_AGE() - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(INitroVerifier.AttestationExpired.selector, tooOld, block.timestamp));
        verifier.verifyAttestation(pubkey, tooOld, hex"1234");
    }
}
