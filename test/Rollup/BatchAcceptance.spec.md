# BatchAcceptance Spec (Rollup)

## Scope
- Acceptance of new batches, sequencing constraints, and stored batch metadata.

## Actors
- Sequencer
- Owner

## Privileged Functions
- `acceptNextBatch(...)` (sequencer-only)

## Required Guarantees
- Accepting a valid batch:
- Stores `acceptedBatchHash[batchIndex]`.
- Increments `nextBatchIndex`.
- Stores `lastBlockHashInBatch[batchIndex]`.
- Emits `BatchAccepted(batchIndex, batchRoot)`.
- Rejects invalid batch index with `InvalidBatchIndex`.
- Rejects invalid batch size with `InvalidBatchSize`.
- Rejects wrong previous hash with `WrongPreviousBlockHash`.
- Rejects broken intra-batch sequence with `InvalidBlockSequence`.
- Rejects invalid block proof/deposit mapping via `DepositVerificationFailed` / `BlockHashMismatch` when applicable.

## Scenarios: Happy
- Two-block batch accepted with valid previous linkage.
- Root computed by helper equals emitted/stored batch hash.

## Scenarios: Revert
- Wrong `_batchIndex`.
- Wrong `_commitmentBatch.length`.
- Wrong `previousBlockHash`.
- Non-linked adjacent commitments.

## Scenarios: Edge
- Batch index starts from 1, genesis anchor in index 0.

## Scenarios: Attack
- Cannot commit malformed chains that break hash continuity.

## Notes
- Legacy parity source:
- `test/Rollup.js` acceptance path.
