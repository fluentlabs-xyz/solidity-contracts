# Staking System – Internal Audit Report

## Scope

| Contract                                       | Lines |
|------------------------------------------------|-------|
| `contracts/staking/Staking.sol`                | ~930  |
| `contracts/staking/StakingPool.sol`            | ~264  |
| `contracts/staking/StakingContext.sol`         | ~128  |
| `contracts/staking/ChainConfig.sol`            | ~246  |
| `contracts/staking/SystemReward.sol`           | ~165  |
| `contracts/staking/SlashingIndicator.sol`      | ~47   |
| Interfaces under `contracts/staking/interfaces/*` | —  |

Tests reviewed: `test/staking/Staking.t.sol`, `test/staking/StakingAdditional.t.sol`.

Coverage (post additions, `--ir-minimum`):

| File                                          | Lines  | Statements | Branches | Funcs   |
|-----------------------------------------------|--------|------------|----------|---------|
| `Staking.sol`                                 | 96.51% | 96.65%     | 40.17%   | 100.00% |
| `StakingPool.sol`                             | 95.61% | 96.15%     | 31.25%   | 100.00% |
| `ChainConfig.sol`                             | 98.89% | 98.75%     | 0.00%    | 100.00% |
| `SystemReward.sol`                            | 91.38% | 91.94%     | 36.84%   | 100.00% |
| `StakingContext.sol`                          | 86.11% | 81.82%     | 0.00%    | 92.86%  |
| `SlashingIndicator.sol`                       | 100%   | 100%       | n/a      | 100%    |

## Severity Definitions

- **High** – exploit produces loss of funds, permanent DoS, or breaks core protocol invariant.
- **Medium** – degraded protocol behavior, recoverable loss, conditional exploit.
- **Low** – limited or hard-to-trigger issues; code quality with security flavor.
- **Informational** – style, gas, documentation, test coverage.

---

## Status of Fixes

| ID  | Status                       | Notes                                                                                                  |
|-----|------------------------------|--------------------------------------------------------------------------------------------------------|
| H-1 | Open                         | Not in scope for this fix batch — see recommendation.                                                  |
| H-2 | **Fixed**                    | `MAX_EPOCHS_PER_CLAIM = 1000` cap added to delegator and validator claim paths.                        |
| M-1 | **Fixed**                    | `disable/activate/changeValidatorOwner` now persist the validator struct after `_touchValidatorSnapshot`. |
| M-2 | Acknowledged / open          | Retired-address guard removed by design; re-use semantics should be reassessed in the follow-up audit. |
| M-3 | **Fixed**                    | `safeTransferFrom` now runs after all state updates in `delegate`, `deposit`, and `registerValidator`. |
| M-4 | **Fixed**                    | Owner self-stake floor enforced in `_undelegateFrom` unless the owner is the only remaining delegator. |
| L-1 | **Fixed earlier**            | `_addValidator` already rejects zero addresses (`ZeroValidator`, `ZeroOwner`).                         |
| L-2 | **Fixed**                    | `changeValidatorOwner` now reverts `ValidatorNotFound` for unknown validators.                         |
| L-3 | Open                         | Out of scope for this fix batch.                                                                       |
| L-4 | **Documented decision: WONTFIX** | `ValidatorReleased(validator, epoch)` is the dedicated Jail→Active event; emitting an additional `ValidatorModified` would create redundant work for indexers. Documentation should pair `ValidatorReleased` with the status transition in the spec. |
| L-5 | Open                         | Out of scope for this fix batch.                                                                       |
| I-1..I-5 | Open                     | Informational — separate cleanup PR.                                                                   |

Regression tests for the applied fixes live in `test/staking/StakingAdditional.t.sol` under the section "Regression tests for findings from docs/StakingAudit.md".

---

## Summary of Findings

