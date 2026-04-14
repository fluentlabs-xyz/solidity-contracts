// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {INitroVerifier} from "../interfaces/INitroVerifier.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title NitroVerifier
 * @author Fluent Labs
 * @dev Two-phase verifier for AWS Nitro Enclave-based block and batch signing.
 *
 *      Phase 1 — Attestation: an SP1 ZK proof is submitted via {verifyAttestation},
 *      confirming that a Nitro enclave controls a given pubkey. The SP1 program
 *      verifies the AWS Nitro certificate chain off-chain; the resulting proof is
 *      verified on-chain against {_programVKey}. Attested pubkeys are stored in
 *      {verifiedPubkeys}.
 *
 *      Phase 2 — Verification: the attested enclave signs L2 block and batch payloads
 *      with its private key. {verifyBlock} and {verifyBatch} recover the signer via
 *      ECDSA and confirm it is in {verifiedPubkeys}.
 *
 *      Multiple pubkeys may be attested simultaneously to allow zero-downtime enclave
 *      rotation. Full pubkey enumeration is available off-chain via
 *      {INitroVerifier-AttestationVerified} and
 *      {INitroVerifier-AttestationRevoked} events.
 *
 *      {_programVKey} rotation uses a two-step timelock: {proposeVKeyUpdate} followed
 *      by {executeVKeyUpdate} after {VKEY_UPDATE_DELAY} seconds.
 */
contract NitroVerifier is AccessControl, INitroVerifier {
    // ============ Constants ============

    /// @dev Minimum seconds between {proposeVKeyUpdate} and {executeVKeyUpdate}.
    uint256 public constant VKEY_UPDATE_DELAY = 1 days;

    /// @dev Maximum age of an attestation document at the moment it is submitted on-chain.
    ///      Prevents replay of stale attestations produced by nodes whose ephemeral
    ///      keys may have been compromised in the interim (e.g. RAM extraction after
    ///      hardware decommission, AWS cert rotation, hypervisor updates).
    uint256 public constant ATTESTATION_MAX_AGE = 1 hours;

    /// @dev Permitted clock skew for attestations whose reported timestamp is in
    ///      the future relative to `block.timestamp`.
    uint256 public constant ATTESTATION_MAX_SKEW = 5 minutes;

    // ============ Storage ============

    /// @dev SP1 verifier contract used to validate attestation proofs. Immutable — set in constructor.
    address public immutable _attestationVerifier;

    /// @dev VKey queued for rotation; zero if no update is pending.
    bytes32 public pendingVKey;

    /// @dev Earliest timestamp at which {executeVKeyUpdate} may be called. Zero if no update is pending.
    uint256 public pendingVKeyValidAt;

    /// @dev Current SP1 program verification key for attestation proofs.
    bytes32 internal _programVKey = 0x00e34107e4c5284bd4ecc4269c650671038c1e85d9dacb931b534e984f607334;

    /// @dev Enclave pubkeys that have passed ZK attestation.
    ///      Enumeration is intentionally off-chain via events — avoids array SSTORE overhead.
    mapping(address => bool) public verifiedPubkeys;

    // ============ Constructor ============

    /**
     * @dev Sets the SP1 attestation verifier and grants DEFAULT_ADMIN_ROLE to the deployer.
     *      Reverts if `attestationVerifier_` is the zero address.
     */
    constructor(address attestationVerifier, address admin) {
        require(attestationVerifier != address(0) && admin != address(0), ZeroAddress());
        _attestationVerifier = attestationVerifier;
        require(_grantRole(DEFAULT_ADMIN_ROLE, admin), RoleGrantFailed());
    }

    // ============ INitroVerifier ============

    /// @inheritdoc INitroVerifier
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes calldata signature,
        bytes32[] calldata blobHashes
    ) external view returns (address) {
        require(signature.length == 65, InvalidSignatureLength());

        bytes32 payload = sha256(abi.encode(block.chainid, address(this), parentHash, blockHash, withdrawalHash, depositHash, blobHashes));
        address verifier = _assertSignerAttested(payload, signature);

        return verifier;
    }

    /// @inheritdoc INitroVerifier
    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes calldata signature) external view returns (address) {
        require(signature.length == 65, InvalidSignatureLength());

        bytes32 payload = sha256(abi.encode(block.chainid, address(this), batchRoot, blobHashes));
        address verifier = _assertSignerAttested(payload, signature);

        return verifier;
    }

    // ============ Admin: VKey Rotation ============

    /**
     * @notice Step 1 — propose a VKey rotation; executable after {VKEY_UPDATE_DELAY}.
     */
    function proposeVKeyUpdate(bytes32 newProgramVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newProgramVKey != bytes32(0), ZeroVKey());
        require(newProgramVKey != _programVKey, VKeyUnchanged());
        pendingVKey = newProgramVKey;
        uint256 validAt = block.timestamp + VKEY_UPDATE_DELAY;
        pendingVKeyValidAt = validAt;
        emit VKeyUpdateProposed(newProgramVKey, validAt);
    }

    /**
     * @notice Step 2 — execute the proposed VKey rotation after the timelock expires.
     */
    function executeVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 pending = pendingVKey; // 1 SLOAD, used twice below
        require(pending != bytes32(0), NoPendingUpdate());
        require(block.timestamp >= pendingVKeyValidAt, TimelockNotExpired());
        bytes32 oldVKey = _programVKey;
        _programVKey = pending;
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
        emit ProgramVKeyUpdated(oldVKey, pending);
    }

    /**
     * @notice Cancel a pending VKey rotation before it is executed.
     */
    function cancelVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 pending = pendingVKey; // 1 SLOAD, used twice below
        require(pending != bytes32(0), NoPendingUpdate());
        emit VKeyUpdateCancelled(pending);
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
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
     * @dev Enclave signatures from `pubkey` are rejected by {verifyBlock} and
     *      {verifyBatch} immediately after revocation.
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
    function verifyAttestation(address expectedPubkey, uint64 attestationTime, bytes calldata proofBytes) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(expectedPubkey != address(0), ZeroAddress());
        require(!verifiedPubkeys[expectedPubkey], PubkeyAlreadyVerified());

        // Freshness window: attestationTime must lie within
        // [block.timestamp - ATTESTATION_MAX_AGE, block.timestamp + ATTESTATION_MAX_SKEW].
        uint256 nowTs = block.timestamp;
        if (uint256(attestationTime) + ATTESTATION_MAX_AGE < nowTs || uint256(attestationTime) > nowTs + ATTESTATION_MAX_SKEW) {
            revert AttestationExpired(attestationTime, nowTs);
        }

        bytes32 vkey = _programVKey; // 1 SLOAD, passed to external call and event

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
