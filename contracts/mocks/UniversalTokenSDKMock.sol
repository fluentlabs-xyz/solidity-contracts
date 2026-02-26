// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title UniversalTokenSDKMock
 * @notice Test-only mock SDK for Universal Tokens.
 * @dev Keeps the same surface as the real UniversalTokenSDK where the factory depends on it,
 *      but with trivial, deterministic behaviour and no precompile calls.
 */
library UniversalTokenSDKMock {
    /// @notice Prefix for bridge token deployment (must match real SDK semantics for salt).
    string public constant BRIDGE_TOKEN_PREFIX = "BRIDGE_TOKEN";

    /**
     * @notice Creates deployment transaction data for a Universal Token (mocked).
     * @dev For tests we just need deterministic, non-empty data that depends on inputs.
     *      The exact encoding does not need to match production, as long as
     *      computeTokenAddress and deployToken are consistent.
     */
    function createDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) public pure returns (bytes memory deploymentData) {
        deploymentData = abi.encode(
            keccak256(abi.encodePacked(name)),
            keccak256(abi.encodePacked(symbol)),
            decimals,
            initialSupply,
            minter,
            pauser
        );
    }
}

