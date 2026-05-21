# Staking System Follow-up Audit

Date: 2026-05-19

Scope:
- `contracts/staking/Staking.sol`
- `contracts/staking/StakingPool.sol`
- `contracts/staking/StakingContext.sol`
- `contracts/staking/ChainConfig.sol`
- `contracts/staking/SystemReward.sol`
- `contracts/staking/SlashingIndicator.sol`
- `contracts/staking/interfaces/*`

Context:
- `_validatorRetired` was removed by request. Validator address re-use remains allowed and is assessed as an acknowledged design risk below.
- Recently applied fixes for claim loop caps, CEI ordering in `Staking`, `changedAt` persistence in lifecycle methods, owner self-stake floor, zero validator/owner checks, and `changeValidatorOwner` existence checks are included in scope.

## Executive Summary

The highest-confidence remaining issue is in `StakingPool`: concurrent pending unstakes for the same validator can leave another user’s reserved principal recorded as `dustRewards`, causing later pool compounding to attempt to delegate tokens the pool no longer holds. This can permanently DoS pool operations for that validator until extra tokens are sent to the pool or accounting is repaired.

The major protocol-level issue from the first audit remains open: slash counters are per-epoch, so validators can avoid felony/misdemeanor thresholds by spreading faults across epochs.

The removal of `_validatorRetired` is acknowledged. Address re-use is not automatically unsafe in the active-set path, but it leaves old snapshots/delegation queues keyed to the same validator address and creates asymmetric behavior: a new owner can re-register, while the same owner may be blocked by a stale `delegateQueue.length`.

## Findings

### H-1: StakingPool concurrent unstakes poison pool accounting

Severity: High

Location: `StakingPool.claim`, `_advanceValidatorPoolRewards`, `_calcCompoundableDelegatorFee`.

Description:
`StakingPool` is a single delegator from `Staking`’s perspective. If two users have matured pending unstakes for the same validator, the first user to call `claim()` triggers `_stakingContract.claimDelegatorFee(validator)`, which releases all matured undelegations for `address(stakingPool)`, not only the caller’s amount.

The current pool tries to reserve the other user’s still-pending amount by passing `claimedAmount - amount` into `_advanceValidatorPoolRewards`. When that amount equals the remaining `validatorPool.pendingUnstake`, `_calcCompoundableDelegatorFee` returns `(0, unclaimedRewards)`, storing the reserved principal in `dustRewards`.

The second user can still claim their principal because the token balance remains in the pool. However, after that second claim, `dustRewards` remains inflated even though the corresponding tokens were transferred out. The next `stake()` or `unstake()` call, when `pendingUnstake == 0`, will try to compound that stale `dustRewards` and delegate tokens the pool does not hold.

Impact:
- Pool operations for the validator can become stuck after two users claim concurrent matured unstakes.
- If unrelated tokens are later sent to the pool, stale `dustRewards` can be delegated as if it were real pool yield, corrupting share accounting.
- This is reachable by ordinary users; no privileged access is required.

Recommended fix:
- Track claimed principal separately from compoundable rewards.
- In `claim()`, when `claimedAmount > amount`, first reserve the excess as liquid backing for other pending unstakes, not as `dustRewards`.
- Only compound `claimedAmount - amount - remainingPendingUnstake` when positive.
- Add a regression test with two stakers who both unstake, both mature, claim one after the other, and then call `stake()` again. The final stake should not revert and pool accounting should not include phantom dust.

### H-2: Slash counters reset across epochs

Severity: High

Location: `Staking._touchValidatorSnapshot`, `Staking._slashValidator`, `Staking._calcValidatorSnapshotEpochPayout`.

Description:
`_touchValidatorSnapshot` copies `totalDelegated` and `commissionRate`, but it does not copy `slashesCount`. A validator slashed once per epoch starts each epoch from zero and never reaches `felonyThreshold` or `misdemeanorThreshold`.

Impact:
- A validator can avoid jail by spreading faults across epochs.
- Misdemeanor reward redirection only works when enough slashes occur in the same epoch.

