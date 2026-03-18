# Bridge Contracts

This repository contains the Fluent bridge, gateway, factory, token, verifier, oracle, and rollup contracts used to move messages and assets between L1 and L2.

## Overview

The main production surface is:

- `contracts/FluentBridge.sol`: cross-chain message transport, native-value custody, relayer delivery, proof-based withdrawals, and rollback handling.
- `contracts/gateways/PaymentGateway.sol`: native/ERC20 bridging built on top of `FluentBridge`.
- `contracts/factories/*.sol`: deterministic pegged-token deployment and beacon management.
- `contracts/tokens/*.sol`: bridged token implementations.
- `contracts/rollup/*.sol`: batch submission, preconfirmation, challenge resolution, finalization, and corruption handling.
- `contracts/verifier/*.sol` and `contracts/oracle/L1BlockOracle.sol`: verifier and oracle trust anchors.

## Security Docs

- `docs/SecurityModel.md`: trust boundaries, privileged roles, and protocol invariants.
- `docs/UpgradeSafety.md`: deployment and upgrade procedure expectations.
- `docs/Addresses.md`: currently tracked public deployment addresses.

## User Flows

### Deposit (L1 → L2)

```mermaid
sequenceDiagram
    participant User
    participant L1Token as L1 ERC20
    participant L1Gateway as L1 PaymentGateway
    participant L1Bridge as L1 FluentBridge
    participant Relayer as Bridge Authority
    participant L2Bridge as L2 FluentBridge
    participant L2Gateway as L2 PaymentGateway

    User->>L1Token: approve(L1Gateway, amount)
    User->>L1Gateway: sendTokens(L1Token, user/L2Recipient, amount)
    L1Gateway->>L1Token: transferFrom(User, L1Gateway, amount)
    L1Gateway->>L1Bridge: sendMessage(L2Gateway, message)
    L1Bridge-->>Relayer: SentMessage event
    Relayer->>L2Bridge: receiveMessage(from, to=L2Gateway, value, chainId, blockNumber, recvNonce, data)
    L2Bridge->>L2Gateway: receivePeggedTokens / receiveNativeTokens
    L2Gateway->>User: mint or transfer tokens on L2
```

### Withdrawal (L2 → L1)

```mermaid
sequenceDiagram
    participant User
    participant L2Pegged as L2 PeggedToken
    participant L2Gateway as L2 PaymentGateway
    participant L2Bridge as L2 FluentBridge
    participant Relayer as Bridge Authority
    participant L1Bridge as L1 FluentBridge
    participant L1Gateway as L1 PaymentGateway

    User->>L2Pegged: approve(L2Gateway, amount)
    User->>L2Gateway: sendTokens(L2Pegged, L1Recipient, amount)
    L2Gateway->>L2Pegged: burn(User, amount)
    L2Gateway->>L2Bridge: sendMessage(L1Gateway, message)
    L2Bridge-->>Relayer: SentMessage event
    Relayer->>L1Bridge: receiveMessage(from, to=L1Gateway, value, chainId, blockNumber, recvNonce, data)
    L1Bridge->>L1Gateway: receiveNativeTokens
    L1Gateway->>User: transfer underlying L1 tokens
```

> In rollup mode, L2 -> L1 withdrawals can alternatively be proven via `receiveMessageWithProof` using finalized rollup batches and Merkle proofs instead of the trusted relayer path.

## Prerequisites

Make sure you have the following installed:

- Node.js (`>=16.x.x`) and npm
- Foundry (`forge`, `cast`, `anvil`)
- Solidity compiler compatible with the above contracts

## Installation

Clone the repository and install dependencies:

```bash
git clone https://github.com/<your-repo>/bridge-contracts.git
cd bridge-contracts
forge install
```

## Testing

Run the active test suite with Foundry:

```bash
forge test
```

Useful commands:

```bash
forge build
forge fmt
anvil --port 8545
anvil --port 8546
```

## Test Layout

- `test/Rollup`: active rollup lifecycle and admin coverage.
- `test/Bridge`: active message-delivery, timeout, and relayer funding coverage.
- `test/Gateway`: active token/native bridge coverage.
- `test/Invariant`: active invariant coverage for bridge/gateway interactions.
- `test-old`: archived parity/e2e/invariant suites kept for reference while coverage is migrated into the active tree.

## Operational Notes

- `foundry.toml` enables `build_info`, `ast`, and `storageLayout` outputs for upgrade review.
- Some deployment and upgrade scripts still rely on unsafe upgrade helpers. They now require `ALLOW_UNSAFE_UPGRADES=true` so unsafe execution is always explicit.
- `scripts/deploy/SetupBridge.s.sol` uses FFI and external `cast send` calls, so deployment operators should treat it as a privileged operational script rather than pure Solidity logic.