# Deployed Bridge Addresses

Deployment manifests are stored per environment as JSON:

| Environment | L1 manifest | L2 manifest |
|-------------|-------------|-------------|
| **testnet** (Sepolia ↔ Fluent testnet) | [`deployments/testnet/l1.json`](../deployments/testnet/l1.json) | [`deployments/testnet/l2.json`](../deployments/testnet/l2.json) |
| **mainnet** (Ethereum ↔ Fluent mainnet) | [`deployments/mainnet/l1.json`](../deployments/mainnet/l1.json) | [`deployments/mainnet/l2.json`](../deployments/mainnet/l2.json) |

The tables below mirror those manifests for readability. **On conflict, the
JSON files are the source of truth** (scripts read them via `ENV=<env> …`).

---

## Testnet — Sepolia (L1)

Chain ID: **11155111** · RPC: <https://ethereum-sepolia-rpc.publicnode.com> ·
Explorer: <https://sepolia.etherscan.io>

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| `L1FluentBridge` | `0x9CAcf613fC29015893728563f423fD26dCdB8Ddc` | `0x273A4005573809e779889516fD95A078B5f23e57` |
| `ERC20Gateway` | `0xfd4c62647a34ff6d6802092f5fbe176099223b61` | `0x648a97b29946b62e9feea63c5134ef6beb82313b` |
| `NativeGateway` | `0x8976ca4e0c8467097da675399fb7db454a1b56dd` | `0x482df12fbc3ba7a7f02aa928e620fd12af5fd30e` |
| `ERC20TokenFactory` | `0xf6d49e874cb64b8ee56d6f99bd340134b30ab225` | `0x1c8779d41e89908e888e08d0e5871c9824032c71` |
| `UpgradeableBeacon` (pegged ERC20s) | — | `0xdd283a04cc711ab9c08d79e665835821beef710b` |
| `ERC20PeggedToken` impl | — | `0x57125e0de1dd238154558643b1e78fcbf5ab1a92` |
| `Rollup` | `0x1cF53Fd9CD0b713be29F2b41cA17A943f138727f` | `0xee635CAF8a270F7073bE56AA5d68A2F3b7DdD733` |
| `NitroVerifier` | — | `0xbA3d3B60b6f462AA3fb2D63F8B610Fa8825c3019` |

## Testnet — Fluent (L2)

Chain ID: **20994** · RPC: <https://rpc.testnet.fluent.xyz/> ·
Explorer: <https://testnet.fluentscan.xyz/>

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| `L2FluentBridge` | `0x9CAcf613fC29015893728563f423fD26dCdB8Ddc` | `0x646490733DEfce66Bb5139f67B4b92a66709CFC9` |
| `ERC20Gateway` | `0xFD4C62647A34FF6d6802092F5fbe176099223B61` | `0x8c435855E8090eB526f33f94d0474d59fD7E32A2` |
| `NativeGateway` | `0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd` | `0x482Df12fbc3BA7A7f02Aa928e620fd12aF5Fd30e` |
| `UniversalTokenFactory` | `0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225` | `0xE2A964a92d1857B8058474BD51d195C934d8BFc5` |
| `L1BlockOracle` | `0x19e1b30C792E417BC1827f5E2F288052b5c05e8F` | — |
| `L1GasOracle` | `0x207FBb4AC5227Ab598B8072BdC1E150dF687AC5B` | — |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

---

## Mainnet — Ethereum (L1)

Chain ID: **1** · Explorer: <https://etherscan.io>

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| `L1FluentBridge` | `0x9CAcf613fC29015893728563f423fD26dCdB8Ddc` | `0xA0374Fa5324f4A255693Eb6B35236a21C24392f8` |
| `ERC20Gateway` | `0xfd4c62647a34ff6d6802092f5fbe176099223b61` | `0x5398c8De96Ef049B5d8D0ce01e4C9D58c47B98C9` |
| `NativeGateway` | `0x8976ca4e0c8467097da675399fb7db454a1b56dd` | `0xbA3d3B60b6f462AA3fb2D63F8B610Fa8825c3019` |
| `ERC20TokenFactory` | `0xf6d49e874cb64b8ee56d6f99bd340134b30ab225` | `0xeDB323c7406d534B301355913717EC0B2F7b350d` |
| `UpgradeableBeacon` (pegged ERC20s) | — | `0xdd283a04cc711ab9c08d79e665835821beef710b` |
| `ERC20PeggedToken` impl | — | `0x056fD0A3eD85c6ae1Ec1c398B33581951Ed4b090` |
| `Rollup` | `0x1cF53Fd9CD0b713be29F2b41cA17A943f138727f` | `0x46a485181ab7E0D68508b8dE306e88a3B6718193` |
| `NitroVerifier` | — | `0xFdB04b67ecD8352bA3885F66fFfddf1f5f25292F` |
| Timelock (listed in manifest) | `0x7846C001835d889A29ba659f67A5B7ac98E73bF4` | — |

