// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IRollupVerifier
 * @author Fluent Labs
 * @notice Interface for the RollupVerifier contract
 * @dev Provides a function to verify an aggregate proof
 */
interface IRollupVerifier {
    function verifyAggregateProof(uint256 batchIndex, bytes calldata aggregationProof, bytes32 publicInputHash) external view;
}
