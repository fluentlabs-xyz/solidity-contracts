# DepositDeadline Spec (Rollup)

## Scope
- Deposit queue verification and acceptance deadline behavior tied to bridge queue updates.

## Actors
- Sequencer
- Owner
- Bridge contract (queue source)

## Privileged Functions
- `acceptNextBatch(...)` (sequencer-only)

## Required Guarantees
- For non-empty deposit commitments, deposits are popped from `Bridge` queue and hash-checked.
- `lastDepositAcceptedBlockNumber` updates when queue transitions indicate deposits consumed.
- If queue remains non-empty beyond `acceptDepositDeadline`, acceptance reverts with `AcceptDepositDeadlineExceeded`.
- Invalid deposit block hash mapping reverts with `BlockHashMismatch`.
- Invalid deposit root reverts with `DepositVerificationFailed`.

## Scenarios: Happy
- Batch with valid deposit roots passes and consumes queue entries.
- Queue fully drained resets `lastDepositAcceptedBlockNumber` to zero.

## Scenarios: Revert
- Deadline exceeded while pending deposits remain.
- Wrong block hash in `DepositsInBlock`.
- Wrong deposit hash.

## Scenarios: Edge
- Empty deposit hash (`ZERO_BYTES_HASH`) bypasses queue pop for that commitment.

## Scenarios: Attack
- Sequencer cannot forge deposit root inconsistent with bridge queue.

## Notes
- Legacy Rollup parity has partial indirect coverage.
- Full dedicated coverage is needed for DA/deposit operations before e2e migration.
