# Staking test cases

This document describes the current Foundry test coverage for the staking contracts.

Source suites:

- `test/staking/Staking.t.sol`
- `test/staking/StakingAdditional.t.sol`

The tests deploy the staking module behind ERC-1967 proxies and use `MockBlendToken` as the staking token. Most tests use `ONE = 1 ether`, an epoch interval configured through `ChainConfig`, and `_rollToNextEpoch()` to move queued delegation, undelegation, and reward accounting across epoch boundaries.

## Baseline Deployment

Both suites deploy the full staking module:

- `Staking`
- `SlashingIndicator`
- `SystemReward`
- `StakingPool`
- `ChainConfig`

The setup checks deterministic deployment wiring by comparing each deployed proxy address with its predicted address. It also pre-funds test actors and grants staking-token approvals to `Staking` and `StakingPool`.

## Core Delegation And Validator Ordering

- `test_stakerCanDelegateToValidator`
  Scenario: two stakers delegate to the same validator.
  Checks: per-staker delegated balances, validator total delegated stake, validator active status, token movement from staker to staking contract.

- `test_delegateAfterCommittedDelegationIncreasesAmount`
  Scenario: a staker delegates once, waits for the delegation epoch to commit, then delegates again.
  Checks: committed and newly queued delegation are aggregated in the delegator view.

- `test_undelegateUpdatesActiveSetAndClaimableFunds`
  Scenario: two validators have different delegated stake, one validator receives undelegations, and the active set is re-evaluated across epochs.
  Checks: invalid undelegate amounts revert, current-epoch ordering does not change before the epoch rolls, next-epoch ordering reflects reduced stake, and fully undelegated funds become claimable after the undelegate period.

- `test_activeValidatorSetDependsOnDelegatedAmount`
  Scenario: four validators compete for a three-validator active set.
  Checks: top validators are ordered by current delegated amount, a same-epoch delegation to a new validator does not affect the active set immediately, and the new higher-stake validator enters the active set after the next epoch.

- `test_RevertIf_delegateToUnknownValidator`
  Scenario: a staker attempts to delegate to an address that is not registered as a validator.
  Checks: delegation reverts with `ValidatorNotFound`.

- `test_statusAndDelegationViewsForEmptyAndHistoricalEpochs`
  Scenario: delegation views are queried before any delegation and after a committed delegation.
  Checks: empty delegation views return zero values, historical validator status reflects committed delegated stake, `isValidatorActive` distinguishes active and unknown validators, and unknown validators have zero pending validator fee.

- `test_userCanUndelegateAfterUndelegate`
  Scenario: a delegator queues multiple undelegations across epochs.
  Checks: repeated undelegations reduce validator total delegated stake to zero and the full withdrawn principal becomes claimable after the undelegate period.

- `test_RevertIf_undelegateMoreThanDelegated`
  Scenario: a delegator builds several queued delegations and then attempts to undelegate more than the remaining balance.
  Checks: the over-undelegation path eventually reverts with `InsufficientBalance`, valid remaining undelegation succeeds, and all original delegated principal becomes claimable after maturity.

- `test_RevertIf_undelegateFromUnknownValidator`
  Scenario: a user attempts to undelegate from an address that is not a validator.
  Checks: undelegation reverts with `ValidatorNotFound`.

- `test_incorrectStakingAmounts`
  Scenario: staking minimums and compact-balance precision are configured to expose invalid amount paths.
  Checks: valid precision-compatible amount succeeds, non-precision-compatible amounts revert with `WrongAmountPrecision`, and zero amount reverts with `AmountTooLow`.

## Validator Lifecycle

- `test_canAddAndRemoveValidator`
  Scenario: governance adds and removes a validator with no active delegations.
  Checks: module dependency getters return the wired contracts, `isValidator` changes correctly, and the active validator list is updated on add/remove.

- `test_removeValidatorFromBeginningMiddleAndEnd`
  Scenario: governance removes validators from each position in the active list.
  Checks: removing the first, middle, and last validator leaves the remaining validators registered and active.

- `test_validatorCanUndelegateInitialStake`
  Scenario: a validator registers with self-stake and later undelegates that initial stake.
  Checks: initial self-delegation is tracked, self-undelegation matures after the undelegate period, and the validator owner can claim the original principal.

