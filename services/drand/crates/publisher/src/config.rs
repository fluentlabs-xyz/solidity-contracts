use std::env::{self, VarError};
use std::error::Error;
use std::fmt::{self, Display};
use std::str::FromStr;
use std::time::Duration;

use alloy::primitives::Address;
use alloy::signers::local::PrivateKeySigner;
use alloy::transports::http::reqwest::Url;

const SIGNING_KEY: &str = "DRAND_SIGNING_KEY";
const RPC_URL: &str = "DRAND_RPC_URL";
const ORACLE_ADDRESS: &str = "DRAND_ORACLE_ADDRESS";
const RELAYS: &str = "DRAND_RELAYS";
const POLL_INTERVAL: &str = "DRAND_POLL_INTERVAL_SECONDS";
const PENDING_TIMEOUT: &str = "DRAND_PENDING_TIMEOUT_SECONDS";

const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(3);
const DEFAULT_PENDING_TIMEOUT: Duration = Duration::from_secs(30);

/// Everything the service reads from its process environment, read once at startup.
#[derive(Clone)]
pub struct Config {
    pub signer: PrivateKeySigner,
    pub rpc_url: Url,
    pub oracle: Address,
    pub relays: Vec<String>,
    pub poll_interval: Duration,
    pub pending_timeout: Duration,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let mut problems = Vec::new();

        let signer = required(SIGNING_KEY, &mut problems)
            .and_then(|raw| parsed::<PrivateKeySigner>(SIGNING_KEY, &raw, &mut problems));
        let rpc_url = required(RPC_URL, &mut problems)
            .and_then(|raw| parsed::<Url>(RPC_URL, &raw, &mut problems));
        let oracle = required(ORACLE_ADDRESS, &mut problems)
            .and_then(|raw| parsed::<Address>(ORACLE_ADDRESS, &raw, &mut problems));
        let relays = required(RELAYS, &mut problems).and_then(|raw| {
            let relays: Vec<String> = raw
                .split(',')
                .map(str::trim)
                .filter(|relay| !relay.is_empty())
                .map(str::to_owned)
                .collect();
            if relays.is_empty() {
                problems.push(format!("{RELAYS} lists no relay"));
                return None;
            }
            Some(relays)
        });
        let poll_interval = seconds(POLL_INTERVAL, DEFAULT_POLL_INTERVAL, &mut problems);
        let pending_timeout = seconds(PENDING_TIMEOUT, DEFAULT_PENDING_TIMEOUT, &mut problems);

        match (signer, rpc_url, oracle, relays) {
            (Some(signer), Some(rpc_url), Some(oracle), Some(relays)) if problems.is_empty() => {
                Ok(Self {
                    signer,
                    rpc_url,
                    oracle,
                    relays,
                    poll_interval,
                    pending_timeout,
                })
            }
            _ => Err(ConfigError { problems }),
        }
    }
}

/// The signing key is the one field a derived `Debug` would print, so this one names the
/// address it signs as instead.
impl fmt::Debug for Config {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Config")
            .field("signer", &self.signer.address())
            .field("rpc_url", &self.rpc_url.as_str())
            .field("oracle", &self.oracle)
            .field("relays", &self.relays)
            .field("poll_interval", &self.poll_interval)
            .field("pending_timeout", &self.pending_timeout)
            .finish()
    }
}

/// Every variable the environment failed to supply, so one startup names them all.
#[derive(Debug)]
pub struct ConfigError {
    problems: Vec<String>,
}

impl Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "the environment does not configure the publisher: {}",
            self.problems.join("; ")
        )
    }
}

impl Error for ConfigError {}

fn required(key: &str, problems: &mut Vec<String>) -> Option<String> {
    match env::var(key) {
        Ok(value) => Some(value),
        Err(VarError::NotPresent) => {
            problems.push(format!("{key} is not set"));
            None
        }
        Err(VarError::NotUnicode(_)) => {
            problems.push(format!("{key} is not valid UTF-8"));
            None
        }
    }
}

fn parsed<T: FromStr>(key: &str, raw: &str, problems: &mut Vec<String>) -> Option<T>
where
    T::Err: Display,
{
    match raw.trim().parse() {
        Ok(value) => Some(value),
        Err(error) => {
            problems.push(format!("{key} is not readable: {error}"));
            None
        }
    }
}

fn seconds(key: &str, default: Duration, problems: &mut Vec<String>) -> Duration {
    match env::var(key) {
        Err(VarError::NotPresent) => default,
        Err(VarError::NotUnicode(_)) => {
            problems.push(format!("{key} is not valid UTF-8"));
            default
        }
        Ok(raw) => parsed::<u64>(key, &raw, problems)
            .map(Duration::from_secs)
            .unwrap_or(default),
    }
}
