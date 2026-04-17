// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ISP1Verifier} from "../interfaces/verifiers/ISP1Verifier.sol";
import {INitroVerifier} from "../interfaces/verifiers/INitroVerifier.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title NitroVerifier
 * @author Fluent Labs
 * @dev Two-phase verifier for AWS Nitro Enclave-based batch signing.
 *
 *      Phase 1 — Attestation: an SP1 ZK proof is submitted via {verifyAttestation},
 *      confirming that a Nitro enclave controls a given pubkey. The SP1 program
 *      verifies the AWS Nitro certificate chain off-chain; the resulting proof is
 *      verified on-chain against {_programVKey}. Attested pubkeys are stored in
 *      {verifiedPubkeys}.
 *
 *      Phase 2 — Verification: the attested enclave signs L2 batch payloads with
 *      its private key. {verifyBatch} recovers the signer via ECDSA and confirms
 *      it is in {verifiedPubkeys}.
 *
 *      Multiple pubkeys may be attested simultaneously to allow zero-downtime
 *      enclave rotation. Full pubkey enumeration is available off-chain via
 *      {INitroVerifier-AttestationVerified} and
 *      {INitroVerifier-AttestationRevoked} events.
 *
 *      Governance timing (VKey rotation, attestation approval) is enforced by
 *      the admin account, which is expected to be an OpenZeppelin
 *      `TimelockController`. No timelock is enforced inside this contract; if
 *      the admin role is granted to a non-timelock account, rotations are
 *      immediate. Verify the admin identity at deploy time.
 */
