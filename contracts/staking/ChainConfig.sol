// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /// @custom:storage-location erc7201:Fluent.storage.ChainConfigStorage
    struct ChainConfigStorage {
        uint32 activeValidatorsLength;
        uint32 epochBlockInterval;
        uint32 misdemeanorThreshold;
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
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
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        StakingContext(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
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
        $.activeValidatorsLength = activeValidatorsLength;
        emit ActiveValidatorsLengthChanged(0, activeValidatorsLength);
        $.epochBlockInterval = epochBlockInterval;
        emit EpochBlockIntervalChanged(0, epochBlockInterval);
        $.misdemeanorThreshold = misdemeanorThreshold;
        emit MisdemeanorThresholdChanged(0, misdemeanorThreshold);
        $.felonyThreshold = felonyThreshold;
        emit FelonyThresholdChanged(0, felonyThreshold);
        $.validatorJailEpochLength = validatorJailEpochLength;
        emit ValidatorJailEpochLengthChanged(0, validatorJailEpochLength);
        $.undelegatePeriod = undelegatePeriod;
        emit UndelegatePeriodChanged(0, undelegatePeriod);
        $.minValidatorStakeAmount = minValidatorStakeAmount;
        emit MinValidatorStakeAmountChanged(0, minValidatorStakeAmount);
        $.minStakingAmount = minStakingAmount;
        emit MinStakingAmountChanged(0, minStakingAmount);
    }

    function getActiveValidatorsLength() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.activeValidatorsLength;
    }

    function setActiveValidatorsLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.activeValidatorsLength;
        $.activeValidatorsLength = newValue;
        emit ActiveValidatorsLengthChanged(prevValue, newValue);
    }

    function getEpochBlockInterval() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.epochBlockInterval;
    }

    function setEpochBlockInterval(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.epochBlockInterval;
        $.epochBlockInterval = newValue;
        emit EpochBlockIntervalChanged(prevValue, newValue);
    }

    function getMisdemeanorThreshold() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.misdemeanorThreshold;
    }

    function setMisdemeanorThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.misdemeanorThreshold;
        $.misdemeanorThreshold = newValue;
        emit MisdemeanorThresholdChanged(prevValue, newValue);
    }

    function getFelonyThreshold() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.felonyThreshold;
        $.felonyThreshold = newValue;
        emit FelonyThresholdChanged(prevValue, newValue);
    }

    function getValidatorJailEpochLength() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.validatorJailEpochLength;
    }

    function setValidatorJailEpochLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.validatorJailEpochLength;
        $.validatorJailEpochLength = newValue;
        emit ValidatorJailEpochLengthChanged(prevValue, newValue);
    }

    function getUndelegatePeriod() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.undelegatePeriod;
    }

    function setUndelegatePeriod(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint32 prevValue = $.undelegatePeriod;
        $.undelegatePeriod = newValue;
        emit UndelegatePeriodChanged(prevValue, newValue);
    }

    function getMinValidatorStakeAmount() external view returns (uint256) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.minValidatorStakeAmount;
    }

    function setMinValidatorStakeAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint256 prevValue = $.minValidatorStakeAmount;
        $.minValidatorStakeAmount = newValue;
        emit MinValidatorStakeAmountChanged(prevValue, newValue);
    }

    function getMinStakingAmount() external view returns (uint256) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $.minStakingAmount;
    }

    function setMinStakingAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        uint256 prevValue = $.minStakingAmount;
        $.minStakingAmount = newValue;
        emit MinStakingAmountChanged(prevValue, newValue);
    }
}
