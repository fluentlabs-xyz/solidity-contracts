// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Runtime upgrade EVM hook interface
/// @notice Low-level hook used by runtime upgrade flow to write bytecode for system contracts.
interface IRuntimeUpgradeEvmHook {
    /// @notice Replaces bytecode at an existing system contract address.
    function upgradeTo(address contractAddress, bytes calldata byteCode) external;

    /// @notice Deploys bytecode to a system contract address.
    function deployTo(address contractAddress, bytes calldata byteCode) external;
}
