// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IVerifier} from "contracts/interfaces/IVerifier.sol";
import {INitroEnclaveVerifier} from "contracts/interfaces/INitroEnclaveVerifier.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title NitroVerifier
 * @dev Two-phase verifier for AWS Nitro Enclave-based block and batch signing.
 *
 *      Phase 1 — Attestation: an SP1 ZK proof is submitted via {verifyAttestation},
 *      confirming that a Nitro enclave controls a given pubkey. The SP1 program
 *      verifies the AWS Nitro certificate chain off-chain; the resulting proof is
 *      verified on-chain against {PROGRAM_VKEY}. Attested pubkeys are stored in
 *      {verifiedPubkeys}.
 *
 *      Phase 2 — Verification: the attested enclave signs L2 block and batch payloads
 *      with its private key. {verifyBlock} and {verifyBatch} recover the signer via
 *      ECDSA and confirm it is in {verifiedPubkeys}.
 *
 *      Multiple pubkeys may be attested simultaneously to allow zero-downtime enclave
 *      rotation. Full pubkey enumeration is available off-chain via
 *      {INitroEnclaveVerifier-AttestationVerified} and
 *      {INitroEnclaveVerifier-AttestationRevoked} events.
 *
 *      {PROGRAM_VKEY} rotation uses a two-step timelock: {proposeVKeyUpdate} followed
 *      by {executeVKeyUpdate} after {VKEY_UPDATE_DELAY} seconds.
 */
contract NitroVerifier is AccessControl, INitroEnclaveVerifier {
    // ============ Constants ============

    /// @dev Minimum seconds between {proposeVKeyUpdate} and {executeVKeyUpdate}.
    uint256 public constant VKEY_UPDATE_DELAY = 1 days;

    // ============ Storage ============

    /// @dev SP1 verifier contract used to validate attestation proofs. Immutable — set in constructor.
    address public immutable _attestationVerifier;

    /// @dev Current SP1 program verification key for attestation proofs.
    bytes32 public PROGRAM_VKEY = 0x00e34107e4c5284bd4ecc4269c650671038c1e85d9dacb931b534e984f607334;

    /// @dev VKey queued for rotation; zero if no update is pending.
    bytes32 public pendingVKey;

    /// @dev Earliest timestamp at which {executeVKeyUpdate} may be called. Zero if no update is pending.
    ///      uint64 leaves 24 bytes in its slot free for future packing.
    uint64 public pendingVKeyValidAt;

    /// @dev Enclave pubkeys that have passed ZK attestation.
    ///      Enumeration is intentionally off-chain via events — avoids array SSTORE overhead.
    mapping(address => bool) public verifiedPubkeys;

    // ============ Constructor ============

    constructor(address attestationVerifier, address admin) {
        if (attestationVerifier == address(0) || admin == address(0)) revert ZeroAddress();
        _attestationVerifier = attestationVerifier;
        bool granted = _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (!granted) revert RoleGrantFailed();
    }

    // ============ INitroEnclaveVerifier ============

    /// @inheritdoc INitroEnclaveVerifier
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes calldata signature,
        bytes32[] calldata blobHashes
    ) external view returns (address) {
        require(signature.length == 65, InvalidSignatureLength());

        bytes32 payload = sha256(abi.encode(parentHash, blockHash, withdrawalHash, depositHash, blobHashes));
        address verifier = _assertSignerAttested(payload, signature);

        return verifier;
    }

    /// @inheritdoc INitroEnclaveVerifier
    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes calldata signature) external view returns (address) {
        require(signature.length == 65, InvalidSignatureLength());

        bytes32 payload = sha256(abi.encode(batchRoot, blobHashes));
        address verifier = _assertSignerAttested(payload, signature);

        return verifier;
    }

    // ============ Admin: VKey Rotation ============

    /**
     * @notice Step 1 — propose a VKey rotation; executable after {VKEY_UPDATE_DELAY}.
     */
    function proposeVKeyUpdate(bytes32 newProgramVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newProgramVKey == bytes32(0)) revert ZeroVKey();
        if (newProgramVKey == PROGRAM_VKEY) revert VKeyUnchanged();
        pendingVKey = newProgramVKey;
        uint64 validAt = uint64(block.timestamp + VKEY_UPDATE_DELAY);
        pendingVKeyValidAt = validAt;
        emit VKeyUpdateProposed(newProgramVKey, validAt);
    }

    /**
     * @notice Step 2 — execute the proposed VKey rotation after the timelock expires.
     */
    function executeVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 pending = pendingVKey; // 1 SLOAD, used twice below
        if (pending == bytes32(0)) revert NoPendingUpdate();
        if (block.timestamp < pendingVKeyValidAt) revert TimelockNotExpired();
        bytes32 oldVKey = PROGRAM_VKEY;
        PROGRAM_VKEY = pending;
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
        emit ProgramVKeyUpdated(oldVKey, pending);
    }

    /**
     * @notice Cancel a pending VKey rotation before it is executed.
     */
    function cancelVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 pending = pendingVKey; // 1 SLOAD, used twice below
        if (pending == bytes32(0)) revert NoPendingUpdate();
        emit VKeyUpdateCancelled(pending);
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
    }

    // ============ Admin: Attestation Management ============

    /**
     * @notice Revoke a previously attested enclave pubkey.
     * @dev Enclave signatures from `pubkey` are rejected by {verifyBlock} and
     *      {verifyBatch} immediately after revocation.
     */
    function revokeAttestation(address pubkey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!verifiedPubkeys[pubkey]) revert PubkeyNotVerified();
        verifiedPubkeys[pubkey] = false;
        emit AttestationRevoked(pubkey);
    }

    // ============ External: Attestation ============

    /**
     * @notice Verify an SP1 ZK proof of a Nitro enclave attestation document,
     *         confirming that `expectedPubkey` is controlled by a valid enclave.
     * @dev The SP1 program verifies the AWS Nitro certificate chain off-chain and
     *      produces a proof with `abi.encode(expectedPubkey)` as the public output,
     *      verified here against {PROGRAM_VKEY}.
     * @param expectedPubkey Enclave-derived address to attest.
     * @param proofBytes     Encoded SP1 proof.
     */
    function verifyAttestation(address expectedPubkey, bytes calldata proofBytes) external {
        if (expectedPubkey == address(0)) revert ZeroAddress();
        if (verifiedPubkeys[expectedPubkey]) revert PubkeyAlreadyVerified();
        bytes32 vkey = PROGRAM_VKEY; // 1 SLOAD, passed to external call and event
        IVerifier(_attestationVerifier).verifyProof(vkey, abi.encode(expectedPubkey), proofBytes);
        verifiedPubkeys[expectedPubkey] = true;
        emit AttestationVerified(vkey, expectedPubkey);
    }

    // ============ Internal ============

    /**
     * @dev Recovers the signer from (payload, signature) and reverts if the
     *      recovered address is not in {verifiedPubkeys}.
     *      Signature layout: r (32 bytes) || s (32 bytes) || v (1 byte).
     */
    function _assertSignerAttested(bytes32 payload, bytes calldata signature) internal view returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address verifier = ecrecover(payload, v, r, s);
        require(verifier != address(0), InvalidSignature());
        require(verifiedPubkeys[verifier], SignerNotAttested());

        return verifier;
    }
}
