//! A body that does not verify is charged to the relay that served it by name, and the
//! same round is then asked of the next relay — against a real `DrandOracle` on a local
//! anvil, so what lands on chain is the genuine beacon and not the relabelled one.

use std::env;
use std::fs;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy::node_bindings::Anvil;
use alloy::primitives::B256;
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use drand_beacon::{Beacon, BeaconSource, Fetched, HttpRelays};
use drand_publisher::{Config, DrandOracle, Publisher};
use serde_json::Value;
use tokio::time;
use tracing::{subscriber, Level};
use tracing_subscriber::fmt::MakeWriter;

const GENESIS_TIMESTAMP: u64 = 1_692_803_367;
const PERIOD_SECONDS: u64 = 3;
const ANVIL_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const FIXTURES: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../beacon/fixtures/quicknet_rounds.json"
);
const RELAY_ONE: &str = "https://relay-one.invalid";
const RELAY_TWO: &str = "https://relay-two.invalid";
const UNREACHABLE_ONE: &str = "http://127.0.0.1:1";
const UNREACHABLE_TWO: &str = "http://127.0.0.1:2";

/// Two relays for one round. The first serves a genuine beacon relabelled to its
/// neighbour's round: it parses, and its `randomness` is still the hash of its own
/// signature, so nothing short of the BLS check refuses it. The second serves the round's
/// own beacon.
struct RelabelledThenGenuine {
    round: u64,
    relabelled: String,
    genuine: String,
}

impl RelabelledThenGenuine {
    fn serve(&self, body: &str, round: u64) -> Fetched {
        if round == self.round {
            Fetched::Beacon(Beacon::from_json(body).expect("a served body parses"))
        } else {
            Fetched::NotReady
        }
    }
}

impl BeaconSource for RelabelledThenGenuine {
    async fn fetch(&self, round: u64) -> Fetched {
        self.fetch_from(round, 0).await.0
    }

    async fn fetch_from(&self, round: u64, skip: usize) -> (Fetched, Option<String>) {
        match skip {
            0 => (
                self.serve(&self.relabelled, round),
                Some(RELAY_ONE.to_owned()),
            ),
            1 => (self.serve(&self.genuine, round), Some(RELAY_TWO.to_owned())),
            _ => (
                Fetched::Exhausted {
                    failures: Vec::new(),
                },
                None,
            ),
        }
    }
}

#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn read(&self) -> String {
        let bytes = self.0.lock().expect("the capture buffer").clone();
        String::from_utf8(bytes).expect("the log lines are UTF-8")
    }
}

impl Write for Captured {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .expect("the capture buffer")
            .extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for Captured {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

#[tokio::test]
async fn a_body_that_does_not_verify_names_its_relay_and_the_next_relay_serves_the_round() {
    let raw = fs::read_to_string(FIXTURES).expect("the pinned quicknet fixtures");
    let bodies: Vec<Value> = serde_json::from_str(&raw).expect("an array of drand round bodies");
    let genuine = bodies.first().expect("a pinned round").clone();
    let mut relabelled = bodies.get(1).expect("a neighbouring pinned round").clone();
    let round = genuine["round"].as_u64().expect("round");
    relabelled["round"] = Value::from(round);
    let expected: B256 = format!("0x{}", genuine["randomness"].as_str().expect("randomness"))
        .parse()
        .expect("the pinned randomness is 32 bytes");

    let timestamp = GENESIS_TIMESTAMP + (round - 1) * PERIOD_SECONDS;
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

    env::set_var("DRAND_SIGNING_KEY", ANVIL_KEY);
    env::set_var("DRAND_RPC_URL", anvil.endpoint().as_str());
    env::set_var("DRAND_ORACLE_ADDRESS", oracle.address().to_string());
    env::set_var("DRAND_RELAYS", format!("{RELAY_ONE},{RELAY_TWO}"));
    let config = Config::from_env().expect("the environment the test just set");

    let source = RelabelledThenGenuine {
        round,
        relabelled: relabelled.to_string(),
        genuine: genuine.to_string(),
    };
    let captured = Captured::default();
    let _logs = subscriber::set_default(
        tracing_subscriber::fmt()
            .with_writer(captured.clone())
            .with_ansi(false)
            .with_max_level(Level::ERROR)
            .finish(),
    );

    let mut publisher = Publisher::new(config, source)
        .await
        .expect("the service starts from the chain's current round");
    time::timeout(Duration::from_secs(60), publisher.run_until(round))
        .await
        .expect("the round was published inside its budget")
        .expect("the loop ran without failing");

    let stored = oracle
        .randomnessOf(round)
        .call()
        .await
        .expect("the round is on chain");
    assert_eq!(stored, expected, "the genuine beacon is what landed");

    let logs = captured.read();
    assert!(
        logs.contains(RELAY_ONE),
        "the relay that served the body that does not verify is named: {logs}"
    );
    assert!(
        !logs.contains(RELAY_TWO),
        "the relay that served the genuine body is charged for nothing: {logs}"
    );
}

/// The rotation the publisher drives, at the source it drives it through: `HttpRelays`
/// lives in `drand-beacon`, whose own test target has no async runtime to await it with.
#[tokio::test]
async fn a_skip_passes_over_the_relays_already_asked() {
    let relays = HttpRelays::new(vec![UNREACHABLE_ONE.to_owned(), UNREACHABLE_TWO.to_owned()])
        .expect("a client over two relays that answer nothing");

    let asked = |outcome: (Fetched, Option<String>)| match outcome {
        (Fetched::Exhausted { failures }, None) => failures
            .into_iter()
            .map(|failure| failure.relay)
            .collect::<Vec<_>>(),
        other => panic!("relays that answer nothing exhaust the list, got {other:?}"),
    };

    assert_eq!(
        asked(relays.fetch_from(1_000, 0).await),
        vec![UNREACHABLE_ONE, UNREACHABLE_TWO]
    );
    assert_eq!(
        asked(relays.fetch_from(1_000, 1).await),
        vec![UNREACHABLE_TWO]
    );
}