| ID  | Severity | Title                                                                                  |
|-----|----------|----------------------------------------------------------------------------------------|
| H-1 | High     | Slash counters reset every epoch – felony/misdemeanor thresholds are per-epoch only    |
| H-2 | High     | Unbounded reward loops can DoS delegator and validator claims after long inactivity    |
| M-1 | Medium   | `validator.changedAt` update is dropped on `disable`, `activate`, `changeValidatorOwner` |
| M-2 | Medium   | Deleted validator does not clear delegator/snapshot storage, allowing state to resurface |
| M-3 | Medium   | `safeTransferFrom` performed before state updates in `delegate`, `deposit`, `registerValidator` (CEI violation) |
| M-4 | Medium   | Validator-owner self-stake has no lock; entire registration stake can be withdrawn immediately |
| L-1 | Low      | `_addValidator` accepts `validatorAddress == address(0)`                                |
| L-2 | Low      | `changeValidatorOwner` does not check validator existence                              |
| L-3 | Low      | Commission rate change applies one epoch later with no governance / notice window      |
| L-4 | Low      | `releaseValidatorFromJail` does not emit `ValidatorModified` for status transition     |
| L-5 | Low      | `releaseValidatorFromJail` blindly `push`es to active list (no duplicate guard)        |
| I-1 | Info     | `TRANSFER_GAS_LIMIT` constant is declared but never used                                |
| I-2 | Info     | Selection sort in `_getValidators` is O(n·k); fine for current sizes, document limit   |
| I-3 | Info     | `StakingContext.sol` and `ChainConfig.sol` branch coverage is 0%                       |
| I-4 | Info     | `_calcDelegatorRewardsAndPendingUndelegates` and friends use a `Validator memory` read-mutate-write pattern that is easy to misuse |
| I-5 | Info     | Snapshot zero-value disambiguation relies on probabilistic “any non-zero field” heuristic (now also guarded by `changedAt`) |

---

## High Severity

### H-1: Slash counters reset every epoch

**Location:** `Staking.sol` `_slashValidator`, `_calcValidatorSnapshotEpochPayout`, `_touchValidatorSnapshot`.

**Description.** `_touchValidatorSnapshot` only copies `totalDelegated` and `commissionRate` from the previous snapshot. It does **not** carry over `slashesCount` or `totalRewards`. As a result, when `_slashValidator` is invoked in a new epoch, `currentSnapshot.slashesCount + 1` always starts from `0 + 1 = 1`:

```692:710:contracts/staking/Staking.sol
function _slashValidator(address validatorAddress) internal {
    ...
    ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
    uint32 slashesCount = currentSnapshot.slashesCount + 1;
    currentSnapshot.slashesCount = slashesCount;
    ...
    if (slashesCount == _chainConfigContract.getFelonyThreshold()) {
        validator.jailedBefore = _currentEpoch() + _chainConfigContract.getValidatorJailEpochLength();
        validator.status = ValidatorStatus.Jail;
        ...
    }
}
```

Consequences:
- A validator who misbehaves once per epoch never reaches `felonyThreshold` (default 150) and therefore is never jailed.
- The misdemeanor-driven reward redirection in `_calcValidatorSnapshotEpochPayout` only triggers when `misdemeanorThreshold` slashes occur in the **same** epoch.
- The existing tests pass because they slash within a single block/epoch (e.g. `test_putValidatorInJailAfterFelonyThreshold` performs 20 consecutive slashes without rolling epochs).

**Impact.** If slashes are intended to accumulate over time (the typical Tendermint/Parlia semantics), the jailing logic is effectively disabled in production traffic patterns. Validators can misbehave indefinitely without being removed.

**Recommendation.** Either
1. propagate `slashesCount` in `_touchValidatorSnapshot` (so the counter is monotonically non-decreasing across epochs), or
2. keep a separate cumulative `slashesCount` on the `Validator` struct (not on the snapshot) and only use the per-epoch snapshot slash count to gate the reward distribution.

The second option matches the BSC/Parlia model more closely. Either change must be paired with explicit documentation of the semantics and a regression test that slashes the validator across multiple epochs.

### H-2: Unbounded reward loops can DoS claims after long inactivity

**Location:** `Staking.sol` `_claimDelegatorRewardsAndPendingUndelegates`, `_calcDelegatorRewardsAndPendingUndelegates`, `_claimValidatorOwnerRewards`, `_calcValidatorOwnerRewards`.

**Description.** Reward calculation walks every epoch from `claimedAt`/`delegateOp.epoch` to `beforeEpoch`:

```553:561:contracts/staking/Staking.sol
function _calcValidatorOwnerRewards(Validator memory validator, uint64 beforeEpoch) internal view returns (uint256) {
    StakingStorage storage $ = _getStakingStorage();
    uint256 availableFunds = 0;
    for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
        ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator.validatorAddress][validator.claimedAt];
        ( /*uint256 delegatorFee*/, uint256 ownerFee,  /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
        availableFunds += ownerFee;
    }
    return availableFunds;
}
```

