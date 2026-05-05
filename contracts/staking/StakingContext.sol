// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./StakingErrors.sol";

import "./interfaces/IChainConfig.sol";
import "./interfaces/IGovernance.sol";
import "./interfaces/ISlashingIndicator.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/ISystemReward.sol";

/// @title Staking system context
/// @notice Stores staking module dependencies and exposes shared access-control modifiers.
/// @dev Each concrete staking contract wires shared dependencies through immutable constructor arguments.
abstract contract StakingContext is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, StakingErrors {
    IStaking internal immutable _stakingContract;
    ISlashingIndicator internal immutable _slashingIndicatorContract;
    ISystemReward internal immutable _systemRewardContract;
    IStakingPool internal immutable _stakingPoolContract;
    IGovernance internal immutable _governanceContract;
    IChainConfig internal immutable _chainConfigContract;

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract
    ) {
        _stakingContract = stakingContract;
        _slashingIndicatorContract = slashingIndicatorContract;
        _systemRewardContract = systemRewardContract;
        _stakingPoolContract = stakingPoolContract;
        _governanceContract = governanceContract;
        _chainConfigContract = chainConfigContract;
        // Disable initializer for UUPS proxy contract.
        _disableInitializers();
    }

    function __StakingContext_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    modifier onlyFromCoinbase() {
        if (msg.sender != block.coinbase) revert OnlyCoinbase();
        _;
    }

    modifier onlyFromSlashingIndicator() {
        if (msg.sender != address(_slashingIndicatorContract)) revert OnlySlashingIndicator();
        _;
    }

    modifier onlyFromGovernance() {
        if (IGovernance(msg.sender) != _governanceContract) revert OnlyGovernance();
        _;
    }

    modifier onlyZeroGasPrice() {
        if (tx.gasprice != 0) revert OnlyZeroGasPrice();
        _;
    }

    function getStaking() public view returns (IStaking) {
        return _stakingContract;
    }

    function getSlashingIndicator() public view returns (ISlashingIndicator) {
        return _slashingIndicatorContract;
    }

    function getSystemReward() public view returns (ISystemReward) {
        return _systemRewardContract;
    }

    function getStakingPool() public view returns (IStakingPool) {
        return _stakingPoolContract;
    }

    function getGovernance() public view returns (IGovernance) {
        return _governanceContract;
    }

    function getChainConfig() public view returns (IChainConfig) {
        return _chainConfigContract;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
