// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenFactory
 * @notice Common interface for token factories used by the bridge
 */
interface ITokenFactory {
  /**
   * @notice Computes the address of a pegged token for a given gateway and origin token
   * @param _gateway Gateway address
   * @param _originToken Origin token address
   * @return Predicted pegged token address
   */
  function computePeggedTokenAddress(
    address _gateway,
    address _originToken
  ) external view returns (address);

  /**
   * @notice Computes the address of a pegged token on the other side
   * @param _gateway Other side gateway address
   * @param _originToken Origin token address
   * @param _implementation Token implementation address (for legacy factories)
   * @param _factory Factory address (for legacy factories)
   * @return Predicted pegged token address
   */
  function computeOtherSidePeggedTokenAddress(
    address _gateway,
    address _originToken,
    address _implementation,
    address _factory
  ) external view returns (address);

  /**
   * @notice Deploys a pegged token for a given gateway and origin token
   * @param _gateway Gateway address
   * @param _originToken Origin token address
   * @return Address of the deployed pegged token
   */
  function deployToken(
    address _gateway,
    address _originToken
  ) external returns (address);
}