- `test_validatorOwnerCanChangeOwnerAndCommission`
  Scenario: a validator owner rotates ownership and unauthorized accounts try owner-only actions.
  Checks: `getValidatorByOwner` is updated after owner rotation and unauthorized owner/commission changes revert with `OnlyValidatorOwner`.

- `test_registerValidatorRejectsInvalidInputsAndDuplicateOwners`
  Scenario: validator registration is attempted with invalid stake, invalid precision, invalid commission, duplicate validator address, and duplicate owner.
  Checks: registration reverts with the expected custom errors, and a valid registration succeeds before duplicate cases are checked.

- `test_validatorLifecycleRejectsInvalidCallersAndStatuses`
  Scenario: non-governance users and invalid status transitions call governance-controlled lifecycle functions.
  Checks: non-governance add/disable/remove calls revert, and activating an already active validator reverts with `NotPendingValidator`.

- `test_removeValidatorRevertsWhileDelegationsAreActive`
  Scenario: governance attempts to remove a validator while delegated stake is active, then after undelegation.
  Checks: removal with active delegations reverts with `ValidatorHasActiveDelegations`, removal after undelegation succeeds, and the delegator can still claim matured undelegated funds after removal.

- `test_RevertIf_changeValidatorOwner_newOwnerIsZero`
  Scenario: a validator owner attempts to transfer ownership to the zero address.
  Checks: owner change reverts with `OwnerCantBeZero`.

- `test_disableValidatorAndPendingRewardViews`
  Scenario: a validator has active delegation and pending rewards, then governance disables it.
  Checks: pending delegator and validator reward views return expected values, disable changes validator status, disabled validators are no longer active, and disabling an already non-active validator reverts with `NotActiveValidator`.

- `test_changeValidatorOwner_revertsWhenValidatorUnknown`
  Scenario: owner change is attempted for an unknown validator.
  Checks: call reverts with `ValidatorNotFound`.

- `test_registerValidatorUpdatesStateBeforePullingTokens`
  Scenario: validator registration pulls tokens after updating internal state.
  Checks: token balance decreases by the self-stake amount and validator status/owner are visible immediately after registration.

- `test_ownerCannotUndelegateBelowMinimumWhileOtherDelegatorsRemain`
  Scenario: a validator owner tries to reduce self-stake below the configured minimum while another delegator remains.
  Checks: draining below minimum reverts with `OwnerSelfStakeBelowMinimum`, but reducing self-stake down to exactly the minimum succeeds.

- `test_ownerCanDrainSelfStakeOnceOtherDelegatorsLeave`
  Scenario: all external delegators leave before the validator owner drains self-stake.
  Checks: after other delegators undelegate, the owner can fully undelegate self-stake and validator total delegated stake becomes zero.

## Slashing And Jail

- `test_noValidatorRewardsForInactivitySlashOnly`
  Scenario: one validator is repeatedly slashed for inactivity and then receives rewards.
  Checks: the unslashed validator has no validator fee from the slashed validator's reward, and the slashed validator's claim path routes the reward to `SystemReward`.

- `test_putValidatorInJailAfterFelonyThreshold`
  Scenario: a validator accumulates slashes up to the felony threshold.
  Checks: validator remains active before the threshold and enters jail status once the felony threshold is reached.

- `test_validatorCanBeReleasedFromJailByOwner`
  Scenario: a jailed validator is released after the jail period.
  Checks: release fails when the validator is not jailed, fails before jail expiry, fails for non-owner callers, and succeeds for the validator owner after enough epochs pass.

- `test_jailedValidatorLeavesAndRejoinsActiveSet`
  Scenario: a validator is jailed and later released.
  Checks: jailed validator is removed from the active validator set and rejoins after the jail period and owner release.

## Validator And Delegator Rewards

- `test_validatorCanClaimCommissionAndDelegatorRewards`
  Scenario: a validator with self-stake and commission receives rewards over multiple epochs.
  Checks: validator commission and self-delegator rewards are split according to the configured commission rate.

- `test_stakerRewardsWithMultipleDelegations`
  Scenario: a validator owner and external delegator both participate, with delegations spread across epochs.
  Checks: validator commission, owner delegator rewards, and external delegator rewards are calculated proportionally across reward epochs.

- `test_onlyCommittedEpochIsClaimable`
  Scenario: rewards are deposited in the current epoch and the next epoch.
  Checks: only committed epochs are claimable; rewards deposited in the current uncommitted epoch are excluded from immediate claimable fee views.