Recommended fix:
- If thresholds are intended to be cumulative, move the cumulative slash count to `Validator` or propagate `slashesCount` across snapshots.
- Keep per-epoch slash data separate only if reward routing needs per-epoch semantics.
- Add a regression test that slashes once per epoch until the felony threshold and expects `Jail`.

### M-1: Removed validator address re-use keeps old keyed state

Severity: Medium

Location: `Staking._removeValidator`, `Staking._addValidator`, `Staking._claimDelegatorRewardsAndPendingUndelegates`.

Description:
After `_validatorRetired` removal, validator address re-use remains allowed. `_removeValidator` deletes only `_validatorsMap[validator]` and `_validatorOwners[oldOwner]`; it does not clear `_validatorDelegations[validator][delegator]` or `_validatorSnapshots[validator][epoch]`.

This is intentionally not fixed by banning address re-use. The current model should therefore define explicit re-use semantics:
- A new owner can re-register the same validator address if their own delegation queue is empty.
- The same owner is usually blocked because `_addValidator` requires `delegation.delegateQueue.length == 0`, and old queues are never physically shrunk.
- Old delegators may still claim matured undelegations or historical rewards after removal and re-registration because claims are keyed only by validator address.

Impact:
- Operational ambiguity around who is responsible for old obligations after address re-use.
- Same-owner re-registration can be unintentionally impossible.
- Integrators may assume `removeValidator` fully tombstones a validator, but it leaves claimable keyed state behind.

Recommended fix:
- Do not re-add `_validatorRetired` if validator address re-use is desired.
- Instead add a validator generation/incarnation id and key snapshots/delegations by `(validator, generation)`, or define a removal precondition requiring all delegator queues to be fully drained before removal.
- If address re-use with historical claims is intended, document it and replace `delegateQueue.length == 0` with a fully-drained queue check for same-owner re-registration.

### M-2: Jailed owner can withdraw below self-stake floor

Severity: Medium

Location: `Staking._undelegateFrom`, `Staking.releaseValidatorFromJail`.

Description:
The owner self-stake floor applies only while the validator is `Active` or `Pending`. A jailed validator owner can undelegate below `minValidatorStakeAmount`, wait for maturity, then release the validator from jail back to `Active` without the minimum self-stake.

Impact:
- The self-stake invariant can be bypassed via the jail state.
- Delegators may end up attached to an active validator that no longer has the configured owner stake.

Recommended fix:
- Apply the self-stake floor to `Jail` as well, or require `releaseValidatorFromJail` to check the owner’s current self-delegation before moving to `Active`.

### M-3: StakingPool claim assumes one `Staking.claimDelegatorFee` fully funds the caller

Severity: Medium

Location: `StakingPool.claim`, `Staking._cappedDelegatorClaimEpoch`.

Description:
`Staking.claimDelegatorFee` is now capped by `MAX_EPOCHS_PER_CLAIM`. `StakingPool.claim` assumes one call fully processes the pool’s matured undelegation and then transfers the caller’s full `amount`.

If the pool has been idle for more than the cap window, the unstake entry may be mature according to `pendingUnstake.epoch`, while the underlying `Staking` claim only advances part of the delegation history and does not release that undelegation yet.

Impact:
- `claim()` can revert because the pool did not receive enough tokens.
- If the pool already holds unrelated tokens, it can pay the caller from unrelated liquidity and corrupt accounting.

Recommended fix:
- In `StakingPool.claim`, require `claimedAmount >= amount` before accounting is finalized.
- Better: loop or expose a helper to drain `Staking.claimDelegatorFee` until the pool has received at least the caller’s `amount` or no progress is possible.

### M-4: SystemReward native distribution can be DoSed by a recipient

Severity: Medium

Location: `SystemReward._claimSystemFee`.

Description:
Native ETH distribution uses `.call` inside the distribution loop. A recipient contract can revert or reenter `claimSystemFee`. Reentrancy is unlikely to steal funds because outer failures revert the transaction, but a malicious or broken recipient can prevent distribution to later recipients.

