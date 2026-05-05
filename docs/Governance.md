# Governance contracts

The governance module gives active validator owners an OpenZeppelin Governor-compatible way to manage staking and consensus parameters. It is designed for the Fluent staking system and is deployed behind an ERC-1967 proxy.

## Contract map

| Contract | Purpose |
|----------|---------|
| `Governance` | Validator-owner Governor. Active validator owners can propose and vote; voting power comes from active validator delegated stake. |
| `FluentTimeLock` | Thin wrapper around OpenZeppelin `TimelockController`, deployed as a self-administered timelock for delayed governance execution. |

## Voting model

`Governance` reads validator data from `Staking` and epoch parameters from `ChainConfig`:

- A caller can propose only if it owns an active validator.
- Voting power is the validator's total delegated stake at the proposal snapshot block.
- Quorum is two thirds of the active validator voting supply at the queried block.
- Vote accounting is keyed by validator address, not owner address. If a validator owner changes during an active proposal, the validator cannot vote twice through the old and new owners.
- The default voting delay is `0`; the default voting period is configured at initialization and can also be overridden for a single proposal with `proposeWithCustomVotingPeriod`.

This keeps governance aligned with the validator set while avoiding double-vote edge cases during ownership rotation.

## Upgrade and storage model

`Governance` is UUPS-upgradeable. The proxy owner authorizes upgrades via `Ownable2StepUpgradeable`, and the implementation constructor disables initializers. Mutable custom governance state uses ERC-7201 namespaced storage.

The staking contracts receive the governance address as an immutable constructor dependency, so deployments that wire staking and governance together must predict proxy addresses before creating the implementations. The Foundry deployment scripts and tests follow that pattern.

## Timelock usage

`FluentTimeLock` is not upgradeable. Its admin is set to `address(0)`, which makes it self-administered after deployment. Operationally, this means changes to timelock roles or delay must themselves be scheduled and executed through the timelock.

Typical production ownership flow:

1. Deploy staking and governance proxies.
2. Deploy `FluentTimeLock` with governance as proposer and appropriate executor configuration.
3. Transfer ownership or privileged roles for governed contracts to the timelock.
4. Execute parameter changes through Governor proposals routed to the timelock.

## Tests

Governance tests live in `test/governance/Governance.t.sol` and cover:

- voting power following validator owner changes;
- preventing double-votes after validator owner rotation; and
- custom voting periods for individual proposals.

Run them with:

```sh
forge test --match-path test/governance/Governance.t.sol -vvv
```
