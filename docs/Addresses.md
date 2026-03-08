# Deployed Bridge Addresses

Current deployment: **Sepolia (L1)** ↔ **Fluent testnet (L2)**.

Source: `deployments/sepolia.json`, `deployments/fluent_testnet.json`.
**Fluent testnet Explorer:** https://testnet.fluentscan.xyz/

---

## Sepolia (L1)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x45B7Db9A02E62719fD6Fa9c16bEFCB6Dd24d0827` | [View](https://sepolia.etherscan.io/address/0x45B7Db9A02E62719fD6Fa9c16bEFCB6Dd24d0827) |
| FluentBridge (impl) | `0x894beE8112342163FcbFC7B460360B78b4eb68dc` | [View](https://sepolia.etherscan.io/address/0x894beE8112342163FcbFC7B460360B78b4eb68dc) |
| **ERC20TokenFactory** (proxy) | `0x4DF8aD1da9605d4F2cC0DF3a3Af74274b0521F90` | [View](https://sepolia.etherscan.io/address/0x4DF8aD1da9605d4F2cC0DF3a3Af74274b0521F90) |
| ERC20TokenFactory (impl) | `0x37E5aF59DAC28e7e572EFF34F01E6d90E27FcF43` | [View](https://sepolia.etherscan.io/address/0x37E5aF59DAC28e7e572EFF34F01E6d90E27FcF43) |
| UpgradeableBeacon | `0x69F1e3d5F5cBCD16242AC251de7C093a4A603797` | [View](https://sepolia.etherscan.io/address/0x69F1e3d5F5cBCD16242AC251de7C093a4A603797) |
| ERC20PeggedToken (impl) | `0x68Cf6B409d21D08CC68E0c484c70661fB26C9470` | [View](https://sepolia.etherscan.io/address/0x68Cf6B409d21D08CC68E0c484c70661fB26C9470) |
| **PaymentGateway** (proxy) | `0x0fa56ec76447a4B331f288e31DB4F4a0F957Af6e` | [View](https://sepolia.etherscan.io/address/0x0fa56ec76447a4B331f288e31DB4F4a0F957Af6e) |
| PaymentGateway (impl) | `0xC1a070A9BC36335118857Db4a8E9e83c5AE585af` | [View](https://sepolia.etherscan.io/address/0xC1a070A9BC36335118857Db4a8E9e83c5AE585af) |
| **MockERC20** (test token) | `0xaFCAeb5Da2a026080a4D12Bf7fCE88742bb1B2aD` | [View](https://sepolia.etherscan.io/address/0xaFCAeb5Da2a026080a4D12Bf7fCE88742bb1B2aD) |

- **Chain ID:** 11155111
- **RPC:** https://ethereum-sepolia-rpc.publicnode.com
- **Explorer:** https://sepolia.etherscan.io

---

## Fluent testnet (L2)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x8D1919f5419ECC66A38680C088A941d66e57f6a2` | [View](https://testnet.fluentscan.xyz/address/0x8D1919f5419ECC66A38680C088A941d66e57f6a2) |
| FluentBridge (impl) | `0x51fEB71fDB7899275c1D533f227B687F4fb5fC1D` | [View](https://testnet.fluentscan.xyz/address/0x51fEB71fDB7899275c1D533f227B687F4fb5fC1D) |
| **UniversalTokenFactory** (proxy) | `0x8E17248117cf7523eCaCaE5e6a1062b2e7e579Ea` | [View](https://testnet.fluentscan.xyz/address/0x8E17248117cf7523eCaCaE5e6a1062b2e7e579Ea) |
| UniversalTokenFactory (impl) | `0xda5950F1b47daCE5aFa26144B2E889efF96FD1d5` | [View](https://testnet.fluentscan.xyz/address/0xda5950F1b47daCE5aFa26144B2E889efF96FD1d5) |
| **PaymentGateway** (proxy) | `0x443688cb80Bec4b5280E8f6C64D99C603F504560` | [View](https://testnet.fluentscan.xyz/address/0x443688cb80Bec4b5280E8f6C64D99C603F504560) |
| PaymentGateway (impl) | `0x011E1aa0857420951e323599704Ac276bCECDfe9` | [View](https://testnet.fluentscan.xyz/address/0x011E1aa0857420951e323599704Ac276bCECDfe9) |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

- **Chain ID:** 20994 (confirm at runtime with `cast chain-id --rpc-url <L2_RPC>`)
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## Pegged token address (L1 → L2)

The L2 pegged token address is computed with CREATE2 using the **L2 chain id** in the salt. The L1 gateway's `otherSideChainId` must equal L2's actual `block.chainid`, or the relayer will hit `WrongPeggedToken` on L2. The deploy script `deploy-sepolia-fluent-devnet.sh` now sets `otherSideChainId` from L2 RPC (`cast chain-id`) so it matches. If you deployed earlier with a wrong chain id, call on L1 gateway (as owner): `setOtherSideUniversal(L2_GATEWAY, L2_PEGGED_IMPL, L2_FACTORY, <L2_CHAIN_ID_FROM_RPC>)` with the real L2 chain id from `cast chain-id --rpc-url <L2_RPC>`.

---

## Relayer – deployment blocks (FluentBridge)

Use these as **from-block** when indexing `SentMessage` (and other bridge events) so the relayer starts from bridge deployment.

| Chain        | FluentBridge (proxy) | Deployment block |
|-------------|----------------------|------------------|
| **Sepolia** | `0x45B7Db9A02E62719fD6Fa9c16bEFCB6Dd24d0827` | **10408951** |
| **Fluent testnet** | `0x8D1919f5419ECC66A38680C088A941d66e57f6a2` | **20995183** |

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

Runs L1 (Etherscan) and L2 (Blockscout) verification in a single execution. Sepolia contracts are verified via Etherscan; Fluent testnet contracts via Blockscout at https://testnet.fluentscan.xyz/.
