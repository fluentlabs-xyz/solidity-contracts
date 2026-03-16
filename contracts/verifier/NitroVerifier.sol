// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerifier} from "contracts/interfaces/IVerifier.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract NitroVerifier is AccessControl {
    // ============ Errors ============

    error ZeroAddress();
    error ZeroVKey();
    error VKeyUnchanged();
    error NoPendingUpdate();
    error TimelockNotExpired();
    error RoleGrantFailed();
    error PubkeyAlreadyVerified();
    error PubkeyNotVerified();
    error InvalidSignatureLength();
    error BlockAlreadyVerified();
    error SignerNotAttested();
    error InvalidSignature();

    // ============ Constants ============

    /// @notice Delay between proposing and executing a VKey rotation
    uint256 public constant VKEY_UPDATE_DELAY = 1 days;

    // ============ State Variables ============

    address public immutable _attestationVerifier;

    bytes32 public PROGRAM_VKEY = 0x00e34107e4c5284bd4ecc4269c650671038c1e85d9dacb931b534e984f607334;

    bytes32 public pendingVKey;
    uint256 public pendingVKeyValidAt;

    /// @notice Enclave pubkeys that have passed ZK attestation
    mapping(address => bool) public verifiedPubkeys;

    /// @notice Block hashes that have been verified to prevent replay
    mapping(bytes32 => bool) public verifiedBlocks;

    // ============ Events ============

    event VKeyUpdateProposed(bytes32 indexed proposedVKey, uint256 validAt);
    event VKeyUpdateCancelled(bytes32 indexed cancelledVKey);
    event ProgramVKeyUpdated(bytes32 indexed oldVKey, bytes32 indexed newVKey);
    event AttestationVerified(bytes32 indexed programVKey, address indexed pubkey);
    event AttestationRevoked(address indexed pubkey);
    event BlockVerified(bytes32 indexed blockHash, bytes32 parentHash, address indexed signer);

    // ============ Constructor ============

    constructor(address attestationVerifier, address admin) {
        if (attestationVerifier == address(0) || admin == address(0)) revert ZeroAddress();
        _attestationVerifier = attestationVerifier;
        bool granted = _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (!granted) revert RoleGrantFailed();
    }

    // ============ Admin: VKey Rotation ============

    /// @notice Step 1 — propose a VKey rotation; executable after VKEY_UPDATE_DELAY
    function proposeVKeyUpdate(bytes32 newProgramVKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newProgramVKey == bytes32(0)) revert ZeroVKey();
        if (newProgramVKey == PROGRAM_VKEY) revert VKeyUnchanged();
        pendingVKey = newProgramVKey;
        pendingVKeyValidAt = block.timestamp + VKEY_UPDATE_DELAY;
        emit VKeyUpdateProposed(newProgramVKey, pendingVKeyValidAt);
    }

    /// @notice Step 2 — execute the proposed VKey rotation after timelock expires
    function executeVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingVKey == bytes32(0)) revert NoPendingUpdate();
        if (block.timestamp < pendingVKeyValidAt) revert TimelockNotExpired();
        bytes32 oldVKey = PROGRAM_VKEY;
        PROGRAM_VKEY = pendingVKey;
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
        emit ProgramVKeyUpdated(oldVKey, PROGRAM_VKEY);
    }

    /// @notice Cancel a pending VKey update before it is executed
    function cancelVKeyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingVKey == bytes32(0)) revert NoPendingUpdate();
        emit VKeyUpdateCancelled(pendingVKey);
        pendingVKey = bytes32(0);
        pendingVKeyValidAt = 0;
    }

    // ============ Admin: Attestation Management ============

    function revokeAttestation(address pubkey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!verifiedPubkeys[pubkey]) revert PubkeyNotVerified();
        verifiedPubkeys[pubkey] = false;
        emit AttestationRevoked(pubkey);
    }

    // ============ External Functions ============

    /**
     * @notice Verify SP1 ZK proof that a Nitro enclave controls `expectedPubkey`.
     * @param expectedPubkey  Enclave-derived address to attest
     * @param proofBytes      SP1 proof bytes
     */
    function verifyAttestation(address expectedPubkey, bytes calldata proofBytes) external {
        if (expectedPubkey == address(0)) revert ZeroAddress();
        if (verifiedPubkeys[expectedPubkey]) revert PubkeyAlreadyVerified();

        IVerifier(_attestationVerifier).verifyProof(PROGRAM_VKEY, abi.encode(expectedPubkey), proofBytes);

        verifiedPubkeys[expectedPubkey] = true;
        emit AttestationVerified(PROGRAM_VKEY, expectedPubkey);
    }

    /**
     * @notice Verify a block signed by a previously attested enclave.
     * @param parentHash     Parent block hash
     * @param blockHash      Current block hash
     * @param withdrawalHash Hash of withdrawal events
     * @param depositHash    Hash of deposit events
     * @param signature      65-byte ECDSA signature (r || s || v)
     * @return signer        Recovered enclave address
     */
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes calldata signature
    ) external returns (address signer) {
        if (signature.length != 65) revert InvalidSignatureLength();
        if (verifiedBlocks[blockHash]) revert BlockAlreadyVerified();

        bytes32 signingPayload = computeSigningPayload(parentHash, blockHash, withdrawalHash, depositHash);
        signer = recoverSigner(signingPayload, signature);

        if (!verifiedPubkeys[signer]) revert SignerNotAttested();

        verifiedBlocks[blockHash] = true;
        emit BlockVerified(blockHash, parentHash, signer);
    }

    // ============ Public Functions ============

    /**
     * @notice Compute signing payload: SHA256(data || SHA256(data))
     * @dev Double-hash scheme binds all four block fields into a single digest
     */
    function computeSigningPayload(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash
    ) public pure returns (bytes32) {
        bytes memory data = abi.encodePacked(parentHash, blockHash, withdrawalHash, depositHash);
        return sha256(abi.encodePacked(data, sha256(data)));
    }

    // ============ Internal Functions ============

    function recoverSigner(bytes32 messageHash, bytes calldata signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(messageHash, v, r, s);
        if (recovered == address(0)) revert InvalidSignature();
        return recovered;
    }
}
