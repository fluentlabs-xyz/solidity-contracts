// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IStakingPoolEvents
 * @dev Lifecycle events emitted by the staking pool for stake, unstake, and claim actions.
 */
interface IStakingPoolEvents {
    /**
     * @notice Emitted when `staker` deposits `amount` staking tokens into `validator` pool via {IStakingPool-stake}.
     */
    event Staked(address indexed validator, address indexed staker, uint256 amount);

    /**
     * @notice Emitted when `staker` enqueues a new pending unstake of `amount` from `validator` pool via {IStakingPool-unstake}.
     * @dev A new {IStakingPool-PendingUnstake} entry is appended to the staker's queue for the validator;
     *      it is settled separately once it matures via {IStakingPool-claim}.
     */
    event Unstaked(address indexed validator, address indexed staker, uint256 amount);

    /**
     * @notice Emitted when `staker` claims `amount` from `validator` pool via {IStakingPool-claim}.
     * @dev `amount` is the sum of every matured {IStakingPool-PendingUnstake} entry drained in the call,
     *      not the rewards earned on the underlying stake.
     */
    event RewardsClaimed(address indexed validator, address indexed staker, uint256 amount);
}

/**
 * @title IStakingPoolErrors
 * @dev Custom errors raised by the staking pool.
 */
interface IStakingPoolErrors {
    /**
     * @notice Validator address argument must not be the zero address.
     */
    error ZeroValidator();

    /**
     * @notice Staker address argument must not be the zero address.
     */
    error ZeroStaker();
}

/**
 * @title IStakingPool
 * @author Fluent Labs
 * @notice Share-based pooled staking on top of the underlying `Staking` contract.
 * @dev Users deposit the staking ERC20 against a specific validator and receive a proportional share of
 *      the pool's delegated stake plus compounded rewards. The pool handles delegation, periodic reward
 *      claims, and unstake finalization on behalf of all depositors.
 */
interface IStakingPool is IStakingPoolEvents, IStakingPoolErrors {
    /**
     * @notice Accounting state for one validator pool.
     * @dev Tracks the aggregate share supply, delegated stake, residual reward dust, and the total
     *      amount reserved by in-flight {PendingUnstake} entries across all stakers.
     */
    struct ValidatorPool {
        /// @dev Address of the validator the pool is bound to.
        address validatorAddress;
        /// @dev Total number of shares minted by the pool.
        uint256 sharesSupply;
        /// @dev Total amount of staking tokens currently delegated through the pool.
        uint256 totalStakedAmount;
        /// @dev Reward residue below the staking compact precision; carried forward to combine with future rewards.
        uint256 dustRewards;
        /// @dev Total amount reserved by all in-flight {PendingUnstake} entries for this validator.
        uint256 pendingUnstake;
        /// @dev Epoch of the last update to the validator pool.
        uint64 epoch;
    }

    /**
     * @notice One outstanding unstake request belonging to a single (validator, staker) pair.
     * @dev Multiple entries may coexist per staker; they are stored in the order they are appended by
     *      {IStakingPool-unstake} and matured prefix-first by {IStakingPool-claim}.
     */
    struct PendingUnstake {
        /// @dev Amount of staking tokens reserved for this pending unstake.
        uint256 amount;
        /// @dev Number of shares reserved for this pending unstake; burned at {IStakingPool-claim} time.
        uint256 shares;
        /// @dev Maturity epoch — `currentEpoch` must reach this value before the entry is claimable.
        uint64 epoch;
    }

    /**
     * @notice Returns the current stake represented by a staker's pool shares.
     * @dev Converts the staker's full share balance, including shares already reserved by pending
     *      unstakes, to the underlying token amount at the current pool ratio.
     * @param validator Validator the shares are bound to.
     * @param staker Account whose share balance is being valued.
     * @return amount Staking token amount currently represented by the staker's shares.
     */
    function getStakedAmount(address validator, address staker) external view returns (uint256 amount);

    /**
     * @notice Returns the raw share balance held by `staker` in `validator` pool.
     * @dev Includes shares still reserved by in-flight {PendingUnstake} entries; shares are only
     *      burned when {claim} settles a matured entry.
     * @param validator Validator the shares are bound to.
     * @param staker Account whose share balance is returned.
     * @return shares Number of pool shares owned by the staker.
     */
    function getShares(address validator, address staker) external view returns (uint256 shares);

