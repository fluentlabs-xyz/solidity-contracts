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
| PaymentGateway (impl) | `0x246f6AA064F607AEb76208BcF7948212F0894ceA` | [View](https://sepolia.etherscan.io/address/0x246f6AA064F607AEb76208BcF7948212F0894ceA) |
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
| PaymentGateway (impl) | `0xdE0079364f24045Fa144CaE722055709d8547b4d` | [View](https://testnet.fluentscan.xyz/address/0xdE0079364f24045Fa144CaE722055709d8547b4d) |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

- **Chain ID:** 20994 (confirm at runtime with `cast chain-id --rpc-url <L2_RPC>`)
- **RPC:** https://rpc.testnet.fluent.xyz/
- **Explorer:** https://testnet.fluentscan.xyz/

---

## Fluent Connect – AppDeposit

Stateless and ownerless: forwards a deposit into a paymaster's EntryPoint v0.7 deposit
(`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) and emits `Deposited`, which the Fluent Connect
settler credits to the App. Deployed with `scripts/deploy/DeployAppDeposit.s.sol`; the address goes
into the Network row of the Fluent Connect catalogue. Index `Deposited` from the deployment block.

| Chain | AppDeposit | Deployment block | Source |
|-------|------------|------------------|--------|
| **Fluent testnet** (20994) | [`0xce0AE7B8F82d6EaCE709e04F21736B1D664CD011`](https://testnet.fluentscan.xyz/address/0xce0AE7B8F82d6EaCE709e04F21736B1D664CD011) | 37674974 | `deployments/testnet/l2.app-deposit.json` |
| **Fluent mainnet** (25363) | not deployed yet | — | — |

---

## Fluent Connect – SingletonPaymasterV7

The ERC-4337 paymaster Fluent Connect sponsors user operations with. It is Pimlico's
`SingletonPaymasterV7`, used as published from the `lib/singleton-paymaster` submodule pinned at
`1e2305d1102242379b582142f62bd17add12b8c2`, with no copy in `contracts/`. Only its **verifying
mode** is used; ERC-20 mode is neither used nor configured.

Deployed with `scripts/deploy/DeploySingletonPaymaster.s.sol`, which in one broadcast creates the
contract, deposits `DEPOSIT_WEI` at the EntryPoint (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`)
and adds a stake of `STAKE_WEI` with `UNSTAKE_DELAY_SEC`. That run is done by hand from the
`deployer` keystore and is not part of this change. The address then goes into the Network row of
the Fluent Connect catalogue.

Roles are OpenZeppelin `AccessControl` roles, not `Ownable`:

- **owner** holds `DEFAULT_ADMIN_ROLE` — grants and revokes roles, withdraws the deposit and the
  stake;
- **manager** holds `MANAGER_ROLE`;
- either role may call `addSigner`, `removeSigner`, `addStake`, `unlockStake` and
  `updateBundlerAllowlist`.

The signer set is therefore **rotatable without a redeploy**: a wrong or leaked
`PAYMASTER_SIGNER` is replaced with `removeSigner` plus `addSigner`, and the address, the deposit
and the stake stay as they are. The rotation commands are in the pull request that deployed it.

| Chain | SingletonPaymasterV7 | Owner | Manager | Signer | Deployment block | Runtime code hash | Compiler | Explorer | Manifest |
|-------|----------------------|-------|---------|--------|------------------|-------------------|----------|----------|----------|
| **Fluent testnet** (20994) | `0xC1f36BF0B66f8ac4Ac8a7477378fe9C718c57c56` | `0xcBbF3a2A1D0Eb93B0817EBD6D028EaE1282F0214` (`deployer`) | `0xcBbF3a2A1D0Eb93B0817EBD6D028EaE1282F0214` (`deployer`) | `0x262FEc034C1258c8C4d96C9D43794e05D8d62c13` | 40092000 | `0x20d941487e2a4337ee575ca973db269161cad885a8b735618f5f510e6ea75a95` | solc 0.8.30, `evm_version` prague, optimizer 80 runs, `via_ir` | [fluentscan](https://testnet.fluentscan.xyz/address/0xC1f36BF0B66f8ac4Ac8a7477378fe9C718c57c56) | `deployments/testnet/l2.singleton-paymaster.json` |
| **Fluent mainnet** (25363) | not deployed yet | — | — | — | — | — | — | — | — |

The testnet row comes from the hand-run deploy of 2026-10-15 (CREATE tx
`0xc5f957e6dfa1595372ecf886c98c1d5fbd154b45d7134cc6efb1bc3b2d41ff02`): deposit 0.05 ETH, stake
0.1 ETH, unstake delay 86400 s. It was deployed with a temporary mock signer
(`0x83e40d2fE6BB07D0ea952e8Da2d703D6ec16b226`); the service's dev `PAYMASTER_SIGNER_KEY`
(`0x262FEc034C1258c8C4d96C9D43794e05D8d62c13`) was then added with `addSigner` and the mock removed
with `removeSigner`, with no redeploy. The Signer column and the manifest's `signers` hold the
current set: `cast call <paymaster> "signers(address)(bool)" <address>`.

- **Deployment block:** the `blockNumber` of the paymaster's CREATE receipt in
  `broadcast/DeploySingletonPaymaster.s.sol/20994/run-latest.json`. The script serializes none,
  because a simulated `block.number` is not the mined one.
- **Runtime code hash:** `cast keccak $(cast code <paymaster> --rpc-url <L2_RPC>)`, equal to the
  address's `extcodehash`. It covers the contract's immutables, so it is specific to this
  deployment's constructor arguments, and `fluent-connect-service` (FLU-1589) compares the Network
  row's paymaster against it on save. The compiler column is the build that produced it: a change
  to `solc_version`, `evm_version`, the optimizer runs or `via_ir` in `foundry.toml` changes the
  hash, so both columns are read together.
- **Signer:** the address of the service's `PAYMASTER_SIGNER_KEY` in the dev SOPS pool, or the
  probe key currently rotated in. The key itself never enters this repository.

Mainnet waits for the KMS or HSM signer and the ownership decision.

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

## Rollup deployment status

`DeployRollup.s.sol` exists, but no canonical rollup deployment is tracked in the public deployment JSON files above yet. Keep rollup addresses and verifier metadata with the deployment artifacts before sharing a package with auditors.

---

## Verification

**Compiler:** Solidity 0.8.30, optimization enabled, 200 runs.

With `ETHERSCAN_API_KEY` in `.env`:

```bash
bash ./scripts/deploy/bash/verify-sepolia-fluent-testnet.sh
```

Runs L1 (Etherscan) and L2 (Blockscout) verification in a single execution. Sepolia contracts are verified via Etherscan; Fluent testnet contracts via Blockscout at https://testnet.fluentscan.xyz/.
