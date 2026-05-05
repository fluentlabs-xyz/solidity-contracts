# Staking contracts

The staking module ports the legacy validator staking system into the Foundry codebase. It is intended for the Fluent system-contract environment and is wired with OpenZeppelin-style initializers.

## Contract map

| Contract | Purpose |
|----------|---------|
| `Staking` | Validator registry, delegation accounting, validator/delegator reward claims, slashing, jail/release flow, and active validator ordering. |
| `StakingPool` | Share-based pooled staking wrapper that delegates pooled ETH to validators and lets users unstake/claim after the undelegation delay. |
| `SystemReward` | Receives system fees and distributes them by governance-configured shares. |
| `ChainConfig` | Governance-controlled consensus/staking parameters such as epoch length, active validator count, jail duration, and minimum stake sizes. |
| `SlashingIndicator` | Coinbase-only entrypoint that forwards slash events into `Staking`. |
| `StakingContext` | Shared dependency holder for staking, governance, chain config, system reward, and access-control helpers. |

## Epoch model

`Staking` derives epochs from `block.number / epochBlockInterval` using `ChainConfig`. Delegations and undelegations are queued with the next epoch so reward accounting can use epoch snapshots instead of mutating historical validator state.

Important consequences:

- New delegation becomes effective at `nextEpoch()`.
- Undelegated funds become claimable after `nextEpoch() + undelegatePeriod`.
- Validator snapshots carry delegated amount, commission rate, slash count, and total rewards for a given epoch.
- Reward claims can be bounded with `beforeEpoch` variants to avoid claiming beyond a caller-selected accounting point.

## Validator lifecycle

Validators can be introduced in two ways:

1. Governance calls `addValidator`, which creates an active validator owned by the same address.
2. A validator owner calls `registerValidator` with the minimum validator stake and a commission rate.

Governance can activate, disable, or remove validators. Slashing is triggered through `SlashingIndicator`, increments the validator slash count, and jails the validator once the felony threshold is reached. The owner can call `releaseValidatorFromJail` after the jail epoch expires.

The active validator list is sorted by delegated amount and capped by `activeValidatorsLength`. When a validator's delegated amount changes, the set is rebuilt so higher delegated stake takes priority.

## Delegation and rewards

Delegators call `delegate(validator)` with ETH. The contract stores compacted balances using `BALANCE_COMPACT_PRECISION`; stake amounts must be compatible with this precision and the configured minimum staking amount.

Validator rewards arrive through `deposit(validator)`, which is restricted to the block coinbase and zero gas price in the legacy system-contract model. Rewards are split between:

- validator owner commission, based on the validator commission rate; and
- delegators, proportional to their delegated stake after commission.

Delegators can:

- `claimDelegatorFee` / `claimDelegatorFeeAtEpoch` to withdraw rewards and mature undelegations;
- `redelegateDelegatorFee` to compound claimable rewards back into stake, leaving dust that is below compact-balance precision claimable.

Validator owners can claim commission through `claimValidatorFee` or `claimValidatorFeeAtEpoch`.

## Pooled staking

`StakingPool` wraps `Staking` with a share model. Users deposit ETH into a validator pool and receive shares. The pool delegates the ETH to `Staking`, periodically claims delegator rewards, and redelegates claimable rewards that meet the compact-balance precision.

Unstaking burns shares only after the underlying undelegation matures:

1. `unstake(validator, amount)` records a pending unstake, reserves the amount, and calls `Staking.undelegate`.
2. `claim(validator)` becomes available once the pending epoch is reached and transfers ETH back to the user.

Only one pending unstake per user/validator is supported at a time.

## System rewards

`SystemReward` receives ETH system fees and stores them as `_systemFee`. Fees can be claimed manually or automatically once the auto-claim threshold is reached. Governance configures distribution accounts and basis-point-style shares; total shares must equal 100% (`10000`).

## Configuration

`ChainConfig` owns the runtime parameters used by staking:

- `activeValidatorsLength`
- `epochBlockInterval`
- `misdemeanorThreshold`
- `felonyThreshold`
- `validatorJailEpochLength`
- `undelegatePeriod`
- `minValidatorStakeAmount`
- `minStakingAmount`

All setters are governance-only and emit before/after events.

## Tests

The Foundry test suite in `test/staking/Staking.t.sol` covers:

- delegation and delegation across epochs;
- undelegation and claimable funds;
- active validator ordering by delegated amount;
- rejecting delegation to unknown validators;
- pooled staking accounting; and
- pooled reward/claim flow.

Run staking tests with:

```sh
forge test --match-path test/staking/Staking.t.sol -vvv
```
