# Known Limitations

This document lists known limitations of the Fluent bridge that operators,
auditors, and integrators should be aware of. Each item carries a short
description, the **current mitigation** shipped in the code, and a **planned
resolution** where one exists. Severity reflects blast radius if the stated
mitigation is not in place.

> See also: [`SecurityModel.md`](./SecurityModel.md),
> [`Architecture.md`](./Architecture.md),
> [`BridgeFailuresAndRollback.md`](./BridgeFailuresAndRollback.md).

---

## High

### L2 relayer trust is unconditional

**Where:** `L2FluentBridge.receiveMessage` (inherited from `FluentBridge`) —
L1→L2 delivery is `onlyRole(RELAYER_ROLE)` with **no** Merkle proof against the
L1 sent-queue.

**Implication:** A compromised `RELAYER_ROLE` can fabricate an L1→L2 deposit of
any amount to any address. Because L2 mints native ETH via consensus before
each receive, the attacker can then withdraw that fabricated balance through
`L2FluentBridge.sendMessage` → `L1FluentBridge.receiveMessageWithProof` along
the normal proof path, draining the real L1 pool.

**Mitigation today:**
- `RELAYER_ROLE` is held only by trusted infrastructure (not third parties).
- `PAUSER_ROLE` / `EMERGENCY_ROLE` can halt the bridge, and `EMERGENCY_ROLE`
  can `revertBatches` on the rollup to roll back fraudulent preconfirmed
  withdrawals.
