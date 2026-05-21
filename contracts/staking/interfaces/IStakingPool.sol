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

/**
 * @title IStakingPool interface
 * @author Fluent Labs
 * @notice Provides share-based staking into a validator through the underlying `Staking` contract.
 */
interface IStakingPool is IStakingPoolEvents, IStakingPoolErrors {
    /**
     * @notice Accounting state for one validator pool.
     * @dev The validator pool is used to track the staking and unstaking of a validator.
     */
    struct ValidatorPool {
        /// @dev The address of the validator.
        address validatorAddress;
        /// @dev The total number of shares in the validator pool.
        uint256 sharesSupply;
        /// @dev The total amount of staked tokens in the validator pool.
        uint256 totalStakedAmount;
        /// @dev The amount of dust rewards in the pool.
        uint256 dustRewards;
        /// @dev The amount of pending unstake in the validator pool.
        uint256 pendingUnstake;
        /// @dev The epoch of the last update to the validator pool.
        uint64 epoch;
    }

    /**
     * @notice One outstanding unstake request for a staker and validator.
     */
    struct PendingUnstake {
        /// @dev The amount of tokens in the pending unstake.
        uint256 amount;
        /// @dev The number of shares in the pending unstake.
        uint256 shares;
        /// @dev The epoch of the pending unstake.
        uint64 epoch;
    }

    /**
     * @notice Returns the current stake represented by `staker` shares in `validator` pool.
     */
    function getStakedAmount(address validator, address staker) external view returns (uint256);

    /**
     * @notice Deposits `amount` staking tokens into `validator` pool and delegates it to staking.
     */
    function stake(address validator, uint256 amount) external;

    /**
     * @notice Starts undelegating `amount` from `validator` pool for `msg.sender`.
     */
    function unstake(address validator, uint256 amount) external;

    /**
     * @notice Returns matured amount pending claim for `staker` in `validator` pool.
     */
    function claimableRewards(address validator, address staker) external view returns (uint256);

    /**
     * @notice Claims a matured unstake from `validator` pool.
     */
    function claim(address validator) external;
}
