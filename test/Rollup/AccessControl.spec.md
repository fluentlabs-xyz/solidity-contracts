# AccessControl Spec (Rollup)

## Scope
- Ownership/role boundaries for owner and sequencer paths.

## Actors
- Owner
- Non-owner attacker
- Sequencer
- Non-sequencer attacker

## Privileged Functions
- Owner-only:
- `setDaCheck(bool)`
- `setBlobHashGetter(address)`
- `setBridge(address)`
- `updateVerifier(address)`
- `pause()`
- `unpause()`
- `forceRevertBatch(uint256)`
- Sequencer-only:
- `acceptNextBatch(uint256, BlockCommitment[], DepositsInBlock[])`

## Required Guarantees
- Non-owner cannot call owner-only functions.
- Non-sequencer cannot call `acceptNextBatch`.
- Open functions remain open:
- `challengeBlockCommitment(...)`
- `proofBlockCommitment(...)`
- `withdrawChallengeDeposit(...)`
- `withdrawProofReward()`

## Scenarios: Happy
- Owner updates bridge/verifier/DA flag and events reflect new values.
- Sequencer accepts batch with valid inputs.

## Scenarios: Revert
- Non-owner reverts on owner-only functions.
- Non-sequencer reverts with `"call only by sequencer"` on `acceptNextBatch`.

## Scenarios: Edge
- `updateVerifier(address(0))` reverts with `ZeroAddressNotAllowed("verifier")`.

## Scenarios: Attack
- Unauthorized actors cannot alter bridge/verifier/pause state.

## Notes
- Current legacy tests explicitly cover owner pause path and sequencer usage.
- Additional non-owner negative cases are required for complete role hardening.
