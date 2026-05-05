// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Staking chain configuration interface
/// @notice Exposes governance-controlled parameters used by validator staking and reward accounting.
interface IChainConfig {
    /// @notice Maximum number of validators returned in the active validator set.
    function getActiveValidatorsLength() external view returns (uint32);

    /// @notice Updates the active validator set size. Callable by governance.
    function setActiveValidatorsLength(uint32 newValue) external;

    /// @notice Number of blocks in one staking epoch.
    function getEpochBlockInterval() external view returns (uint32);

    /// @notice Updates the staking epoch length. Callable by governance.
    function setEpochBlockInterval(uint32 newValue) external;

    /// @notice Number of slash events treated as a misdemeanor threshold.
    function getMisdemeanorThreshold() external view returns (uint32);

    /// @notice Updates the misdemeanor slash threshold. Callable by governance.
    function setMisdemeanorThreshold(uint32 newValue) external;

    /// @notice Number of slash events after which a validator is jailed.
    function getFelonyThreshold() external view returns (uint32);

    /// @notice Updates the felony slash threshold. Callable by governance.
    function setFelonyThreshold(uint32 newValue) external;

    /// @notice Number of epochs a jailed validator must wait before release.
    function getValidatorJailEpochLength() external view returns (uint32);

    /// @notice Updates validator jail duration in epochs. Callable by governance.
    function setValidatorJailEpochLength(uint32 newValue) external;

    /// @notice Number of epochs before undelegated funds become claimable.
    function getUndelegatePeriod() external view returns (uint32);

    /// @notice Updates the undelegation delay in epochs. Callable by governance.
    function setUndelegatePeriod(uint32 newValue) external;

    /// @notice Minimum self-stake required to register a validator.
    function getMinValidatorStakeAmount() external view returns (uint256);

    /// @notice Updates validator registration minimum stake. Callable by governance.
    function setMinValidatorStakeAmount(uint256 newValue) external;

    /// @notice Minimum delegation amount accepted by staking.
    function getMinStakingAmount() external view returns (uint256);

    /// @notice Updates minimum delegation amount. Callable by governance.
    function setMinStakingAmount(uint256 newValue) external;
}
