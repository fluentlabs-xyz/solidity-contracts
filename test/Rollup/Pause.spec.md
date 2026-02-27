# Pause Spec (Rollup)

## Scope
- Pausable behavior around batch/challenge/proof execution.

## Actors
- Owner
- Sequencer
- Challenger
- Proof provider

## Privileged Functions
- `pause()`
- `unpause()`

## Required Guarantees
- Contract starts unpaused.
- `pause()` flips paused state to true.
- `unpause()` flips paused state back to false.
- While paused, `acceptNextBatch` reverts (`EnforcedPause` from OZ).
- While paused, `challengeBlockCommitment` reverts (`EnforcedPause`).
- While paused, `proofBlockCommitment` reverts (`EnforcedPause`).

## Scenarios: Happy
- Owner pauses and unpauses successfully.
- Batch acceptance works again after unpause.

## Scenarios: Revert
- `acceptNextBatch` during pause reverts.

## Scenarios: Edge
- Repeated pause/unpause operations keep consistent state.

## Scenarios: Attack
- Attacker cannot bypass pause with alternate call paths.

## Notes
- Legacy parity source:
- `test/Rollup.js` currently validates `acceptNextBatch` blocked while paused.
