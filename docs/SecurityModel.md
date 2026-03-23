# Security Model

## Contract Topology

- `FluentBridge.sol`: cross-chain message transport, nonce tracking, native-value custody, rollback handling, and relayer/proof execution.
- `ERC20Gateway.sol` and `NativeGateway.sol` (both inherit `GatewayBase.sol`): user-facing asset entrypoints built on top of `FluentBridge`. `ERC20Gateway` locks/escrows origin ERC-20s and mints/burns pegged tokens; `NativeGateway` handles native ETH bridging. Both enforce `onlyFluentBridge` on receive paths.
- `Rollup.sol` and `RollupStorageLayout.sol`: batch lifecycle, challenges, proofs, corruption detection, and bridge deposit consumption.
- `GenericTokenFactory.sol`, `ERC20TokenFactory.sol`, `UniversalTokenFactory.sol`: deterministic pegged-token deployment and beacon upgrades.
- `ERC20PeggedToken.sol` and `UniversalToken.sol`: bridged asset representations controlled by the gateway/factory configuration.
- `NitroVerifier.sol`, `SP1VerifierGroth16.sol`, `L1BlockOracle.sol`: verifier and oracle trust anchors.

## Privileged Roles

### `FluentBridge`

- `DEFAULT_ADMIN_ROLE`
  - Authorizes UUPS upgrades.
  - Can change `otherBridge`, `rollup`, `l1BlockOracle`, and `receiveMessageDeadline`.
- `PAUSER_ROLE`
  - Can pause and unpause message sends and receives.
- `RELAYER_ROLE`
  - Can execute trusted-delivery messages and retry failed messages.
  - Must be treated as a high-trust operational role because it chooses when messages are delivered.

### `Rollup`

- `DEFAULT_ADMIN_ROLE`
  - Authorizes UUPS upgrades.
  - Can rotate bridge/verifier addresses and all timing/economic parameters.
- `EMERGENCY_ROLE`
  - Can pause/unpause and call `forceRevertBatch`.
- `SEQUENCER_ROLE`
  - Can submit headers and blob hashes.
- `PRECONFIRMATION_ROLE`
  - Can preconfirm batches through Nitro verification.
- `CHALLENGER_ROLE`
  - Can open disputes and lock challenge deposits.
- `PROVER_ROLE`
  - Can resolve challenges and claim proof rewards.

### Gateways / Factories / Tokens

- `GatewayBase.owner()` (inherited by `ERC20Gateway` and `NativeGateway`)
  - Authorizes UUPS upgrades.
  - Can change bridge/factory/remote-side routing, update pegged-token mappings, and rescue native ETH.
- `GenericTokenFactory.owner()`
  - Can rotate the gateway address (called "PaymentGateway" in factory code for historical reasons).
  - On ERC20 factory deployments, can upgrade the beacon for all deployed pegged tokens.
- `ERC20PeggedToken.owner()`
  - Can mint, burn, pause, and unpause pegged token supply.
- `UniversalToken` minter/pauser
  - Can mint, burn, pause, and unpause the L2 universal token representation.

## Trust Assumptions

- The configured `otherBridge` and remote gateway are hard trust anchors. Misconfiguration can redirect assets or messages.
- The relayer path is trusted execution, not permissionless proof execution.
- The `L1BlockOracle` must be monotonic and timely. If stale, L2 timeout behavior becomes unreliable.
- Rollup security depends on the active verifier set, Nitro attestation lifecycle, and SP1 program key.
- Factory and gateway ownership are effectively asset-governance powers and should be multisig-controlled.

## Core Invariants

- Every bridged message hash must be processed at most once for successful delivery.
- Trusted relayer delivery must fund native execution with `msg.value == value`.
- Rollback refunds must come from bridge-held funds that were previously locked on the source chain.
- `ERC20Gateway.tokenMapping[peggedToken]` must only classify real pegged tokens, never arbitrary origin assets.
- Rollup finalization must remain sequential and only consume deposits proven in accepted batches.

## Known High-Trust Operations

- Updating remote bridge/gateway/factory configuration.
- Upgrading UUPS proxies or ERC20 beacon implementations.
- Updating oracle, verifier, or rollup timing parameters.
- Forcing rollup reverts or pausing core contracts.

## Operator Notes

- Use proof-based withdrawal delivery where possible; the relayer path is operationally trusted.
- Keep `RELAYER_ROLE`, gateway ownership, and verifier admin keys on separate operational controls.
- Treat any admin mapping update in `ERC20Gateway` as an incident-response action, not normal flow.
- Record the exact config used for each deployment and upgrade, including chain IDs, remote addresses, and storage-layout evidence.
