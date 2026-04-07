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
  - Can change `otherBridge`, `rollup` (L1), `l1BlockOracle` (L2), and `receiveMessageDeadline` (L1).
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

### No withdrawal rate limiting

Once a batch is finalized, all L2→L1 withdrawals within that batch can be claimed immediately via `receiveMessageWithProof` with no per-period or per-batch cap. The bridge does not implement withdrawal rate limiting because pre-finalization defenses provide a sufficient detection and response window:

- **`finalizationDelay`** (configured to ~48 hours worth of L1 blocks) must elapse before `finalizeBatches` can finalize a batch. This is the primary protection — operators have 48 hours to detect fraud, pause the bridge, or force-revert the batch.
- **`finalizeWithProofs`** can bypass the delay, but only if **every block** in the batch has been individually proven through `resolveChallenge`, which requires both a Nitro enclave signature and an SP1 ZK proof per block. This path is cryptographically secure — a batch that passes full dual verification for every block is guaranteed correct.
- **`CHALLENGER_ROLE`** can dispute any block within the `challengeWindow`, forcing the prover to submit dual proofs or the rollup enters the corrupted state.
- **`PAUSER_ROLE`** can freeze the bridge if a malicious batch is detected before or after finalization.
- **`EMERGENCY_ROLE`** can force-revert non-finalized batches via `forceRevertBatch`.

In summary: a malicious batch can only reach finalization through the delay path (giving operators ~48 hours to respond) or through the proof path (requiring full cryptographic verification of every block). Both paths provide strong guarantees.

If withdrawal rate limiting is needed in the future (e.g., as TVL grows), it can be added as a sliding-window cap on `receiveMessageWithProof` and `rollbackMessageWithProof` without changing the rollup or proof architecture.

### Relayer path is full-trust

The relayer (`RELAYER_ROLE`) can deliver messages via `receiveMessage` with no proof requirement. A compromised relayer can construct messages with arbitrary parameters. Mitigations:

- The relayer path is intended as a transitional mechanism. Proof-based delivery (`receiveMessageWithProof`) should be preferred for production L2→L1 traffic.
- `RELAYER_ROLE` should be assigned to infrastructure controlled by the bridge operator, not to third parties.
- Consider removing or disabling the relayer path once proof-based delivery covers all message types.

## Operator Notes

- Use proof-based withdrawal delivery where possible; the relayer path is operationally trusted.
- Keep `RELAYER_ROLE`, gateway ownership, and verifier admin keys on separate operational controls.
- Treat any admin mapping update in `ERC20Gateway` as an incident-response action, not normal flow.
- Record the exact config used for each deployment and upgrade, including chain IDs, remote addresses, and storage-layout evidence.
- Monitor oracle submitter keys. If `L1BlockOracle` or `L1GasOracle` submitters are compromised, use the owner override (`setL1BlockNumber` / `setL1GasPrice`) to correct values and rotate the submitter via `setSubmitter`.
