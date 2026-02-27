# TESTPLAN: Rollup

## Contract Analysis
- Primary features:
- Batch acceptance with block-sequence and deposit-root verification.
- Challenge and proof lifecycle for block commitments.
- Corruption detection and force-revert recovery.
- Owner-controlled configuration (bridge, verifier, DA check, pause).
- DA-oriented helpers (`setDaCheck`, `calculateBlobHash`).
- Actors:
- `owner` (governance/ops).
- `sequencer` (allowed to accept batches).
- `challenger` (posts challenge deposit).
- `proofProvider` (proves commitment).
- Risks:
- Incorrect batch sequencing / wrong previous hash.
- Incorrect deposit root verification against `Bridge` queue.
- Stuck challenge queue and incorrect corruption flag behavior.
- Wrong handling of challenge deposits/incentive settlement.
- Pause bypass for functions that must be blocked.
- DA hash masking correctness.

## Proposed Test Tree
- `test/Rollup/Base.t.sol`
- `test/Rollup/Initialization.t.sol`
- `test/Rollup/Pause.t.sol`
- `test/Rollup/BatchAcceptance.t.sol`
- `test/Rollup/ChallengeProof.t.sol`
- `test/Rollup/DepositDeadline.t.sol`
- `test/Rollup/DaConfig.t.sol`
- `test/Rollup/VerifierProof.t.sol`
- `test/Rollup/SecurityEdgeCases.t.sol`
- `test/invariant/Rollup.invariant.t.sol`
- `test/invariant/RollupHandler.t.sol`

## Spec Files
- `test/Rollup/Initialization.spec.md`
- `test/Rollup/AccessControl.spec.md`
- `test/Rollup/Pause.spec.md`
- `test/Rollup/BatchAcceptance.spec.md`
- `test/Rollup/ChallengeProof.spec.md`
- `test/Rollup/DepositDeadline.spec.md`
- `test/Rollup/DaConfig.spec.md`
- `test/Rollup/VerifierProof.spec.md`

## Legacy Mapping
- `test/Rollup.js` -> `BatchAcceptance`, `ChallengeProof`, `Pause`.
- `test/Verifier.js` -> `VerifierProof`.
- Planned DA-oriented additions -> `DaConfig`, `DepositDeadline`.

## Checklist
- [x] Tooling added: Foundry side-by-side with Hardhat
- [x] Initialization behavior covered
- [x] Access control coverage complete
- [x] Pause behavior covered
- [x] Batch acceptance happy path covered
- [x] Challenge queue + proof lifecycle covered
- [x] Corruption + `forceRevertBatch` behavior covered
- [x] Verifier proof flow (SP1 path) covered
- [x] DA config coverage complete (`setDaCheck`, `calculateBlobHash`)
- [x] DA fail-closed behavior covered (match + mismatch scenarios)
- [x] Deposit deadline behavior covered
- [x] Security-critical events asserted
- [x] Repeated proof protection covered
- [x] Pull-payment reward flow covered (`withdrawProofReward`)
- [x] Stateful invariants for challenge/proof/queue/accounting covered
- [x] All `test/Rollup/*.t.sol` passing
- [x] All `test/invariant/*.t.sol` passing

## Contract Bugs Discovered
- `High` fixed: DA check was effectively disabled in `acceptNextBatch`.
- `Medium` fixed: `proofBlockCommitment` used push payment with external call in hot path.
- `Medium` fixed: challenge queue removal in `proofBlockCommitment` and `forceRevertBatch` scanned whole queue.
- `Medium` fixed: repeated proofs of already-proven commitment were accepted.
- `Medium` known/design risk (documented): proof submission remains permissionless, so valid calldata can still be front-run economically.
