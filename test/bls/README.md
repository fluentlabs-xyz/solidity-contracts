# BLS EIP-2537 conformance gate

Tier-3 authoritative gate for the fluentbase BLS byte layout. Vectors are
hand-mirrored from fluentbase `crates/bls/tests/eip2537_conformance_vectors.rs`
(`EXPECTED` + `NEG_G2_GENERATOR_EIP2537`; recipe/contract in
`crates/bls/CONFORMANCE.md`) — update both in the **same PR**; divergence is a
real conformance failure.

Run: `forge test --match-path test/bls/Eip2537Conformance.t.sol`
Env: built-in Foundry Prague EVM (no fork/RPC). See task brief/research.

The on-chain hash-to-G1 + end-to-end `verify` gate mirrors
`crates/bls/tests/hash_to_g1_conformance.rs` (`EXPECTED_H` +
`VERIFY_EXPECTED`, both DSTs) — update both in the **same PR**; divergence is
a real conformance failure. `verify` is pure pairing (5-param); `hashToG1`
is internal and pinned via `BLS12381VerifierHarness.hashToG1Exposed`, and
`compressG1/compressG2` are pinned against the corpus compressed vectors.
Run: `forge test --match-path test/bls/BlsHashToG1Conformance.t.sol`.
