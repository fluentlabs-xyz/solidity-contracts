# Developer Guide

## Prerequisites

- **[Foundry](https://book.getfoundry.sh/getting-started/installation)** — `forge`, `cast`, `anvil`
- **[gblend](https://github.com/aspect-build/gblend)** — Fluent VM-compatible forge fork (required for L2)
- **Node.js** — required by OpenZeppelin upgrade validator (runs via `npx`)
## Key management

Scripts never handle private keys directly. Use Foundry's encrypted keystore:

```bash
# Import a private key into encrypted keystore (prompts for key + password)
cast wallet import deployer --interactive

# Verify the account was created
cast wallet list
```

Then use `--account deployer` in all forge/gblend commands. Foundry prompts for the password at runtime.

| Method | When to use |
|--------|-------------|
| `--account deployer` | Testnet deploys (encrypted keystore) |
| `--ledger` / `--trezor` | Production mainnet |
| `--private-key` | Local Anvil only |

---

## Deployment

### Quick start

```bash
cp .env.example .env
# Edit .env: set L1_RPC, L2_RPC, DEPLOYER

# Clean build (required before first deploy)
forge clean && forge build

# Deploy everything (L1 + L2 + setup)
./scripts/deploy.sh
```

Available flags:

```bash
./scripts/deploy.sh                # deploy all (L1 + L2 + setup)
./scripts/deploy.sh --l1-only      # deploy L1 only
./scripts/deploy.sh --l2-only      # deploy L2 only
./scripts/deploy.sh --setup-only   # setup only (requires deployed manifests)
./scripts/deploy.sh --preflight    # clean build
```

### Step-by-step (manual)

If you prefer running forge scripts directly instead of `deploy.sh`:

#### 1. Preflight

```bash
forge clean && forge build
```

The OZ upgrade validator requires full build-info.

#### 2. Deploy L1 (Sepolia)

```bash
NETWORK=testnet/l1 \
    forge script scripts/deploy/DeployL1.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast
```

Deploys: NitroVerifier → Rollup (bridge=placeholder) → L1FluentBridge → `Rollup.setBridge()` → ERC20TokenFactory → ERC20Gateway → NativeGateway → MockERC20.

Output: `deployments/testnet/l1.json`

#### 3. Deploy L2 (Fluent)

```bash
NETWORK=testnet/l2 \
    gblend script scripts/deploy/DeployL2.s.sol \
    --rpc-url $L2_RPC --account deployer --broadcast --skip-simulation
```

Deploys: L1BlockOracle → L2FluentBridge → UniversalTokenFactory → ERC20Gateway → NativeGateway.

Output: `deployments/testnet/l2.json`

`gblend` is required for L2. `--skip-simulation` is required because gblend can't simulate proxy delegation calls locally.

#### 4. Setup (cross-chain linking)

```bash
# L1: link bridge and gateways to L2 addresses
forge script scripts/deploy/SetupL1.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast

# L2: link bridge and gateways to L1 addresses
gblend script scripts/deploy/SetupL2.s.sol \
    --rpc-url $L2_RPC --account deployer --broadcast --skip-simulation
```

Setup scripts call:
- `bridge.setOtherBridge(remoteBridge)`
- `bridge.setExecuteGasLimit(executeGasLimit)` (from `scripts/config/<env>/<chain>.json`)
- `erc20Gateway.setOtherSide(isUniversal, remoteGateway, chainId, tokenImpl, factory, beacon)`
- `nativeGateway.setOtherSideGateway(remoteGateway)`

#### 5. Post-deploy: fund L2 bridge and configure oracles

```bash
# Fund L2 bridge for testnet (needed for native bridging)
cast send $L2_BRIDGE --value 1ether --rpc-url $L2_RPC --account deployer

# Set L1 block number on L2 oracle
cast send $L1_BLOCK_ORACLE "updateL1BlockNumber(uint256)" \
    $(cast block-number --rpc-url $L1_RPC) \
    --rpc-url $L2_RPC --account deployer

# Configure L2 gas oracle (for bridge fee calculation)
cast send $L2_BRIDGE "setGasPriceConfig(uint256,uint256,uint256)" \
    1000 1000000000000000000 21000 \
    --rpc-url $L2_RPC --account deployer
```

---

## Configuration

### Config files

```
scripts/config/
  testnet/
    l1.json     ← Sepolia: roles, rollup params, chainId
    l2.json     ← Fluent testnet: roles, bridge params, chainId
```

Configs contain **static** values only (roles, timing, economics). Dynamic addresses come from deployment manifests or env vars.

To add a new environment: copy `testnet/`, update addresses, run with `NETWORK=mainnet/l1`.

### Environment variables

See `.env.example` for the full list. Key variables:

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `L1_RPC` | Yes | — | L1 RPC endpoint |
| `L2_RPC` | Yes | — | L2 RPC endpoint |
| `DEPLOYER` | Yes | — | Keystore account name |
| `FOUNDRY_OUT` | No | `out` | Only set if `foundry.toml` overrides output dir |
| `ENV` | No | `testnet` | Deployment environment (config + manifest paths) |
| `OUTPUT_PATH` | No | `deployments/<ENV>/l1.json` | Manifest output path (derived from NETWORK) |
| `L2_FORGE` | No | `gblend` | Forge binary for L2 commands |

### Deployment manifests

Written to `deployments/<env>/<network>.json`. Flat JSON format:

```json
{
  "bridge": "0x...",
  "bridge_impl": "0x...",
  "rollup": "0x...",
  "factory": "0x...",
  "erc20_gateway": "0x...",
  "native_gateway": "0x..."
}
```

### Verifying configuration with cast

```bash
cast call "$BRIDGE" "getOtherBridge()(address)" --rpc-url "$RPC"
cast call "$BRIDGE" "getSentMessageFee()(uint256)" --rpc-url "$RPC"
cast call "$GATEWAY" "getOtherSideGateway()(address)" --rpc-url "$RPC"
```

---

## Upgrades

All proxy contracts use UUPS pattern with ERC-7201 namespaced storage. The OpenZeppelin Foundry Upgrades plugin validates storage layout compatibility.

### Upgrade procedure

```bash
forge clean && forge build

PROXY_ADDRESS=0x... \
    forge script scripts/upgrade/UpgradeRollup.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast
```

### First upgrade (no reference build)

On the first upgrade after initial deployment, no reference build exists:

```bash
UNSAFE_SKIP_STORAGE_CHECK=true \
PROXY_ADDRESS=0x... \
    forge script scripts/upgrade/UpgradeERC20Gateway.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast
```

### L2 upgrades

```bash
PROXY_ADDRESS=0x... \
    gblend script scripts/upgrade/UpgradeL2Bridge.s.sol \
    --rpc-url $L2_RPC --account deployer --broadcast --skip-simulation
```

### Upgrade scripts

| Contract | Script | Notes |
|----------|--------|-------|
| Rollup | `UpgradeRollup.s.sol` | Safe Upgrades API |
| L1FluentBridge | `UpgradeL1Bridge.s.sol` | Safe Upgrades API |
| L2FluentBridge | `UpgradeL2Bridge.s.sol` | UnsafeUpgrades (gblend compat) |
| ERC20Gateway | `UpgradeERC20Gateway.s.sol` | Supports `UNSAFE_SKIP_STORAGE_CHECK` |
| NativeGateway | `UpgradeNativeGateway.s.sol` | Safe Upgrades API |
| ERC20TokenFactory | `UpgradeERC20TokenFactory.s.sol` | Safe Upgrades API |
| UniversalTokenFactory | `UpgradeUniversalTokenFactory.s.sol` | Safe Upgrades API |
| ERC20PeggedToken (beacon) | `UpgradeERC20Beacon.s.sol` | Beacon upgrade, not proxy |

Non-upgradeable contracts (NitroVerifier, L1BlockOracle, L1GasOracle) are replaced by deploying a new instance and updating the reference in the parent contract.

---

## E2E testing

### Native token bridge (L1→L2)

```bash
./scripts/test-native-bridge.sh
```

Steps: send native on L1 → parse SentMessage event → update L1BlockOracle → fund L2 bridge (testnet only, simulates consensus-layer minting) → relay on L2 → verify balance.

### ERC20 bridge (L1→L2)

```bash
./scripts/test-erc20-bridge.sh
```

Steps: deploy fresh test token on L1 → deposit via ERC20Gateway → parse SentMessage event → update L1BlockOracle → relay on L2 → verify pegged token deployed and balance correct.

Deploys a new `MockERC20Token` on each run to test the full path including factory token deployment on L2.

Both scripts read addresses from deployment manifests and use `cast send` for L2 relay (avoids gblend simulation issues).

---

## Operations scripts

| Script | Purpose |
|--------|---------|
| `scripts/operations/SendNative.s.sol` | Send native tokens via NativeGateway |
| `scripts/operations/DepositTokens.s.sol` | Deposit ERC20 via ERC20Gateway |
| `scripts/operations/ReceiveNative.s.sol` | Relay native message (reads broadcast JSON) |
| `scripts/operations/ReceiveTokens.s.sol` | Low-level relay with explicit message params |
| `scripts/operations/SendEth.s.sol` | Simple ETH transfer |
| `scripts/operations/WithdrawERC20FluentToSepolia.s.sol` | L2→L1 pegged token withdrawal |

---

## Script architecture

```
scripts/deploy/
├── DeployBase.s.sol              # Shared: _readConfig(), _readAddr()
├── DeployRollup.s.sol            # _deployRollup() + _readRollupParams() + run()
├── DeployL1Bridge.s.sol          # _deployL1Bridge() + run()
├── DeployL2Bridge.s.sol          # _deployL2Bridge() + run()
├── DeployERC20Factory.s.sol      # _deployERC20Factory() + run()
├── DeployUniversalFactory.s.sol  # _deployUniversalFactory() + run()
├── DeployERC20Gateway.s.sol      # _deployERC20Gateway() + run()
├── DeployNativeGateway.s.sol     # _deployNativeGateway() + run()
├── DeployL1.s.sol                # Orchestrator: inherits all L1 scripts
├── DeployL2.s.sol                # Orchestrator: inherits all L2 scripts
├── SetupL1.s.sol                 # Cross-chain linking L1→L2
└── SetupL2.s.sol                 # Cross-chain linking L2→L1
```

Each component script has:
- `_deploy*()` — internal function, no broadcast, returns result struct. Used by orchestrators.
- `run()` — standalone entry point with env var reading, broadcast, and manifest writing.

Orchestrators inherit component scripts and call `_deploy*()` inside a single broadcast.

---

## Governance

### Architecture

Two-tier timelock backed by Gnosis Safe multisig (3-of-5 or similar):

| Tier | Delay | Holds | Purpose |
|------|-------|-------|---------|
| **Normal timelock** | 24h (mainnet) / 60s (testnet) | `DEFAULT_ADMIN_ROLE` on Rollup, Bridge, NitroVerifier; `owner()` on Gateways, Factories, Oracles | Upgrades, config changes, granting roles |
| **Emergency timelock** | 1-5 min | `EMERGENCY_ROLE` on Rollup; `PAUSER_ROLE` on Bridge | Pause, force-revert, revoke compromised operators |

Hot keys (sequencer, relayer, preconfirmation, challenger, prover) remain as EOA addresses. The normal timelock can rotate them via `grantRole`/`revokeRole`. In emergencies, the emergency timelock can revoke them instantly via `emergencyRevokeRole` (Rollup) and `emergencyRevokeRelayer` (Bridge).

### Gnosis Safe setup

Install the Safe CLI:

```bash
npm install -g @safe-global/safe-cli
```

Create a Safe on each chain with 3-of-5 (or your desired threshold):

```bash
# L1 (Sepolia)
safe create --network sepolia --owners 0xOwner1,0xOwner2,0xOwner3,0xOwner4,0xOwner5 --threshold 3

# L2 (Fluent)
safe create --network <fluent-rpc> --owners 0xOwner1,0xOwner2,0xOwner3,0xOwner4,0xOwner5 --threshold 3
```

Note the Safe addresses and update `scripts/config/<env>/l1.json` and `l2.json`:
```json
"timelock": {
    "safe": "0xYourSafeAddress..."
}
```

Safe contracts v1.4.1 and v1.5.0 must be deployed on both networks. Check [safe-deployments](https://github.com/safe-global/safe-deployments) for existing deployments, or deploy via Safe CLI if not available.

### Deploy timelocks

```bash
# L1
NETWORK=testnet/l1 forge script scripts/deploy/DeployTimelocks.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast

# L2
NETWORK=testnet/l2 gblend script scripts/deploy/DeployTimelocks.s.sol \
    --rpc-url $L2_RPC --account deployer --broadcast --skip-simulation
```

### Migrate roles

After deploying timelocks, migrate all roles from deployer EOA:

```bash
# L1
LAYER=l1 NORMAL_TIMELOCK=0x... EMERGENCY_TIMELOCK=0x... \
    NORMAL_DELAY=86400 EMERGENCY_DELAY=60 \
    forge script scripts/deploy/MigrateRoles.s.sol \
    --rpc-url $L1_RPC --account deployer --broadcast

# L2
LAYER=l2 NORMAL_TIMELOCK=0x... EMERGENCY_TIMELOCK=0x... \
    NORMAL_DELAY=86400 EMERGENCY_DELAY=60 \
    gblend script scripts/deploy/MigrateRoles.s.sol \
    --rpc-url $L2_RPC --account deployer --broadcast --skip-simulation
```

The migration script:
1. Grants admin roles to normal timelock, emergency roles to emergency timelock
2. Transfers Ownable2Step contracts to normal timelock (and accepts via timelock)
3. Sets target delays on both timelocks (deployed with delay=0 for atomic migration)
4. Renounces all EOA admin roles (irreversible)

### Operating via timelock

After migration, all admin operations go through the Safe → Timelock flow:

1. Safe signer proposes operation via Safe UI/CLI
2. Other signers confirm (reach threshold)
3. Safe calls `timelock.schedule(target, value, data, predecessor, salt, delay)`
4. Wait for delay
5. Safe calls `timelock.execute(target, value, data, predecessor, salt)`

---

## Extending the system

- **New asset type:** Inherit `GatewayBase`, enforce `onlyFluentBridge` on receive paths, encode a fixed remote selector payload (same pattern as `NativeGateway` / `ERC20Gateway`).
- **New message path:** L1/L2 differences live in `L1FluentBridge` / `L2FluentBridge`. Coordinate storage layout via `FluentBridgeStorageLayout` and run storage diffs before upgrades.
- **Tests:** Add suites under `test/Bridge`, `test/Gateway`, `test/Rollup`, etc., following existing `Base.t.sol` patterns.

---

## FAQ / Troubleshooting

**`Build info file is not from a full compilation`**
Run `forge clean && forge build` before deploying or upgrading.

**`vm.readFile: failed to open file .../out/...`**
The OZ plugin can't find build artifacts. Run `forge clean && forge build` for a full compilation. If `foundry.toml` has a custom `out` directory, set `FOUNDRY_OUT` to match.

**`MalformedBuiltinParams` on L2 proxy calls**
Use `--skip-simulation` for all L2 gblend commands. For relay, use `cast send` directly.


**`does not specify what contract it upgrades from`**
First upgrade — set `UNSAFE_SKIP_STORAGE_CHECK=true`.

**`MessageReceivedOutOfOrder`**
Check `cast call $BRIDGE "getReceivedNonce()(uint256)"` and relay skipped nonces first.

**Bridge↔Rollup circular dependency**
DeployL1 handles this: Rollup with placeholder → Bridge → `Rollup.setBridge()`.

**`Device not configured (os error 6)` on macOS**
Run in interactive terminal. Use `--sender` for dry-run, `--account` for broadcast.

**L2 bridge needs ETH for native bridging**
Testnet: `cast send $BRIDGE --value 1ether --rpc-url $L2_RPC --account deployer`. Mainnet: consensus layer mints.

**`ZeroValueNotAllowed("l1BlockNumber")`**
Initialize oracle: `cast send $ORACLE "updateL1BlockNumber(uint256)" $(cast block-number --rpc-url $L1_RPC) --rpc-url $L2_RPC --account deployer`

**`InsufficientFee()` on `sendMessage`**
`msg.value` is below `getSentMessageFee()`. Increase it.

**`MessageAlreadyReceived()`**
Duplicate delivery. Do not re-submit same hash.
