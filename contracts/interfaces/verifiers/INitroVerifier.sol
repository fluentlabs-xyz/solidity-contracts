// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title INitroVerifier
 * @dev Interface for verifying AWS Nitro Enclave attestations and enclave-signed
 *      batch payloads. Supports multiple attested pubkeys simultaneously —
 *      use {AttestationVerified} and {AttestationRevoked} events for off-chain enumeration.
 *
 *      Same-chain replay protection (batchRoot deduplication) is the caller's
 *      responsibility. Cross-chain and cross-deployment replay is prevented by domain
 *      separation: payloads include `block.chainid` and `address(this)`.
 */
interface INitroVerifier {
    // ============ Errors ============

    /**
     * @notice Zero address passed where a non-zero address is required.
     * @dev selector: 0xd92e233d
     */
    error ZeroAddress();

    /**
     * @notice Zero bytes32 passed where a non-zero VKey is required.
     * @dev selector: 0xce403dd2
     */
    error ZeroVKey();

    /**
     * @notice Pubkey has already been attested via {verifyAttestation}.
     * @dev selector: 0x1595b31b
     */
    error PubkeyAlreadyVerified();

    /**
     * @notice Pubkey has not been attested or has been revoked.
     * @dev selector: 0x2b257030
     */
    error PubkeyNotVerified();

    /**
     * @notice Signature length is not exactly 65 bytes.
     * @dev selector: 0x4be6321b
     */
    error InvalidSignatureLength();

    /**
     * @notice Recovered signer is not in {verifiedPubkeys}.
     * @dev selector: 0x203fccd1
     */
    error SignerNotAttested();

    /**
     * @notice Attestation's enclave timestamp is older than the maximum allowed age.
     * @dev selector: 0x6b3df692
     */
    error AttestationExpired(uint64 attestationTime, uint256 blockTime);

    // ============ Events ============

    /**
     * @notice Emitted when a pubkey passes ZK attestation via {verifyAttestation}.
     */
    event AttestationVerified(bytes32 indexed programVKey, address indexed pubkey);

    /**
     * @notice Emitted when an admin revokes a previously attested pubkey via {revokeAttestation}.
     */
    event AttestationRevoked(address indexed pubkey);

    /**
     * @notice Emitted when the program verification key is rotated via {updateProgramVKey}.
     * @dev `oldVKey` is `bytes32(0)` on the first-ever set.
     */
    event ProgramVKeyUpdated(bytes32 indexed oldVKey, bytes32 indexed newVKey);

    // ============ Functions ============

    /**
     * @notice Verifies a batch payload signed by an attested enclave.
     * @dev Does not deduplicate — caller must track `batchRoot` to prevent replay.
     * @param batchRoot Merkle root of L2 block headers in the batch.
     * @param blobHashes EIP-4844 versioned blob hashes bound to the batch.
     * @param signature 65-byte ECDSA signature (r || s || v).
     * @return signer Address recovered from the enclave signature.
     */
    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes calldata signature) external view returns (address);
}
