# Staking contracts

The staking module implements the validator staking system in the Foundry codebase. It is intended for the Fluent system-contract environment. Shared contract dependencies are constructor-wired immutables, while mutable module state is configured with OpenZeppelin-style initializers. Contracts are UUPS-upgradeable behind ERC-1967 proxies, with upgrade authorization controlled by the configured owner account. Mutable staking state uses ERC-7201 namespaced storage, and validation failures use custom errors instead of revert strings.

## Contract map

| Contract | Purpose |
|----------|---------|
| `Staking` | Validator registry, delegation accounting, validator/delegator reward claims, slashing, jail/release flow, and active validator ordering. |
| `StakingPool` | Share-based pooled staking wrapper that delegates pooled ERC20 staking tokens to validators and lets users unstake/claim after the undelegation delay. |
| `SystemReward` | Receives native ETH and staking-token system fees and distributes both by governance-configured shares. |
| `ChainConfig` | Governance-controlled consensus/staking parameters such as epoch length, active validator count, jail duration, and minimum stake sizes. |
| `SlashingIndicator` | Coinbase-only entrypoint that forwards slash events into `Staking`. |
| `Governance` | Validator-owner Governor whose voting power comes from active validator stake and whose votes are counted per validator. |
| `StakingContext` | Shared immutable dependency holder for staking, governance, chain config, system reward, owner-controlled UUPS upgrades, and custom-error access-control helpers. |

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
2. A validator owner approves the staking token and calls `registerValidator` with the minimum validator stake and a commission rate.

Governance can activate, disable, or remove validators. Slashing is triggered through `SlashingIndicator`, increments the validator slash count, and jails the validator once the felony threshold is reached. The owner can call `releaseValidatorFromJail` after the jail epoch expires.

The active validator list is sorted by delegated amount and capped by `activeValidatorsLength`. When a validator's delegated amount changes, the set is rebuilt so higher delegated stake takes priority.

## Delegation and rewards

The staking token is an ERC20 configured at module deployment and exposed by `getStakingToken()`. Tests use `MockBlend` as that token.

Delegators approve the staking token and call `delegate(validator, amount)`. The contract stores compacted balances using `BALANCE_COMPACT_PRECISION`; stake amounts must be compatible with this precision and the configured minimum staking amount.

Validator rewards arrive through `deposit(validator, amount)` after the validator approves the staking token, which is restricted to the block coinbase and zero gas price in the system-contract environment. Rewards are split between:

- validator owner commission, based on the validator commission rate; and
- delegators, proportional to their delegated stake after commission.

Delegators can:

- `claimDelegatorFee` / `claimDelegatorFeeAtEpoch` to withdraw rewards and mature undelegations;
- `redelegateDelegatorFee` to compound claimable rewards back into stake, leaving dust that is below compact-balance precision claimable.

Validator owners can claim commission through `claimValidatorFee` or `claimValidatorFeeAtEpoch`.

## Pooled staking

`StakingPool` wraps `Staking` with a share model. Users approve the staking token and call `stake(validator, amount)` to receive shares. The pool delegates the tokens to `Staking`, periodically claims delegator rewards, and redelegates claimable rewards that meet the compact-balance precision.

Unstaking burns shares only after the underlying undelegation matures:

1. `unstake(validator, amount)` records a pending unstake, reserves the amount, and calls `Staking.undelegate`.
2. `claim(validator)` becomes available once the pending epoch is reached and transfers staking tokens back to the user.

Only one pending unstake per user/validator is supported at a time.

## System rewards

`SystemReward` receives staking-token system fees through `deposit(amount)` and native ETH system fees through `receive`. Fees are accounted from the contract balances and can be claimed manually or automatically once either asset reaches the auto-claim threshold. Governance configures distribution accounts and basis-point-style shares; total shares must equal 100% (`10000`). The same share table is applied independently to both native ETH and staking-token balances, leaving any rounding dust in the contract for later claims.

## Governance

`Governance` is an OpenZeppelin Governor-compatible contract. Validator owners can create proposals and vote, while voting power is derived from the active validator's delegated stake at the proposal block. Votes are counted by validator address rather than owner address, so rotating a validator owner during an active proposal cannot double-vote.

The governance contract is UUPS-upgradeable behind an ERC-1967 proxy. Its mutable custom voting-period override uses ERC-7201 namespaced storage. See [`Governance.md`](Governance.md) for the governance-specific voting, upgrade, and timelock notes.

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

The Foundry staking tests in `test/staking/` cover:

- delegation across epochs;
- undelegation and claimable funds;
- active validator ordering by delegated amount;
- rejecting delegation to unknown validators;
- pooled staking accounting; and
- pooled reward/claim flow.

Run staking and governance tests with:

```sh
forge test --match-contract 'GovernanceTest|StakingFoundryTest|StakingAdditionalTest' -vvv
```
