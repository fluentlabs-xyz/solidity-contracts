# Frontend integration: StakingPool and Governance

This guide describes the frontend-facing integration surface for pooled staking and validator-owner governance on Fluent
L2. End-user staking should use `StakingPool`; direct `Staking` writes are mainly for validator operators and
governance-controlled administration.

## Contracts

Use the proxy addresses from the selected L2 deployment manifest:

| Manifest key         | Contract      | Frontend use                                                                                     |
|----------------------|---------------|--------------------------------------------------------------------------------------------------|
| `staking_pool_proxy` | `StakingPool` | User stake, unstake, claim, and pooled position reads.                                           |
| `staking_proxy`      | `Staking`     | Validator list, validator metadata, epochs, direct reward reads, and validator-owner operations. |
| `chain_config_proxy` | `ChainConfig` | Epoch length, undelegation delay, minimum stake values, and active validator limit.              |
| `governance proxy`   | `Governance`  | Proposal creation, voting, proposal state, voting power, quorum, and execution.                  |

ABIs are produced by `forge build` under:

- `out/StakingPool.sol/StakingPool.json`
- `out/Staking.sol/Staking.json`
- `out/ChainConfig.sol/ChainConfig.json`
- `out/Governance.sol/Governance.json`

For the current testnet manifest, see `deployments/testnet/l2.json`.

## StakingPool user flow

### 1. Load global staking context

Read these values when the staking page opens:

| Contract      | Function                  | Use                                                                              |
|---------------|---------------------------|----------------------------------------------------------------------------------|
| `Staking`     | `getValidators()`         | Active validators to display as staking targets.                                 |
| `Staking`     | `currentEpoch()`          | Current epoch for claim/unstake status.                                          |
| `Staking`     | `nextEpoch()`             | Epoch at which new delegation and new undelegation requests are queued.          |
| `ChainConfig` | `getEpochBlockInterval()` | Convert blocks to approximate epoch timing.                                      |
| `ChainConfig` | `getUndelegatePeriod()`   | Number of epochs a user must wait after unstaking.                               |
| `ChainConfig` | `getMinStakingAmount()`   | Minimum `msg.value` for pool stake operations and reward redelegation precision. |

Show epoch-based timing as an estimate. The protocol clock is block-number-based, and `Governance.CLOCK_MODE()` returns
`mode=blocknumber&from=default`.

### 2. Display validators

For each validator from `Staking.getValidators()`, read:

```solidity
staking.getValidatorStatus(validator)
```

The return tuple is:

```text
ownerAddress,
status,
totalDelegated,
slashesCount,
changedAt,
jailedBefore,
claimedAt,
commissionRate,
totalRewards
```

Frontend notes:

- `status` is `0 = NotFound`, `1 = Active`, `2 = Pending`, `3 = Jail`.
- `commissionRate` is basis points with two decimal places. For example, `300` is `3%`, and `3000` is `30%`.
- Only active validators should be offered as normal staking targets.
- `totalDelegated`, user stake amounts, and claimable amounts are native token wei values.

### 3. Read a user's pooled position

Use `StakingPool` for user balances:

```solidity
stakingPool.getStakedAmount(validator, user)
stakingPool.claimableRewards(validator, user)
```

`getStakedAmount` returns the current stake represented by the user's pool shares. `claimableRewards` returns the sum
of pending unstakes that have already matured for the user; entries still inside their undelegate period are excluded.
It does not include accrued staking yield; yield is reflected in the pool share ratio and therefore in
`getStakedAmount`.

To inspect every queued unstake — including its maturity epoch — use:

```solidity
stakingPool.getPendingUnstakes(validator, user)
```

It returns an array of `PendingUnstake { amount, shares, epoch }` entries in submission order. Maturity epochs are
monotonically non-decreasing, and `claim` always drains the matured prefix of this queue.

If the frontend also imports the full `StakingPool` ABI rather than the minimal interface, these helper reads are
available:

```solidity
stakingPool.getShares(validator, user)
stakingPool.getValidatorPool(validator)
stakingPool.getRatio(validator)
```

These are useful for advanced pool analytics, but the basic user position can be rendered with `getStakedAmount`,
`claimableRewards`, and `getPendingUnstakes`.

### 4. Stake

User action:

```solidity
stakingPool.stake{value: amount}(validator)
```

Preflight checks:

- `amount > 0`.
- `amount >= chainConfig.getMinStakingAmount()`.
- `staking.isValidatorActive(validator) == true`.
- Wallet is on the Fluent L2 chain for the selected deployment.