`_claimDelegatorRewardsAndPendingUndelegates` has the same shape and additionally has an inner loop per delegate-queue entry.

**Impact.** A validator owner or delegator who does not claim for, say, `N = 100_000` epochs effectively cannot claim – the loop performs ~`N` SLOADs and will exceed the block gas limit. Funds become locked. A malicious validator with very long-lived delegations could also accidentally trip this path on first claim.

**Recommendation.**
- Provide a paginated claim entry point (`claimDelegatorFeeAtEpoch(validator, beforeEpoch)` already exists – document it and use it in front-end / SDK as the primary path for catch-up claims).
- Add an automatic cap on the number of epochs processed per call (e.g. `beforeEpoch - claimedAt <= MAX_EPOCHS_PER_CLAIM`) and require the caller to drain progressively.
- Consider compacting consecutive zero-reward epochs in the snapshot store so the loop can skip them in O(1).

**Applied fix.** Added `MAX_EPOCHS_PER_CLAIM = 1000` constant. Both `_claimDelegatorRewardsAndPendingUndelegates` and `_claimValidatorOwnerRewards` now cap the processed `beforeEpoch` to `firstUnprocessedEpoch + MAX_EPOCHS_PER_CLAIM`. Users with very long unclaimed stretches can drain by re-calling the claim function. View functions (`getDelegatorFee`/`getValidatorFee` and friends) remain uncapped so the UI still reports the full claimable amount. Regression test: `test_delegatorClaimCapsAtMaxEpochsPerClaim`, `test_validatorOwnerClaimCapsAtMaxEpochsPerClaim`.

---

## Medium Severity

### M-1: `validator.changedAt` update is dropped on `disable`, `activate`, `changeValidatorOwner`

**Location:** `_activateValidator`, `_disableValidator`, `changeValidatorOwner`.

**Description.** `_touchValidatorSnapshot` mutates the in-memory `validator.changedAt`:

```298:316:contracts/staking/Staking.sol
function _touchValidatorSnapshot(Validator memory validator, uint64 epoch) internal returns (ValidatorSnapshot storage) {
    ...
    if (epoch > validator.changedAt) {
        validator.changedAt = epoch;
    }
    return snapshot;
}
```

In `_disableValidator`, `_activateValidator`, and `changeValidatorOwner`, the validator struct is written to storage **before** `_touchValidatorSnapshot` is called, so the freshly bumped `changedAt` is lost:

```703:712:contracts/staking/Staking.sol
function _disableValidator(address validatorAddress) internal {
    StakingStorage storage $ = _getStakingStorage();
    Validator memory validator = $._validatorsMap[validatorAddress];
    require(validator.status == ValidatorStatus.Active, NotActiveValidator());
    _removeValidatorFromActiveList(validatorAddress);
    validator.status = ValidatorStatus.Pending;
    $._validatorsMap[validatorAddress] = validator;                       // (1) writes old changedAt
    ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch()); // (2) bumps memory only
    ...
}
```

`changeValidatorCommissionRate` does it correctly (touch first, then write).

**Impact.** The newly created snapshot at `_nextEpoch()` exists in storage, but `validator.changedAt` continues to point to the older epoch. Future `_touchValidatorSnapshot(validator, ...)` calls source `lastModifiedSnapshot` from the stale `changedAt`, ignoring the orphaned snapshot. In the current code paths this is benign because `disable`/`activate`/`changeOwner` do not change `totalDelegated`/`commissionRate`, but it is a fragile invariant – any future state added to the snapshot (e.g. cumulative slash count from H-1) would silently fail to propagate.

**Recommendation.** Move the `$._validatorsMap[validatorAddress] = validator;` write **after** `_touchValidatorSnapshot` in all three call sites, mirroring `changeValidatorCommissionRate` and `_delegateTo`.

**Applied fix.** All three sites now persist the validator struct after `_touchValidatorSnapshot`. Regression test: `test_validatorChangedAtPersistsThroughLifecycleTransitions`.

### M-2: Removed validator leaves delegator/snapshot storage behind

**Location:** `_removeValidator`.

**Description.** `_removeValidator` requires `_totalDelegatedToValidator(validator) == 0` and then deletes the `Validator` and the owner index, but the per-validator mappings for delegations and per-epoch snapshots are not cleared:

