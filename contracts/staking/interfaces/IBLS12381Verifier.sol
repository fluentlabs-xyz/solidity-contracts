// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @title BLS12-381 MinSig verify interface.
/// @notice Minimal consumer view of `BLS12381Verifier.verify`.
interface IBLS12381Verifier {
    /// @notice Verify one MinSig signature: e(sig,-G2gen)·e(H,pk) == 1.
    ///         Pure pairing — the caller binds sig/pk to its trust anchor
    ///         via compressG1Unchecked/compressG2Unchecked.
    function verify(
        bytes calldata namespace,
        bytes calldata message,
        bytes calldata dst,
        bytes calldata sigUncompressed,
        bytes calldata pkUncompressed
    ) external view returns (bool);

    /// @notice Compress a 128 B EIP-2537 G1 to 48 B zcash (MinSig).
    /// @dev UNCHECKED — performs NO on-curve / subgroup check; the
    ///      caller MUST bind the output to a trust anchor (e.g. keccak-
    ///      compare against a pre-anchored 48-byte identity, OR route
    ///      through `verify(...)` whose PAIRING precompile enforces
    ///      subgroup membership). The `Unchecked` suffix carries this
    ///      contract.
    function compressG1Unchecked(bytes calldata uncompressed128) external pure returns (bytes memory);

    /// @notice Compress a 256 B EIP-2537 G2 to 96 B zcash (c1-first, MinSig).
    /// @dev UNCHECKED — see `compressG1Unchecked` doc for trust-anchor
    ///      binding requirement.
    function compressG2Unchecked(bytes calldata uncompressed256) external pure returns (bytes memory);
}
