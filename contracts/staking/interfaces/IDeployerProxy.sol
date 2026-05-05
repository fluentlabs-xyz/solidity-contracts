// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Deployer proxy interface
/// @notice Registry for deployer permissions and active/banned system contract state.
interface IDeployerProxy {
    /// @notice Registers `impl` as a contract deployed by `account`.
    function registerDeployedContract(address account, address impl) external;

    /// @notice Reverts if `impl` is not an active contract.
    function checkContractActive(address impl) external;

    /// @notice Returns whether `account` can deploy contracts through the proxy.
    function isDeployer(address account) external view returns (bool);

    /// @notice Returns deployment state for `contractAddress`.
    function getContractState(address contractAddress)
        external
        view
        returns (address deployer, bool banned, bool active, uint256 version);

    /// @notice Returns whether `account` is banned.
    function isBanned(address account) external view returns (bool);

    /// @notice Grants deployer permission to `account`.
    function addDeployer(address account) external;

    /// @notice Bans `account` from deployment operations.
    function banDeployer(address account) external;

    /// @notice Removes a deployment ban from `account`.
    function unbanDeployer(address account) external;

    /// @notice Removes deployer permission from `account`.
    function removeDeployer(address account) external;

    /// @notice Disables `contractAddress`.
    function disableContract(address contractAddress) external;

    /// @notice Re-enables `contractAddress`.
    function enableContract(address contractAddress) external;
}
