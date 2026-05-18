// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @title BLS12-381 MinSig verify interface.
/// @notice Minimal consumer view of `BLS12381Verifier.verify`.
interface IBLS12381Verifier {
    /// @notice Verify one MinSig signature: e(sig,-G2gen)·e(H,pk) == 1.
    ///         Pure pairing — the caller binds sig/pk to its trust anchor
    ///         via compressG1/compressG2.
    function verify(
        bytes calldata namespace,
        bytes calldata message,
        bytes calldata dst,
        bytes calldata sigUncompressed,
        bytes calldata pkUncompressed
    ) external view returns (bool);

    /// @notice Compress a 128 B EIP-2537 G1 to 48 B zcash (MinSig).
    function compressG1(bytes calldata uncompressed128) external pure returns (bytes memory);

    /// @notice Compress a 256 B EIP-2537 G2 to 96 B zcash (c1-first, MinSig).
    function compressG2(bytes calldata uncompressed256) external pure returns (bytes memory);
}