- `FastWithdrawalList` caps the damage from a single fraudulent preconfirmed
  batch (see also: [*Rate-limit policy*](#rate-limit-policy-off-by-default)).

**Planned resolution:** Cryptographically bind L1→L2 receives to the
`L1FluentBridge._sentMessageHashes` queue (e.g. a per-block deposit root
committed to L2 by consensus) so the relayer cannot construct a message that
didn't actually originate on L1.

---

### Gateway deregistration DoS on L2→L1

**Where:** `FluentBridge._receiveMessage` reverts with `GatewayNotWhitelisted`
when the target gateway has been unregistered — and
`L1FluentBridge.receiveMessageWithProof` already consumed the nonce via
`_takeNextReceivedNonce()` before the revert unwinds the transaction.

**Implication:** Because the revert also rolls back the nonce increment, the
strict equality `messageNonce == _takeNextReceivedNonce()` will stay stuck on
`N` for every subsequent call whose target is the deregistered gateway. If the
admin deregisters gateway `G` while messages targeting `G` are in-flight, **all
L2→L1 withdrawals** (not only the ones targeting `G`) halt until `G` is
re-registered.

**Mitigation today:** Only the multisig-controlled `DEFAULT_ADMIN_ROLE` can
call `unregisterGateway`, and the admin procedure is to pause first, drain
in-flight messages, then deregister.

**Planned resolution:** Make gateway-whitelist rejection a soft-fail on the
receive path — record `MessageStatus.Failed`, emit the standard
`ReceivedMessage(hash, false, …)` event, consume the nonce — so deregistration
cannot block the queue.

---

### `advanceSentMessageCursor` allows skipping non-expired deposits (admin-only)

**Where:** `L1FluentBridge.advanceSentMessageCursor` is gated by
`onlyRollupOrOwner`, i.e. the admin can call it directly.

**Implication:** Unlike `skipExpiredDeposits` (which requires each slot to be
past its frozen `_sentMessageProcessByBlock`), `advanceSentMessageCursor`
performs no expiry check. The admin can silently move the consume cursor
forward and abandon arbitrary user deposits. There is currently no refund path
because `rollbackMessageWithProof` is `NOT_IMPLEMENTED`.

**Mitigation today:** Admin is a multisig / timelock. Off-chain monitoring
should alert on any `advanceSentMessageCursor` call not originating from the
rollup.

**Planned resolution:** Remove the owner branch from the modifier (let the
rollup be the sole caller). Keep the expired-only variant behind
`PAUSER_ROLE`.

---

### `skipExpiredDeposits` is a user-fund-loss primitive

**Where:** `L1FluentBridge.skipExpiredDeposits`, combined with
`L1FluentBridge.rollbackMessageWithProof` being `NOT_IMPLEMENTED`.

**Implication:** When the rollup stalls long enough for deposits to expire,
`PAUSER_ROLE` can advance the cursor past those slots — but the corresponding
ETH (or ERC-20s escrowed in gateways) remain locked forever, with no on-chain
path for the user to reclaim them. The author's own comment flags each skip as
"a permanently lost user deposit".

**Mitigation today:** Operator practice is to exhaust all remediation paths
(unpause rollup, prove valid batches, revert fraudulent batches) before
skipping expired deposits. The current deployment uses a long
`depositProcessingWindow` (~7 days) to make this extremely unlikely during
normal operation.

**Planned resolution:** Ship `rollbackMessageWithProof` (with per-message
nonce + value accounting) and replace `skipExpiredDeposits` with a
user-initiated cancel/refund flow. Until then, do not hold material TVL with
this release in production.

---

## Medium

### Rate-limit policy off by default

**Where:** `GatewayBase._whitelistEnabled` defaults to `false` in freshly
initialized gateways; `_consumeLimit` short-circuits to a no-op until an admin
flips it on.

**Implication:** Before an operator calls `setWhitelistEnabled(true)`,
withdrawals against a Preconfirmed batch are unrestricted. A single fraudulent
Preconfirmed batch can drain the full pool without hitting any hourly/daily
cap.

**Mitigation today:** The `MigrateL1_Fastlist` script registers every
fast-withdrawable token and sets up the `WETH → NATIVE_LIMIT_KEY` alias, but
**deliberately does not** flip the master switch — that's a separate
operational step so limits can be verified post-migration before enforcement
goes live.

**Planned resolution:** After rate-limit config and burn-in, call
`setWhitelistEnabled(true)` on both L1 gateways. Make the script do this
automatically once the configuration set is considered stable.

---

### `_setRelayerRole` grants without revoking

**Where:** `FluentBridgeStorageLayout._setRelayerRole` calls `_grantRole`
without revoking any existing holder, so every call to `setRelayerRole(new)`
accumulates an additional relayer. Given the L2 relayer concern above, every
extra live key is another takeover vector.

**Mitigation today:** Operators use `removeRelayerRole(old)` and
`emergencyRevokeRelayer(old)` as follow-up calls. `emergencyRevokeRelayer` is
under `PAUSER_ROLE` specifically for fast rotation.

**Planned resolution:** Change `setRelayerRole` semantics to swap (revoke
previous, grant new), or deprecate in favour of the standard OZ
`grantRole` / `revokeRole` pair so admins never have the "granted but forgot
to revoke" anti-pattern.

---

### `receiveMessageWithProof` requires `RELAYER_ROLE` despite "permissionless" NatSpec

**Where:** `L1FluentBridge.receiveMessageWithProof` carries
`onlyRole(RELAYER_ROLE)`, but an inline comment claims "All fields are
deterministic — anyone can call this function permissionlessly".

**Implication:** The proofs are self-authenticating, but users holding a valid
proof still cannot finalize their own withdrawal if the relayer is offline or
censoring. This concentrates liveness on a single role.

**Mitigation today:** Relayer infrastructure is monitored; users can contact
operators to force-relay.

**Planned resolution:** Make the function truly permissionless by removing the
role gate (the proofs prevent anyone from crafting arbitrary withdrawals).
Until then, fix the comment to match the code.

---

### `setRollup` does not protect in-flight L2→L1 withdrawals

**Where:** `L1FluentBridge._setRollup` requires the L1→L2 sent queue to be
empty (`_sentMessageBack == _sentMessageFront`), but there is **no** analogous
guard for L2→L1 withdrawals that rely on already-accepted batches in the
outgoing rollup.

**Implication:** After migrating to a new rollup, any in-flight withdrawal
whose proof targets an old batch reverts with `InvalidBatchStatus` (the new
rollup has no `BatchRecord` for those indices). Funds destined for those users
are stuck until an admin-operated path replays the batches into the new
rollup.

**Mitigation today:** Rollup migration is a manual procedure; ops plays the
outstanding batches forward before repointing `FluentBridge`.

**Planned resolution:** Add a grace window that consults the old rollup until
its finalized batches age out, or bulk-import `BatchRecord`s at migration
time.

---

### `_setBlacklistRegistry` silently accepts `address(0)`

**Where:** `GatewayBase._setBlacklistRegistry` allows clearing the blacklist
address. `_requireAccountNotBlacklisted` short-circuits on `registry == 0`, so
writing zero disables OFAC-style enforcement globally without any additional
confirmation.

**Mitigation today:** Off-chain monitoring alerts on
`BlacklistRegistryUpdated(_, 0)`.

**Planned resolution:** Require a dedicated `disableBlacklist()` call (emits a
distinct event) and reject zero in the standard setter.

---

### Cross-chain compiler drift breaks pegged-token address prediction

**Where:** `ERC20Gateway._computeBeaconProxyAddress` hashes
`type(BeaconProxy).creationCode ++ abi.encode(beacon, "")`. The address the
**other** chain will produce with the same inputs depends on that chain's
compiler / optimizer settings.

**Implication:** If L1 and L2 are built with different Solidity versions or
optimizer options, the first `receivePeggedTokens` for each origin token
reverts with `WrongPeggedToken`.

**Mitigation today:** Both chains pin `solc = 0.8.30` and the same optimizer
profile in `foundry.toml`. CI blocks drift.

**Planned resolution:** Bake a fixed init-code constant into both gateways so
the address derivation is version-independent.

---

## Low / informational

### `UnsafeUpgrades` in migration scripts

All migrations currently use `openzeppelin-foundry-upgrades/UnsafeUpgrades` —
this skips the OZ storage-layout validator. Operators MUST run
`forge inspect … storageLayout` before and after and diff the output. See
[`UpgradeSafety.md`](./UpgradeSafety.md).

### `ReceiveFailedMessage` re-emits `RollbackMessage` on every expired retry

Each retry of an expired message emits a fresh `RollbackMessage` that is
included in the next L2 block's `withdrawalRoot`. This is cosmetic (L1
`rollbackMessageWithProof` will still only refund once) but noisy for
indexers.

### `consumeNextSentMessage` is dead code on L1

Replaced by `advanceSentMessageCursor(count)` in the rollup. Kept behind
`onlyRollup`; safe, but a candidate for removal in the next upgrade.

### `_stringToBytes32` silent truncation in universal-token deployments

Origin token names / symbols longer than 32 bytes are truncated before being
baked into the L2 universal-token init code. No address collision (the salt
uses the origin address), but the deployed token's metadata is shorter than
the source's.

### Treasury call in `_chargeSendFee` is gas-unbounded

`L2FluentBridge._chargeSendFee` forwards all remaining gas to the configured
treasury. A buggy or malicious treasury can gas-grief every outbound L2 send.
Treasury is admin-set; operators should use an EOA or a minimal receiver.

---

## Out-of-scope for the bridge contracts

These are not bridge bugs but are frequently confused with them:

- **Oracle freshness.** `L1BlockOracle` and `L1GasOracle` are separate
  contracts with their own submitter/owner trust model. See
  [`SecurityModel.md`](./SecurityModel.md) for the owner override path.
- **Verifier compromise.** `SP1Verifier` and `NitroVerifier` are external
  contracts. The rollup trusts the configured verifier set; a faulty verifier
  breaks the proof path but cannot bypass `PAUSER_ROLE` / `EMERGENCY_ROLE`.
- **L2 sequencer liveness.** If the sequencer stops producing batches,
  deposits expire and land in the
  [*`skipExpiredDeposits` is a user-fund-loss primitive*](#skipexpireddeposits-is-a-user-fund-loss-primitive)
  path. This is a liveness / operational concern; it has its own remediation
  track.
