// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenFactory
 * @notice Interface for the TokenFactory used by the bridge
 */
interface ITokenFactory {
  function computeTokenAddress(
    address l1Token,
    uint256 chainId
  ) external view returns (address tokenAddress);

  function getOrDeployToken(
    address l1Token,
    uint256 chainId,
    string memory name,
    string memory symbol,
    uint8 decimals,
    address minter,
    address pauser
  ) external returns (address tokenAddress);
}