- `test_validatorWithoutDelegatorsGetsAllRewards`
  Scenario: an active validator has no external delegators and receives a reward.
  Checks: the validator owner receives the entire reward as validator fee.

- `test_validatorRewardsAreWellCalculated`
  Scenario: a validator with low commission receives several reward deposits with different magnitudes.
  Checks: zero deposits and unknown validators revert, validator/delegator reward math matches expected values, reward views are stable across empty epochs, and delegator claim clears only the delegator fee.

- `test_epochBoundedClaimsAndUnsafeTransferPath`
  Scenario: bounded claim functions are called at valid and future epochs.
  Checks: claiming at a committed epoch succeeds, claiming beyond the current epoch reverts, and both validator and delegator bounded-claim paths are exercised.

- `test_delegatorCanClaimNewRewardsWithoutNewDelegations`
  Scenario: a delegator claims rewards, then receives new rewards without changing delegation.
  Checks: claiming clears prior rewards and later reward epochs remain claimable even without a new delegation snapshot.

- `test_userCanRedelegateStakingRewards`
  Scenario: a delegator compounds claimable rewards back into stake.
  Checks: available redelegation rounds down to compact-balance precision, dust is reported separately, redelegation clears claimable rewards, and delegated stake increases by the compacted amount.

- `test_delegatorClaimCapsAtMaxEpochsPerClaim`
  Scenario: a delegator accrues rewards over more epochs than the per-call claim cap.
  Checks: the view reports full rewards, the first claim is capped, and repeated claims drain the remaining rewards.

- `test_validatorOwnerClaimCapsAtMaxEpochsPerClaim`
  Scenario: a validator owner accrues commission over more epochs than the per-call claim cap.
  Checks: the first validator claim is capped and repeated claims drain the full validator commission.

- `test_emptyDelegatorClaimAndPoolClaimDoNotRevert`
  Scenario: a delegator claim is made for a validator when the caller has no claimable fee.
  Checks: empty claim path is a no-op and does not revert.

## Chain Config And Upgradeability

- `test_ownerControlsUUPSUpgrade`
  Scenario: UUPS upgrade authorization is exercised on a proxy.
  Checks: owner is set correctly, non-owner upgrade attempt reverts, and owner upgrade preserves ownership.

- `test_chainConfigGovernanceSetters`
  Scenario: governance updates all chain configuration parameters.
  Checks: each getter reflects the updated value and non-governance calls revert with `OnlyGovernance`.

- `test_chainConfigRejectsInconsistentSlashThresholds`
  Scenario: governance attempts to configure inconsistent misdemeanor/felony slash thresholds.
  Checks: misdemeanor threshold cannot exceed felony threshold and felony threshold cannot be below misdemeanor threshold.

## System Rewards

- `test_systemFeeCalculationAndDistribution`
  Scenario: token and native system fees are deposited, claimed with one distribution, then claimed again after changing distribution shares.
  Checks: accumulated token/native fees, manual claims, balance transfers, zeroing of fee counters, and proportional multi-account distribution.

- `test_systemRewardDustAndShareValidation`
  Scenario: distribution shares produce rounding dust and an invalid share total is configured.
  Checks: token/native dust remains in the reward contract and invalid total shares revert with `BadShareDistribution`.

- `test_systemRewardNativeClaimSupportsGasHeavyReceiver`
  Scenario: the native-fee recipient is a contract with a non-trivial `receive` function.
  Checks: native fee transfer forwards enough gas for the receiver to update state.

- `test_systemRewardDecreaseDistributionArraySize`
  Scenario: governance replaces a two-recipient reward distribution with a one-recipient distribution.
  Checks: stale recipients are removed and the new distribution array has the expected length and account.

- `test_systemFeeAutoClaimAfterThreshold`
  Scenario: system fees are deposited below and then above the auto-claim threshold.
  Checks: sub-threshold deposits remain accumulated, crossing the threshold auto-claims token/native fees to the treasury, and counters reset.

## Staking Pool

- `test_stakingPoolTracksStakedAmount`
  Scenario: multiple pool stakes are made by the same and different users.
  Checks: pool share accounting maps back to the correct per-user staked amounts.

- `test_stakingPoolClaimKeepsCompoundedRewards`
  Scenario: a pool staker earns compounded rewards, then unstakes only principal.
  Checks: staked amount includes compounded rewards before unstake and retains the residual reward balance after claiming the unstaked principal.

