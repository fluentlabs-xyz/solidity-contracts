// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../Staking.sol";

/// @title Test staking implementation
/// @notice Exposes governance/coinbase/slashing-restricted hooks for tests by bypassing production access checks.
contract MockStaking is Staking {
    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        Staking(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {}

    function addValidator(address account) external override {
        _addValidator(account, account, ValidatorStatus.Active, 0, 0, _nextEpoch());
    }

    function removeValidator(address account) external override {
        _removeValidator(account);
    }

    function activateValidator(address validator) external override {
        _activateValidator(validator);
    }

    function disableValidator(address validator) external override {
        _disableValidator(validator);
    }

    function deposit(address validatorAddress, uint256 amount) external override {
        _depositFee(validatorAddress, amount);
    }

    function slash(address validatorAddress) external override {
        _slashValidator(validatorAddress);
    }
}
