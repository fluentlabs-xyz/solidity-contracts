// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingContext} from "./StakingContext.sol";

import {IStaking} from "./interfaces/IStaking.sol";
import {IGovernance} from "./interfaces/IGovernance.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {ISlashingIndicator} from "./interfaces/ISlashingIndicator.sol";
import {IChainConfig, IChainConfigEvents} from "./interfaces/IChainConfig.sol";

/**
 * @title Staking chain configuration
 * @author Fluent Labs
 * @notice Stores consensus and staking parameters controlled by governance.
 * @dev Values are consumed by `Staking` and `StakingPool` for epoch, jail, undelegation, and minimum stake logic.
 */
contract ChainConfig is StakingContext, IChainConfig, IChainConfigEvents {
    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.ChainConfigStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CHAIN_CONFIG_STORAGE_LOCATION = 0x8046150a36ce023dec392c496d6e64fcdc42b4e5054073dafc987cdbcc500e00;

    /// @custom:storage-location erc7201:Fluent.storage.ChainConfigStorage
    struct ChainConfigStorage {
        /**
         * @dev Maximum number of validators returned in the active validator set.
         *      Used in `Staking` and `StakingPool` to select the top validators.
         */
        uint32 _activeValidatorsLength;
        uint32 _epochBlockInterval;
        uint32 _misdemeanorThreshold;
        uint32 _felonyThreshold;
        uint32 _validatorJailEpochLength;
        uint32 _undelegatePeriod;
        uint256 _minValidatorStakeAmount;
        uint256 _minStakingAmount;
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
        __ChainConfig_init(
            activeValidatorsLength,
            epochBlockInterval,
            misdemeanorThreshold,
            felonyThreshold,
            validatorJailEpochLength,
            undelegatePeriod,
            minValidatorStakeAmount,
            minStakingAmount
        );
    }

    function getActiveValidatorsLength() external view override returns (uint32) {
        return _getChainConfigStorage()._activeValidatorsLength;
    }

    function setActiveValidatorsLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ActiveValidatorsLengthChanged($._activeValidatorsLength, newValue);
        $._activeValidatorsLength = newValue;
    }

    function getEpochBlockInterval() external view override returns (uint32) {
        return _getChainConfigStorage()._epochBlockInterval;
    }

    function setEpochBlockInterval(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit EpochBlockIntervalChanged($._epochBlockInterval, newValue);
        $._epochBlockInterval = newValue;
    }

    function getMisdemeanorThreshold() external view override returns (uint32) {
        return _getChainConfigStorage()._misdemeanorThreshold;
    }

    function setMisdemeanorThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit MisdemeanorThresholdChanged($._misdemeanorThreshold, newValue);
        $._misdemeanorThreshold = newValue;
    }

    function getFelonyThreshold() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $._felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit FelonyThresholdChanged($._felonyThreshold, newValue);
        $._felonyThreshold = newValue;
    }

    function getValidatorJailEpochLength() external view override returns (uint32) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $._validatorJailEpochLength;
    }

    function setValidatorJailEpochLength(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ValidatorJailEpochLengthChanged($._validatorJailEpochLength, newValue);
        $._validatorJailEpochLength = newValue;
    }

    function getUndelegatePeriod() external view override returns (uint32) {
        return _getChainConfigStorage()._undelegatePeriod;
    }

    function setUndelegatePeriod(uint32 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit UndelegatePeriodChanged($._undelegatePeriod, newValue);
        $._undelegatePeriod = newValue;
    }

    function getMinValidatorStakeAmount() external view returns (uint256) {
        return _getChainConfigStorage()._minValidatorStakeAmount;
    }

    function setMinValidatorStakeAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit MinValidatorStakeAmountChanged($._minValidatorStakeAmount, newValue);
        $._minValidatorStakeAmount = newValue;
    }

    function getMinStakingAmount() external view returns (uint256) {
        return _getChainConfigStorage()._minStakingAmount;
    }

    function setMinStakingAmount(uint256 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit MinStakingAmountChanged($._minStakingAmount, newValue);
        $._minStakingAmount = newValue;
    }

    function __ChainConfig_init(
        uint32 activeValidatorsLength,
        uint32 epochBlockInterval,
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount
    ) internal onlyInitializing {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        require(activeValidatorsLength > 0, ZeroValue("activeValidatorsLength"));
        $._activeValidatorsLength = activeValidatorsLength;
        emit ActiveValidatorsLengthChanged(0, activeValidatorsLength);

        require(epochBlockInterval > 0, ZeroValue("epochBlockInterval"));
        $._epochBlockInterval = epochBlockInterval;
        emit EpochBlockIntervalChanged(0, epochBlockInterval);

        require(misdemeanorThreshold > 0, ZeroValue("misdemeanorThreshold"));
        $._misdemeanorThreshold = misdemeanorThreshold;
        emit MisdemeanorThresholdChanged(0, misdemeanorThreshold);

        require(felonyThreshold > 0, ZeroValue("felonyThreshold"));
        $._felonyThreshold = felonyThreshold;
        emit FelonyThresholdChanged(0, felonyThreshold);

        require(validatorJailEpochLength > 0, ZeroValue("validatorJailEpochLength"));
        $._validatorJailEpochLength = validatorJailEpochLength;
        emit ValidatorJailEpochLengthChanged(0, validatorJailEpochLength);

        require(undelegatePeriod > 0, ZeroValue("undelegatePeriod"));
        $._undelegatePeriod = undelegatePeriod;
        emit UndelegatePeriodChanged(0, undelegatePeriod);

        require(minValidatorStakeAmount > 0, ZeroValue("minValidatorStakeAmount"));
        $._minValidatorStakeAmount = minValidatorStakeAmount;
        emit MinValidatorStakeAmountChanged(0, minValidatorStakeAmount);

        require(minStakingAmount > 0, ZeroValue("minStakingAmount"));
        $._minStakingAmount = minStakingAmount;
        emit MinStakingAmountChanged(0, minStakingAmount);
    }
}
