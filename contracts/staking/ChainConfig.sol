// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./StakingContext.sol";

/// @title Staking chain configuration
/// @notice Stores consensus and staking parameters controlled by governance.
/// @dev Values are consumed by `Staking` and `StakingPool` for epoch, jail, undelegation, and minimum stake logic.
contract ChainConfig is StakingContext, IChainConfig {
    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.ChainConfigStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CHAIN_CONFIG_STORAGE_LOCATION =
        0x8046150a36ce023dec392c496d6e64fcdc42b4e5054073dafc987cdbcc500e00;

    event ActiveValidatorsLengthChanged(uint32 prevValue, uint32 newValue);
    event EpochBlockIntervalChanged(uint32 prevValue, uint32 newValue);
    event MisdemeanorThresholdChanged(uint32 prevValue, uint32 newValue);
    event FelonyThresholdChanged(uint32 prevValue, uint32 newValue);
    event ValidatorJailEpochLengthChanged(uint32 prevValue, uint32 newValue);
    event UndelegatePeriodChanged(uint32 prevValue, uint32 newValue);
    event MinValidatorStakeAmountChanged(uint256 prevValue, uint256 newValue);
    event MinStakingAmountChanged(uint256 prevValue, uint256 newValue);

    /// @notice Snapshot of all mutable consensus parameters used by the staking module.
    struct ConsensusParams {
        uint32 activeValidatorsLength;
        uint32 epochBlockInterval;
        uint32 misdemeanorThreshold;
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
    }

    /// @custom:storage-location erc7201:Fluent.storage.ChainConfigStorage
    struct ChainConfigStorage {
        ConsensusParams consensusParams;
    }

    function _getChainConfigStorage() private pure returns (ChainConfigStorage storage $) {
        assembly {
            $.slot := CHAIN_CONFIG_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract
    )
        StakingContext(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract
        )
    {}

    function initialize(
        address initialOwner,
        uint32 activeValidatorsLength,
        uint32 epochBlockInterval,
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount
    ) external initializer {
        __StakingContext_init(initialOwner);
        ChainConfigStorage storage $ = _getChainConfigStorage();
        $.consensusParams.activeValidatorsLength = activeValidatorsLength;
        emit ActiveValidatorsLengthChanged(0, activeValidatorsLength);
        $.consensusParams.epochBlockInterval = epochBlockInterval;
        emit EpochBlockIntervalChanged(0, epochBlockInterval);
        $.consensusParams.misdemeanorThreshold = misdemeanorThreshold;
        emit MisdemeanorThresholdChanged(0, misdemeanorThreshold);
        $.consensusParams.felonyThreshold = felonyThreshold;
        emit FelonyThresholdChanged(0, felonyThreshold);
        $.consensusParams.validatorJailEpochLength = validatorJailEpochLength;
        emit ValidatorJailEpochLengthChanged(0, validatorJailEpochLength);
        $.consensusParams.undelegatePeriod = undelegatePeriod;
        emit UndelegatePeriodChanged(0, undelegatePeriod);
        $.consensusParams.minValidatorStakeAmount = minValidatorStakeAmount;
        emit MinValidatorStakeAmountChanged(0, minValidatorStakeAmount);
        $.consensusParams.minStakingAmount = minStakingAmount;
        emit MinStakingAmountChanged(0, minStakingAmount);
    }

    function getActiveValidatorsLength() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.activeValidatorsLength;
    }

    function setActiveValidatorsLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.activeValidatorsLength;
        $.consensusParams.activeValidatorsLength = newValue;
        emit ActiveValidatorsLengthChanged(prevValue, newValue);
    }

    function getEpochBlockInterval() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.epochBlockInterval;
    }

    function setEpochBlockInterval(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.epochBlockInterval;
        $.consensusParams.epochBlockInterval = newValue;
        emit EpochBlockIntervalChanged(prevValue, newValue);
    }

    function getMisdemeanorThreshold() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.misdemeanorThreshold;
    }

    function setMisdemeanorThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.misdemeanorThreshold;
        $.consensusParams.misdemeanorThreshold = newValue;
        emit MisdemeanorThresholdChanged(prevValue, newValue);
    }

    function getFelonyThreshold() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.felonyThreshold;
        $.consensusParams.felonyThreshold = newValue;
        emit FelonyThresholdChanged(prevValue, newValue);
    }

    function getValidatorJailEpochLength() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.validatorJailEpochLength;
    }

    function setValidatorJailEpochLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.validatorJailEpochLength;
        $.consensusParams.validatorJailEpochLength = newValue;
        emit ValidatorJailEpochLengthChanged(prevValue, newValue);
    }

    function getUndelegatePeriod() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.undelegatePeriod;
    }

    function setUndelegatePeriod(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.consensusParams.undelegatePeriod;
        $.consensusParams.undelegatePeriod = newValue;
        emit UndelegatePeriodChanged(prevValue, newValue);
    }

    function getMinValidatorStakeAmount() external view returns (uint256) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.minValidatorStakeAmount;
    }

    function setMinValidatorStakeAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint256 prevValue = $.consensusParams.minValidatorStakeAmount;
        $.consensusParams.minValidatorStakeAmount = newValue;
        emit MinValidatorStakeAmountChanged(prevValue, newValue);
    }

    function getMinStakingAmount() external view returns (uint256) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.consensusParams.minStakingAmount;
    }

    function setMinStakingAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint256 prevValue = $.consensusParams.minStakingAmount;
        $.consensusParams.minStakingAmount = newValue;
        emit MinStakingAmountChanged(prevValue, newValue);
    }
}