```661:674:contracts/staking/Staking.sol
function _removeValidator(address validatorAddress) internal {
    ...
    require(_totalDelegatedToValidator(validator) == 0, ValidatorHasActiveDelegations(validatorAddress));
    _removeValidatorFromActiveList(validatorAddress);
    delete $._validatorOwners[validator.ownerAddress];
    delete $._validatorsMap[validatorAddress];
    emit ValidatorRemoved(validatorAddress);
}
```

If the same validator address is later re-added (via governance or self-registration of a clean owner), the new `Validator` shares its `validatorAddress`-keyed delegation queues and snapshots with the old incarnation.

**Impact.**
- A delegator who undelegated but never claimed retains a non-empty `delegateQueue`/`undelegateQueue` keyed by validator address. After re-registration their stale matured undelegations become claimable from the new incarnation’s rewards pool (their `claimDelegatorFee` reads from the same mapping).
- Stale `commissionRate` and historical `totalRewards` in `_validatorSnapshots[validatorAddress][...]` can leak into the new incarnation’s `_validatorSnapshotAtOrBefore` lookups, potentially mis-reporting active set ordering.

**Recommendation.**
- Either disallow re-using a validator address after removal (track a per-address generation number and key snapshots/delegations by `(validator, generation)`), or
- Require all delegators to fully claim before removal and walk the active delegator set on removal to delete remaining queues. The current implementation already requires zero delegations; extending it to require zero pending undelegations and zero claimable rewards closes the gap with minimal complexity.

**Current decision.** A retired-address guard was considered and removed by design, so validator address re-use remains allowed. This finding should be reassessed in the follow-up audit against the intended validator lifecycle semantics.

### M-3: External `safeTransferFrom` precedes state updates (CEI violation)

**Location:** `_delegateTo`, `_depositFee`, `registerValidator`.

**Description.**

```334:347:contracts/staking/Staking.sol
function _delegateTo(address fromDelegator, address toValidator, uint256 amount, bool pullTokens) internal {
    ...
    require(amount % BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
    if (pullTokens) {
        _stakingToken.safeTransferFrom(fromDelegator, address(this), amount);
    }
    ...
    Validator memory validator = $._validatorsMap[toValidator];
    require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(toValidator));
    ...
}
```

`registerValidator` performs `safeTransferFrom` **before** checking `commissionRate`, `validatorAddress` uniqueness, or `validatorOwner` uniqueness:

```582:589:contracts/staking/Staking.sol
function registerValidator(address validatorAddress, uint16 commissionRate, uint256 initialStake) external override {
    require(initialStake >= _chainConfigContract.getMinValidatorStakeAmount(), InitialStakeTooLow(initialStake));
    require(initialStake % BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
    _stakingToken.safeTransferFrom(msg.sender, address(this), initialStake);
    _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
}
```

**Impact.**
- For a standard ERC-20 (no callback) the impact is limited to a brief inconsistency window with no exploit path.
- The staking token is an externally provided `IERC20` set in the constructor. If a future deployment configures a token with hooks (e.g. ERC-777, fee-on-transfer, rebasing) a malicious receiver could reenter `delegate`, `registerValidator`, or any other staking entry point while the contract has already received tokens but not yet updated state. The same applies in `_depositFee`, which is reachable only by the coinbase but still useful to harden.
- Failed `_addValidator` calls (e.g. `ValidatorAlreadyExists`) leak tokens via revert refund semantics on the surface, but if the token is non-standard (fee-on-transfer) tokens may already have left the user’s balance.

**Recommendation.**
- Apply CEI: validate all preconditions and update state, then pull tokens last. For `_delegateTo`, move the `safeTransferFrom` to after the validator existence check and the delegation queue updates.
- Document explicitly that `_stakingToken` must be a standard, non-rebasing, non-callback ERC-20, and add a deploy-time invariant check.

**Applied fix.** `safeTransferFrom` was moved to be the last side-effecting step before the event emit in `_delegateTo`, `_depositFee`, and `registerValidator`. The `initialize` path already pulled tokens after `_addValidator` and is unchanged. The documentation-side invariant (`_stakingToken` must be a standard ERC-20) remains a follow-up. Regression test: `test_registerValidatorUpdatesStateBeforePullingTokens`; existing tests cover the delegate/deposit paths.

### M-4: Validator self-stake is not locked

**Location:** `registerValidator` / `_addValidator` / `_undelegateFrom`.