Impact:
- Governance-selected recipient contracts can DoS fee distribution.
- Auto-claim triggered by `receive()` or `deposit()` can also become brittle if a configured recipient reverts.

Recommended fix:
- Use a pull-payment model for native rewards, or add a reentrancy guard and isolate failed recipients.
- At minimum, require distribution accounts to be trusted EOAs/contracts and document the operational risk.

### L-1: `_depositFee` does not persist `changedAt`

Severity: Low

Location: `Staking._depositFee`.

Description:
`_depositFee` calls `_touchValidatorSnapshot`, which can bump the in-memory `validator.changedAt`, but `_depositFee` does not persist the updated validator. This is the same pattern fixed in lifecycle methods.

Impact:
- Core reward claiming still reads exact per-epoch snapshots, so funds are not lost.
- `getValidatorStatus` can continue pointing at an older snapshot after deposit-only epochs.
- Future snapshot fields could make this more fragile.

Recommended fix:
- Persist `$._validatorsMap[validatorAddress] = validator` after `_touchValidatorSnapshot` in `_depositFee`.

### L-2: StakingPool local validation is incomplete

Severity: Low

Location: `StakingPool.stake`, `StakingPool.unstake`, `StakingPool.claim`.

Description:
`IStakingPoolErrors` defines `ZeroValidator` and `ZeroStaker`, but the pool does not use them. `stake()` also performs `safeTransferFrom` before local validation of amount precision and minimum amount; the revert currently comes from `Staking.delegate`.

Impact:
- Poor UX and weaker CEI posture if a future staking token has hooks.
- No direct fund loss with the current ERC20 test token because the full transaction reverts.

Recommended fix:
- Mirror `Staking`’s amount and validator checks before pulling tokens in `stake()`.
- Consider moving pool state updates before token transfer or adding a reentrancy guard if callback-capable tokens are in scope.

### L-3: SystemReward accepts zero or duplicate distribution accounts

Severity: Low

Location: `SystemReward._updateDistributionShare`.

Description:
Distribution accounts are not checked for `address(0)` and are not deduplicated.

Impact:
- Zero address can burn fees.
- Duplicate accounts can make distribution harder to reason about, even if total shares still sum to 10000.

Recommended fix:
- Reject `address(0)`.
- Reject duplicate accounts or explicitly document that duplicates are allowed and additive.

### L-4: Staking view functions remain unbounded

Severity: Low

Location: `Staking.getDelegatorFee`, `Staking.getValidatorFee`, `Staking.getPendingDelegatorFee`, `Staking.getPendingValidatorFee`.

Description:
The state-changing claim paths are capped, but view helpers still loop across the full unclaimed epoch range.

Impact:
- `eth_call` can OOG for wallets, indexers, and frontends after long inactivity.
- On-chain funds remain claimable through repeated state-changing claims.

Recommended fix:
- Add paginated view helpers or clearly document that frontends should use bounded claim progress rather than relying on a single unbounded view.

## Confirmed Fixes From Previous Batch

- H-2 claim loop DoS in state-changing claims: capped by `MAX_EPOCHS_PER_CLAIM`.
- `changedAt` persistence in `_activateValidator`, `_disableValidator`, and `changeValidatorOwner`: fixed.
- CEI ordering in `Staking._delegateTo`, `Staking._depositFee`, and `Staking.registerValidator`: fixed.
- Owner self-stake floor for `Active`/`Pending`: fixed.
- `changeValidatorOwner` unknown validator diagnostic: fixed.
- `_addValidator` zero validator/owner validation: fixed.
- `_validatorRetired`: removed by design; no longer part of the proposed fix set.

## Verification

Commands run after removing `_validatorRetired`:

```sh
forge test --match-path 'test/staking/*.sol' --summary
forge test --summary
```

Results:
- Staking suite: `53` tests passed (`StakingFoundryTest`: 7, `StakingAdditionalTest`: 46).
- Full project test suite: passed.
