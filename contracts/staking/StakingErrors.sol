// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @notice Shared custom errors for the staking module.
interface StakingErrors {
    error AmountTooLow();
    error BadCommissionRate();
    error BadLength();
    error BadShareDistribution();
    error DepositIsZero();
    error DelegationQueueEmpty();
    error DelegationQueueNotEmpty();
    error InitialStakeBalanceMismatch();
    error InitialStakeTooLow();
    error InsufficientBalance();
    error InvalidClaimEpoch();
    error NotActiveValidator();
    error NotEnoughBalance();
    error NotEnoughShares();
    error NotPendingValidator();
    error NotReady();
    error NothingToClaim();
    error NothingToUnstake();
    error OnlyCoinbase();
    error OnlyGovernance();
    error OnlySlashingIndicator();
    error OnlyStakingContract();
    error OnlyValidatorOwner();
    error OnlyZeroGasPrice();
    error PendingUndelegate();
    error SafeTransferFailed();
    error StillInJail();
    error UnsafeTransferFailed();
    error ValidatorAlreadyExists();
    error ValidatorNotFound();
    error ValidatorNotInJail();
    error ValidatorOwnerAlreadyInUse();
    error WrongAmountPrecision();
    error ZeroAmount();
}