**Description.** `registerValidator` requires `initialStake >= getMinValidatorStakeAmount()`, but as soon as the validator is added the owner can call `undelegate` and remove the entire self-stake. The contract does not enforce that an active or pending validator keeps at least `minValidatorStakeAmount` self-delegated. The test `test_validatorCanUndelegateInitialStake` exercises this path on purpose.

**Impact.** A validator can satisfy the registration check, get governance to `activateValidator`, then immediately drain its self-stake. Delegators may then be staking against an under-collateralized validator without any skin in the game, defeating the purpose of `minValidatorStakeAmount`.

**Recommendation.**
- Enforce a self-stake floor in `_undelegateFrom` when `fromDelegator == validator.ownerAddress`: do not allow the owner’s remaining delegated amount to drop below `minValidatorStakeAmount` while `status` is `Pending` or `Active`.
- Optionally introduce a withdrawal cooldown that is longer than `undelegatePeriod` for validator owner self-stake.

**Applied fix.** `_undelegateFrom` now reverts with `OwnerSelfStakeBelowMinimum` when the owner withdraws and the post-undelegate self-stake drops below `minValidatorStakeAmount` while the validator is `Active` or `Pending` and other delegators still trust them. The owner can still drain fully once they are the sole remaining delegator (`totalDelegated == selfStake`), preserving the path to a clean `removeValidator`. The optional extra cooldown was not implemented. Regression tests: `test_ownerCannotUndelegateBelowMinimumWhileOtherDelegatorsRemain`, `test_ownerCanDrainSelfStakeOnceOtherDelegatorsLeave`.

---

## Low Severity

### L-1: `_addValidator` accepts `validatorAddress == address(0)`

`_addValidator` and `registerValidator` do not reject the zero address. An attacker can register a validator at `address(0)` (paying min self-stake) which permanently occupies the slot and pollutes the `_validatorsMap` / `_validatorOwners` mappings. Add `require(validatorAddress != address(0), ...)` and `require(validatorOwner != address(0), ...)`.

### L-2: `changeValidatorOwner` does not check existence

`changeValidatorOwner` reads the validator from storage and only checks `validator.ownerAddress == msg.sender`. For a non-existent validator the owner is `address(0)`, so calling with `msg.sender == address(0)` succeeds and writes `_validatorOwners[newOwner] = validatorAddress` for a non-existent validator. Although unreachable in normal usage, an explicit `require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(...))` would harden the function.

**Applied fix.** Added an explicit `require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress))` at the top of `changeValidatorOwner`. Regression test: `test_changeValidatorOwner_revertsWhenValidatorUnknown`.

### L-3: Commission rate change has no notice window

`changeValidatorCommissionRate` takes effect at `_nextEpoch()` with no delay. With short epochs (`epochBlockInterval = 50` in the L2 config) a validator can front-run their own delegators’ claims by raising commission immediately before a high-reward epoch. Consider a notice window (`commissionChangedAtEpoch + COMMISSION_NOTICE`) before the new value becomes effective.

### L-4: `releaseValidatorFromJail` does not emit `ValidatorModified`

The function emits only `ValidatorReleased`. Off-chain indexers that track validator status via `ValidatorModified` will miss the Jail→Active transition. Either emit both events, or have `ValidatorReleased` be a subtype of `ValidatorModified`.

**Decision: WONTFIX.** `ValidatorReleased(validator, epoch)` is the dedicated, semantically-precise event for the Jail→Active transition. Emitting an extra `ValidatorModified` would force off-chain consumers to deduplicate two events for the same logical state change. The indexer integration should subscribe to both `ValidatorModified` and `ValidatorReleased`, treating the latter as a status transition; this should be documented in the off-chain spec rather than fixed in the contract.

### L-5: `releaseValidatorFromJail` blindly pushes to active list

```228:242:contracts/staking/Staking.sol
function releaseValidatorFromJail(address validatorAddress) external {
    ...
    validator.status = ValidatorStatus.Active;
    $._validatorsMap[validatorAddress] = validator;
    $._activeValidatorsList.push(validatorAddress);
    ...
}
```

There is no check that `validatorAddress` is not already in `_activeValidatorsList`. The current code path is safe because `_slashValidator` removes the validator from the list before setting Jail status, but any future change that allows entering Jail without removal would silently introduce a duplicate. Add an idempotent helper that only pushes when absent, or assert via the status transition state machine.

---

## Informational

### I-1: Unused `TRANSFER_GAS_LIMIT` constant

