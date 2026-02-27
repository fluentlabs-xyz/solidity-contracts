# ChallengeProof Spec (Rollup)

## Scope
- Challenge lifecycle, proof submission, corruption signaling, and forced reversion.

## Actors
- Sequencer
- Challenger
- Proof provider
- Owner

## Privileged Functions
- `forceRevertBatch(...)` (owner-only)

## Required Guarantees
- `challengeBlockCommitment`:
- Verifies commitment inclusion proof.
- Requires exact challenge deposit amount.
- Adds commitment to challenge queue.
- Records challenger and challenge deadline.
- `proofBlockCommitment`:
- Verifies block inclusion proof.
- Verifies zk proof through configured verifier.
- Marks commitment as proven.
- Clears challenge state for commitment.
- Removes commitment from queue.
- Rejects repeated proof for already proven commitment.
- Accrues challenge reward to prover withdrawal balance (pull-payment), no direct push transfer.
- `rollupCorrupted()`:
- Returns false before challenge deadline expiry.
- Returns true after expiry when queue head unresolved.
- `forceRevertBatch`:
- Reverts rollup state to selected accepted batch.
- Clears challenged/proven state for reverted tail.
- Restores non-corrupted state.

## Scenarios: Happy
- Accept batch -> challenge commitment -> prove commitment -> queue becomes empty.
- Challenge -> prove -> `proverReadyForWithdrawal` increases -> `withdrawProofReward` transfers ETH.
- Accept batch -> challenge commitment -> deadline passes -> `rollupCorrupted` true -> `forceRevertBatch` resets state.

## Scenarios: Revert
- Challenge with low deposit -> `InsufficientChallengeDeposit`.
- Challenge with excessive deposit -> `ExcessiveChallengeDeposit`.
- Challenge already approved/proven/challenged commitment -> dedicated custom errors.
- Repeated proof on already proven commitment -> `BlockCommitmentAlreadyProofed`.
- `withdrawProofReward` with zero balance -> `NothingToWithdraw`.

## Scenarios: Edge
- Queue cleanup works when challenged entries are deleted during proof/revert.
- Proof path must not execute external ETH callback before state cleanup.

## Scenarios: Attack
- Invalid commitment proofs cannot be used to challenge/prove.

## Notes
- Legacy parity source:
- `test/Rollup.js` first two test cases.
