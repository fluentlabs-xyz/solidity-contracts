# Airdrop

Push-distributes one ERC20 token plus a fixed amount of native ETH to an
immutable recipient list in a single transaction.

## How it works

The contract stores the recipient list as a packed `Entry[]` (20-byte
address + 12-byte `uint96` per slot) and a bitmap of distributed indices.
`distribute()` iterates over every still-unset index and dispatches each
send through `this._send(…)` — an external self-call wrapped in `try/catch`.

The self-call is the point of the design. If a recipient rejects ETH (a
contract without `receive()`, a blocklisted recipient, out-of-gas on their
fallback, etc.), the revert bubbles up inside `_send` and rolls back the
whole call frame — **including the token transfer**. The outer loop catches
the failure, emits `AirdropFailed(index, recipient)`, leaves the bit unset,
and moves on to the next entry. One bad recipient cannot brick the batch.

Before the loop, `distribute()` sums up the undistributed entries and
reverts early if the contract doesn't hold enough tokens or ETH — no
partial spend, no surprises.

`distribute()` is idempotent. Calling it again only re-processes entries
with their bit still clear, so after you fix an off-chain problem with a
failed recipient (or the recipient fixes themselves), re-running the
function retries just the failures. Successful entries stay marked.

Recipients are set in the constructor and never change. If the list is
wrong, redeploy — no mutable-list API on purpose.

## Files

- `contracts/airdrop/Airdrop.sol` — the contract.
- `scripts/airdrop/DeployAirdrop.s.sol` — one-shot deploy + fund +
  distribute.
- `scripts/config/airdrop/recipients.json` — recipient list, shape:
  `{"entries": [{"recipient": "0x…", "tokenAmount": "<wei>"}, …]}`.
  `tokenAmount` is a string so big numbers don't lose JSON precision.

## Running

1. Edit the four constants at the top of
   `scripts/airdrop/DeployAirdrop.s.sol`:
   - `TOKEN` — address of the ERC20 to distribute.
   - `ETH_PER_RECIPIENT` — flat wei amount per recipient.
   - `RECIPIENTS_PATH` — path to the JSON.
   - `SKIP_DISTRIBUTE` — `true` to deploy + fund only, then call
     `distribute()` manually when ready.

2. Make sure the broadcast account holds:
   - `sum(tokenAmount)` of the TOKEN.
   - `recipients × ETH_PER_RECIPIENT + gas` of native ETH.

3. Run:

   ```bash
   gblend script scripts/airdrop/DeployAirdrop.s.sol \
     --rpc-url https://rpc.testnet.fluent.xyz \
     --account <your-account> \
     --broadcast
   ```

The script runs four transactions in sequence inside a single broadcast
block: deploy Airdrop, fund it with tokens, fund it with ETH, call
`distribute()`. Because all four go from the same account, the deployer is
the owner and distribute passes the `onlyOwner` check.

## If something fails

- **Mid-run failure** (e.g. token transfer tx reverts): the Airdrop is
  already deployed but not funded. Redeploy — address is cheap.
- **Individual `AirdropFailed` events**: fix the recipient off-chain (or
  replace them if you're testing), then call `distribute()` again. It will
  retry only the entries whose bit is still clear.
- **Block gas limit concerns** on very large lists: call
  `distributeRange(start, end)` in chunks instead of `distribute()`.
  Splits the same loop across multiple transactions.

## Rescue

After a successful distribution (or to recover after a partial failure),
sweep any leftovers back to a safe address:

```solidity
airdrop.rescue(TOKEN,         safe);  // leftover tokens
airdrop.rescue(address(0),    safe);  // leftover ETH
```

Only the owner can call. The destination must be non-zero.

## Security

- `owner = msg.sender` at deploy time. Only owner can run `distribute`,
  `distributeRange`, `rescue`.
- `_send` is `external` but guarded — reverts unless called by the
  contract itself.
- Failures emit `AirdropFailed(index, recipient)` but carry no reason
  payload. Watch the event log for monitoring.
