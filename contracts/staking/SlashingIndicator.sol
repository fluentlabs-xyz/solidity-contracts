// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./StakingContext.sol";

/// @title Slashing indicator
/// @notice Coinbase-only adapter that reports validator faults to `Staking`.
contract SlashingIndicator is ISlashingIndicator, StakingContext {
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

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    function slash(address validator) external virtual override onlyFromCoinbase {
        // we need this proxy to be compatible with BSC
        _stakingContract.slash(validator);
    }
}
