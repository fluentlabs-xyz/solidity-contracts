use std::future::Future;
use std::time::Duration;

use reqwest::Client;

use crate::error::BeaconError;
use crate::wire::Beacon;

/// drand quicknet's chain hash, the chain whose genesis, period and group key the oracle
/// hardcodes. It is part of every relay URL and is not configurable for that reason.
pub const QUICKNET_CHAIN_HASH: &str =
    "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971";

/// A relay that answers slowly is a relay that stalls the publishing loop, so a request
/// that outlives a few drand periods is treated as a failure of that relay.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// What one round's fetch produced. `NotReady` and `Exhausted` are separate outcomes:
/// the first says drand has not published the round yet, the second says no relay could
/// be asked.
#[derive(Debug)]
pub enum Fetched {
    Beacon(Beacon),
    NotReady,
    SourceError { relay: String, reason: String },
    Exhausted { failures: Vec<RelayFailure> },
}

#[derive(Debug)]
pub struct RelayFailure {
    pub relay: String,
    pub reason: String,
}

/// The relay list behind a trait, so a test can serve rounds without a network.
pub trait BeaconSource {
    fn fetch(&self, round: u64) -> impl Future<Output = Fetched> + Send;

    /// The same fetch with the first `skip` relays passed over, naming the relay that
    /// answered: a caller that refuses the body it was served can then charge that relay
    /// for it and ask the next one for the same round. The default is for a source with
    /// no list to rotate through — it names no relay and passes nothing over, so a caller
    /// learns from the missing name that this round has nowhere left to go.
    ///
    /// `Self: Sync` is what the `Send` bound on this defaulted body requires; it
    /// propagates to every caller that reaches this method through a generic parameter.
    fn fetch_from(
        &self,
        round: u64,
        _skip: usize,
    ) -> impl Future<Output = (Fetched, Option<String>)> + Send
    where
        Self: Sync,
    {
        async move { (self.fetch(round).await, None) }
    }
}

/// Map one relay's answer to an outcome, without reference to how it was obtained.
pub fn classify(relay: &str, status: u16, body: &str) -> Fetched {
    match status {
        200 => match Beacon::from_json(body) {
            Ok(beacon) => Fetched::Beacon(beacon),
            Err(error) => source_error(relay, error.to_string()),
        },
        // The live relay answers 425 for a round that does not exist yet; the published
        // API documentation promises 404 for the same state.
        404 | 425 => Fetched::NotReady,
        status => source_error(relay, format!("HTTP {status}: {body}")),
    }
}

fn source_error(relay: &str, reason: String) -> Fetched {
    Fetched::SourceError {
        relay: relay.to_owned(),
        reason,
    }
}

/// The ordered relay list, tried in turn until one answers for the round.
pub struct HttpRelays {
    client: Client,
    relays: Vec<String>,
}

impl HttpRelays {
    pub fn new(relays: Vec<String>) -> Result<Self, BeaconError> {
        let client = Client::builder().timeout(REQUEST_TIMEOUT).build()?;
        Ok(Self { client, relays })
    }

    async fn ask(&self, relay: &str, round: u64) -> Fetched {
        let url = format!(
            "{}/{QUICKNET_CHAIN_HASH}/public/{round}",
            relay.trim_end_matches('/')
        );
        let response = match self.client.get(url).send().await {
            Ok(response) => response,
            Err(error) => return source_error(relay, error.to_string()),
        };
        let status = response.status().as_u16();
        match response.text().await {
            Ok(body) => classify(relay, status, &body),
            Err(error) => source_error(relay, error.to_string()),
        }
    }
}

impl BeaconSource for HttpRelays {
    async fn fetch(&self, round: u64) -> Fetched {
        self.fetch_from(round, 0).await.0
    }

    async fn fetch_from(&self, round: u64, skip: usize) -> (Fetched, Option<String>) {
        let mut failures = Vec::new();
        for relay in self.relays.iter().skip(skip) {
            match self.ask(relay, round).await {
                Fetched::SourceError { relay, reason } => {
                    failures.push(RelayFailure { relay, reason })
                }
                answered => return (answered, Some(relay.clone())),
            }
        }
        (Fetched::Exhausted { failures }, None)
    }
}
