// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Pooled staking interface
/// @notice Provides share-based staking into a validator through the underlying `Staking` contract.
interface IStakingPool {
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
