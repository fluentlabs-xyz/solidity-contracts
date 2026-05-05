// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./IChainConfig.sol";
import "./IGovernance.sol";
import "./ISlashingIndicator.sol";
import "./IStaking.sol";
import "./IStakingPool.sol";
import "./ISystemReward.sol";

/// @title Staking dependency injector interface
/// @notice Provides initialized system-contract references to staking module contracts.
interface IInjector {
    /// @notice Initializes the contract using encoded constructor parameters and injected dependencies.
    function init() external;

    /// @notice Returns whether initialization has completed.
    function isInitialized() external view returns (bool);

    /// @notice Returns the staking contract reference.
    function getStaking() external view returns (IStaking);

    /// @notice Returns the slashing indicator contract reference.
    function getSlashingIndicator() external view returns (ISlashingIndicator);

    /// @notice Returns the system reward contract reference.
    function getSystemReward() external view returns (ISystemReward);

    /// @notice Returns the pooled staking contract reference.
    function getStakingPool() external view returns (IStakingPool);

    /// @notice Returns the governance contract reference.
    function getGovernance() external view returns (IGovernance);

    /// @notice Returns the chain configuration contract reference.
    function getChainConfig() external view returns (IChainConfig);
}
