// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {INitroVerifier} from "contracts/interfaces/INitroVerifier.sol";
import {NitroVerifier} from "contracts/verifier/NitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

contract NitroVerifierTest is Test {
    address internal admin = makeAddr("admin");
    NitroVerifier internal verifier;
    MockSp1Verifier internal attestationVerifier;

    function setUp() public {
        attestationVerifier = new MockSp1Verifier();
        verifier = new NitroVerifier(address(attestationVerifier), admin);
    }

    function test_vkeyRotation_respectsTimelock() public {
        bytes32 newVKey = keccak256("new-vkey");

        vm.prank(admin);
        verifier.proposeVKeyUpdate(newVKey);

        vm.prank(admin);
        vm.expectRevert(INitroVerifier.TimelockNotExpired.selector);
        verifier.executeVKeyUpdate();

        vm.warp(block.timestamp + verifier.VKEY_UPDATE_DELAY());
        vm.prank(admin);
        verifier.executeVKeyUpdate();

        assertEq(verifier.getProgramVKey(), newVKey);
        assertEq(verifier.pendingVKey(), bytes32(0));
    }

    function test_verifyAttestation_whitelistsPubkey() public {
        address pubkey = makeAddr("pubkey");
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, hex"1234");
        assertTrue(verifier.verifiedPubkeys(pubkey));
    }

    function test_revokeAttestation_removesPubkey() public {
        address pubkey = makeAddr("pubkey");
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, hex"1234");
        vm.prank(admin);
        verifier.revokeAttestation(pubkey);
        assertFalse(verifier.verifiedPubkeys(pubkey));
    }

    function test_verifyBlock_requiresAttestedSigner() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);

        vm.prank(admin);
        verifier.verifyAttestation(signer, hex"1234");

        bytes32 parentHash = keccak256("parent");
        bytes32 blockHash = keccak256("block");
        bytes32 withdrawalHash = keccak256("withdrawal");
        bytes32 depositHash = keccak256("deposit");
        bytes32[] memory blobHashes = new bytes32[](0);
        bytes32 digest = sha256(abi.encode(parentHash, blockHash, withdrawalHash, depositHash, blobHashes));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address signer_ = verifier.verifyBlock(parentHash, blockHash, withdrawalHash, depositHash, signature, blobHashes);
        assertEq(signer_, signer);
    }

    function test_verifyBatch_requiresAttestedSigner() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);

        vm.prank(admin);
        verifier.verifyAttestation(signer, hex"1234");

        bytes32 batchRoot = keccak256("batch");
        bytes32[] memory blobHashes = new bytes32[](2);
        blobHashes[0] = keccak256("blob0");
        blobHashes[1] = keccak256("blob1");

        bytes32 digest = sha256(abi.encode(batchRoot, blobHashes));
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

        bytes32 digest = sha256(abi.encode(batchRoot, blobHashes));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(INitroVerifier.SignerNotAttested.selector);
        verifier.verifyBatch(batchRoot, blobHashes, signature);
    }

    function test_RevertIf_verifyAttestation_pubkeyAlreadyVerified() public {
        address pubkey = makeAddr("pubkey");
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, hex"1234");
        vm.expectRevert(INitroVerifier.PubkeyAlreadyVerified.selector);
        vm.prank(admin);
        verifier.verifyAttestation(pubkey, hex"1234");
    }

    function test_RevertIf_proposeVKeyUpdate_zeroVKey() public {
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.ZeroVKey.selector);
        verifier.proposeVKeyUpdate(bytes32(0));
    }

    function test_RevertIf_cancelVKeyUpdate_noPendingUpdate() public {
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.NoPendingUpdate.selector);
        verifier.cancelVKeyUpdate();
    }

    function test_RevertIf_revokeAttestation_pubkeyNotVerified() public {
        vm.prank(admin);
        vm.expectRevert(INitroVerifier.PubkeyNotVerified.selector);
        verifier.revokeAttestation(makeAddr("unknown"));
    }

    function test_RevertIf_verifyBlock_invalidSignatureLength() public {
        vm.expectRevert(INitroVerifier.InvalidSignatureLength.selector);
        verifier.verifyBlock(keccak256("a"), keccak256("b"), keccak256("c"), keccak256("d"), hex"0102", new bytes32[](0));
    }
}
