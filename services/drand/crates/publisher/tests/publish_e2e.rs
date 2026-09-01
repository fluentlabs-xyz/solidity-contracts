//! Spec test for design.md:269 — the loop, unmodified, against a real `DrandOracle`
//! deployed on a local anvil (per R1: consecutive rounds land; per R4: the counter starts
//! from the chain's `currentRound()`; per R8: one integration run on a real node).
//!
//! The chain clock is placed so `currentRound()` equals the OLDEST pinned round, which is
//! what the service's own startup derivation then yields — no start-round key is invented
//! for the test. The pinned rounds must be consecutive, or the counter never reaches them.

use alloy::node_bindings::Anvil;
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use drand_beacon::{Beacon, BeaconSource, Fetched};
use drand_publisher::{Config, DrandOracle, Publisher};
use std::collections::BTreeMap;
use std::time::Duration;

const GENESIS_TIMESTAMP: u64 = 1_692_803_367;
const PERIOD_SECONDS: u64 = 3;
const ANVIL_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const FIXTURES: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../beacon/fixtures/quicknet_rounds.json"
);

/// Stands in for the relay list: it serves the pinned rounds and nothing else.
struct FixtureRelay {
    bodies: BTreeMap<u64, String>,
}

impl BeaconSource for FixtureRelay {
    async fn fetch(&self, round: u64) -> Fetched {
        match self.bodies.get(&round) {
            Some(body) => Fetched::Beacon(Beacon::from_json(body).expect("a pinned body parses")),
            None => Fetched::NotReady,
        }
    }
}

// `unsafe` is required from edition 2024 on and harmless before it.
#[allow(unused_unsafe)]
fn set(key: &str, value: &str) {
    unsafe { std::env::set_var(key, value) }
}

#[tokio::test]
async fn publishes_every_pinned_round_to_a_real_oracle() {
    let raw = std::fs::read_to_string(FIXTURES).expect("the pinned quicknet fixtures");
    let bodies: BTreeMap<u64, String> = serde_json::from_str::<Vec<serde_json::Value>>(&raw)
        .expect("an array of drand round bodies")
        .into_iter()
        .map(|body| (body["round"].as_u64().expect("round"), body.to_string()))
        .collect();
    let oldest = *bodies.keys().next().expect("at least one pinned round");
    let newest = *bodies.keys().next_back().expect("at least one pinned round");
    assert_eq!(
        bodies.len() as u64,
        newest - oldest + 1,
        "the pinned rounds must be consecutive"
    );

    let timestamp = GENESIS_TIMESTAMP + (oldest - 1) * PERIOD_SECONDS;
    let anvil = Anvil::new()
        .arg("--hardfork")
        .arg("prague")
        .arg("--timestamp")
        .arg(timestamp.to_string())
        .try_spawn()
        .expect("anvil with the EIP-2537 precompiles");

    let signer: PrivateKeySigner = ANVIL_KEY.parse().expect("anvil's first dev key");
    let owner = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(signer)
        .connect_http(anvil.endpoint_url());
    let oracle = DrandOracle::deploy(provider, owner)
        .await
        .expect("deploy the oracle from the artifact forge build regenerated");

    set("DRAND_SIGNING_KEY", ANVIL_KEY);
    set("DRAND_RPC_URL", anvil.endpoint().as_str());
    set("DRAND_ORACLE_ADDRESS", &oracle.address().to_string());
    set("DRAND_RELAYS", "http://127.0.0.1:1");
    let config = Config::from_env().expect("the environment the test just set");

    // `run_until` takes `&mut self` and returns once the counter has passed `newest`.
    let mut publisher = Publisher::new(config, FixtureRelay { bodies })
        .await
        .expect("the service starts from the chain's current round");
    let budget = Duration::from_secs(60 + 5 * (newest - oldest + 1));
    tokio::time::timeout(budget, publisher.run_until(newest))
        .await
        .expect("the loop published the whole span inside its budget")
        .expect("the loop ran without failing");

    for round in oldest..=newest {
        let published = oracle
            .isPublished(round)
            .call()
            .await
            .expect("isPublished answers");
        assert!(published, "round {round} is not on chain");
    }
}
