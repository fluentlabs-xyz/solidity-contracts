// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRollupVerifier {
    function verifyAggregateProof(
        uint256 batchIndex,
        bytes calldata aggregationProof,
        bytes32 publicInputHash
    ) external view;
}