- `test_stakingPoolViewsAndPendingClaimableRewards`
  Scenario: pool ratio/views are queried around staking, reward compounding, a second staker deposit, and one pending unstake.
  Checks: empty pool ratio is 1e18, shares/pool state are exposed correctly, `claimableRewards` reports only matured pending unstakes, and `getPendingUnstakes` exposes queued entries.

- `test_stakingPool_secondStakerCanStakeWhileFirstHasPendingUnstake`
  Scenario: one staker has a pending unstake while another staker continues staking.
  Checks: pending unstakes do not block other users from staking and second staker's amount is tracked correctly.

- `test_stakingPool_doesNotClaimRewardsWhileUnstakeIsPending`
  Scenario: a pool user has a pending unstake while validator rewards are deposited and another user stakes.
  Checks: pool does not claim/compound rewards while an unstake is pending, pending unstake accounting remains intact, and underlying delegator fee stays in `Staking`.

- `test_stakingPoolRejectsInvalidUnstakeAndClaimStates`
  Scenario: invalid pool unstake and claim states are exercised.
  Checks: unstaking with no shares reverts with `NothingToUnstake`, over-unstaking reverts with `NotEnoughShares`, multiple pending unstakes are allowed, over-reserving remaining shares reverts, empty claim reverts with `NothingToClaim`, early claim reverts, mature claim drains the queue, and remaining staked amount is zero.

- `test_stakingPool_supportsMultiplePendingUnstakesQueued`
  Scenario: a staker queues two unstakes in different epochs.
  Checks: queue order and amounts are preserved, pool pending total is the sum of queued entries, only matured entries are claimable, partial claims pop matured entries and preserve later entries, and final claim drains the queue while leaving the expected remaining stake.

- `test_stakingPool_drainsAllMaturedUnstakesInSingleClaim`
  Scenario: a staker queues several unstakes in the same maturity window.
  Checks: `claimableRewards` sums all matured entries and one claim drains every matured pending unstake.

- `test_stakingPool_claimRevertsWhenNoEntryHasMatured`
  Scenario: a staker claims immediately after queuing an unstake.
  Checks: claim reverts with `EpochIsNotReady` and includes the pending entry's maturity epoch.

- `test_stakingPoolClaimDoesNotTurnPrincipalIntoDustRewards`
  Scenario: a pool staker unstakes and claims principal, then another user stakes.
  Checks: claimed principal is not misclassified as dust rewards, pool total stake and ratio remain stable after claim, and later staking does not compound phantom rewards.

## Audit Regression Tests

The later section of `StakingAdditional.t.sol` includes explicit regression tests tied to prior audit findings:

- `test_changeValidatorOwner_revertsWhenValidatorUnknown`
  Covers L-2: unknown validators must be rejected explicitly in owner-change flow.

- `test_validatorChangedAtPersistsThroughLifecycleTransitions`
  Covers M-1: lifecycle transitions and owner changes must persist bumped `changedAt` values so snapshot lookups remain correct.

- `test_registerValidatorUpdatesStateBeforePullingTokens`
  Covers M-3: registration follows checks-effects-interactions so internal state is updated before ERC20 transfer hooks can run.

- `test_ownerCannotUndelegateBelowMinimumWhileOtherDelegatorsRemain`
  Covers M-4: validator owners cannot drop self-stake below the minimum while external delegators remain.

- `test_ownerCanDrainSelfStakeOnceOtherDelegatorsLeave`
  Covers M-4 counterpart: once external delegators have exited, validator owners can drain self-stake for removal.

- `test_delegatorClaimCapsAtMaxEpochsPerClaim`
  Covers H-2: delegator reward claims are capped per call but can be fully drained through repeated claims.

- `test_validatorOwnerClaimCapsAtMaxEpochsPerClaim`
  Covers H-2 counterpart: validator commission claims are capped per call but can be fully drained through repeated claims.

## Current Coverage Themes

The suite currently checks:

- deployment wiring and UUPS authorization;
- governance-controlled configuration;
- validator registration, activation, disable, removal, jail, and release;
- delegation, undelegation, active set ordering, and epoch-delayed state changes;
- validator and delegator reward accounting, including claim caps and precision dust;
- staking pool share accounting, reward compounding, and multiple pending unstake queues;
- system reward accounting, native/token distribution, dust, and auto-claim behavior;
- many custom-error revert paths around authorization, invalid inputs, unknown validators, premature claims, and insufficient stake.

