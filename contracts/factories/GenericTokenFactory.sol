// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title GenericTokenFactory
 * @notice Base contract for token factories used by the bridge
 * @dev Provides common storage and events for bridged token deployments
 */
abstract contract GenericTokenFactory is Ownable2Step {
    /// @notice Mapping from L1 token address to L2 token address
    mapping(address => address) public bridgedTokens;

    /// @notice Token deployment information
    struct TokenInfo {
        address l1Token;
        uint256 chainId;
        bool deployed;
    }

    /// @notice Mapping from token address to deployment info
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Emitted when a new bridged token is deployed
    event TokenDeployed(
        address indexed l1Token,
        address indexed l2Token,
        string name,
        string symbol,
        uint8 decimals
    );

    constructor() Ownable(msg.sender) {}
}
