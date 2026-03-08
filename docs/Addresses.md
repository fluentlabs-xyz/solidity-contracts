# Deployed Bridge Addresses

Current deployment: **Sepolia (L1)** ↔ **Fluent testnet (L2)**.

Source: `deployments/sepolia.json`, `deployments/fluent_testnet.json`.
**Fluent testnet Explorer:** https://testnet.fluentscan.xyz/

---

## Sepolia (L1)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x2E0a1bB6406Cae9012B43EAf01DA2BD10Ca98b3D` | [View](https://sepolia.etherscan.io/address/0x2E0a1bB6406Cae9012B43EAf01DA2BD10Ca98b3D) |
| FluentBridge (impl) | `0xEf0898f69A6851cA927fA67650b2118D69BC969F` | [View](https://sepolia.etherscan.io/address/0xEf0898f69A6851cA927fA67650b2118D69BC969F) |
| **ERC20TokenFactory** (proxy) | `0xe96e07560D31840c1E8b25C1c6D83Cb4AD3718Af` | [View](https://sepolia.etherscan.io/address/0xe96e07560D31840c1E8b25C1c6D83Cb4AD3718Af) |
| ERC20TokenFactory (impl) | `0xE6e4Fca4E3d48b54dF016dB5aD49e10e5b723612` | [View](https://sepolia.etherscan.io/address/0xE6e4Fca4E3d48b54dF016dB5aD49e10e5b723612) |
| UpgradeableBeacon | `0x747B34293b03dCeC5EaF6AB1D9C1974d0f4636e8` | [View](https://sepolia.etherscan.io/address/0x747B34293b03dCeC5EaF6AB1D9C1974d0f4636e8) |
| ERC20PeggedToken (impl) | `0x97F9747F1C6Da86e7C4c441bE50567214045484A` | [View](https://sepolia.etherscan.io/address/0x97F9747F1C6Da86e7C4c441bE50567214045484A) |
| **PaymentGateway** (proxy) | `0x0b72DDB11Ca801f5D14a86a9Fd2C96A1E068E3F7` | [View](https://sepolia.etherscan.io/address/0x0b72DDB11Ca801f5D14a86a9Fd2C96A1E068E3F7) |
| PaymentGateway (impl) | `0x4946B09ec17708d6b5dcC5FBA661D232D8f57d39` | [View](https://sepolia.etherscan.io/address/0x4946B09ec17708d6b5dcC5FBA661D232D8f57d39) |
| **MockERC20** (test token) | `0x3f92d2104c6b61aC9240980a6D570776D7e1558b` | [View](https://sepolia.etherscan.io/address/0x3f92d2104c6b61aC9240980a6D570776D7e1558b) |

- **Chain ID:** 11155111
- **RPC:** https://ethereum-sepolia-rpc.publicnode.com
- **Explorer:** https://sepolia.etherscan.io

---

## Fluent testnet (L2)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x1c4b74359f47e9ceF645167FD9834E5b5512665e` | [View](https://testnet.fluentscan.xyz/address/0x1c4b74359f47e9ceF645167FD9834E5b5512665e) |
| FluentBridge (impl) | `0xaBf18b892AA851b26b06118330F077529474FC16` | [View](https://testnet.fluentscan.xyz/address/0xaBf18b892AA851b26b06118330F077529474FC16) |
| **UniversalTokenFactory** (proxy) | `0x3092cC68Dc5eE1be55a588c09C7c10E834d1BABB` | [View](https://testnet.fluentscan.xyz/address/0x3092cC68Dc5eE1be55a588c09C7c10E834d1BABB) |
| UniversalTokenFactory (impl) | `0xc1de75246e41D7104d357332A77b717a9A2BAC7e` | [View](https://testnet.fluentscan.xyz/address/0xc1de75246e41D7104d357332A77b717a9A2BAC7e) |
| **PaymentGateway** (proxy) | `0xF5E8528151a3413F1eb1F3415cd939eF26E89b8b` | [View](https://testnet.fluentscan.xyz/address/0xF5E8528151a3413F1eb1F3415cd939eF26E89b8b) |
| PaymentGateway (impl) | `0x7BE6D0CEb37a10B43F61c3762D09C9a477d134EA` | [View](https://testnet.fluentscan.xyz/address/0x7BE6D0CEb37a10B43F61c3762D09C9a477d134EA) |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

- **Chain ID:** 20994 (confirm at runtime with `cast chain-id --rpc-url <L2_RPC>`)
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## Pegged token address (L1 → L2)

The L2 pegged token address is computed with CREATE2 using the **L2 chain id** in the salt. The L1 gateway’s `otherSideChainId` must equal L2’s actual `block.chainid`, or the relayer will hit `WrongPeggedToken` on L2. The deploy script `deploy-sepolia-fluent-devnet.sh` now sets `otherSideChainId` from L2 RPC (`cast chain-id`) so it matches. If you deployed earlier with a wrong chain id, call on L1 gateway (as owner): `setOtherSideUniversal(L2_GATEWAY, L2_PEGGED_IMPL, L2_FACTORY, <L2_CHAIN_ID_FROM_RPC>)` with the real L2 chain id from `cast chain-id --rpc-url <L2_RPC>`.

---

## Relayer – deployment blocks (FluentBridge)

Use these as **from-block** when indexing `SentMessage` (and other bridge events) so the relayer starts from bridge deployment.

| Chain        | FluentBridge (proxy) | Deployment block |
|-------------|----------------------|------------------|
| **Sepolia** | `0x2E0a1bB6406Cae9012B43EAf01DA2BD10Ca98b3D` | **10408787** |
| **Fluent testnet** | `0x1c4b74359f47e9ceF645167FD9834E5b5512665e` | **20995147** |

Source: `broadcast/DeployFluentBridge.s.sol/{chainId}/run-latest.json` (receipts).

---

## JSON sources

- **L1:** `deployments/sepolia.json`
- **L2:** `deployments/fluent_testnet.json`

---

## Verification

**Compiler:** Solidity 0.8.30, optimization enabled, 200 runs.

With `ETHERSCAN_API_KEY` in `.env`:

```bash
./scripts/deploy/bash/verify-sepolia-fluent-devnet.sh
```

Sepolia contracts are verified via Etherscan; Fluent testnet contracts via Blockscout at https://testnet.fluentscan.xyz/.
