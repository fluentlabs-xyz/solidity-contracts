# Deployed Bridge Addresses

Current deployment: **Sepolia (L1)** ↔ **Fluent testnet (L2)**.

Source: `deployments/sepolia.json`, `deployments/fluent_testnet.json`.
**Fluent testnet Explorer:** https://testnet.fluentscan.xyz/

---

## Sepolia (L1)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x4C5e91Eb110d39896E9d4aEbC6122Ea1335963d9` | [View](https://sepolia.etherscan.io/address/0x4C5e91Eb110d39896E9d4aEbC6122Ea1335963d9) |
| FluentBridge (impl) | `0xb7DbEb4779728da06Ea0f00aBE249bC424A235a4` | [View](https://sepolia.etherscan.io/address/0xb7DbEb4779728da06Ea0f00aBE249bC424A235a4) |
| **ERC20TokenFactory** (proxy) | `0x2748B8068DEb5229AcD420bf9E2Daa7DDE04098C` | [View](https://sepolia.etherscan.io/address/0x2748B8068DEb5229AcD420bf9E2Daa7DDE04098C) |
| ERC20TokenFactory (impl) | `0xBFbeEC28d16c227453dEc576120F006c258FDDaC` | [View](https://sepolia.etherscan.io/address/0xBFbeEC28d16c227453dEc576120F006c258FDDaC) |
| UpgradeableBeacon | `0x9adEEA65c560bCc32Da8A0e082DE6585cCa87644` | [View](https://sepolia.etherscan.io/address/0x9adEEA65c560bCc32Da8A0e082DE6585cCa87644) |
| ERC20PeggedToken (impl) | `0xfCF23A4F72c481ed9C8e5BC1433B5800bC58aD3F` | [View](https://sepolia.etherscan.io/address/0xfCF23A4F72c481ed9C8e5BC1433B5800bC58aD3F) |
| **PaymentGateway** (proxy) | `0x22BC1D0b22CD5C2696c4a05Deaeb18c91226B37A` | [View](https://sepolia.etherscan.io/address/0x22BC1D0b22CD5C2696c4a05Deaeb18c91226B37A) |
| PaymentGateway (impl) | `0x6317faa6389184308903A81b4989F88aBB044A4F` | [View](https://sepolia.etherscan.io/address/0x6317faa6389184308903A81b4989F88aBB044A4F) |
| **MockERC20** (test token) | `0xeDeA99d586a5d536d3a64e491FCc58ed65E37F5B` | [View](https://sepolia.etherscan.io/address/0xeDeA99d586a5d536d3a64e491FCc58ed65E37F5B) |

- **Chain ID:** 11155111
- **RPC:** https://ethereum-sepolia-rpc.publicnode.com
- **Explorer:** https://sepolia.etherscan.io

---

## Fluent testnet (L2)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x509d762A611Df2877925AF5Eed38d772fDC062B0` | [View](https://testnet.fluentscan.xyz/address/0x509d762A611Df2877925AF5Eed38d772fDC062B0) |
| FluentBridge (impl) | `0xaFCAeb5Da2a026080a4D12Bf7fCE88742bb1B2aD` | [View](https://testnet.fluentscan.xyz/address/0xaFCAeb5Da2a026080a4D12Bf7fCE88742bb1B2aD) |
| **UniversalTokenFactory** (proxy) | `0x08640D6dF235AA084081A151fd2b2bBF8315377c` | [View](https://testnet.fluentscan.xyz/address/0x08640D6dF235AA084081A151fd2b2bBF8315377c) |
| UniversalTokenFactory (impl) | `0x2aa8E7385Ba4d8753911a5559ffEdd54aC0eC593` | [View](https://testnet.fluentscan.xyz/address/0x2aa8E7385Ba4d8753911a5559ffEdd54aC0eC593) |
| **PaymentGateway** (proxy) | `0xc09881B61c2f1A447B3F6565c12bE5b5934741E7` | [View](https://testnet.fluentscan.xyz/address/0xc09881B61c2f1A447B3F6565c12bE5b5934741E7) |
| PaymentGateway (impl) | `0x1A2a2aD377c580567E3f09388e55806b4c573DbB` | [View](https://testnet.fluentscan.xyz/address/0x1A2a2aD377c580567E3f09388e55806b4c573DbB) |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

- **Chain ID:** 20994 (confirm at runtime with `cast chain-id --rpc-url <L2_RPC>`)
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## Pegged token address (L1 → L2)

The L2 pegged token address is computed with CREATE2 using the **L2 chain id** in the salt. The L1 gateway's `otherSideChainId` must equal L2's actual `block.chainid`, or the relayer will hit `WrongPeggedToken` on L2. The deploy scripts set `otherSideChainId` from L2 RPC (`cast chain-id`) so it matches. If you deployed earlier with a wrong chain id, call on L1 gateway (as owner): `setOtherSideUniversal(L2_GATEWAY, L2_PEGGED_IMPL, L2_FACTORY, <L2_CHAIN_ID_FROM_RPC>)` with the real L2 chain id from `cast chain-id --rpc-url <L2_RPC>`.

---

## Relayer – deployment blocks (FluentBridge)

Use these as **from-block** when indexing `SentMessage` (and other bridge events) so the relayer starts from bridge deployment.

| Chain        | FluentBridge (proxy) | Deployment block |
|-------------|----------------------|------------------|
| **Sepolia** | `0x4C5e91Eb110d39896E9d4aEbC6122Ea1335963d9` | **10408986** |
| **Fluent testnet** | `0x509d762A611Df2877925AF5Eed38d772fDC062B0` | **20995145** |

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
bash ./scripts/deploy/bash/verify-sepolia-fluent-devnet.sh
```

Runs L1 (Etherscan) and L2 (Blockscout) verification in a single execution. Sepolia contracts are verified via Etherscan; Fluent testnet contracts via Blockscout at https://testnet.fluentscan.xyz/.
