# VerifierProof Spec (Rollup)

## Scope
- SP1 verifier integration path for proving challenged commitments.

## Actors
- Owner
- Sequencer
- Challenger
- Proof provider

## Privileged Functions
- `updateVerifier(address)` (owner-only)

## Required Guarantees
- Rollup with SP1 verifier accepts valid challenge and valid proof flow.
- After proof:
- challenged commitment removed from queue.
- `provenBlockCommitment[hash] == true`.
- invalid verifier address update reverts (`ZeroAddressNotAllowed`).

## Scenarios: Happy
- Deploy Rollup with `SP1Verifier`.
- Accept one-commitment batch.
- Challenge commitment with valid inclusion proof.
- Prove commitment with provided zk proof bytes.
- Assert queue emptied and proven flag set.

## Scenarios: Revert
- Invalid block proof passed to challenge/proof reverts with `InvalidBlockProof`.

## Scenarios: Edge
- Minimal batch size (`1`) verifier path works.

## Scenarios: Attack
- Re-proving already proven commitment reverts with `BlockCommitmentAlreadyProofed`.

## Notes
- Legacy parity source:
- `test/Verifier.js`.
