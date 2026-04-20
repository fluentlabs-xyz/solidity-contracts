# Security Model

> Companion documents: [`Architecture.md`](./Architecture.md) for the
> end-to-end system design, [`Limitations.md`](./Limitations.md) for a full
> inventory of known limits and mitigations, and
> [`BridgeFailuresAndRollback.md`](./BridgeFailuresAndRollback.md) for the
> message-status state machine.

## Contract Topology

- `FluentBridge.sol`: cross-chain message transport, nonce tracking, native-value custody, rollback handling, and relayer/proof execution. Also maintains the **gateway whitelist** (`_gatewayWhitelist`) that gates both outbound sends and inbound receives.
- `ERC20Gateway.sol` and `NativeGateway.sol` (both inherit `GatewayBase.sol`): user-facing asset entrypoints built on top of `FluentBridge`. `ERC20Gateway` locks/escrows origin ERC-20s and mints/burns pegged tokens; `NativeGateway` handles native ETH bridging. Both enforce `onlyFluentBridge` on receive paths and, when enabled, consult `FastWithdrawalList` for rate limiting.
- `Rollup.sol` and `RollupStorageLayout.sol`: batch lifecycle, challenges, proofs, corruption detection, and bridge deposit consumption.
- `GenericTokenFactory.sol`, `ERC20TokenFactory.sol`, `UniversalTokenFactory.sol`: deterministic pegged-token deployment and beacon upgrades.
- `ERC20PeggedToken.sol` and `UniversalToken.sol`: bridged asset representations controlled by the gateway/factory configuration.
- `NitroVerifier.sol`, `SP1VerifierGroth16.sol`, `L1BlockOracle.sol`: verifier and oracle trust anchors.
- `FastWithdrawalList.sol`: rate-limit registry consulted by gateways during optimistic (Preconfirmed-batch) withdrawals. Per-token hourly/daily caps, alias routing (e.g. `WETH → NATIVE_LIMIT_KEY`) so multiple physical tokens can share one bucket.
- `Blacklist.sol`: optional deposit-side denylist consulted by gateways before `sendTokens` / `sendNativeTokens` forwards to the bridge.

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
  - Can change bridge/factory/remote-side routing, update pegged-token mappings, rescue native ETH.
  - Can set/clear the `FastWithdrawalList` address (`setFastWithdrawalList`) and flip the rate-limit master switch (`setWhitelistEnabled`).
  - Can set/clear the `Blacklist` registry (`setBlacklistRegistry`).
- `GenericTokenFactory.owner()`
  - Can rotate the gateway address (called "PaymentGateway" in factory code for historical reasons).
  - On ERC20 factory deployments, can upgrade the beacon for all deployed pegged tokens.
- `ERC20PeggedToken.owner()`
  - Can mint, burn, pause, and unpause pegged token supply.
- `UniversalToken` minter/pauser
  - Can mint, burn, pause, and unpause the L2 universal token representation.

### Registries

