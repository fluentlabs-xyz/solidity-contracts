// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../SystemReward.sol";

/// @title Test system reward implementation
/// @notice Exposes reward distribution updates without governance restrictions for tests.
contract MockSystemReward is SystemReward {
    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        SystemReward(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {}

    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external virtual override {
        _updateDistributionShare(accounts, shares);
    }
}
