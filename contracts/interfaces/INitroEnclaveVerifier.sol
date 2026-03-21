// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title INitroEnclaveVerifier
 * @dev Interface for verifying AWS Nitro Enclave attestations and enclave-signed
 *      block/batch payloads. Supports multiple attested pubkeys simultaneously —
 *      use {AttestationVerified} and {AttestationRevoked} events for off-chain enumeration.
 *
 *      Replay protection (blockHash / batchRoot deduplication) is the caller's responsibility.
 */
interface INitroEnclaveVerifier {
    // ============ Errors ============

    /**
     * @notice Zero address passed where a non-zero address is required.
     */
    error ZeroAddress();

    /**
     * @notice Zero bytes32 passed where a non-zero VKey is required.
     */
    error ZeroVKey();

    /**
     * @notice Proposed VKey is identical to the current {PROGRAM_VKEY}.
     */
    error VKeyUnchanged();

    /**
     * @notice {executeVKeyUpdate} or {cancelVKeyUpdate} called with no pending update.
     */
    error NoPendingUpdate();

    /**
     * @notice {executeVKeyUpdate} called before the timelock has expired.
     */
    error TimelockNotExpired();

    /**
     * @notice {DEFAULT_ADMIN_ROLE} grant failed in constructor.
     */
    error RoleGrantFailed();

    /**
     * @notice Pubkey has already been attested via {verifyAttestation}.
     */
    error PubkeyAlreadyVerified();

    /**
     * @notice Pubkey has not been attested or has been revoked.
     */
    error PubkeyNotVerified();

    /**
     * @notice Signature length is not exactly 65 bytes.
     */
    error InvalidSignatureLength();

    /**
     * @notice Recovered signer is not in {verifiedPubkeys}.
     */
    error SignerNotAttested();

    /**
     * @notice `ecrecover` returned the zero address — malformed signature.
     */
    error InvalidSignature();

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
     * @notice Emitted when a VKey rotation is proposed via {proposeVKeyUpdate}.
     */
    event VKeyUpdateProposed(bytes32 indexed proposedVKey, uint256 validAt);

    /**
     * @notice Emitted when a pending VKey rotation is cancelled via {cancelVKeyUpdate}.
     */
    event VKeyUpdateCancelled(bytes32 indexed cancelledVKey);

    /**
     * @notice Emitted when a VKey rotation is executed via {executeVKeyUpdate}.
     */
    event ProgramVKeyUpdated(bytes32 indexed oldVKey, bytes32 indexed newVKey);

    // ============ Functions ============

    /**
     * @notice Verifies a block payload signed by an attested enclave.
     * @dev Does not deduplicate — caller must track `blockHash` to prevent replay.
     * @param signature 65-byte ECDSA signature (r || s || v).
     */
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes calldata signature,
        bytes32[] calldata blobHashes
    ) external view returns (address);

    /**
     * @notice Verifies a batch payload signed by an attested enclave.
     * @dev Does not deduplicate — caller must track `batchRoot` to prevent replay.
     * @param signature 65-byte ECDSA signature (r || s || v).
     */
    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes calldata signature) external view returns (address);
}
