// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface IStakingPoolEvents {
    event Staked(address indexed validator, address indexed staker, uint256 amount);
    event Unstaked(address indexed validator, address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed validator, address indexed staker, uint256 amount);
}

interface IStakingPoolErrors {
    error ZeroValidator();
    error ZeroStaker();
}

/// @title Pooled staking interface
/// @notice Provides share-based staking into a validator through the underlying `Staking` contract.
interface IStakingPool is IStakingPoolEvents, IStakingPoolErrors {
    /// @notice Returns the current stake represented by `staker` shares in `validator` pool.
    function getStakedAmount(address validator, address staker) external view returns (uint256);

    /// @notice Deposits `amount` staking tokens into `validator` pool and delegates it to staking.
    function stake(address validator, uint256 amount) external;

    /// @notice Starts undelegating `amount` from `validator` pool for `msg.sender`.
    function unstake(address validator, uint256 amount) external;

    /// @notice Returns matured amount pending claim for `staker` in `validator` pool.
    function claimableRewards(address validator, address staker) external view returns (uint256);

    /// @notice Claims a matured unstake from `validator` pool.
    function claim(address validator) external;
}