## Mainnet — Fluent (L2)

Chain ID: **25363**

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| `L2FluentBridge` | `0x9CAcf613fC29015893728563f423fD26dCdB8Ddc` | `0x3236Bd10446ce1DC68118E563baDa25b43781348` |
| `ERC20Gateway` | `0xFD4C62647A34FF6d6802092F5fbe176099223B61` | `0x7EafBd621Df027EbefFb7a971120b13A88710494` |
| `NativeGateway` | `0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd` | `0x5E0D546dAdE979c9eEE458Cc8b6212E53921889f` |
| `UniversalTokenFactory` | `0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225` | `0xd19E9EaC7FCe28f6528C28625007C3B065524661` |
| `L1BlockOracle` | `0x19e1b30C792E417BC1827f5E2F288052b5c05e8F` | — |
| `L1GasOracle` | `0x207FBb4AC5227Ab598B8072BdC1E150dF687AC5B` | — |
| Pegged token (precompile) | `0x0000000000000000000000000000000000520008` | — |

---

## Auxiliary contracts

Addresses for `FastWithdrawalList` and `Blacklist` are populated by their
dedicated migrations (see
[`scripts/migrations/mainnet/MigrateL1_Fastlist.s.sol`](../scripts/migrations/mainnet/MigrateL1_Fastlist.s.sol)
and
[`scripts/migrations/mainnet/MigrateL1_Blacklist.s.sol`](../scripts/migrations/mainnet/MigrateL1_Blacklist.s.sol)).
After broadcast, add the resulting proxy + implementation addresses to the
respective manifest JSON and reflect them here.

---

## Pegged-token address derivation

The L2 pegged token address is computed with CREATE2 from `(gateway,
originToken)` and the L2 factory's init code. The L1 gateway's
`otherSideChainId` must equal the L2's actual `block.chainid`, or the relayer
hits `WrongPeggedToken` on L2. The deploy scripts read the L2 chain id at
deploy time so this is correct by construction; if a deployment pre-dates that
fix, the L1 gateway owner can repair it with

```solidity
ERC20Gateway(l1Gateway).setOtherSide(
    /* isOtherSideUniversal */ true,
    /* otherSideGateway      */ l2Gateway,
    /* otherSideChainId      */ <real chainid from `cast chain-id`>,
    /* otherSideTokenImpl    */ l2PeggedImpl,
    /* otherSideFactory      */ l2Factory,
    /* otherSideBeacon       */ address(0)
);
```

See [`Architecture.md`](./Architecture.md) for the full address-derivation
description.

---

## Deployment blocks (for indexers)

Use these as the `fromBlock` when indexing `SentMessage` (and other bridge
events) so the relayer starts from bridge-proxy creation. The precise block
numbers live in the broadcast receipts — the authoritative files are:

- **L1:** `broadcast/DeployFluentBridge.s.sol/<chainId>/run-latest.json`
- **L2:** `broadcast/DeployL2.s.sol/<chainId>/run-latest.json`

Grep for the tx that created the proxy contract (`contractName` =
`ERC1967Proxy` targeting `FluentBridge`).

---

## Verification

Compiler: **Solidity 0.8.30**, optimizer on, `80` runs, `via_ir` enabled (see
[`foundry.toml`](../foundry.toml)). With `ETHERSCAN_API_KEY` set in `.env`:

```bash
bash ./scripts/deploy/bash/verify-sepolia-fluent-testnet.sh
```

Runs L1 (Etherscan) and L2 (Blockscout / Fluentscan) verification in a single
pass.