contract NitroVerifier is AccessControl, INitroVerifier {
    // ============ Constants ============

    bytes32 public constant ENCLAVE_ATTESTER_ROLE = keccak256("ENCLAVE_ATTESTER_ROLE");

    /**
     * @dev Maximum age of an attestation document at the moment it is submitted on-chain.
     *      Prevents replay of stale attestations produced by nodes whose ephemeral
     *      keys may have been compromised in the interim (e.g. RAM extraction after
     *      hardware decommission, AWS cert rotation, hypervisor updates).
     */
    uint256 public constant ATTESTATION_MAX_AGE = 12 hours;

    // ============ Storage ============

    /**
     * @dev SP1 verifier contract used to validate attestation proofs. Immutable — set in constructor.
     */
    address public immutable _attestationVerifier;

    /**
     * @dev Current SP1 program verification key for attestation proofs.
     *      Zero until the admin calls {updateProgramVKey}; {verifyAttestation}
     *      will fail until that first call.
     */
    bytes32 internal _programVKey;

    /**
     * @dev Enclave pubkeys that have passed ZK attestation.
     *      Enumeration is intentionally off-chain via events — avoids array SSTORE overhead.
     */
    mapping(address => bool) public verifiedPubkeys;

    // ============ Constructor ============

    /**
     * @notice Initializes the verifier with the given SP1 verifier and admin.
     * @dev Reverts if either address is zero. The admin is expected to be an
     *      OpenZeppelin `TimelockController` so that {updateProgramVKey},
     *      {revokeAttestation}, and {verifyAttestation} are subject to an
     *      off-chain-observable delay. This is a deployment-time invariant —
     *      nothing on-chain enforces it.
     *      `_programVKey` starts at zero; the admin must call {updateProgramVKey}
     *      before {verifyAttestation} can succeed.
     * @param attestationVerifier Address of the SP1 verifier contract used to
     *                            verify attestation proofs.
     * @param admin               Address granted `DEFAULT_ADMIN_ROLE`; should be
     *                            a `TimelockController`.
     */
    constructor(address attestationVerifier, address admin) {
        require(attestationVerifier != address(0) && admin != address(0), ZeroAddress());
        _attestationVerifier = attestationVerifier;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ============ INitroVerifier ============

    /// @inheritdoc INitroVerifier
    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes calldata signature) external view returns (address) {
        require(signature.length == 65, InvalidSignatureLength());

        bytes32 payload = sha256(abi.encode(block.chainid, address(this), batchRoot, blobHashes));
        address verifier = _assertSignerAttested(payload, signature);

        return verifier;
    }

    // ============ Admin: VKey Rotation ============

    /**
     * @notice Sets the SP1 program verification key for attestation proofs.
     * @dev Rotation is immediate. Governance delay is expected to be enforced
     *      by the admin (a `TimelockController`), giving off-chain monitors a
     *      window to observe and contest the proposed key.
     */
    function updateProgramVKey(bytes32 newProgramVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newProgramVKey != bytes32(0), ZeroVKey());
        bytes32 oldVKey = _programVKey;
        _programVKey = newProgramVKey;
        emit ProgramVKeyUpdated(oldVKey, newProgramVKey);
    }

    /**
     * @notice Returns the current SP1 program verification key.
     */
    function getProgramVKey() external view returns (bytes32) {
        return _programVKey;
    }

    // ============ Admin: Attestation Management ============

    /**
     * @notice Revoke a previously attested enclave pubkey.
     * @dev Enclave signatures from `pubkey` are rejected by {verifyBatch}
     *      immediately after revocation.
     */
    function revokeAttestation(address pubkey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(verifiedPubkeys[pubkey], PubkeyNotVerified());
        verifiedPubkeys[pubkey] = false;
        emit AttestationRevoked(pubkey);
    }

    // ============ External: Attestation ============

    /**
     * @notice Verify an SP1 ZK proof of a Nitro enclave attestation document,
     *         confirming that `expectedPubkey` is controlled by a valid enclave.
     * @dev The SP1 program verifies the AWS Nitro certificate chain off-chain and
     *      commits `abi.encode(expectedPubkey, attestationTime)` as the proof's
     *      public output, where `attestationTime` is the enclave-reported NSM
     *      timestamp (seconds since the Unix epoch) extracted structurally from
     *      the signed AttestationDoc. The caller mirrors the timestamp in the
     *      call; SP1's `verifyProof` binds it to the proof, and
     *      {ATTESTATION_MAX_AGE} enforces freshness to prevent replay of
     *      long-dead attestation documents (e.g. after ephemeral key extraction
     *      from decommissioned hardware, AWS cert rotation, or hypervisor
     *      updates).
     *      DEFAULT_ADMIN_ROLE is required to prevent attack if SP1 verification is compromised —
     *      ensures only trusted parties can submit proofs. Since DEFAULT_ADMIN_ROLE is multisig,
     *      the risk of compromise is reduced.
     * @param expectedPubkey   Enclave-derived address to attest.
     * @param attestationTime  Enclave NSM timestamp (seconds since Unix epoch)
     *                         committed inside the SP1 proof.
     * @param proofBytes       Encoded SP1 proof.
     */
    function verifyAttestation(address expectedPubkey, uint64 attestationTime, bytes calldata proofBytes) external onlyRole(ENCLAVE_ATTESTER_ROLE) {
        require(expectedPubkey != address(0), ZeroAddress());
        require(!verifiedPubkeys[expectedPubkey], PubkeyAlreadyVerified());

        // Freshness window: attestationTime must be no older than ATTESTATION_MAX_AGE.
        // Future timestamps are accepted — SP1 binds the timestamp to the proof, so
        // a forged future value cannot satisfy the enclave-side signing check.
        uint256 nowTs = block.timestamp;
        if (uint256(attestationTime) + ATTESTATION_MAX_AGE < nowTs) {
            revert AttestationExpired(attestationTime, nowTs);
        }

        bytes32 vkey = _programVKey;

        // Public-values layout produced by the guest's `main`:
        //   abi.encode(address, uint64)  → 64 bytes (two 32-byte words).
        // Any mismatch between (expectedPubkey, attestationTime) and the values
        // baked into the proof causes `verifyProof` to revert, so a forged
        // timestamp cannot satisfy both the freshness window and the SP1 check.
        ISP1Verifier(_attestationVerifier).verifyProof(vkey, abi.encode(expectedPubkey, attestationTime), proofBytes);

        verifiedPubkeys[expectedPubkey] = true;
        emit AttestationVerified(vkey, expectedPubkey);
    }

    // ============ Internal ============

    /**
     * @dev Recovers the signer from (payload, signature) via {ECDSA.recover}
     *      and reverts if the recovered address is not in {verifiedPubkeys}.
     *      Signature layout: r (32 bytes) || s (32 bytes) || v (1 byte).
     */
    function _assertSignerAttested(bytes32 payload, bytes calldata signature) internal view returns (address) {
        address verifier = ECDSA.recover(payload, signature);
        require(verifiedPubkeys[verifier], SignerNotAttested());

        return verifier;
    }
}
