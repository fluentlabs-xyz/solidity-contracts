# Deployed Bridge Addresses

Current deployment: **Sepolia (L1)** ↔ **Fluent testnet (L2)**.

Source: `deployments/sepolia.json`, `deployments/fluent_testnet.json`.
**Fluent testnet Explorer:** https://testnet.fluentscan.xyz/

---

## Sepolia (L1)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x990568FfaDddBDBF614ff1EA0eF5630BD8957Ddc` | [View](https://sepolia.etherscan.io/address/0x990568FfaDddBDBF614ff1EA0eF5630BD8957Ddc) |
| FluentBridge (impl) | `0x5d88CD642b160477A2A7B121edF8338dff6B59b3` | [View](https://sepolia.etherscan.io/address/0x5d88CD642b160477A2A7B121edF8338dff6B59b3) |
| **ERC20TokenFactory** (proxy) | `0x299647D9CCB041CC7B24334132Ce40bAe782307B` | [View](https://sepolia.etherscan.io/address/0x299647D9CCB041CC7B24334132Ce40bAe782307B) |
| ERC20TokenFactory (impl) | `0xAcc5dbf44ED0720A58247c91A60825bbC44770a9` | [View](https://sepolia.etherscan.io/address/0xAcc5dbf44ED0720A58247c91A60825bbC44770a9) |
| UpgradeableBeacon | `0x89C1066323dBb4a0fC8a23343EC2966579cc0877` | [View](https://sepolia.etherscan.io/address/0x89C1066323dBb4a0fC8a23343EC2966579cc0877) |
| ERC20PeggedToken (impl) | `0xe2963EC5EE91C5EF911Ea5993135C72b7ce6CA2e` | [View](https://sepolia.etherscan.io/address/0xe2963EC5EE91C5EF911Ea5993135C72b7ce6CA2e) |
| **PaymentGateway** (proxy) | `0x8a2b6627fFbd481907b23070Faf5a33C596A1b9f` | [View](https://sepolia.etherscan.io/address/0x8a2b6627fFbd481907b23070Faf5a33C596A1b9f) |
| PaymentGateway (impl) | `0x497Aaa773d9F02A36737bfc59669667c8CC28B49` | [View](https://sepolia.etherscan.io/address/0x497Aaa773d9F02A36737bfc59669667c8CC28B49) |
| **MockERC20** (test token) | `0x39f86A7d19f1bF090EbBaF6BFAbB900c5CF48DB8` | [View](https://sepolia.etherscan.io/address/0x39f86A7d19f1bF090EbBaF6BFAbB900c5CF48DB8) |

- **Chain ID:** 11155111
- **RPC:** https://ethereum-sepolia-rpc.publicnode.com
- **Explorer:** https://sepolia.etherscan.io

---

## Fluent testnet (L2)

| Contract | Address | Explorer |
|----------|---------|----------|
| **FluentBridge** (proxy) | `0x22795142Ceb81A2b676c72a369edb99990A3622B` | [View](https://testnet.fluentscan.xyz/address/0x22795142Ceb81A2b676c72a369edb99990A3622B) |
| FluentBridge (impl) | `0xa09E0ca1C5fa103fd7a91Ce10b1d88af9C9f9Fd3` | [View](https://testnet.fluentscan.xyz/address/0xa09E0ca1C5fa103fd7a91Ce10b1d88af9C9f9Fd3) |
| **UniversalTokenFactory** (proxy) | `0x4c64F50F9CbeE440f8c4ea6147517018D680AE6c` | [View](https://testnet.fluentscan.xyz/address/0x4c64F50F9CbeE440f8c4ea6147517018D680AE6c) |
| UniversalTokenFactory (impl) | `0x4bc7ef271d5659025c2A88B149BD1da019570538` | [View](https://testnet.fluentscan.xyz/address/0x4bc7ef271d5659025c2A88B149BD1da019570538) |
| **PaymentGateway** (proxy) | `0xdC9BF18a1c307ce1A84e2775C7645e57eB373CD4` | [View](https://testnet.fluentscan.xyz/address/0xdC9BF18a1c307ce1A84e2775C7645e57eB373CD4) |
| PaymentGateway (impl) | `0x5D21C0E4040c6D5B6016D85255f85d0eFc42f6ac` | [View](https://testnet.fluentscan.xyz/address/0x5D21C0E4040c6D5B6016D85255f85d0eFc42f6ac) |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

- **Chain ID:** 20994 (confirm at runtime with `cast chain-id --rpc-url <L2_RPC>`)
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## Pegged token address (L1 → L2)

The L2 pegged token address is computed with CREATE2 using the **L2 chain id** in the salt (L1 gateway) or origin-token-only salt (L2 Universal). The L1 gateway's `otherSideChainId` must equal L2's actual `block.chainid`, or the relayer can hit `WrongPeggedToken` on L2. The deploy scripts set `otherSideChainId` from L2 RPC (`cast chain-id`) so it matches. If you deployed earlier with a wrong chain id, call on L1 gateway (as owner): `setOtherSideUniversal(L2_GATEWAY, L2_PEGGED_IMPL, L2_FACTORY, <L2_CHAIN_ID_FROM_RPC>)` with the real L2 chain id from `cast chain-id --rpc-url <L2_RPC>`.

---

## Relayer – deployment blocks (FluentBridge)

Use these as **from-block** when indexing `SentMessage` (and other bridge events) so the relayer starts from bridge deployment. Get the block number from the broadcast receipts in `broadcast/DeployFluentBridge.s.sol/{chainId}/run-latest.json` (transaction that created the **proxy** contract).

| Chain        | FluentBridge (proxy) | Deployment block |
|-------------|----------------------|------------------|
| **Sepolia** | `0x990568FfaDddBDBF614ff1EA0eF5630BD8957Ddc` | See broadcast receipts |
| **Fluent testnet** | `0x22795142Ceb81A2b676c72a369edb99990A3622B` | See broadcast receipts |

---

## JSON sources

- **L1:** `deployments/sepolia.json`
- **L2:** `deployments/fluent_testnet.json`

---

## Verification

**Compiler:** Solidity 0.8.30, optimization enabled, 200 runs.

With `ETHERSCAN_API_KEY` in `.env`:

```bash
bash ./scripts/deploy/bash/verify-sepolia-fluent-testnet.sh
```

Runs L1 (Etherscan) and L2 (Blockscout) verification in a single execution. Sepolia contracts are verified via Etherscan; Fluent testnet contracts via Blockscout at https://testnet.fluentscan.xyz/.
