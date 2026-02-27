# DaConfig Spec (Rollup)

## Scope
- DA configuration, fail-closed enforcement, and deterministic blob hash helper behavior.

## Actors
- Owner
- Non-owner attacker

## Privileged Functions
- `setDaCheck(bool)` (owner-only)
- `setBlobHashGetter(address)` (owner-only)

## Required Guarantees
- Owner can toggle DA check and event `DaCheckUpdated(oldValue, newValue)` is emitted.
- Owner can update blob hash getter address.
- Non-owner cannot toggle DA check.
- `calculateBlobHash(bytes)` is deterministic for equal input.
- Returned blob hash is masked/formatted:
- Highest byte forced to `0x01`.
- Next highest bits aligned with implementation mask (`0x00ff..ff` and prefix OR).
- If `daCheck == true`, `acceptNextBatch` must fail closed when submitted blob hash is missing/mismatched.
- If `daCheck == true` and submitted blob hash matches expected hash, `acceptNextBatch` succeeds.

## Scenarios: Happy
- Toggle false->true and assert emitted event values.
- Known commitment input yields stable hash and correct prefix/mask.
- Configure blob hash getter with matching blob hash and accept batch successfully.

## Scenarios: Revert
- Non-owner `setDaCheck` reverts.
- Non-owner `setBlobHashGetter` reverts.
- DA mismatch reverts with `DaBlobHashMismatch`.

## Scenarios: Edge
- Empty blob bytes input still produces a properly formatted hash.

## Scenarios: Attack
- Caller cannot influence format bits outside SHA256+masking rules.

## Notes
- DA validation is now enforced in `acceptNextBatch` when `daCheck` is enabled.
