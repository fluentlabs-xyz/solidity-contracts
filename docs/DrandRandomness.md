# Drand Randomness

`DrandOracle` is a public randomness service. It serves the [drand](https://drand.love) quicknet
beacon on chain: a threshold-signed value that a committee of independent operators produces every
3 seconds, that nobody — not the sequencer, not this team, not you — can predict before it exists,
and that anyone can check against `api.drand.sh` afterwards.

You do not need to know anything about drand or BLS signatures to use it. You need two calls.

---

## What the service guarantees

- **Unpredictable at commit time.** You bind yourself to a round whose beacon does not exist yet.
  `commit()` measures "now" on the chain's clock; `commitTo(round)` lets you measure it yourself
  (see [The residual](#the-residual-the-chains-clock-and-the-upgrade-key) for what each rests on).
- **Immutable once published.** A round's value is written once and never rewritten by any body
  of the contract; publishing a round twice reverts `RoundAlreadyPublished`. The contract sits
  behind a UUPS proxy whose admin role can replace the implementation, and nothing else — see
  [The residual](#the-residual-the-chains-clock-and-the-upgrade-key) for who holds it.
- **Verified on chain.** A value is stored only after the contract itself checks drand's threshold
  signature against a hardcoded public key, using the EIP-2537 pairing precompile. A forged or
  mismatched signature reverts `InvalidSignature` — it cannot be stored.
- **Byte-identical to drand's own output.** The stored value is `sha256` of drand's compressed
  signature, which is exactly the `randomness` field the public API serves for that round. Any
  dispute about an on-chain value is settled by a URL — see
  [Checking a value against api.drand.sh](#checking-a-value-against-apidrandsh).
- **Permissionless publication.** Nobody holds a publisher role. The keeper that normally posts
  rounds posts the ones consumers committed to; if it goes quiet, anyone can post the same
  signature to the same effect — one round at a time with `publish`, or many under one signature
  check with `publishBatch`. The one exception is the emergency pause, held by a timelock, which
  stops publishing for everyone at once (`EnforcedPause`); reads, commits and `verifyRound` go on.
- **Never zero.** An unpublished or aged-out round reverts. It never reads back as `bytes32(0)`,
  which would be a deterministic, attacker-known "random" number.
- **Bounded state.** The contract holds published values for a window of 8192 rounds and nothing
  more, forever. See [Retention](#retention-6h49m36s).

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

The commit is also what makes the round get published: the keeper publishes the rounds this event
names and no others. A round nobody committed to is not on chain, and you can put it there
yourself with `publish` if you ever need one.

If you need a specific round rather than the earliest safe one — a draw at a fixed wall-clock time,
say, or a margin of your own choosing — use `oracle.commitTo(round)` instead. It emits the same
event and checks nothing: the round is your claim, and a round whose beacon is already public gives
you a value anyone could have predicted. Pick it ahead of the clock you trust.

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

    /// @notice Entry is closed once `open()` has bound the draw to a round
    error EntryClosed();
    /// @notice The winner of this draw has already been drawn
    error AlreadyDrawn();
    /// @notice A draw needs at least one entrant
    error NoEntrants();

    IDrandOracle public immutable ORACLE;

    address[] public entrants;
    uint64 public round;
    address public winner;
    bool public drawn;

    constructor(address oracle) {
        ORACLE = IDrandOracle(oracle);
    }

    /// @notice Joins the draw; reverts once `open()` has closed entry
    function enter() external {
        if (round != 0) revert EntryClosed();
        entrants.push(msg.sender);
    }

    /// @notice Closes entry and binds the draw to a round drand has not reached yet
    /// @return The committed round
    function open() external returns (uint64) {
        if (round != 0) revert EntryClosed();
        if (entrants.length == 0) revert NoEntrants();
        round = ORACLE.commit();
        return round;
    }

    /// @notice Draws the winner from the committed round's randomness
    /// @return The winning entrant
    function draw() external returns (address) {
        if (drawn) revert AlreadyDrawn();
        bytes32 value = ORACLE.randomnessFor(round, DOMAIN);
        drawn = true;
        winner = entrants[uint256(value) % entrants.length];
        return winner;
    }
}
```

Note what `draw()` does *not* do: it does not wrap the read in `try`/`catch` and fall back to a
default. If the round is not published yet, `draw()` reverts and the caller tries again later. A
catch branch that substitutes a zero, a block hash or a timestamp is the classic way to turn a
randomness oracle back into a predictable one.

Note also what `open()` does: it **closes entry**. The set the winner is drawn from must be fixed
before the round's beacon exists, which is the whole point of committing ahead. A lottery that let
`enter()` run after the round was published would hand any caller a free win — publish the beacon,
compute `uint256(randomness) % (entrants.length + 1)` off chain, and keep entering until the index
lands on you. `enter()` therefore reverts with `EntryClosed` once `round` is set, and `draw()` is
guarded with `AlreadyDrawn` so the winner cannot be re-rolled. Whatever your consumer's payout
looks like, the same rule applies: nothing that changes the draw may move after the commit.

---

## Retention: 6h49m36s

The contract keeps published rounds in a fixed 8192-slot ring. At 3 seconds per round that is
**6 hours, 49 minutes and 36 seconds** of history, and it is the entire storage footprint of the
contract — no amount of publishing can grow it. Round `N` overwrites the slot of round
`N - 8192` when it is published, and eviction is strictly first-in, first-out by elapsed time:
nobody can push your round out early.

The ring holds the rounds that were *published*, which are the rounds consumers committed to — not
every round drand emitted in the window. `oracle.isPublished(round)` is what says whether a
particular one is there.

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

## Publishing: `publish` and `publishBatch`

Publication is permissionless. Whoever holds a round's beacon can put it on chain, and the keeper
([`fluentlabs-xyz/drand-publisher`](https://github.com/fluentlabs-xyz/drand-publisher)) is just the
party that normally does it first.

```solidity
oracle.publish(round, signature);                       // one round, one pairing
uint256 written = oracle.publishBatch(rounds, signatures); // up to 64 rounds, one pairing
```

`oracle.publishBatch(rounds, signatures)` takes strictly ascending rounds, all inside the retention
window, and their 128-byte signatures concatenated in the same order. Rounds already published are
skipped rather than refused — two publishers racing do not fail each other's batch — and the return
value is how many rounds the call wrote; if that would be zero it reverts `NothingToPublish`. The
batch is verified as a whole, `e(Σ rᵢ·sigᵢ, −g2) · e(Σ rᵢ·H(roundᵢ), pk) == 1` with the `rᵢ` drawn
from a hash of the whole input, so a wrong signature anywhere reverts `InvalidBatchSignature` for
the whole call without naming the round: publish the rounds one at a time to find it. Nothing is
written by a batch that fails.

A batch pays the pairing once and the hash-to-curve and storage per round. Measured in the test
suite, through the proxy, from a cold caller:

| call | gas | per round |
|---|---|---|
| `publish`, one round | 185,451 | 185,451 |
| `publishBatch`, five rounds | 561,322 | 112,264 |

Both figures write into never-used ring slots; once the ring has wrapped (6h49m after deployment)
every write lands on a slot that already holds an older round, which is about 34,000 gas cheaper
per round (151,325 for one `publish`).

The keeper (`drand-publisher`) publishes on demand: it watches `RoundCommitted`, waits for the
committed round's beacon to be emitted, and posts it. A commit gives it at least four seconds of
notice — the contract's floor puts the committed round two rounds ahead of the clock that measured
it — so the round normally lands within a second or two of becoming public. Several rounds that
come due together travel in one `publishBatch`; that is also how a backlog goes out after the
keeper has been down. Rounds nobody committed to cost nothing and are not published.

The keeper is built to outlive what goes wrong around it, without an operator. Its memory is the
chain: what it owes is read from `RoundCommitted`, what it has paid from `isPublished`, and its
SQLite file only spares it the rescan — a file from another oracle, another chain or another
build of the service is emptied and rebuilt, and a crash or a `SIGTERM` at any point leaves
nothing the next start cannot reconcile. A relay that is silent hands the question to the next
one after 750 ms; one that lies is charged by name and the ones after it asked; a relay outage
keeps the round owed and retries it at the beacon's cadence, and a beacon that is late is asked
for at a doubling pace rather than once per round per quarter second. A round the chain's clock
has not reached is held, not sent to be refused, and goes out with the first scan that reads a
clock past it. A node that stops answering is backed off up to a minute and then the chain is
re-read; no transaction bids more than `DRAND_MAX_FEE_PER_GAS_GWEI` per gas, and one that
sticks is resent at a doubled fee each pending timeout up to that ceiling, past which it is
waited for rather than outbid. A revert the
service has no row for splits a batch and retries a single round three times, at 3, 6 and 12
seconds, before that round alone is given up; a round the ring has moved past, or one no relay
can serve, is dropped without holding the rounds behind it. A signer that cannot pay waits for a
top-up; a chain whose precompiles or clock have gone wrong is probed once a poll until they are
back. Under systemd the service feeds a watchdog only while it is idle, probing, or carrying
rounds the chain's clock is within ten minutes of, so a loop that is alive but stuck is
restarted with a clean memory.

With `DRAND_METRICS_ADDRESS` set the keeper serves Prometheus metrics at `/metrics`, all
prefixed `drand_publisher_`; `deploy/grafana/drand-publisher.json` in its repository is a Grafana
dashboard over them (import it, pick the Prometheus datasource; it expects the scrape job to be
named `drand-publisher`). The ones to alert on:

| metric | meaning | alert when |
|---|---|---|
| `publish_delay_seconds` (histogram) | seconds from a round's emission to the block carrying it | p95 over 10 s for 5 min: the relays or the chain are slow |
| `rounds_owed`, `oldest_owed_round` vs `chain_round` | the backlog, and how far the chain's clock has left its oldest round behind | `chain_round - oldest_owed_round > 200` for 10 min: something holds the queue |
| `accounted_for` | 1 while the loop can explain its state; what feeds the watchdog | 0: the loop is stuck (systemd restarts it after `WatchdogSec`) |
| `halted{reason}` | 1 while stopped on a chain property: `paused`, `precompiles`, `genesis` | 1 for longer than the pause was meant to last |
| `rounds_dropped_total{reason}` | rounds given up on: `too_old`, `rejected`, `unserviceable` | any increase — a consumer's commit went unserved |
| `signer_balance_wei` | the signer's balance, read once a minute | below a week of publishing (`rounds_published_total` rate × gas × fee) |
| `relay_failures_total{relay}`, `relays_exhausted_total` | relay requests that failed, and fetches where every relay did | `relays_exhausted_total` increasing: no relay answers |
| `resubmissions_total`, `unknown_reverts_total`, `sends_starved_total`, `read_failures_total`, `reconciles_total` | the loop's recoveries, each of which it makes on its own | a sustained rate — the environment is degraded even though rounds still land |

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

## The residual: the chain's clock and the upgrade key

`commit()` has to know which round is "now" so it can hand you one whose beacon does not exist
yet. It reads `block.timestamp`, which the sequencer chooses, and returns
`currentRound() + minFutureRounds()` — two rounds ahead, at least four seconds away.

- A chain clock **ahead** of real time only makes commits land further ahead: slower, never
  unsafe.
- A chain clock **behind** real time hands out a round whose beacon is already public. A sequencer
  that can back-date its blocks by four seconds can do this; so can validators whose clocks drift
  that far.

`commit()` therefore trusts the chain's clock — which is to say the operator running the
sequencer, who on this chain also runs the keeper. If that is not a trust you want to extend, do
not use `commit()`. Use `oracle.commitTo(round)` with a round of your own choosing —
`oracle.currentRound() + N` for an `N` that covers the skew you are willing to assume, or a round
computed from a wall-clock time you hold yourself — and the contract records it as given. The
beacon you get is then unpredictable unless the chain's clock is running `3N - 2` seconds or
more behind real time (at exactly `3N - 2` the commit and the emission coincide). A sequencer
that back-dates that far can already reorder and censor every transaction on the L2; if you do
not trust it at all, you should not be building on the chain.

`commitTo` checks nothing about timing, in either direction: a round the chain has already passed
is accepted, and the keeper publishes it like any other committed round as long as it is inside
the retention window. Only round 0, which is not a drand round, reverts `InvalidRound`. That is deliberate — the contract cannot tell a careless commit from a consumer that wants
a past round on chain — and it makes the round you commit to your responsibility alone.

The second thing every path rests on is who holds the contract's two roles, which follow the
model of the other Fluent contracts (`Rollup`, the bridge): `DEFAULT_ADMIN_ROLE` may upgrade the
implementation and administer both roles, `EMERGENCY_ROLE` may pause and unpause publishing, and
nothing else is gated on anyone. In production both sit behind `FluentTimeLock`s driven by the
governance Safe — the admin behind the normal timelock, whose delay is longer than the retention
window, so any round you can commit to and read inside the window is read under the code you
committed under; the emergency role behind the short-delay one, since a pause is for a verifier
found to accept what it should not, until the upgrade that fixes it lands. `MigrateRoles`
moves both roles off the deployer and renounces its own. An upgrade can change anything, the
verifier and the ring included, so "verified on chain" holds for the implementation the proxy
points at today, which anyone can read from the proxy's ERC-1967 implementation slot and
compare against this repository; the timelock is what makes the next one visible in advance.
The roles are not renounceable in practice: the verifier is compiled in, and a change in
quicknet or in EIP-2537 pricing is repaired only by an upgrade.

---

## Error reference

| Error | Meaning | What to do |
|---|---|---|
| `RoundNotPublished(round)` | inside the window, nobody published it yet | wait and poll, or publish it yourself |
| `RoundEvicted(round, oldestRetained)` | older than the 8192-round window | use `verifyRound` with the signature from the API |
| `RoundAlreadyPublished(round)` | someone published it first | read it; the value is already correct |
| `RoundTooOld(round, oldestRetained)` | `publish` target predates the window | nothing to do; the ring will not hold it |
| `RoundInFuture(round, currentRound)` | `publish` target is ahead of the chain's clock | wait |
| `InvalidSignature(round)` | signature is not drand's for this round | check the round number and the encoding |
| `EnforcedPause()` | the emergency role has paused publishing | wait; the keeper holds the round and posts it when publishing reopens |
| `InvalidSignatureLength(provided, expected)` | signature is not 128 bytes, or a batch's signatures are not 128 bytes per round | decompress to uncompressed EIP-2537 G1 |
| `EmptyBatch()` | `publishBatch` with no rounds | send at least one round |
| `BatchTooLarge(provided, maximum)` | more than `MAX_BATCH_ROUNDS` (64) rounds in one batch | split the batch |
| `RoundsNotAscending(previous, round)` | a batch repeats a round or lists one out of order | sort and dedupe the rounds |
| `NothingToPublish()` | every round in the batch is already published | read them; the values are already correct |
| `InvalidBatchSignature()` | the batch does not verify as a whole | publish the rounds one at a time to find the wrong one |
| `InvalidRound(round)` | round 0; drand rounds start at 1 | use a real round |
| `TimestampBeforeGenesis(timestamp, genesis)` | chain clock predates drand genesis | only reachable in tests under `vm.warp` |

The three below come from `DrandQuicknetVerifier`, not `IDrandOracle`. They are in the deployed
ABI all the same, so a `catch` that matches on `IDrandOracle` selectors alone will miss them.

| Error | Meaning | What to do |
|---|---|---|
| `InfinityPoint()` | the signature — or, with negligible probability, the hashed message — is the point at infinity | send the real 128-byte beacon; all-zero bytes land here, not on `InvalidSignature` |
| `InvalidPointLength()` | point reached the verifier at a width other than EIP-2537's | decompress to 128 bytes; `publish` and `verifyRound` screen this first with `InvalidSignatureLength` |
| `PrecompileFailed()` | an EIP-2537 or MODEXP precompile rejected the call | the chain is not Prague-enabled, or the call was starved of gas |

---

## Deployment

```bash
ADMIN_ROLE=<admin> EMERGENCY_ROLE=<emergency> forge script scripts/deploy/DeployDrandOracle.s.sol \
  --rpc-url https://rpc.testnet.fluent.xyz --account deployer --broadcast
```

`ADMIN_ROLE` falls back to `.roles.admin` of the `NETWORK` config (default `testnet/l2`),
`EMERGENCY_ROLE` to `.roles.emergency` or, failing that, to the admin. Set `OUTPUT_PATH` to have
the addresses written into a deployment manifest under the keys `drand_oracle` (the proxy — the
address consumers use) and `drand_oracle_impl`. The testnet deployment is recorded in
`deployments/testnet/drand.json`. Once the timelocks exist, `scripts/deploy/MigrateRoles.s.sol`
(`LAYER=l2`) grants the admin role to the normal timelock and the emergency role to the
emergency one, then renounces the deployer's.

To upgrade, first reproduce the build of the implementation the proxy runs today (check out
its commit, `forge clean && forge build`) and copy its `out/build-info` aside; then build the new
implementation from a clean `out/` and run

```bash
REFERENCE_BUILD_INFO_DIR=<copied build-info> PROXY_ADDRESS=<drand_oracle> \
  forge script scripts/upgrade/UpgradeDrandOracle.s.sol \
  --rpc-url https://rpc.testnet.fluent.xyz --account owner --broadcast
```

OpenZeppelin's upgrade checker compares the new storage layout against the reference build and
refuses the upgrade on a layout change (a field inserted before the ring, for instance); it needs
a clean `out/`, since a stale build-info file makes it report two contracts of the same name.
`UNSAFE_SKIP_STORAGE_CHECK=true` skips the comparison for a reference build that cannot be
reproduced. A proxy that the first, owner-based implementation initialized is moved to the roles
by the same script with `ADMIN_ROLE` and `EMERGENCY_ROLE` set, which makes the upgrade call
`initializeV2`; only that proxy's owner may make the call. The ring lives in an ERC-7201 namespace (`Fluent.storage.DrandOracleStorage`), so a
new implementation that keeps `RoundSlot` and `RING_ROUNDS` keeps every published round.
