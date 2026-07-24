// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingContextErrors} from "./interfaces/IStakingContext.sol";

// EIP-4788 / EIP-7002 / EIP-2935 canonical system sentinel address.
address constant SYSTEM_CALLER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

/**
 * @title Staking system context
 * @author Fluent Labs
 * @notice Stores staking module dependencies and exposes shared access-control modifiers.
 * @dev Each concrete staking contract wires shared dependencies through immutable constructor arguments.
 */
abstract contract StakingContext is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IStakingContextErrors {
    IStaking internal immutable _stakingContract;
    ISystemReward internal immutable _systemRewardContract;
    IStakingPool internal immutable _stakingPoolContract;
    IFluentGovernance internal immutable _governanceContract;
    IChainConfig internal immutable _chainConfigContract;
    IERC20 internal immutable _stakingToken;

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    ) {
        _stakingContract = stakingContract;
        _systemRewardContract = systemRewardContract;
        _stakingPoolContract = stakingPoolContract;
        _governanceContract = governanceContract;
        _chainConfigContract = chainConfigContract;
        _stakingToken = stakingToken;
        _disableInitializers();
    }

    function __StakingContext_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @dev System-call entry-point guard. Only callable when `msg.sender`
    ///      is the canonical EIP-4788 sentinel.
    modifier onlySystemCall() {
        require(msg.sender == SYSTEM_CALLER, OnlySystemCall());
        _;
    }

    modifier onlyFromGovernance() {
        require(IFluentGovernance(msg.sender) == _governanceContract, OnlyGovernanceContract());
        _;
    }

    modifier onlyFromStaking() {
        require(IStaking(msg.sender) == _stakingContract, OnlyStakingContract());
        _;
    }

    function getStaking() public view returns (IStaking) {
        return _stakingContract;
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
