# E2E Migration Checklist (Hardhat -> Foundry)

## Scope
- Goal: full e2e parity for Bridge/Rollup first, then Restaker.
- Runtime model: dual-fork Foundry (`switchToL1` / `switchToL2` via `selectFork`).
- DA policy: `daCheck=true` fail-closed in batch acceptance paths.

## Legacy Mapping
- `test/e2e/SendTokens.js` -> `test/e2e/ERC20RoundtripHappyPath.t.sol` (`test_e2e_erc20Roundtrip_happyPath_dualFork_daOn`, plus DA mismatch negative path).
- `test/e2e/AcceptBatch.js` -> `test/e2e/AcceptBatchParity.t.sol` (`test_bulkAcceptBatchAndProcessMessages_withProofs`, `test_bulkPath_preservesQueueAndConsumesDepositsCorrectly`).
- `test/e2e/RestakeTokens.js` -> `test/e2e/RestakerRoundtripParity.t.sol` (`test_restakerComparePeggedTokenAddresses`, `test_restakedRoundtrip_sendClaimUnstake`).
- `test/e2e/TokenApprove.js` -> covered by unit tests; optional Foundry smoke can be added later if needed.

## Parity Gates
- [ ] `forge test --match-path test/e2e/ERC20RoundtripHappyPath.t.sol -vv`
- [ ] `forge test --match-path test/e2e/AcceptBatchParity.t.sol -vv`
- [ ] `forge test --match-path test/e2e/RestakerRoundtripParity.t.sol -vv`
- [ ] `forge test --match-path test/e2e/*.t.sol -vv`

## Hardhat E2E Deprecation Gate
- Hardhat e2e (`test/e2e/*.js`) can be retired from CI only after all parity gates above are green on CI and local dual-anvil runs.
- Until then, Hardhat e2e remains reference coverage for migration validation.