- `FluentBridge.DEFAULT_ADMIN_ROLE` additionally manages the **gateway whitelist**:
  - `registerGateway(address)` / `unregisterGateway(address)` admit/deny a gateway for both directions.
  - Note: deregistering a gateway can block the nonce queue for L2→L1 withdrawals — see [`Limitations.md § Gateway deregistration DoS`](./Limitations.md#gateway-deregistration-dos-on-l2-l1).
- `FastWithdrawalList.DEFAULT_ADMIN_ROLE`
  - Authorizes UUPS upgrades.
  - `registerToken` / `deregisterToken` / `setLimit` / `setAlias` — configure the bucket layout.
  - Grants/revokes `CONSUMER_ROLE` via standard OZ `grantRole` / `revokeRole` (each gateway is granted this role during migration).
- `FastWithdrawalList.CONSUMER_ROLE`
  - Held by each gateway that calls `consumeUsage`. A compromised consumer can only over-count against a bucket it already has access to; it cannot skip limits.
- `Blacklist.owner()`
  - Sets and clears per-address flags used by gateways' `_requireAccountNotBlacklisted` check on deposit.

## Trust Assumptions

- The configured `otherBridge` and remote gateway are hard trust anchors. Misconfiguration can redirect assets or messages.
- The relayer path is trusted execution, not permissionless proof execution.
- The `L1BlockOracle` must be monotonic and timely. If stale, L2 timeout behavior becomes unreliable. If the submitter is compromised and posts a far-future block number, all pending L1→L2 messages will be marked as deadline-exceeded, triggering mass rollback events. The oracle owner can override via `setL1BlockNumber` (bypasses monotonicity for emergency corrections).
- The `L1GasOracle` must return values within a sane range. If the submitter is compromised and posts an extreme gas price, the fee calculation in `getSentMessageFee` can overflow (Solidity 0.8.x checked arithmetic), causing all `sendMessage` calls on L2 to revert and blocking L2→L1 bridge traffic until the oracle owner corrects it via `setL1GasPrice`.
- Rollup security depends on the active verifier set, Nitro attestation lifecycle, and SP1 program key.
- Factory and gateway ownership are effectively asset-governance powers and should be multisig-controlled.

## Core Invariants

- Every bridged message hash must be processed at most once for successful delivery.
- The bridge must hold sufficient pooled balance to cover native value in all pending messages (receive functions are not payable; value is paid from the bridge's own balance).
- Rollback refunds must come from bridge-held funds that were previously locked on the source chain.
- `ERC20Gateway.tokenMapping[peggedToken]` must only classify real pegged tokens, never arbitrary origin assets.
- Rollup finalization must remain sequential and only consume deposits proven in accepted batches.

## Known High-Trust Operations

- Updating remote bridge/gateway/factory configuration.
- Upgrading UUPS proxies or ERC20 beacon implementations.
- Updating oracle, verifier, or rollup timing parameters.
- Forcing rollup reverts or pausing core contracts.

## Acknowledged Design Trade-Offs

### Withdrawal rate limiting (Preconfirmed-batch window only)

Withdrawals from a **Finalized** batch are unrestricted — the challenge window has passed and the batch is cryptographically settled. Withdrawals from a **Preconfirmed** batch are gated by `FastWithdrawalList`, because the Preconfirmed status is optimistic (Nitro attestation only) and a fraudulent batch can still be challenged or reverted within its window.

Gateway-level policy (see `GatewayBase._consumeLimit`):

```
whitelistEnabled == false                                  → no-op
whitelistEnabled == true && batch not Preconfirmed         → no-op
whitelistEnabled == true && batch Preconfirmed:
    token NOT in list    → revert FastWithdrawalNotAllowed
    token IN list        → FWL.consumeUsage(tokenKey, amount)
```

Layered defences against a fraudulent batch reaching the pool:

- **`finalizationDelay`** (~48 hours of L1 blocks) must elapse before `finalizeBatches` can finalize a batch. Operators have that window to detect fraud, pause the bridge, or force-revert the batch.
- **`finalizeWithProofs`** can bypass the delay only if **every block** in the batch has an SP1 ZK proof (`resolveBlockChallenge`). This is cryptographically secure.
- **`CHALLENGER_ROLE`** can dispute any block within the challenge window, forcing an SP1 proof or the rollup enters corrupted state.
- **`FastWithdrawalList`** caps per-token hourly/daily exposure during the Preconfirmed window. Aliasing (e.g. `WETH → NATIVE_LIMIT_KEY`) makes multiple physical tokens share a single bucket so an attacker cannot drain the cap twice across gateways.
- **`PAUSER_ROLE`** can freeze the bridge.
- **`EMERGENCY_ROLE`** can `revertBatches` on the rollup.

**Caveat.** `_whitelistEnabled` defaults to `false` on freshly initialized gateways — limits become a no-op until an operator explicitly flips the switch post-migration. See [`Limitations.md § Rate-limit policy`](./Limitations.md#rate-limit-policy-off-by-default).

### Relayer path is full-trust

The relayer (`RELAYER_ROLE`) can deliver messages via `receiveMessage` with no proof requirement. A compromised relayer can construct messages with arbitrary parameters. On L2 this is especially consequential because there is no cryptographic binding back to the L1 sent-message queue; see [`Limitations.md § L2 relayer trust`](./Limitations.md#l2-relayer-trust-is-unconditional).

Mitigations:

- The relayer path is intended as a transitional mechanism. Proof-based delivery (`receiveMessageWithProof`) should be preferred for production L2→L1 traffic.
- `RELAYER_ROLE` should be assigned to infrastructure controlled by the bridge operator, not to third parties.
- `emergencyRevokeRelayer` (under `PAUSER_ROLE`) allows fast revocation without waiting for the admin timelock.
- Consider removing or disabling the relayer path once proof-based delivery covers all message types.

## Operator Notes

- Use proof-based withdrawal delivery where possible; the relayer path is operationally trusted.
- Keep `RELAYER_ROLE`, gateway ownership, and verifier admin keys on separate operational controls.
- Treat any admin mapping update in `ERC20Gateway` as an incident-response action, not normal flow.
- Record the exact config used for each deployment and upgrade, including chain IDs, remote addresses, and storage-layout evidence.
- Monitor oracle submitter keys. If `L1BlockOracle` or `L1GasOracle` submitters are compromised, use the owner override (`setL1BlockNumber` / `setL1GasPrice`) to correct values and rotate the submitter via `setSubmitter`.
