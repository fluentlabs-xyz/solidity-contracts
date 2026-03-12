// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface INitroEnclaveVerifier {
    function isAttestationVerified() external view returns (bool);
    function enclaveAddress() external view returns (address);
    function verifyBlock(
        bytes32 parentHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash,
        bytes32 signature,
        bytes32[] calldata blobHashes
    ) external view returns (bool);

    function verifyBatch(bytes32 batchRoot, bytes32[] calldata blobHashes, bytes32 signature) external view returns (bool);
}
