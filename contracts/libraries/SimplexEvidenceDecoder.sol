// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title Simplex equivocation-evidence decoder (stateless, pure).
/// @notice Decodes the bare-concatenation Simplex consensus evidence wire
///         format (byte encoding is the Commonware codec, conformance-pinned)
///         for `ConflictingNotarize` / `ConflictingFinalize` /
///         `NullifyFinalize` and re-enforces the Rust `Read` invariants.
///         Returns the raw signed message sub-slices (no re-encoding) so the
///         bytes fed to the BLS verifier are byte-identical to what the
///         Simplex signer produced.
/// @dev    Conformance-pinned against
///         `crates/bls/tests/equivocation_evidence_conformance.rs`. All
///         integers are commonware-codec `UInt` LEB128 varint (7 bits/byte,
///         low 7 bits first, high bit = continuation). Wire layout:
///           Round       = uvarint(epoch) ‖ uvarint(view)
///           Proposal    = Round ‖ uvarint(parent) ‖ payload[32]
///           Attestation = uvarint(signerIdx) ‖ sig[48]   (Lazy<G1>, raw)
///           Notarize    = Proposal ‖ Attestation
///           Finalize    = Proposal ‖ Attestation
///           Nullify     = Round ‖ Attestation
///         ConflictingNotarize = Notarize ‖ Notarize
///         ConflictingFinalize = Finalize ‖ Finalize
///         NullifyFinalize     = Nullify  ‖ Finalize
contract SimplexEvidenceDecoder {
    /// @notice FluentDigest([u8;32]) — cross-task wire invariant.
    uint256 internal constant PROPOSAL_PAYLOAD_LEN = 32;
    /// @notice Lazy<G1> raw compressed G1 signature, no length prefix.
    uint256 internal constant SIG_LEN = 48;

    uint8 internal constant KIND_NOTARIZE = 0;
    uint8 internal constant KIND_NULLIFY = 1;
    uint8 internal constant KIND_FINALIZE = 2;

    /// @notice Mirrors Commonware `Read` `Error::Invalid` / a malformed blob.
    error InvalidEvidence();

    struct Decoded {
        uint64 epoch; // Round.epoch() of vote 1 (resolver key; == for both)
        uint32 signerIdx; // Attestation.signer (== for both votes, enforced)
        uint8 kind1; // 0=Notarize 1=Nullify 2=Finalize
        bytes msg1; // raw signed body of vote 1 (Proposal/Round sub-slice)
        bytes sig1; // 48 B compressed G1 reference of vote 1
        uint8 kind2;
        bytes msg2;
        bytes sig2;
    }

    /// @notice Decode `ConflictingNotarize = Notarize ‖ Notarize`.
    function decodeConflictingNotarize(bytes calldata e) external pure returns (Decoded memory) {
        return _decodeConflicting(e, KIND_NOTARIZE);
    }

    /// @notice Decode `ConflictingFinalize = Finalize ‖ Finalize`.
    function decodeConflictingFinalize(bytes calldata e) external pure returns (Decoded memory) {
        return _decodeConflicting(e, KIND_FINALIZE);
    }

    /// @dev ConflictingNotarize/ConflictingFinalize share an identical wire
    ///      shape (Proposal‖Attestation ‖ Proposal‖Attestation) and identical
    ///      invariants (same signer, same round, different proposal); only
    ///      the recorded kind differs.
    function _decodeConflicting(bytes calldata e, uint8 kind) private pure returns (Decoded memory d) {
        uint256 off = 0;
        uint64 ep1;
        uint64 vw1;
        uint64 pr1;
        bytes calldata pl1;
        bytes calldata m1;
        uint32 sg1;
        bytes calldata s1;
        (ep1, vw1, pr1, pl1, m1, off) = _readProposal(e, off);
        (sg1, s1, off) = _readAttestation(e, off);

        uint64 ep2;
        uint64 vw2;
        uint64 pr2;
        bytes calldata pl2;
        bytes calldata m2;
        uint32 sg2;
        bytes calldata s2;
        (ep2, vw2, pr2, pl2, m2, off) = _readProposal(e, off);
        (sg2, s2, off) = _readAttestation(e, off);

        if (off != e.length) revert InvalidEvidence();
        if (sg1 != sg2 || ep1 != ep2 || vw1 != vw2) revert InvalidEvidence();
        if (pr1 == pr2 && _bytesEq(pl1, pl2)) revert InvalidEvidence();

        d.epoch = ep1;
        d.signerIdx = sg1;
        d.kind1 = kind;
        d.msg1 = m1;
        d.sig1 = s1;
        d.kind2 = kind;
        d.msg2 = m2;
        d.sig2 = s2;
    }

    /// @notice Decode `NullifyFinalize = Nullify ‖ Finalize`.
    function decodeNullifyFinalize(bytes calldata e) external pure returns (Decoded memory d) {
        uint256 off = 0;
        uint64 ep1;
        uint64 vw1;
        bytes calldata m1; // raw Round.encode()
        uint32 sg1;
        bytes calldata s1;
        (ep1, vw1, m1, off) = _readRound(e, off);
        (sg1, s1, off) = _readAttestation(e, off);

        uint64 ep2;
        uint64 vw2;
        uint64 pr2;
        bytes calldata pl2;
        bytes calldata m2;
        uint32 sg2;
        bytes calldata s2;
        (ep2, vw2, pr2, pl2, m2, off) = _readProposal(e, off);
        (sg2, s2, off) = _readAttestation(e, off);
        pr2; // parent unused for invariant (NullifyFinalize compares only round + signer)
        pl2;

        if (off != e.length) revert InvalidEvidence();
        // NullifyFinalize::read: same signer, same round.
        if (sg1 != sg2 || ep1 != ep2 || vw1 != vw2) revert InvalidEvidence();

        d.epoch = ep1;
        d.signerIdx = sg1;
        d.kind1 = KIND_NULLIFY;
        d.msg1 = m1;
        d.sig1 = s1;
        d.kind2 = KIND_FINALIZE;
        d.msg2 = m2;
        d.sig2 = s2;
    }

    // ------------------------------------------------------------------ //
    //                          field readers                             //
    // ------------------------------------------------------------------ //

    /// @dev Round = uvarint(epoch) ‖ uvarint(view); `raw` is the exact
    ///      byte sub-slice the parser walked (the signed Nullify body).
    function _readRound(bytes calldata e, uint256 off)
        private
        pure
        returns (uint64 epoch, uint64 vw, bytes calldata raw, uint256 newOff)
    {
        uint256 start = off;
        uint256 v;
        (v, off) = _readUvarint(e, off);
        epoch = uint64(v);
        (v, off) = _readUvarint(e, off);
        vw = uint64(v);
        raw = e[start:off];
        newOff = off;
    }

    /// @dev Proposal = Round ‖ uvarint(parent) ‖ payload[32]; `raw` is the
    ///      exact byte sub-slice the parser walked (the signed Proposal body).
    function _readProposal(bytes calldata e, uint256 off)
        private
        pure
        returns (uint64 epoch, uint64 vw, uint64 parent, bytes calldata payload, bytes calldata raw, uint256 newOff)
    {
        uint256 start = off;
        uint256 v;
        (v, off) = _readUvarint(e, off);
        epoch = uint64(v);
        (v, off) = _readUvarint(e, off);
        vw = uint64(v);
        (v, off) = _readUvarint(e, off);
        parent = uint64(v);
        if (off + PROPOSAL_PAYLOAD_LEN > e.length) revert InvalidEvidence();
        payload = e[off:off + PROPOSAL_PAYLOAD_LEN];
        off += PROPOSAL_PAYLOAD_LEN;
        raw = e[start:off];
        newOff = off;
    }

    /// @dev Attestation = uvarint(signerIdx) ‖ sig[48] (Lazy<G1>, no prefix).
    function _readAttestation(bytes calldata e, uint256 off)
        private
        pure
        returns (uint32 signerIdx, bytes calldata sig, uint256 newOff)
    {
        uint256 v;
        (v, off) = _readUvarint(e, off);
        if (v > type(uint32).max) revert InvalidEvidence();
        signerIdx = uint32(v);
        if (off + SIG_LEN > e.length) revert InvalidEvidence();
        sig = e[off:off + SIG_LEN];
        newOff = off + SIG_LEN;
    }

    /// @dev Unsigned LEB128 varint (commonware codec `UInt`): 7 bits/byte,
    ///      low 7 bits first, high bit = continuation. Bounded to uint64.
    function _readUvarint(bytes calldata e, uint256 off) private pure returns (uint256 value, uint256 newOff) {
        uint256 shift = 0;
        while (true) {
            if (off >= e.length) revert InvalidEvidence();
            uint8 b = uint8(e[off]);
            off += 1;
            if (shift >= 64) revert InvalidEvidence();
            value |= uint256(b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (value > type(uint64).max) revert InvalidEvidence();
        newOff = off;
    }

    function _bytesEq(bytes calldata a, bytes calldata b) private pure returns (bool) {
        if (a.length != b.length) return false;
        return keccak256(a) == keccak256(b);
    }
}