    /**
     * @notice Returns the aggregated {ValidatorPool} accounting record for `validator`.
     * @dev The returned record materializes any unclaimed delegator rewards into
     *      {ValidatorPool-totalStakedAmount} and {ValidatorPool-dustRewards} so callers see the
     *      post-compound view without mutating storage.
     * @param validator Validator pool to read.
     * @return pool Pool accounting record snapshot.
     */
    function getValidatorPool(address validator) external view returns (ValidatorPool memory pool);

    /**
     * @notice Returns the current shares-per-asset ratio of `validator` pool, scaled to 1e18.
     * @dev Ratio is `sharesSupply * 1e18 / totalAssets`, rounded up. Used by frontends to display
     *      pool yield and by integration tests to verify invariants across stake/unstake cycles.
     * @param validator Validator pool to read.
     * @return ratio Shares-per-asset ratio scaled by 1e18.
     */
    function getRatio(address validator) external view returns (uint256 ratio);

    /**
     * @notice Deposits `amount` staking tokens into `validator` pool and delegates them via the underlying staking contract.
     * @dev Pulls `amount` from `msg.sender` (prior ERC20 approval required), mints pool shares at the
     *      current ratio, and calls {IStaking-delegate}. Emits {IStakingPoolEvents-Staked}.
     * @param validator Validator pool to deposit into.
     * @param amount Staking token amount to deposit.
     */
    function stake(address validator, uint256 amount) external;

    /**
     * @notice Starts undelegating `amount` from `validator` pool for `msg.sender`.
     * @dev Appends a new {PendingUnstake} entry to the caller's queue and calls {IStaking-undelegate}.
     *      A staker may keep multiple pending unstakes in flight per validator; each entry matures
     *      independently after the configured undelegate period and is settled via {IStakingPool-claim}.
     *      The call reverts with `NotEnoughShares` if `amount` plus the shares already reserved by
     *      earlier pending entries would exceed the staker's share balance. Emits {IStakingPoolEvents-Unstaked}.
     * @param validator Validator pool to unstake from.
     * @param amount Staking token amount to unstake.
     */
    function unstake(address validator, uint256 amount) external;

    /**
     * @notice Returns the amount of pending unstakes that have matured and can be claimed by `staker`
     *         in `validator` pool at the current epoch.
     * @dev Sums the `amount` field of every {PendingUnstake} whose `epoch` is less than or equal to
     *      `currentEpoch`. Unmatured entries are excluded; use {getPendingUnstakes} to inspect the full
     *      queue including maturity epochs of entries that are still locked.
     * @param validator Validator pool to query.
     * @param staker Account whose matured pending unstakes are summed.
     * @return amount Total staking token amount the staker can claim right now.
     */
    function claimableRewards(address validator, address staker) external view returns (uint256 amount);

    /**
     * @notice Returns the full queue of pending unstakes for `staker` in `validator` pool.
     * @dev Entries are returned in submission order. Maturity epochs are monotonically non-decreasing,
     *      so callers can binary-search or linearly walk the prefix to determine which entries are
     *      already claimable.
     * @param validator Validator pool to query.
     * @param staker Account whose pending unstake queue is returned.
     * @return queue Array of {PendingUnstake} entries in submission order.
     */
    function getPendingUnstakes(address validator, address staker) external view returns (PendingUnstake[] memory queue);

    /**
     * @notice Claims every matured pending unstake from `validator` pool for `msg.sender`.
     * @dev Drains the matured prefix of the caller's queue in a single call, burns the corresponding
     *      shares, settles any unclaimed delegator rewards collected from the underlying staking
     *      contract back into the pool, and transfers the matured tokens to `msg.sender`. Unmatured
     *      entries stay in the queue and can be claimed once they reach their epoch. Reverts with
     *      `NothingToClaim` when the queue is empty and with `EpochIsNotReady` when no entry has
     *      matured yet. Emits {IStakingPoolEvents-RewardsClaimed}.
     * @param validator Validator pool to claim from.
     */
    function claim(address validator) external;
}