After a successful transaction:

- Watch `StakingPool.Stake(validator, staker, amount)`.
- Also index `Staking.Delegated(validator, stakingPoolAddress, amount, epoch)` if you want to reconcile pool-level
  delegation.
- Refresh `getStakedAmount(validator, user)` and `getValidatorStatus(validator)`.
- Make clear that newly delegated stake becomes effective from the next staking epoch.

### 5. Unstake

User action:

```solidity
stakingPool.unstake(validator, amount)
```

Preflight checks:

- `amount > 0`.
- The shares required for the new unstake (computed from `amount` and the pool ratio) plus the shares already reserved
  by any in-flight pending unstakes must not exceed `stakingPool.getShares(validator, user)`. As a coarse heuristic the
  frontend can require `amount <= stakingPool.getStakedAmount(validator, user) - sum(pending amounts)`.
- `StakingPool` supports multiple pending unstakes per `(validator, user)`; each call enqueues a new entry that
  matures independently. There is no single-pending-unstake restriction.

Claim availability:

- `unstake` records a pending claim at `staking.nextEpoch() + chainConfig.getUndelegatePeriod()`.
- `claimableRewards(validator, user)` returns the sum of matured pending unstakes that can be claimed right now.
- `getPendingUnstakes(validator, user)` returns the full queue including `epoch` (the maturity epoch) for each entry,
  so the frontend can display when the next slice of stake becomes claimable.

After a successful transaction:

- Watch `StakingPool.Unstake(validator, staker, amount)`.
- Refresh the user's position and show the pending claim state, including the new queue entry.

### 6. Claim matured unstake

User action:

```solidity
stakingPool.claim(validator)
```

Preflight checks:

- `stakingPool.claimableRewards(validator, user) > 0`. The value already reflects only matured entries, so a
  non-zero result guarantees the call will succeed.
- The frontend can additionally read `getPendingUnstakes(validator, user)` to show "X matures at epoch Y" hints.

A single `claim` drains every matured entry in the queue in one transaction; any unmatured entries remain queued and
can be claimed once they reach their epoch. If no entry has matured the call reverts with `EpochIsNotReady(uint64)`,
returning the next maturity epoch.

After a successful transaction:

- Watch `StakingPool.Claim(validator, staker, amount)`.
- Refresh `getStakedAmount(validator, user)`, `claimableRewards(validator, user)`, and
  `getPendingUnstakes(validator, user)`.

## Optional direct Staking actions

Most users should not call direct `Staking.delegate` or `Staking.undelegate` if the product is pool-based. Keep these
direct staking actions on validator/operator screens only:

| Function                                                   | Who should see it                         |
|------------------------------------------------------------|-------------------------------------------|
| `registerValidator(validator, commissionRate)` payable     | Validator operators.                      |
| `changeValidatorCommissionRate(validator, commissionRate)` | Current validator owner.                  |
| `changeValidatorOwner(validator, newOwner)`                | Current validator owner.                  |
| `claimValidatorFee(validator)`                             | Validator owner.                          |
| `releaseValidatorFromJail(validator)`                      | Jailed validator owner after jail expiry. |

Direct delegator reward calls such as `claimDelegatorFee` and `redelegateDelegatorFee` are for users who delegated
directly to `Staking`. They should not be mixed into a `StakingPool` UX for the same position.

## Governance user flow

`Governance` is OpenZeppelin Governor-compatible with Fluent-specific voting power:

- Only active validator owners can propose.
- Voting power comes from the active validator's total delegated stake at the proposal snapshot block.
- Votes are counted per validator address, not per owner address, so owner rotation cannot double-vote.
- Quorum is two thirds of active validator voting supply at the queried block.
- Vote support values are `0 = Against`, `1 = For`, `2 = Abstain`.

### 1. Determine governance eligibility

For the connected wallet:

```solidity
validator = staking.getValidatorByOwner(user)
canGovern = validator != address(0) && staking.isValidatorActive(validator)
votingPower = governance.getVotingPower(user)
```

Show proposal and voting actions only when `canGovern` is true. `getVotingPower(user)` is current voting power;
proposal-specific voting power is derived at the proposal snapshot block.

### 2. List proposals

Index Governor events from the governance proxy:

- `ProposalCreated`
- `VoteCast`
- `ProposalExecuted`
- `ProposalCanceled`

For each proposal id, refresh:

```solidity
governance.state(proposalId)
governance.proposalSnapshot(proposalId)
governance.proposalDeadline(proposalId)
governance.proposalProposer(proposalId)
governance.proposalEta(proposalId)
governance.proposalVotes(proposalId)
governance.quorum(snapshotBlock)
```

