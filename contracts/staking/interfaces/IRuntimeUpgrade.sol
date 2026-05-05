// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Runtime upgrade interface
/// @notice Allows governance/runtime components to deploy and upgrade system smart contracts.
interface IRuntimeUpgrade {
    /// @notice Returns the EVM hook address that performs low-level system contract operations.
    function getEvmHookAddress() external view returns (address);

    /// @notice Upgrades an existing system smart contract implementation.
    function upgradeSystemSmartContract(
        string calldata name,
        address contractAddress,
        bytes calldata byteCode,
        bytes calldata initCalldata
    ) external;

    /// @notice Deploys a new system smart contract implementation at a deterministic address.
    function deploySystemSmartContract(
        string calldata name,
        address contractAddress,
        bytes calldata byteCode,
        bytes calldata initCalldata
    ) external;

    /// @notice Returns registered system contract addresses.
    function getSystemContracts() external view returns (address[] memory);
}
