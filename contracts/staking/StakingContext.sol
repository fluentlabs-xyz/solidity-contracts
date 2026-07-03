// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {ISlashingIndicator} from "./interfaces/ISlashingIndicator.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingContextErrors} from "./interfaces/IStakingContext.sol";

/**
 * @title Staking system context
 * @author Fluent Labs
 * @notice Stores staking module dependencies and exposes shared access-control modifiers.
 * @dev Each concrete staking contract wires shared dependencies through immutable constructor arguments.
 */
abstract contract StakingContext is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IStakingContextErrors {
    /**
     * @notice The staking contract.
     */
    IStaking internal immutable _stakingContract;
    /**
     * @notice The slashing indicator contract.
     */
    ISlashingIndicator internal immutable _slashingIndicatorContract;
    /**
     * @notice The system reward contract.
     */
    ISystemReward internal immutable _systemRewardContract;
    /**
     * @notice The staking pool contract.
     */
    IStakingPool internal immutable _stakingPoolContract;
    /**
     * @notice The governance contract.
     */
    IFluentGovernance internal immutable _governanceContract;
    /**
     * @notice The chain config contract.
     */
    IChainConfig internal immutable _chainConfigContract;
    /**
     * @notice The staking token.
     */
    IERC20 internal immutable _stakingToken;

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    ) {
        _stakingContract = stakingContract;
        _slashingIndicatorContract = slashingIndicatorContract;
        _systemRewardContract = systemRewardContract;
        _stakingPoolContract = stakingPoolContract;
        _governanceContract = governanceContract;
        _chainConfigContract = chainConfigContract;
        _stakingToken = stakingToken;
        // Disable initializer for UUPS proxy contract.
        _disableInitializers();
    }

    function __StakingContext_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    modifier onlyFromCoinbase() {
        require(msg.sender == block.coinbase, OnlyCoinbase());
        _;
    }

    modifier onlyFromSlashingIndicator() {
        require(msg.sender == address(_slashingIndicatorContract), OnlySlashingIndicator());
        _;
    }

    modifier onlyFromGovernance() {
        require(IFluentGovernance(msg.sender) == _governanceContract, OnlyGovernance());
        _;
    }

    modifier onlyZeroGasPrice() {
        require(tx.gasprice == 0, OnlyZeroGasPrice());
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

    function getGovernance() public view returns (IFluentGovernance) {
        return _governanceContract;
    }

    function getChainConfig() public view returns (IChainConfig) {
        return _chainConfigContract;
    }

    function getStakingToken() public view returns (IERC20) {
        return _stakingToken;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