OpenZeppelin Governor proposal states are:

```text
0 Pending
1 Active
2 Canceled
3 Defeated
4 Succeeded
5 Queued
6 Expired
7 Executed
```

This implementation has `votingDelay() == 0`, so proposals normally become active at creation.

### 3. Create a proposal

Standard proposal:

```solidity
governance.propose(targets, values, calldatas, description)
```

Custom voting-period proposal:

```solidity
governance.proposeWithCustomVotingPeriod(
    targets,
    values,
    calldatas,
    description,
    customVotingPeriod
)
```

Frontend responsibilities:

- ABI-encode each target call with the target contract ABI.
- Keep `targets.length == values.length == calldatas.length`.
- Use native-token wei values in `values`.
- Store the exact `description` text because execution uses `keccak256(bytes(description))`.
- Compute or verify the proposal id with `hashProposal(targets, values, calldatas, keccak256(bytes(description)))`.

Example parameter-change proposal:

```typescript
const calldata = encodeFunctionData({
  abi: chainConfigAbi,
  functionName: "setMinStakingAmount",
  args: [parseEther("1")],
});

await governance.write.propose([
  [chainConfigAddress],
  [0n],
  [calldata],
  "Set minimum staking amount to 1 FLUENT"
]);
```

Only propose governance-controlled actions that the governance proxy is authorized to execute. `ChainConfig` setters are
governance-only and are safe examples for frontend proposal builders.

### 4. Vote

User action:

```solidity
governance.castVote(proposalId, support)
```

Optional Governor methods from the ABI may also be used:

```solidity
governance.castVoteWithReason(proposalId, support, reason)
governance.castVoteBySig(proposalId, support, voter, signature)
```

Refresh `proposalVotes(proposalId)` and `state(proposalId)` after the vote transaction confirms. If a validator owner
changes while a proposal is active, the validator still cannot vote twice; the contract counts votes by validator
address.

### 5. Execute

When `state(proposalId) == Succeeded`, execute with the original proposal payload:

```solidity
governance.execute(targets, values, calldatas, keccak256(bytes(description)))
```

If a deployment routes privileged ownership through `FluentTimeLock` instead of direct Governor execution, the frontend
should expose the timelock schedule/execute flow for those targets. Check the deployment's ownership and role
configuration before enabling direct execution.

## Indexing checklist

For staking pages, index:

- `StakingPool.Stake`
- `StakingPool.Unstake`
- `StakingPool.Claim`
- `Staking.ValidatorAdded`
- `Staking.ValidatorModified`
- `Staking.ValidatorRemoved`
- `Staking.ValidatorSlashed`
- `Staking.ValidatorJailed`
- `Staking.ValidatorReleased`
- `Staking.Delegated`
- `Staking.Undelegated`
- `Staking.Claimed`
- `ChainConfig.*Changed`

For governance pages, index:

- `ProposalCreated`
- `VoteCast`
- `ProposalExecuted`
- `ProposalCanceled`

Use contract reads as the source of truth after every indexed event; events are best treated as invalidation signals for
cached UI state.

## Common frontend errors

| Error                     | Likely cause                                                              | UX response                                                                           |
|---------------------------|---------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| `NotActiveValidator()`    | User selected an inactive, pending, jailed, or removed validator.         | Refresh validator list and disable staking for that validator.                        |
| `AmountTooLow(uint256)`   | Stake amount is below `getMinStakingAmount()`.                            | Show minimum stake before submitting.                                                 |
| `WrongAmountPrecision()`  | Amount is incompatible with staking compact precision.                    | Ask user to adjust amount; prefer UI increments compatible with `1e10` wei precision. |
| `EpochIsNotReady(uint64)` | Claim attempted before any pending pool unstake has matured.              | Show the next maturity epoch and keep claim disabled until then.                      |
| `NothingToClaim()`        | No pending or matured claim exists.                                       | Refresh position and hide claim action.                                               |
| `OnlyValidatorOwner()`    | Non-validator-owner tried to propose or perform a validator-owner action. | Hide governance/operator controls for this wallet.                                    |

## Implementation notes

- Use `bigint` or string-safe number handling for all wei, block, and epoch values.
- Always read from proxy addresses, not implementation addresses.
- Treat staking times as block-based estimates, not wall-clock guarantees.
- Keep pooled and direct staking positions separate in the UI.
- After any write, wait for transaction confirmation, then refetch reads from the contracts.
