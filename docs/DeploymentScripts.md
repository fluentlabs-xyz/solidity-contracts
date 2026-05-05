# Deployment and migration scripts

Foundry does not have Truffle's built-in migration registry. This repository treats each deployment or migration script as an explicit release plan, and uses a named-chain wrapper to avoid choosing the wrong RPC manually.

## Preferred entrypoint

Use `scripts/run-chain.sh` and specify exactly one target chain:

```sh
CHAIN=L2_MAINNET ./scripts/run-chain.sh scripts/migrations/MigrateStaking.s.sol:MigrateStaking
```

By default this is a dry-run. To broadcast, add `--broadcast`; the deployer wallet can live in `.env`:

```sh
CHAIN=L2_MAINNET \
DEPLOYER=deployer \
./scripts/run-chain.sh --broadcast scripts/migrations/MigrateStaking.s.sol:MigrateStaking
```

The wrapper derives all of the following from `CHAIN` and uses built-in public RPC constants for non-local chains:

- RPC URL env var
- `NETWORK` (`mainnet/l2`, `testnet/l2`, etc.)
- `ENV` (`mainnet`, `testnet`, `local`)
- `LAYER` (`l1`, `l2`)
- default manifest path (`deployments/<env>/<layer>.json`)

Supported values:

| CHAIN | Config | RPC |
|-------|--------|---------|
| `L1_MAINNET` | `scripts/config/mainnet/l1.json` | `https://ethereum-rpc.publicnode.com` |
| `L1_SEPOLIA` | `scripts/config/testnet/l1.json` | `https://ethereum-sepolia-rpc.publicnode.com` |
| `L2_MAINNET` | `scripts/config/mainnet/l2.json` | `https://rpc.fluent.xyz` |
| `L2_TESTNET` | `scripts/config/testnet/l2.json` | `https://rpc.testnet.fluent.xyz` |
| `LOCAL_L1` | `scripts/config/local/l1.json` | `LOCAL_L1_RPC` or `http://localhost:8545` |
| `LOCAL_L2` | `scripts/config/local/l2.json` | `LOCAL_L2_RPC` or `http://localhost:8546` |

Before invoking Forge, the wrapper checks that `cast chain-id --rpc-url <resolved RPC>` matches the selected config file. Scripts using `DeployBase._readActiveConfig()` also assert `block.chainid` on-chain during simulation/broadcast.


## Staking and governance configuration

Staking and governance release parameters live in the selected L2 config file, for example `scripts/config/mainnet/l2.json`:

```json
{
  "staking": {
    "activeValidatorsLength": 21,
    "epochBlockInterval": 200,
    "misdemeanorThreshold": 50,
    "felonyThreshold": 150,
    "validatorJailEpochLength": 7,
    "undelegatePeriod": 0,
    "minValidatorStakeAmount": "1000000000000000000",
    "minStakingAmount": "1000000000000000000",
    "initialValidators": [],
    "initialStakes": [],
    "initialCommissionRate": 0,
    "systemReward": {
      "accounts": ["0x..."],
      "shares": [10000]
    }
  },
  "governance": {
    "votingPeriod": 172800
  }
}
```

`DeployStaking` reads these values directly from config, deploys staking module implementations and ERC-1967 proxies, and wires governance using predicted proxy addresses. `DeployGovernance` reads `governance.votingPeriod` from config and resolves staking/chain-config addresses from either `governance.staking` / `governance.chainConfig` or the selected deployment manifest.

## Release/migration convention

For each production release:

1. Add or update a script under `scripts/migrations/<env>/` or a shared script under `scripts/migrations/` when it is environment-independent.
2. Read addresses from `deployments/<env>/<layer>.json` instead of hard-coding them where possible.
3. Assert every target proxy/contract has code before upgrade/configuration.
4. Assert `block.chainid == scripts/config/<env>/<layer>.json.chainId`.
5. Dry-run with `scripts/run-chain.sh` first.
6. Broadcast with `BROADCAST=1` only after reviewing the dry-run transaction list.
7. Commit updated manifests and verification notes.

For upgrades, prefer OpenZeppelin Foundry Upgrades with storage-layout validation. Use unsafe upgrade helpers only with an explicit opt-in and a documented reason.
