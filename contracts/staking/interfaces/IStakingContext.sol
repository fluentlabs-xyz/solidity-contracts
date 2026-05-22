// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.30;

/**
 * @title IStakingContextErrors
 * @author Fluent Labs
 * @notice Shared error library used across the staking module.
 * @dev Concrete staking contracts inherit this interface through {StakingContext} so that
 *      `revert` selectors stay consistent across staking, the staking pool, the slashing
 *      indicator, the system reward, and governance.
 */
interface IStakingContextErrors {
    /**
     * @notice Amount is below the configured minimum required for the operation.
     * @param amount Amount that failed the minimum check.
     */
    error AmountTooLow(uint256 amount);

    /**
     * @notice Validator commission rate is outside the accepted range.
     * @param commissionRate Commission rate that failed validation.
     */
    error BadCommissionRate(uint16 commissionRate);

    /**
     * @notice Parallel-array arguments have mismatched lengths.
     * @dev Raised by initializers and configuration setters that accept paired arrays
     *      (e.g. `(accounts, shares)` or `(validators, initialStakes)`).
     */
    error MalformedInputLength();

    /**
     * @notice Aggregate share distribution failed validation.
     * @dev Either an individual share is out of bounds, or the sum across recipients is not
     *      equal to the required total (10_000 basis points).
     * @param shareDistribution Offending value (either the bad single share or the wrong sum).
     */
    error BadShareDistribution(uint16 shareDistribution);

    /**
     * @notice Deposit amount is zero.
     */
    error DepositIsZero();

    /**
     * @notice Delegator's delegate queue is empty for the targeted validator.
     */
    error DelegationQueueEmpty();

    /**
     * @notice Validator still has active delegations preventing the requested operation
     *         (typically validator removal).
     * @param delegationQueue Current length of the delegation queue.
     */
    error DelegationQueueNotEmpty(uint256 delegationQueue);

    /**
     * @notice Initial validator-set balance configuration is malformed.
     */
    error MalformedInitialBalance();

    /**
     * @notice Initial validator self-stake is below {IChainConfig-getMinValidatorStakeAmount}.
     * @param initialStake Provided initial stake.
     */
    error InitialStakeTooLow(uint256 initialStake);

    /**
     * @notice Insufficient balance for the requested staking accounting operation.
     */
    error InsufficientBalance();

    /**
     * @notice Claim attempted for an epoch in the future (only past or current epochs are settleable).
     */
    error InvalidClaimEpoch();

    /**
     * @notice Operation requires the validator to be in {IStaking.ValidatorStatus.Active}.
     */
    error NotActiveValidator();

    /**
     * @notice Insufficient balance for the requested staking accounting operation (variant
     *         used by paths that fall through reward distribution).
     */
    error NotEnoughBalance();

    /**
     * @notice Caller does not own enough pool shares for the requested unstake.
     * @param requiredShares Number of shares actually available to the caller after accounting
     *                       for any pre-existing pending unstakes.
     */
    error NotEnoughShares(uint256 requiredShares);

    /**
     * @notice Operation requires the validator to be in {IStaking.ValidatorStatus.Pending}.
     * @param validator Validator whose status failed the check.
     */
    error NotPendingValidator(address validator);

    /**
     * @notice Pending unstake has not yet reached its maturity epoch.
     * @param epoch Earliest epoch at which the pending entry becomes claimable.
     */
    error EpochIsNotReady(uint64 epoch);

    /**
     * @notice Caller has nothing to claim from the staking pool or staking contract.
     */
    error NothingToClaim();

    /**
     * @notice Caller has no active stake to unstake from the targeted validator pool.
     */
    error NothingToUnstake();

    /**
     * @notice Caller is not the block coinbase, which is required for the action.
     */
    error OnlyCoinbase();

    /**
     * @notice Caller is not the configured governance contract.
     */
    error OnlyGovernance();

    /**
     * @notice Caller is not the configured slashing indicator contract.
     */
    error OnlySlashingIndicator();

    /**
     * @notice Caller is not the configured staking contract.
     */
    error OnlyStakingContract();

    /**
     * @notice Caller is not the registered owner of the targeted validator.
     * @param validator Validator whose owner check failed.
     */
    error OnlyValidatorOwner(address validator);

    /**
     * @notice Caller must use a zero gas price (system path only).
     */
    error OnlyZeroGasPrice();

    /**
     * @notice Reserved for legacy single-pending-unstake enforcement; no longer thrown by the
     *         staking pool now that multiple in-flight unstakes are supported.
     */
    error PendingUndelegate();

    /**
     * @notice ERC20 `safeTransfer` returned false or did not return.
     */
    error SafeTransferFailed();

    /**
     * @notice Validator is still inside its jail window and cannot be released yet.
     * @param validator Validator that remains in jail.
     */
    error StillInJail(address validator);

    /**
     * @notice Low-level native ETH transfer failed (e.g. recipient reverted or ran out of gas).
     */
    error UnsafeTransferFailed();

    /**
     * @notice Validator with the same address is already registered.
     * @param validator Validator address that already exists.
     */
    error ValidatorAlreadyExists(address validator);

    /**
     * @notice Validator is not registered in the staking contract.
     * @param validator Validator address that was not found.
     */
    error ValidatorNotFound(address validator);

    /**
     * @notice Validator is not currently in jail (operation requires the jailed status).
     * @param validator Validator that is not in jail.
     */
    error ValidatorNotInJail(address validator);

    /**
     * @notice The targeted account is already registered as the owner of another validator.
     * @param validator Validator the caller tried to (re)register the owner against.
     */
    error ValidatorOwnerAlreadyInUse(address validator);

    /**
     * @notice Amount is not a multiple of the staking compact balance precision.
     */
    error WrongAmountPrecision();

    /**
     * @notice Amount argument is zero.
     */
    error ZeroAmount();

    /**
     * @notice Validator owner argument must not be the zero address.
     */
    error OwnerCantBeZero();

    /**
     * @notice Validator owner would reduce their self-stake below the configured minimum
     *         while other delegators remain.
     * @dev A full owner exit is allowed only when the owner is the sole remaining delegator,
     *      so governance can subsequently remove the validator.
     */
    error OwnerSelfStakeBelowMinimum();
}
