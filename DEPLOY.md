# Deployment

## Deploy

### L1 (Ethereum / Sepolia)

| # | Contract | Type | Script |
|---|----------|------|--------|
| 1 | NitroVerifier | plain | `DeployL1.s.sol` |
| 2 | L1FluentBridge | UUPS proxy | `DeployL1.s.sol` |
| 3 | Rollup | UUPS proxy | `DeployL1.s.sol` |
| 4 | bridge.setRollup() | admin call | `DeployL1.s.sol` |
| 5 | ERC20TokenFactory | UUPS proxy + beacon | `DeployL1.s.sol` |
| 6 | ERC20Gateway | UUPS proxy | `DeployL1.s.sol` |
| 7 | NativeGateway | UUPS proxy | `DeployL1.s.sol` |

### L2 (Fluent)

| # | Contract | Type | Script |
|---|----------|------|--------|
| 1 | L1BlockOracle | plain | `DeployL2.s.sol` |
| 2 | L2FluentBridge | UUPS proxy | `DeployL2.s.sol` |
| 3 | UniversalTokenFactory | UUPS proxy | `DeployL2.s.sol` |
| 4 | ERC20Gateway | UUPS proxy | `DeployL2.s.sol` |
| 5 | NativeGateway | UUPS proxy | `DeployL2.s.sol` |

### Cross-Chain Linking

| # | Action | Script |
|---|--------|--------|
| 1 | L1 bridge/gateway → L2 addresses | `SetupL1.s.sol` |
| 2 | L2 bridge/gateway → L1 addresses | `SetupL2.s.sol` |

### Commands

```bash
# Full deployment (all chains + linking)
L1_RPC=... L2_RPC=... DEPLOYER=deployer ./scripts/deploy.sh

# Or step by step:
NETWORK=testnet/l1 forge script scripts/deploy/DeployL1.s.sol \
    --rpc-url $L1_RPC --broadcast --account deployer

NETWORK=testnet/l2 ALLOW_UNSAFE_UPGRADES=true \
    forge script scripts/deploy/DeployL2.s.sol \
    --rpc-url $L2_RPC --broadcast --account deployer

forge script scripts/deploy/SetupL1.s.sol --rpc-url $L1_RPC --broadcast --account deployer
forge script scripts/deploy/SetupL2.s.sol --rpc-url $L2_RPC --broadcast --account deployer
```

### Emergency: Redeploy a Single Contract

Every contract has a standalone script in `scripts/deploy/components/`:

```bash
forge script scripts/deploy/components/DeployL1Bridge.s.sol \
    --rpc-url $L1_RPC --broadcast --account deployer
```

## Upgrade

Every UUPS proxy contract has an upgrade script in `scripts/upgrade/`. Each validates storage layout compatibility before deploying the new implementation.

| Contract | Script | Auth |
|----------|--------|------|
| Rollup | `UpgradeRollup.s.sol` | `DEFAULT_ADMIN_ROLE` |
| L1FluentBridge | `UpgradeL1Bridge.s.sol` | `DEFAULT_ADMIN_ROLE` |
| L2FluentBridge | `UpgradeL2Bridge.s.sol` | `DEFAULT_ADMIN_ROLE` |
| ERC20Gateway | `UpgradeERC20Gateway.s.sol` | Owner |
| NativeGateway | `UpgradeNativeGateway.s.sol` | Owner |
| ERC20TokenFactory | `UpgradeERC20TokenFactory.s.sol` | Owner |
| UniversalTokenFactory | `UpgradeUniversalTokenFactory.s.sol` | Owner |
| ERC20PeggedToken (beacon) | `UpgradeERC20Beacon.s.sol` | Factory owner |

```bash
PROXY_ADDRESS=0x... forge script scripts/upgrade/UpgradeRollup.s.sol \
    --rpc-url $L1_RPC --broadcast --account deployer
```

Non-upgradeable contracts (NitroVerifier, L1BlockOracle, L1GasOracle) are replaced by deploying a new instance and updating the reference in the parent contract.

## Configuration

Chain parameters live in `scripts/config/<env>/<layer>.json`, organized by environment:

```
scripts/config/
  testnet/
    l1.json     ← Sepolia
    l2.json     ← Fluent testnet
  devnet/
    l2.json     ← Fluent dev
  mainnet/       ← create when needed
    l1.json
    l2.json
```

Configs contain only **static** values (roles, protocol parameters). Dynamic addresses (deployed contract addresses) come from env vars or the deployment manifest.

To add a new environment: copy an existing directory, update addresses, run with `NETWORK=mainnet/l1`.

Deploy scripts write output to `deployments/<network>.json`.

## Security

**Upgrade validation.** All proxy deployments and upgrades use the OpenZeppelin safe `Upgrades` API, which validates storage layout and checks initializers via FFI. Exception: UniversalTokenFactory requires `ALLOW_UNSAFE_UPGRADES=true` due to an unlinked library.

**Key management.** Scripts never handle private keys. Use `--ledger` (production), `--account` (testnet), or `--private-key` (local Anvil only).

**Dry-run first.** Run without `--broadcast` to simulate. Review transactions in `broadcast/<Script>/<chainId>/dry-run/run-latest.json` before broadcasting.

**Production admin transfer.** Deploy with EOA, then transfer ownership to TimelockController/Safe. For Ownable2Step contracts: `transferOwnership()` → `acceptOwnership()`. For AccessControl contracts: grant admin role to Timelock, then renounce own role.

## Limitations

- **No idempotency** — re-running a deploy creates duplicate contracts
- **No deterministic addresses** — addresses depend on deployer nonce
- **UniversalTokenFactory** skips OZ upgrade validation (unlinked library)
- **Bridge↔Rollup circular dependency** — resolved by deploying bridge first with rollup=0x0, then setting rollup via admin call

## Script Structure

```
scripts/
  deploy/
    DeployL1.s.sol              ← L1 orchestrator (deploys everything)
    DeployL2.s.sol              ← L2 orchestrator (deploys everything)
    SetupL1.s.sol               ← link L1 → L2
    SetupL2.s.sol               ← link L2 → L1
    components/                 ← individual contract scripts
      DeployLib.s.sol           ← shared deployment helpers
      DeployL1Bridge.s.sol
      DeployL2Bridge.s.sol
      DeployRollup.s.sol
      DeployERC20Gateway.s.sol
      DeployNativeGateway.s.sol
      DeployERC20TokenFactory.s.sol
      DeployUniversalTokenFactory.s.sol
      DeployNitroVerifier.s.sol
      DeployL1BlockOracle.s.sol
      DeployMockERC20Token.s.sol
  upgrade/                      ← one script per upgradeable contract
    UpgradeRollup.s.sol
    UpgradeL1Bridge.s.sol
    UpgradeL2Bridge.s.sol
    UpgradeERC20Gateway.s.sol
    UpgradeNativeGateway.s.sol
    UpgradeERC20TokenFactory.s.sol
    UpgradeUniversalTokenFactory.s.sol
    UpgradeERC20Beacon.s.sol
  operations/                   ← day-to-day interactions
  VerifyDeployment.s.sol
  deploy.sh
  config/                       ← chain config JSON files (by environment)
    testnet/
      l1.json
      l2.json
    devnet/
      l2.json
```