`TRANSFER_GAS_LIMIT = 30000` is declared on the staking contract but never read. Remove it or wire it into the `_safeTransfer`/`_systemRewardContract.deposit` paths (the latter would mitigate griefing by a validator owner contract with a hostile `receive`).

### I-2: Active-set selection sort is O(n·k)

`_getValidators` performs a selection sort over all registered validators to extract the top `k`. With the L2 default of `activeValidatorsLength = 50` and an unbounded `_activeValidatorsList`, the worst case is quadratic. After the `_validatorSnapshotAtOrBefore` fix (returns early at `changedAt`) each comparison is O(1), but a hard cap on total registered validators or a switch to a heap (`contracts/libraries/Heap.sol`, already in the repo) would be safer if registration becomes permissionless and unlimited.

### I-3: Branch coverage gaps in `StakingContext` and `ChainConfig`

- `StakingContext.sol`: 86.11% lines, **0%** branches – the `onlyFromCoinbase`, `onlyFromSlashingIndicator`, `onlyFromGovernance`, `onlyZeroGasPrice` modifiers and the `_authorizeUpgrade` access check have no negative-path tests. Add unit tests that prank a non-coinbase / non-governance caller.
- `ChainConfig.sol`: 98.89% lines, **0%** branches – the `ZeroValue(...)` revert paths for every setter and for the initializer are not exercised. Add a parametric “zero value reverts” test.

### I-4: `Validator memory` read–mutate–write pattern is error-prone

Most state-mutating functions read `Validator` into memory, mutate it, then write back. As shown in M-1, the order of write-back relative to `_touchValidatorSnapshot` matters. Consider one of:
1. Refactor to operate on `Validator storage` directly, eliminating the implicit copy.
2. Funnel all writes through a single helper, e.g. `_persistValidator(Validator memory)` that always runs after `_touchValidatorSnapshot`.

### I-5: Snapshot zero-value disambiguation heuristic

`_validatorSnapshotAtOrBefore` walks backwards looking for a snapshot with *any* non-zero field. After the recent fix it also returns immediately at `lookupEpoch == validator.changedAt`, but the underlying heuristic still treats `(totalDelegated=0, commissionRate=0, slashesCount=0, totalRewards=0)` as “no snapshot here.” A validator with a zero-commission, no-reward, fully-undelegated state in some epoch is structurally indistinguishable from an empty slot. Consider adding an explicit `initialized` bit (e.g. fold it into `commissionRate`’s top bit) or per-epoch existence flag.

---

## Test Coverage Recommendations

The following targeted tests would meaningfully raise confidence and branch coverage; they map back to findings above:

1. **H-1 regression** – slash validator across multiple epochs and assert eventual jailing.
2. **H-2 regression** – fuzz the number of epochs without claiming and assert claim succeeds (or, after fix, that paginated claim succeeds).
3. **M-1 regression** – after `disable` → delegate → `activate`, assert the validator’s `changedAt` in storage equals the latest snapshot epoch.
4. **M-2 regression** – remove a validator after delegator undelegated but did not yet claim; re-add same address; assert delegator’s queues are not visible against the new incarnation.
5. **M-4 regression** – assert that validator owner cannot undelegate below `minValidatorStakeAmount` while validator is Active/Pending.
6. **L-1 regression** – `registerValidator(address(0), ...)` and `addValidator(address(0))` should revert.
7. **StakingContext modifier coverage** – non-governance call to each `onlyFromGovernance` setter; non-coinbase call to `deposit`; non-slashing-indicator call to `slash`; non-zero gas price call to `deposit`.
8. **ChainConfig zero-value coverage** – assert `ZeroValue(...)` revert for every setter and initializer parameter.

## Compile / Tooling Notes

- `forge coverage` without `--ir-minimum` fails with `Stack too deep` in unrelated `contracts/rollup/Rollup.sol:540`. Coverage was therefore run with `--ir-minimum` and `--no-match-coverage 'contracts/(blacklist|bridge|factories|fastlist|gateways|governance|libraries|mocks|oracles|rollup|tokens|verifier)/'`. Long-term, configure `viaIR = true` in the foundry profile used by CI to remove the workaround.
- The supplied invocation `forge test -- staking` is interpreted as a positional path filter by Foundry and matches nothing. Use `forge test --match-path 'test/staking/*.sol'` (or `forge test --match-contract Staking`) in CI scripts and docs.
