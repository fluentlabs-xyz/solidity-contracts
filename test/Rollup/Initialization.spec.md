# Initialization Spec (Rollup)

## Scope
- Constructor invariants and initial state setup.

## Actors
- Deployer (`owner`)
- Sequencer

## Privileged Functions
- Constructor-only initialization of core fields.

## Required Guarantees
- Constructor sets `sequencer`, `programVKey`, verifier address, bridge address.
- `nextBatchIndex` starts at `1`.
- `lastBlockHashInBatch[0]` equals provided genesis hash.
- `batchSize` is stored exactly.
- Constructor validation reverts on invalid zero values:
- `sequencer == address(0)` -> `ZeroAddressNotAllowed("sequencer")`.
- `verifier == address(0)` -> `ZeroAddressNotAllowed("verifier")`.
- `programVKey == bytes32(0)` -> `ZeroValueNotAllowed("programVKey")`.
- `genesisHash == bytes32(0)` -> `ZeroValueNotAllowed("genesisHash")`.
- `batchSize == 0` -> `ZeroValueNotAllowed("batchSize")`.

## Scenarios: Happy
- Deploy with valid inputs and assert all persisted state fields.

## Scenarios: Revert
- Deploy with each invalid argument above and assert exact custom error.

## Scenarios: Edge
- `challengeDepositAmount` and `approveBlockCount` can be zero when explicitly configured.

## Scenarios: Attack
- None specific beyond constructor guards.

## Notes
- Legacy parity source:
- `test/Rollup.js` uses valid initialization.
- `test/Verifier.js` validates alternate verifier + key path.
