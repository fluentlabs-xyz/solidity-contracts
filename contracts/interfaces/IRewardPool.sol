// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IstBlend} from "./IstBlend.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IRewardPoolErrors
 * @author Fluent Labs
 * @notice Error set for {RewardPool}.
 */
interface IRewardPoolErrors {
    /**
     * @notice Required address parameter is the zero address.
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Required amount parameter is zero where a positive value is mandatory.
     */
    error ZeroAmount();

    /**
     * @notice {distribute} was called before the current epoch elapsed.
     * @param nextAllowed Earliest timestamp at which the next distribution may execute.
     */
    error DistributionTooEarly(uint64 nextAllowed);

    /**
     * @notice The pool does not hold enough reward tokens to cover the configured daily amount.
     * @param required Configured {dailyRewardAmount}.
     * @param available Current reward-token balance held by the pool.
     */
    error InsufficientBalance(uint256 required, uint256 available);

    /**
     * @notice {initialize} or an admin setter was called with a distribution period outside the safety bounds.
     */
    error InvalidDistributionPeriod(uint64 duration, uint64 min, uint64 max);
}

/**
 * @title IRewardPoolEvents
 * @author Fluent Labs
 * @notice Events emitted by {RewardPool}.
 */
interface IRewardPoolEvents {
    /**
     * @notice Emitted when reward tokens are deposited into the pool.
     */
    event Funded(address indexed funder, uint256 amount);

    /**
     * @notice Emitted when a daily reward bundle is pushed into the linked {stBlend} vault.
     */
    event RewardsDistributed(address indexed caller, uint256 amount, uint64 periodFinish);

    /**
     * @notice Emitted when the admin updates the per-epoch reward amount.
     */
    event DailyRewardAmountUpdated(uint256 previousAmount, uint256 newAmount);

    /**
     * @notice Emitted when the admin updates the minimum time between distributions.
     */
    event DistributionPeriodUpdated(uint64 previousPeriod, uint64 newPeriod);
}

/**
 * @title IRewardPool
 * @author Fluent Labs
 *
 * @notice External reward treasury that funds a linked {stBlend} vault once per epoch by
 *         calling {IstBlend-notifyRewards}. Holds {REWARDS_DISTRIBUTOR_ROLE} on the vault.
 *
 * @dev    Anyone may {fund} the pool. {distribute} is permissionless so keepers or cron
 *         jobs can push rewards on schedule without privileged keys.
 */
interface IRewardPool is IRewardPoolErrors, IRewardPoolEvents {
    /// @notice Lower bound on {distributionPeriod}.
    function MIN_DISTRIBUTION_PERIOD() external view returns (uint64);

    /// @notice Upper bound on {distributionPeriod}.
    function MAX_DISTRIBUTION_PERIOD() external view returns (uint64);

    /// @notice Linked ERC-4626 vault that receives streamed rewards.
    function vault() external view returns (IstBlend);

    /// @notice Underlying reward token; must match {IstBlend-asset}.
    function rewardToken() external view returns (IERC20);

    /// @notice Reward amount pushed to the vault on each successful {distribute} call.
    function dailyRewardAmount() external view returns (uint256);

    /// @notice Minimum elapsed time between consecutive {distribute} calls, in seconds.
    function distributionPeriod() external view returns (uint64);

    /// @notice Timestamp of the most recent successful {distribute}. Zero before the first call.
    function lastDistributionTime() external view returns (uint64);

    /**
     * @notice Deposit `amount` reward tokens into the pool.
     * @dev    Caller must have approved this contract for at least `amount`.
     */
    function fund(uint256 amount) external;

    /**
     * @notice Push {dailyRewardAmount} reward tokens into the linked vault via {notifyRewards}.
     * @dev    Callable once per {distributionPeriod}. Reverts if the pool balance is
     *         insufficient or the amount would yield a zero per-second rate in the vault.
     */
    function distribute() external;

    /**
     * @notice Update the reward amount for future {distribute} calls.
     */
    function setDailyRewardAmount(uint256 newAmount) external;

    /**
     * @notice Update the minimum time between {distribute} calls.
     */
    function setDistributionPeriod(uint64 newPeriod) external;

    /**
     * @notice Withdraw reward tokens to `to`. Restricted to {DEFAULT_ADMIN_ROLE}.
     */
    function recoverRewards(uint256 amount, address to) external;
}
