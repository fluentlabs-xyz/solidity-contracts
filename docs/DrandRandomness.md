# Drand Randomness

`DrandOracle` is a public randomness service. It serves the [drand](https://drand.love) quicknet
beacon on chain: a threshold-signed value that a committee of independent operators produces every
3 seconds, that nobody — not the sequencer, not this team, not you — can predict before it exists,
and that anyone can check against `api.drand.sh` afterwards.

You do not need to know anything about drand or BLS signatures to use it. You need two calls.

---

## What the service guarantees

- **Unpredictable at commit time.** You bind yourself to a round whose beacon does not exist yet.
  The contract refuses to hand you a round that is already public (see
  [The residual](#the-residual-the-clock-is-the-sequencers) for the one assumption this rests on).
- **Immutable once published.** A round's value is written once and never rewritten. There is no
  upgrade proxy and no owner function that can touch a published value; publishing a round twice
  reverts `RoundAlreadyPublished`.
- **Verified on chain.** A value is stored only after the contract itself checks drand's threshold
  signature against a hardcoded public key, using the EIP-2537 pairing precompile. A forged or
  mismatched signature reverts `InvalidSignature` — it cannot be stored.
- **Byte-identical to drand's own output.** The stored value is `sha256` of drand's compressed
  signature, which is exactly the `randomness` field the public API serves for that round. Any
  dispute about an on-chain value is settled by a URL — see
  [Checking a value against api.drand.sh](#checking-a-value-against-apidrandsh).
- **Permissionless publication.** Nobody holds a publisher role. If the keeper that normally posts
  rounds goes quiet, anyone can post the same signature to the same effect. No party can withhold a
  round from you.
- **Never zero.** An unpublished or aged-out round reverts. It never reads back as `bytes32(0)`,
  which would be a deterministic, attacker-known "random" number.
- **Bounded state.** The contract retains the last 8192 rounds and nothing more, forever. See
  [Retention](#retention-6h49m36s).

---

## Integrating in two calls

### 1. Commit

```solidity
uint64 round = oracle.commit();
```

`oracle.commit()` returns the earliest round whose beacon is not public yet, and emits
`RoundCommitted(round, msg.sender)` — the event publishers watch to know which rounds to post.
**Store the returned round yourself.** The contract writes no commit record; the event and your own
storage are the record.

If you need a specific round rather than the earliest safe one — a draw at a fixed wall-clock time,
say — use `oracle.commitTo(round)` instead. It emits the same event and enforces the same floor,
reverting `RoundTooSoon(round, earliestAllowed)` for anything too close to now.

### 2. Read

Once the round has been published:

```solidity
bytes32 value = oracle.randomnessFor(round, "my-app-draw-1");
```

`oracle.randomnessFor(round, domain)` returns
`keccak256(abi.encode(roundRandomness, msg.sender, domain))` — the round's randomness folded
together with **your** contract address and a separator you choose. This is the call you want by
default:

- Two applications that commit to the same round get different numbers, so they cannot draw the
  same winner.
- Two draws inside your own contract get different numbers if you pass different domains.

The raw, undomain-separated value is available as `oracle.randomnessOf(round)`. Use it when you
want the exact bytes drand published — auditing, or cross-checking against the API. Do not use it
as your application's randomness unless you are doing your own domain separation.

To reproduce a `randomnessFor` result off chain (to show a user the same number before submitting a
transaction), call the pure `oracle.deriveRandomness(roundRandomness, consumer, domain)` with the
raw value from `oracle.randomnessOf(round)`.

---

## Knowing when to read: `publishTimeOf`

A round's beacon exists in the real world at a fixed Unix timestamp:

```solidity
uint256 t = oracle.publishTimeOf(round); // genesis + (round - 1) * 3
```

That is when drand emits the beacon, not when it lands on chain — someone still has to publish it,
which normally takes a few seconds more. So the polling shape is: wait until `publishTimeOf(round)`
has passed, then poll until the value is actually there.

```solidity
if (block.timestamp < oracle.publishTimeOf(round)) revert TooEarly();
if (!oracle.isPublished(round)) revert NotYetPublished(); // try again in a few seconds
bytes32 value = oracle.randomnessFor(round, DOMAIN);
```

`oracle.isPublished(round)` is the non-reverting probe. `oracle.randomnessOf` and
`oracle.randomnessFor` revert `RoundNotPublished(round)` inside the retention window, and
`RoundEvicted(round, oldestRetained)` once the round has aged out of it.

Off chain, the same thing from a keeper or a frontend:

```bash
ORACLE=0x...                             # DrandOracle address
ROUND=31799517
RPC=https://rpc.testnet.fluent.xyz

cast call $ORACLE "publishTimeOf(uint64)(uint256)" $ROUND --rpc-url $RPC
cast call $ORACLE "isPublished(uint64)(bool)"      $ROUND --rpc-url $RPC
cast call $ORACLE "randomnessOf(uint64)(bytes32)"  $ROUND --rpc-url $RPC
```

If nobody has published a round you are waiting on, you can publish it yourself — `publish` takes
no role. Fetch the round's signature from the API and submit it in the 128-byte EIP-2537
uncompressed G1 encoding (see [Past the window](#past-the-window-verifyround) for the decompression
note; it is the same encoding there).

---

## Worked example: a lottery

This is `test/mocks/DrandConsumerExample.sol` in full. The oracle's address is the only thing it
knows about drand.

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";

contract DrandConsumerExample {
    /// @dev Separates this lottery's view of a round from every other consumer's
    bytes32 internal constant DOMAIN = "lottery";

    IDrandOracle public immutable ORACLE;

    address[] public entrants;
    uint64 public round;
    address public winner;

    constructor(address oracle) {
        ORACLE = IDrandOracle(oracle);
    }

    /// @notice Joins the current draw
    function enter() external {
        entrants.push(msg.sender);
    }

    /// @notice Closes entry and binds the draw to a round drand has not reached yet
    /// @return The committed round
    function open() external returns (uint64) {
        round = ORACLE.commit();
        return round;
    }

    /// @notice Draws the winner from the committed round's randomness
    /// @return The winning entrant
    function draw() external returns (address) {
        bytes32 value = ORACLE.randomnessFor(round, DOMAIN);
        winner = entrants[uint256(value) % entrants.length];
        return winner;
    }
}
```

Note what `draw()` does *not* do: it does not wrap the read in `try`/`catch` and fall back to a
default. If the round is not published yet, `draw()` reverts and the caller tries again later. A
catch branch that substitutes a zero, a block hash or a timestamp is the classic way to turn a
randomness oracle back into a predictable one.

---

## Retention: 6h49m36s

The contract keeps published rounds in a fixed 8192-slot ring. At 3 seconds per round that is
**6 hours, 49 minutes and 36 seconds** of history, and it is the entire storage footprint of the
contract — no amount of publishing can grow it. Round `N` overwrites the slot of round
`N - 8192` when it is published, and eviction is strictly first-in, first-out by elapsed time:
nobody can push your round out early.

`oracle.oldestRetainedRound()` tells you the current floor, and `oracle.currentRound()` the round
matching the chain's clock. Anything below the floor reverts `RoundEvicted(round, oldestRetained)`
on read.

**If you commit, read within the window.** Six hours and forty-nine minutes is a long draw and a
short outage.

### Past the window: `verifyRound`

A round that has aged out is not lost — it is just no longer in the contract's storage. The beacon
itself is permanent and public, so you can bring it with you:

```solidity
bytes32 value = oracle.verifyRound(round, signature);
```

`oracle.verifyRound(round, signature)` runs the same pairing check and the same derivation as
`publish`, touches no storage, and returns the round's randomness. It is a `view`, so you can call
it inside your own transaction and pay only the verification gas — one pairing, no storage. It
reverts
`InvalidSignature(round)` if the signature is not drand's for that round, so a wrong or forged
signature cannot produce a value. To domain-separate the result the way `randomnessFor` would,
pass it through `oracle.deriveRandomness(value, address(this), domain)`.

> **Commit before you look.** `verifyRound` verifies the signature; it cannot verify *when you
> chose the round*. If you pick the round after seeing its beacon — or let a caller hand you both a
> round and a signature and act on the result — you have chosen your own outcome, and the
> randomness guarantee is gone. Only ever call `verifyRound` with a round your contract committed
> to earlier, from its own storage. This is why `commit` → `randomnessFor` is the default path and
> this one is the escape hatch.

The signature argument is a **128-byte uncompressed EIP-2537 G1 point**. The drand API serves the
48-byte compressed form, so decompress it off chain (any BLS12-381 library does this; the contract
deliberately does not, because on-chain decompression is a large amount of code to get wrong). The
oracle recompresses the point itself before hashing, so a non-canonical encoding cannot change the
result — it is rejected by the precompile.

---

## Checking a value against `api.drand.sh`

The value the contract stores for a round is `sha256` of drand's compressed signature for that
round, which is precisely the `randomness` field drand publishes. So an on-chain value can be
checked with a `curl`:

```bash
CHAIN=52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971
ROUND=31799517

curl -s https://api.drand.sh/$CHAIN/public/$ROUND | jq -r .randomness
# 1e3f931ad3c2321e8c572135aabc96e27ce6cf1e5a807f0b4aa073622b946ada

cast call $ORACLE "randomnessOf(uint64)(bytes32)" $ROUND --rpc-url $RPC
# 0x1e3f931ad3c2321e8c572135aabc96e27ce6cf1e5a807f0b4aa073622b946ada
```

The two must match byte for byte. If they ever do not, the on-chain value is wrong and everything
downstream of it should be treated as compromised.

Chain parameters, for reference and for computing round numbers yourself:

| Parameter | Value |
|---|---|
| drand chain | `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971` (quicknet) |
| scheme | `bls-unchained-g1-rfc9380` (BLS12-381, signature on G1) |
| period | 3 seconds |
| genesis | `1692803367` |
| round formula | `round = (t - 1692803367) / 3 + 1` |
| chain info | <https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info> |

---

## The residual: the clock is the sequencer's

Be honest with yourself about what the commit guarantee rests on.

`oracle.commit()` returns `currentRound() + minFutureRounds`, and `currentRound()` is computed from
`block.timestamp`. The default offset of 2 rounds puts the committed beacon at least 4 seconds in
the future *according to the chain's clock*. But `block.timestamp` is chosen by the sequencer, and
there is no second clock on chain to check it against. A sequencer that back-dated a block by more
than that margin could hand a commit a round whose beacon is already public in real time.

This is the one thing in the design with no on-chain remedy, and it is bounded by two facts rather
than closed by code:

1. A sequencer that can back-date blocks by seconds can already reorder and censor every
   transaction on the L2. This attack adds no capability it did not already have; if you do not
   trust the sequencer at all, you should not be building on the chain.
2. The margin is adjustable. The owner can raise the offset with
   `oracle.setMinFutureRounds(value)`, within `[2, 8192]`, if observed timestamp drift ever
   warrants it. Read the live value with `oracle.minFutureRounds()`.

Raising the offset does not affect commits already made — `minFutureRounds` is read only on the
commit path, never on publish or read, so an in-flight commit cannot be invalidated by a later
change. The range is closed on both ends so the owner cannot set an offset that makes committing
impossible.

If your application cannot tolerate this residual, commit further ahead than the default: use
`oracle.commitTo(round)` with a round minutes rather than seconds away, which makes the required
timestamp manipulation implausibly large.

---

## Error reference

| Error | Meaning | What to do |
|---|---|---|
| `RoundTooSoon(round, earliestAllowed)` | `commitTo` target is too close to now | commit to `earliestAllowed` or later |
| `RoundNotPublished(round)` | inside the window, nobody published it yet | wait and poll, or publish it yourself |
| `RoundEvicted(round, oldestRetained)` | older than the 8192-round window | use `verifyRound` with the signature from the API |
| `RoundAlreadyPublished(round)` | someone published it first | read it; the value is already correct |
| `RoundTooOld(round, oldestRetained)` | `publish` target predates the window | nothing to do; the ring will not hold it |
| `RoundInFuture(round, currentRound)` | `publish` target is ahead of the chain's clock | wait |
| `InvalidSignature(round)` | signature is not drand's for this round | check the round number and the encoding |
| `InvalidSignatureLength(provided, expected)` | signature is not 128 bytes | decompress to uncompressed EIP-2537 G1 |
| `InvalidRound(round)` | round 0; drand rounds start at 1 | use a real round |
| `TimestampBeforeGenesis(timestamp, genesis)` | chain clock predates drand genesis | only reachable in tests under `vm.warp` |

---

## Deployment

```bash
NETWORK=testnet/l2 forge script scripts/deploy/DeployDrandOracle.s.sol \
  --rpc-url https://rpc.testnet.fluent.xyz --account deployer --broadcast
```

The owner defaults to `.roles.initialOwner` from `scripts/config/<network>.json` and can be
overridden with `INITIAL_OWNER`. Set `OUTPUT_PATH` to have the address written into a deployment
manifest under the key `drand_oracle`. Deployed addresses are listed in [Addresses.md](Addresses.md).
