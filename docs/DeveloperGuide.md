# Developer Guide

## Usage examples

### Format

Forge scripts use **`vm.startBroadcast()`** — you supply a private key or keystore via Foundry's usual flags (e.g. `--private-key`, `--ledger`, `--broadcast`).

### ERC-20 deposit (initiate L1 → L2)

**Script:** `scripts/user_flows/DepositTokens.s.sol`

**Environment variables:**

| Variable | Role |
|----------|------|
| `GATEWAY_ADDRESS` | `ERC20Gateway` proxy on the source chain |
| `TOKEN_ADDRESS` | Origin ERC-20 |
| `RECIPIENT` | Address on the destination chain |
| `AMOUNT` | Amount in token units (`> 0`) |

**Command (shape):**

```bash
forge script scripts/user_flows/DepositTokens.s.sol:DepositTokens \
  --rpc-url "$RPC_URL" \
  --broadcast
```

**On-chain effect:** `approve` then `ERC20Gateway.sendTokens` → bridge `sendMessage` → `SentMessage` on source; a relayer (or proof path) must complete delivery on the destination.

### Native bridge (shape)

**Script:** `scripts/user_flows/SendAndReceiveNative.s.sol` (and related `sendNative.s.sol`, `ReceiveNative.s.sol`)

Set addresses per the script header comments (bridge/gateway on L1/L2). These scripts mirror the operational flow used in tests; read each file's `@dev Environment` block for exact env var names.

### Low-level relayer debugging

**Script:** `scripts/user_flows/ReceiveTokens.s.sol`
Calls **`FluentBridge.receiveMessage`** with explicit `(from, to, value, chainId, blockNumber, nonce, message)` — for **operators** who already have the encoded fields from `SentMessage`. Requires the bridge to hold enough ETH if `VALUE_WEI > 0`.

### Cast — read configuration

```bash
cast call "$BRIDGE" "getOtherBridge()(address)" --rpc-url "$RPC"
cast call "$BRIDGE" "getSentMessageFee()(uint256)" --rpc-url "$RPC"
```

**Output:** ABI-decoded return values; use to verify wiring before sending real funds.

---

## Extending the system

- **New asset type:** Prefer a dedicated gateway that inherits **`GatewayBase`**, enforces **`onlyFluentBridge`** on receive paths, and encodes a fixed **remote selector** payload (same pattern as `NativeGateway` / `ERC20Gateway`).
- **New message path on the bridge:** Subclassing **`FluentBridge`** directly is rarely needed; L1/L2 differences live in **`L1FluentBridge`** / **`L2FluentBridge`**. Coordinate storage layout via **`FluentBridgeStorageLayout`** and run storage diffs before upgrades.
- **Tests:** Add suites under `test/Bridge`, `test/Gateway`, `test/Rollup`, etc., following existing **`Base.t.sol`** patterns.

---

## Naming: "PaymentGateway" in scripts and code

The original monolithic `PaymentGateway` contract was split into **`ERC20Gateway`** and **`NativeGateway`** (both inheriting `GatewayBase`). The legacy name persists in two places:

- **Factory code:** `GenericTokenFactory.setPaymentGateway()`, `onlyPaymentGateway` modifier, and `_paymentGateway` storage field still use the old name.
- **Deploy scripts:** `DeployPaymentGateway.s.sol` and `DeployLib._deployPaymentGateway()` deploy `ERC20Gateway` behind a UUPS proxy.

A rename of these code references is tracked as a separate task.

---

## Gotchas / edge cases

- **`receiveMessage` after deadline:** Can mark a message failed without executing the target; operators may use **`receiveFailedMessage`** after fixing downstream state.
- **Self-call / forbidden destinations:** `sendMessage` must not target this bridge or **`otherBridge`**.
- **Paused bridge:** Sends and receives respect **`Pausable`**; all user flows stop while paused.
- **Scripts with `ALLOW_UNSAFE_UPGRADES`:** Some deploy/upgrade paths require **`ALLOW_UNSAFE_UPGRADES=true`** so unsafe OpenZeppelin upgrade helpers are never accidental (see **`docs/UpgradeSafety.md`**).
- **`SetupBridge.s.sol`:** Uses **FFI** and external tooling patterns — treat as **operational** infrastructure, not on-chain logic to replicate in contracts.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|--------|----------------|------------|
| `forge build` / `forge test`: missing imports or `@openzeppelin` errors | Submodules not installed | Run `forge install` from repo root; confirm `lib/openzeppelin-contracts` exists. |
| `InsufficientFee()` on `sendMessage` | `msg.value` below **`getSentMessageFee()`** | Increase `msg.value`; on native flows remember fee is deducted before locked "amount". |
| `MessageReceivedOutOfOrder()` | Relayer delivered nonces out of sequence | Replay or deliver the expected **`receivedNonce`** next; inspect `SentMessage` ordering on source. |
| `MessageAlreadyReceived()` | Duplicate delivery or replay | Do not re-submit same hash; check off-chain idempotency. |
| Target call fails / `Failed` status | Calldata, gas, or destination contract reverts | Fix gateway/token state; use **`receiveFailedMessage`** only when bridge marked the message failed. |
| Deployment script reverts without clear ABI error | **`ALLOW_UNSAFE_UPGRADES`** not set where required | Set env var explicitly as documented in **`UpgradeSafety.md`** for those scripts only. |
| L2 receive / timeout oddities | **`L1BlockOracle`** stale or misconfigured | Verify oracle updater pipeline and admin-configured deadline. |
