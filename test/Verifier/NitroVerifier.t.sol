// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {NitroVerifier} from "../../contracts/verifier/NitroVerifier.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";

contract NitroVerifierTest is Test {
    address internal admin = makeAddr("admin");
    NitroVerifier internal verifier;
    VerifierMock internal attestationVerifier;

    function setUp() public {
        attestationVerifier = new VerifierMock();
        verifier = new NitroVerifier(address(attestationVerifier), admin);
    }

    function test_vkeyRotation_respectsTimelock() public {
        bytes32 newVKey = keccak256("new-vkey");

        vm.prank(admin);
        verifier.proposeVKeyUpdate(newVKey);

        vm.prank(admin);
        vm.expectRevert(NitroVerifier.TimelockNotExpired.selector);
        verifier.executeVKeyUpdate();

        vm.warp(block.timestamp + verifier.VKEY_UPDATE_DELAY());
        vm.prank(admin);
        verifier.executeVKeyUpdate();

        assertEq(verifier.PROGRAM_VKEY(), newVKey);
        assertEq(verifier.pendingVKey(), bytes32(0));
    }

    function test_verifyAttestation_andRevoke() public {
        address pubkey = makeAddr("pubkey");

        verifier.verifyAttestation(pubkey, hex"1234");
        assertTrue(verifier.verifiedPubkeys(pubkey));

        vm.prank(admin);
        verifier.revokeAttestation(pubkey);
        assertFalse(verifier.verifiedPubkeys(pubkey));
    }

    function test_verifyBlock_requiresAttestedSigner() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);

        verifier.verifyAttestation(signer, hex"1234");

        bytes32 parentHash = keccak256("parent");
        bytes32 blockHash = keccak256("block");
        bytes32 withdrawalHash = keccak256("withdrawal");
        bytes32 depositHash = keccak256("deposit");
        bytes32 digest = verifier.computeSigningPayload(parentHash, blockHash, withdrawalHash, depositHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recovered = verifier.verifyBlock(parentHash, blockHash, withdrawalHash, depositHash, signature);

        assertEq(recovered, signer);
        assertTrue(verifier.verifiedBlocks(blockHash));
    }
}
