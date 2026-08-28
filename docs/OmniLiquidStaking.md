# Omni Liquid Staking

## Overview

Omni liquid staking uses the native `FluentBridge` with a dedicated `StakingGateway`.

The design is **L1 source / L2 canonical**:

- **L1** holds the source underlying token and the mirror share token (`StakedTokenMirror`).
- **L2** holds the canonical ERC-4626 vault (`stBlend`) where deposits, withdrawals, and yield accounting happen.
- **Yield is accounted only on L2** through the `stBlend` share price. L1 mirror shares are only a bridged representation of L2 vault shares.

## Contracts

| Contract | Chain | Purpose |
|----------|-------|---------|
| `stBlend` | L2 | Canonical ERC-4626 vault. Streams external rewards into share price. |
| `StakingGateway` | L1 | Escrows underlying, releases withdrawals, mints/burns mirror shares. |
| `StakingGateway` | L2 | Deposits L2 inventory into `stBlend`, redeems shares, locks/releases canonical shares. |
| `StakedTokenMirror` | L1 | Mirror representation of canonical L2 `stBlend` shares. |
| `FluentBridge` | L1/L2 | Native message transport between gateways. |

## L1 to L2 Deposit and Stake

User starts on L1 with the underlying token. The L1 gateway escrows the asset and sends a bridge message. The L2 gateway uses its local inventory to deposit into the canonical vault and mint `stBlend` shares to the L2 receiver.

```mermaid
sequenceDiagram
    participant User
    participant L1GW as L1 StakingGateway
    participant L1Bridge as L1 FluentBridge
    participant Relayer
    participant L2Bridge as L2 FluentBridge
    participant L2GW as L2 StakingGateway
    participant Vault as stBlend

    User->>L1GW: depositAndStake(assets, l2Receiver)
    L1GW->>L1GW: escrow underlying
    L1GW->>L1Bridge: sendMessage(L2GW, receiveDepositAndStake)
    L1Bridge-->>Relayer: SentMessage
    Relayer->>L2Bridge: receiveMessage(...)
    L2Bridge->>L2GW: receiveDepositAndStake(from, l2Receiver, assets)
    L2GW->>Vault: deposit(assets, l2Receiver)
    Vault-->>User: L2 stBlend shares
```

## L2 to L1 Redeem and Withdraw

User starts on L2 with canonical `stBlend` shares. The L2 gateway pulls and redeems the shares into underlying inventory, then sends a bridge message. The L1 gateway releases escrowed underlying to the L1 receiver.

```mermaid
sequenceDiagram
    participant User
    participant Vault as stBlend
    participant L2GW as L2 StakingGateway
    participant L2Bridge as L2 FluentBridge
    participant Relayer
    participant L1Bridge as L1 FluentBridge
    participant L1GW as L1 StakingGateway

    User->>L2GW: redeemToL1(shares, l1Receiver)
    L2GW->>Vault: transferFrom(user, gateway, shares)
    L2GW->>Vault: redeem(shares)
    L2GW->>L2Bridge: sendMessage(L1GW, receiveUnderlyingWithdrawal)
    L2Bridge-->>Relayer: SentMessage
    Relayer->>L1Bridge: receiveMessage(...)
    L1Bridge->>L1GW: receiveUnderlyingWithdrawal(from, l1Receiver, assets)
    L1GW-->>User: release L1 underlying
```

## Native Share Bridging

The gateway also supports moving the staking position itself across chains.

When moving shares from L2 to L1, canonical `stBlend` shares are locked in the L2 gateway and mirror shares are minted on L1.

```mermaid
sequenceDiagram
    participant User
    participant L2GW as L2 StakingGateway
    participant Bridge as FluentBridge
    participant L1GW as L1 StakingGateway
    participant Mirror as StakedTokenMirror

    User->>L2GW: sendSharesToL1(shares, l1Receiver)
    L2GW->>L2GW: lock canonical stBlend shares
    L2GW->>Bridge: sendMessage(receiveSharesToL1)
    Bridge->>L1GW: deliver message
    L1GW->>Mirror: mint(l1Receiver, shares)
```

When moving shares back from L1 to L2, mirror shares are burned and the locked canonical shares are released on L2.

```mermaid
sequenceDiagram
    participant User
    participant Mirror as StakedTokenMirror
    participant L1GW as L1 StakingGateway
    participant Bridge as FluentBridge
    participant L2GW as L2 StakingGateway

    User->>L1GW: sendSharesToL2(shares, l2Receiver)
    L1GW->>Mirror: burn(user, shares)
    L1GW->>Bridge: sendMessage(receiveSharesToL2)
    Bridge->>L2GW: deliver message
    L2GW-->>User: release canonical stBlend shares
```

## Key Notes

- This share movement is implemented directly over the native bridge, not through an external cross-chain token standard.
- `stBlend` is the only source of truth for yield and share price.
- The L1 mirror token does not accrue yield by itself; its economic value follows the canonical L2 share it represents.
- Cross-chain deposit/withdrawal depends on L2 gateway inventory for L1-to-L2 staking and L1 gateway escrow for L2-to-L1 withdrawals.
- Gateway configuration (`otherSideGateway`, bridge address, vault, mirror token, limits) is a high-trust operational surface and should be multisig-controlled.
