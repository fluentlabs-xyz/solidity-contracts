// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerifier} from "../interfaces/IVerifier.sol";

/**
 * @title Enclave
 * @notice Smart contract for verifying AWS Nitro Enclave attestations via SP1 zero-knowledge proofs
 * @dev This contract provides two-phase verification:
 *      1. Attestation phase: Verify ZK proof that enclave generated a specific public key
 *      2. Block verification phase: Verify ECDSA signatures from the attested enclave
 */
contract Enclave {
    // ============ State Variables ============

    /// @notice SP1 verifier contract address
    address public immutable verifier;

    /// @notice Hardcoded Program verification key hash for SP1 proof validation
    bytes32 public constant PROGRAM_VKEY = 0x00e34107e4c5284bd4ecc4269c650671038c1e85d9dacb931b534e984f607334;

    /// @notice Hardcoded Expected public key from the enclave (65 bytes with 0x04 prefix)
    /// @dev This is also used directly as the SP1 publicValues since they match exactly
    bytes public constant EXPECTED_PUBKEY =
        hex"045716cab03a4ffe03ec68236c716f62b84fd69a9d77f736bd8414755012ac78b14ac0bb5ec44962985ce96439f8ebbcf7e9e75fc05eef27d9a249672dcf2635b8";

    /// @notice Hardcoded SP1 Groth16 proof bytes
    bytes public constant PROOF_BYTES =
        hex"a4594c5901666e8872eaccc813646698a69a1f2fa9e7b81d704acb9a78857eee046fa6e8009a02888825cafb22baae6fc46cc49c4bea2591d89403666b2f1c3cfd2bc887131080d987a8634646d9cb793bb1a7b604a78e95d2e4bff8e870e5005b2dfc5c28430daa8d7e59e4ee874fe1d50d6151a2d24d5b3b2ad5e7129dfd0c560b28062df2be57b338b3a74a3bc4c4b6b9711ed17e11536f0f366e5a955237827c41dc0433991a9fb4a04e49ebd11d424f22a0680dc1a63a62e2770d92327c9e5624ab27c2eb1df9d0d2f624a5018fdf10d12f10cc97346a3ef7b477101fb50a14783203cb45428ab6c813a7717fe5dbb613e7e4e7304464a4c5d9a3d936dd8a07cadd";

    /// @notice Ethereum address derived from the expected public key
    address public constant ENCLAVE_ADDRESS = 0xfDDb7C36Fe792CFEfc13FAE504b09312548ba6D4;

    /// @notice Flag indicating whether attestation has been successfully verified
    bool public isAttestationVerified;

    /// @notice Mapping to track which blocks have been verified
    /// @dev blockHash => verified status
    mapping(bytes32 => bool) public verifiedBlocks;

    // ============ Events ============

    /// @notice Emitted when attestation is successfully verified
    /// @param pubkey The public key extracted from the ZK proof
    event AttestationVerified(bytes pubkey);

    /// @notice Emitted when a block signature is successfully verified
    /// @param blockHash Hash of the verified block
    /// @param parentHash Hash of the parent block
    event BlockVerified(bytes32 indexed blockHash, bytes32 parentHash);

    // ============ Constructor ============

    /**
     * @notice Initialize the Enclave contract
     * @param _verifier Address of the SP1 verifier contract
     */
    constructor(address _verifier) {
        verifier = _verifier;
    }

    // ============ External Functions ============

    /**
     * @notice Verify the enclave attestation using hardcoded SP1 zero-knowledge proof
     * @dev This function can only be called once.
     */
    function verifyAttestation() external {
        require(!isAttestationVerified, "Already verified");

        // Verify the SP1 zero-knowledge proof using hardcoded values
        IVerifier(verifier).verifyProof(
            PROGRAM_VKEY,
            EXPECTED_PUBKEY, // The public values are exactly the pubkey in this case
            PROOF_BYTES
        );

        // Mark attestation as verified and store the address
        isAttestationVerified = true;

        emit AttestationVerified(EXPECTED_PUBKEY);
    }

    /**
     * @notice Verify a block signature from the attested enclave
     * @dev Can be called multiple times after successful attestation.
     *      Verifies ECDSA signature using the custom signing payload format.
     * @param parentHash Hash of the parent block
     * @param blockHash Hash of the current block
     * @param withdrawalHash Hash of withdrawal events
     * @param depositHash Hash of deposit events
     * @param signature ECDSA signature (65 bytes: r + s + v)
     * @return bool True if verification succeeds
     */
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes calldata signature
    ) external returns (bool) {
        require(isAttestationVerified, "Attestation not verified");
        require(signature.length == 65, "Invalid signature length");

        // Step 1: Compute the signing payload using custom hash scheme
        bytes32 signingPayload = computeSigningPayload(parentHash, blockHash, withdrawalHash, depositHash);

        // Step 2: Recover the signer's address from the ECDSA signature
        address signer = recoverSigner(signingPayload, signature);

        // Step 3: Verify the signer is the attested enclave
        require(signer == ENCLAVE_ADDRESS, "Invalid signer");

        // Step 4: Prevent replay attacks
        require(!verifiedBlocks[blockHash], "Already verified");

        // Mark block as verified
        verifiedBlocks[blockHash] = true;
        emit BlockVerified(blockHash, parentHash);
        return true;
    }

    // ============ Public Functions ============

    /**
     * @notice Compute the signing payload using double SHA256 hash scheme
     * @dev Payload = SHA256(parent || block || withdrawal || deposit || SHA256(parent || block || withdrawal || deposit))
     */
    function computeSigningPayload(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash
    ) public pure returns (bytes32) {
        bytes32 resultHash = sha256(abi.encodePacked(parentHash, blockHash, withdrawalHash, depositHash));

        bytes32 signingPayload = sha256(abi.encodePacked(parentHash, blockHash, withdrawalHash, depositHash, resultHash));

        return signingPayload;
    }

    // ============ Internal Functions ============

    /**
     * @notice Recover the signer address from an ECDSA signature
     */
    function recoverSigner(bytes32 messageHash, bytes calldata signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        return ecrecover(messageHash, v, r, s);
    }
}
