use std::error::Error;
use std::fmt::{self, Display};
use std::time::Duration;

use alloy::consensus::Transaction as _;
use alloy::contract::Error as ContractError;
use alloy::hex;
use alloy::network::{Ethereum, ReceiptResponse as _};
use alloy::primitives::{Address, Bytes, TxHash};
use alloy::providers::{DynProvider, PendingTransactionBuilder, Provider, ProviderBuilder};
use alloy::rpc::types::{TransactionReceipt, TransactionRequest};
use alloy::sol_types::SolInterface;
use alloy::transports::TransportError;
use drand_beacon::{submittable_payload, Beacon, BeaconError, BeaconSource, Fetched, RelayFailure};
use tokio::time;
use tracing::{debug, error, info, warn};

use crate::config::Config;
use crate::disposition::{classify_revert, next_after, Disposition, Probe};
use crate::oracle::DrandOracle::{DrandOracleErrors, DrandOracleInstance};

/// A link failure that outlasts this cap is an interruption rather than a hiccup, and the
/// counter is re-derived from the chain on the way out of it instead of resumed.
const BACKOFF_CAP: Duration = Duration::from_secs(60);

/// The one outstanding transaction, kept whole so a resubmission can reuse its calldata
/// and a late receipt can still be attributed to its round.
struct Submission {
    round: u64,
    payload: Bytes,
    request: TransactionRequest,
}

/// Why the loop stopped submitting, and the argument its probe needs.
enum Halt {
    Precompiles { round: u64, payload: Bytes },
    Genesis,
}

/// How a chain interaction failed, before any decision is taken about it.
enum Failure {
    Reverted(Bytes),
    Balance(String),
    Link(String),
    Broken(String),
}

#[derive(Clone, Copy, Debug, Default)]
struct Counters {
    published: u64,
    already_published: u64,
    rejected: u64,
    unserviceable: u64,
    exhausted: u64,
    resyncs: u64,
    starved: u64,
}

/// The publishing loop: one counter, one outstanding transaction, no persisted state.
pub struct Publisher<S> {
    source: S,
    provider: DynProvider,
    oracle: DrandOracleInstance<DynProvider>,
    address: Address,
    poll_interval: Duration,
    pending_timeout: Duration,
    backoff: Duration,
    genesis_timestamp: u64,
    period_seconds: u64,
    relay_count: usize,
    unverified: usize,
    next: u64,
    halted: Option<Halt>,
    resync_due: bool,
    counters: Counters,
}

impl<S: BeaconSource> Publisher<S> {
    /// Connect to the chain and derive the counter from the oracle's own `currentRound()`,
    /// which is also what an interrupted service resumes from.
    pub async fn new(config: Config, source: S) -> Result<Self, PublisherError> {
        let Config {
            signer,
            rpc_url,
            oracle: address,
            relays,
            poll_interval,
            pending_timeout,
        } = config;

        // The nonce is read from the node per transaction rather than cached: a cached
        // nonce advances before broadcast, and this loop's routine failure — a gas
        // estimate that reverts `RoundInFuture` because the chain clock has not reached
        // the round — would leave a gap the manager never closes. One transaction is
        // outstanding at a time, so there is nothing for a cache to reserve against.
        let provider = ProviderBuilder::default()
            .with_gas_estimation()
            .with_simple_nonce_management()
            .fetch_chain_id()
            .wallet(signer)
            .connect_http(rpc_url)
            .erased();
        let oracle = DrandOracleInstance::new(address, provider.clone());

        let genesis_timestamp = oracle
            .GENESIS_TIMESTAMP()
            .call()
            .await
            .map_err(|error| PublisherError::from_contract(address, &error))?;
        let period_seconds = oracle
            .PERIOD_SECONDS()
            .call()
            .await
            .map_err(|error| PublisherError::from_contract(address, &error))?;
        let next = oracle
            .currentRound()
            .call()
            .await
            .map_err(|error| PublisherError::from_contract(address, &error))?;

        info!(
            oracle = %address,
            next,
            genesis_timestamp,
            period_seconds,
            "the publisher starts from the chain's current round"
        );
        Ok(Self {
            source,
            provider,
            oracle,
            address,
            poll_interval,
            pending_timeout,
            backoff: poll_interval,
            genesis_timestamp,
            period_seconds: period_seconds.max(1),
            relay_count: relays.len().max(1),
            unverified: 0,
            next,
            halted: None,
            resync_due: false,
            counters: Counters::default(),
        })
    }

    /// Publish for as long as the process lives.
    pub async fn run(&mut self) -> Result<(), PublisherError> {
        loop {
            self.tick().await?;
        }
    }

    /// Publish until the counter has passed `last_round`.
    pub async fn run_until(&mut self, last_round: u64) -> Result<(), PublisherError> {
        while self.next <= last_round {
            self.tick().await?;
        }
        Ok(())
    }

    async fn tick(&mut self) -> Result<(), PublisherError> {
        if self.resync_due {
            return self.resync().await;
        }
        if self.halted.is_some() {
            return self.probe().await;
        }

        let round = self.next;
        match self.source.fetch(round).await {
            Fetched::Beacon(beacon) => self.attempt(beacon).await,
            Fetched::NotReady => {
                debug!(round, "drand has not published this round yet");
                self.wait().await;
                Ok(())
            }
            Fetched::SourceError { relay, reason } => {
                warn!(round, relay, reason, "a relay failed for this round");
                self.wait().await;
                Ok(())
            }
            Fetched::Exhausted { failures } => {
                self.counters.exhausted += 1;
                warn!(
                    round,
                    relays = %describe(&failures),
                    exhausted = self.counters.exhausted,
                    "every relay failed for this round; holding the counter"
                );
                self.wait().await;
                Ok(())
            }
        }
    }

    async fn attempt(&mut self, beacon: Beacon) -> Result<(), PublisherError> {
        let round = beacon.round;
        let payload = match submittable_payload(&beacon) {
            Ok(payload) => Bytes::copy_from_slice(&payload),
            Err(error) => return self.unverifiable(round, &error).await,
        };

        let request = self
            .oracle
            .publish(round, payload.clone())
            .into_transaction_request();
        let submission = Submission {
            round,
            payload,
            request,
        };
        match self
            .provider
            .send_transaction(submission.request.clone())
            .await
        {
            Ok(pending) => self.settle(&submission, pending).await,
            Err(error) => {
                self.failed(&submission, classify_transport_error(&error))
                    .await
            }
        }
    }

    /// Wait out the one outstanding transaction, resubmitting it at a raised fee if it
    /// neither confirms nor reverts in time.
    async fn settle(
        &mut self,
        submission: &Submission,
        mut pending: PendingTransactionBuilder<Ethereum>,
    ) -> Result<(), PublisherError> {
        loop {
            let hash = *pending.tx_hash();
            match time::timeout(self.pending_timeout, pending.get_receipt()).await {
                Ok(Ok(receipt)) => return self.mined(submission, receipt).await,
                Ok(Err(error)) => {
                    self.wait_backoff(&error.to_string()).await;
                    return Ok(());
                }
                Err(_elapsed) => match self.resubmit(submission, hash).await? {
                    Some(resent) => pending = resent,
                    None => return Ok(()),
                },
            }
        }
    }

    async fn mined(
        &mut self,
        submission: &Submission,
        receipt: TransactionReceipt,
    ) -> Result<(), PublisherError> {
        self.backoff = self.poll_interval;
        let round = submission.round;
        if !receipt.status() {
            warn!(
                round,
                hash = %receipt.transaction_hash(),
                "the publish transaction reverted after inclusion"
            );
            let outcome = match self.provider.call(submission.request.clone()).await {
                Ok(_) => Ok(()),
                Err(error) => {
                    self.failed(submission, classify_transport_error(&error))
                        .await
                }
            };
            self.wait().await;
            return outcome;
        }

        self.counters.published += 1;
        self.advance();
        let drift = self.drift(&receipt).await;
        info!(
            round,
            drift,
            published = self.counters.published,
            "the round is on chain"
        );
        Ok(())
    }

    /// How far the counter trails the round the including block's clock implies. The
    /// receipt carries the block, not its timestamp, so the header supplies the clock.
    async fn drift(&self, receipt: &TransactionReceipt) -> u64 {
        let Some(number) = receipt.block_number() else {
            return 0;
        };
        let Ok(Some(block)) = self.provider.get_block_by_number(number.into()).await else {
            return 0;
        };
        let elapsed = block
            .header
            .timestamp
            .saturating_sub(self.genesis_timestamp);
        (elapsed / self.period_seconds + 1).saturating_sub(self.next)
    }

    async fn resubmit(
        &mut self,
        submission: &Submission,
        hash: TxHash,
    ) -> Result<Option<PendingTransactionBuilder<Ethereum>>, PublisherError> {
        warn!(
            round = submission.round,
            %hash,
            "the transaction has not settled within the pending timeout; resubmitting at a raised fee"
        );
        let sent = match self.provider.get_transaction_by_hash(hash).await {
            Ok(Some(sent)) => sent,
            Ok(None) => return self.recheck(submission, hash).await.map(|()| None),
            Err(error) => {
                self.wait_backoff(&error.to_string()).await;
                return Ok(None);
            }
        };

        let replacement = submission
            .request
            .clone()
            .nonce(sent.nonce())
            .max_fee_per_gas(raised(sent.max_fee_per_gas()))
            .max_priority_fee_per_gas(raised(sent.max_priority_fee_per_gas().unwrap_or_default()));
        match self.provider.send_transaction(replacement).await {
            Ok(pending) => Ok(Some(pending)),
            Err(error) => {
                warn!(
                    round = submission.round,
                    %error,
                    "the resubmission was rejected; re-reading the original's receipt"
                );
                self.recheck(submission, hash).await.map(|()| None)
            }
        }
    }

    async fn recheck(
        &mut self,
        submission: &Submission,
        hash: TxHash,
    ) -> Result<(), PublisherError> {
        match self.provider.get_transaction_receipt(hash).await {
            Ok(Some(receipt)) => self.mined(submission, receipt).await,
            Ok(None) => {
                self.wait_backoff("the resubmission was rejected and the original is not mined")
                    .await;
                Ok(())
            }
            Err(error) => {
                self.wait_backoff(&error.to_string()).await;
                Ok(())
            }
        }
    }

    async fn failed(
        &mut self,
        submission: &Submission,
        failure: Failure,
    ) -> Result<(), PublisherError> {
        match failure {
            Failure::Reverted(data) => self.reverted(submission, &data).await,
            Failure::Balance(reason) => {
                self.counters.starved += 1;
                error!(
                    round = submission.round,
                    reason,
                    attempts = self.counters.starved,
                    "the signer cannot pay for this publish; the round waits for a top-up"
                );
                self.wait().await;
                Ok(())
            }
            Failure::Link(message) => {
                self.wait_backoff(&message).await;
                Ok(())
            }
            Failure::Broken(message) => Err(PublisherError::Oracle(format!(
                "{} does not answer the DrandOracle ABI: {message}",
                self.address
            ))),
        }
    }

    async fn reverted(
        &mut self,
        submission: &Submission,
        data: &Bytes,
    ) -> Result<(), PublisherError> {
        self.backoff = self.poll_interval;
        let round = submission.round;
        match classify_revert(data) {
            Disposition::Advance => {
                match DrandOracleErrors::abi_decode(data) {
                    Ok(DrandOracleErrors::RoundAlreadyPublished(_)) => {
                        self.counters.already_published += 1;
                        debug!(
                            round,
                            already_published = self.counters.already_published,
                            "another publisher got there first"
                        );
                    }
                    Ok(error) => {
                        self.counters.rejected += 1;
                        error!(
                            round,
                            selector = %hex::encode_prefixed(error.selector()),
                            rejected = self.counters.rejected,
                            "the chain rejected a beacon that verified locally"
                        );
                    }
                    Err(_) => {
                        self.counters.rejected += 1;
                        error!(
                            round,
                            data = %data,
                            rejected = self.counters.rejected,
                            "the chain reverted with an error this service does not know"
                        );
                    }
                }
                self.advance();
            }
            Disposition::Retry => {
                debug!(round, "the chain clock has not reached this round yet");
                self.wait().await;
            }
            Disposition::Resync => {
                warn!(
                    round,
                    "the counter fell behind the chain's retention window"
                );
                self.resync_due = true;
            }
            Disposition::Halt(probe) => {
                self.halt(probe, submission);
                self.wait().await;
            }
        }
        Ok(())
    }

    fn halt(&mut self, probe: Probe, submission: &Submission) {
        match probe {
            Probe::VerifyRound => {
                error!(
                    oracle = %self.address,
                    "the chain has no EIP-2537 precompiles, so no beacon can be published on it"
                );
                self.halted = Some(Halt::Precompiles {
                    round: submission.round,
                    payload: submission.payload.clone(),
                });
            }
            Probe::CurrentRound => {
                error!(
                    oracle = %self.address,
                    "the chain clock is below drand's genesis, so the oracle has no window yet"
                );
                self.halted = Some(Halt::Genesis);
            }
        }
    }

    /// Ask the chain, once per interval, whether the property that stopped the loop still
    /// holds. Anything short of a definite answer keeps the halt.
    async fn probe(&mut self) -> Result<(), PublisherError> {
        let lifted = match &self.halted {
            Some(Halt::Precompiles { round, payload }) => {
                match self
                    .oracle
                    .verifyRound(*round, payload.clone())
                    .call()
                    .await
                {
                    Ok(_) => true,
                    Err(error) => match classify_contract_error(&error) {
                        Failure::Reverted(data) => {
                            classify_revert(&data) != Disposition::Halt(Probe::VerifyRound)
                        }
                        _ => false,
                    },
                }
            }
            Some(Halt::Genesis) => self.oracle.currentRound().call().await.is_ok(),
            None => true,
        };

        if !lifted {
            self.wait().await;
            return Ok(());
        }
        info!("the chain answers again; the counter is re-derived from it");
        self.halted = None;
        self.resync_due = true;
        Ok(())
    }

    /// Re-derive the counter from `currentRound()` — the same read startup makes, and the
    /// only place the loop performs one.
    async fn resync(&mut self) -> Result<(), PublisherError> {
        let current = match self.oracle.currentRound().call().await {
            Ok(current) => current,
            Err(error) => {
                return match classify_contract_error(&error) {
                    Failure::Reverted(data) => match classify_revert(&data) {
                        Disposition::Halt(Probe::CurrentRound) => {
                            self.halted = Some(Halt::Genesis);
                            self.resync_due = false;
                            error!(
                                oracle = %self.address,
                                "the chain clock is below drand's genesis, so the counter has no value to take"
                            );
                            self.wait().await;
                            Ok(())
                        }
                        _ => Err(PublisherError::Oracle(format!(
                            "{}'s currentRound() reverted with {data}",
                            self.address
                        ))),
                    },
                    Failure::Broken(message) => Err(PublisherError::Oracle(format!(
                        "{} does not answer the DrandOracle ABI: {message}",
                        self.address
                    ))),
                    Failure::Balance(message) | Failure::Link(message) => {
                        self.wait_backoff(&message).await;
                        Ok(())
                    }
                };
            }
        };

        self.backoff = self.poll_interval;
        self.resync_due = false;
        self.counters.resyncs += 1;
        let skipped = current.saturating_sub(self.next);
        warn!(
            from = self.next,
            to = current,
            skipped,
            resyncs = self.counters.resyncs,
            "the counter resumes from the chain's current round; the rounds between are not back-filled"
        );
        self.set_next(next_after(self.next, Disposition::Resync, current));
        Ok(())
    }

    /// A body the relay chose, so the relay is charged for it first: the round is retried
    /// while another relay could still serve it, and only declared unserviceable once the
    /// list has had as many attempts as it has relays.
    async fn unverifiable(
        &mut self,
        round: u64,
        error: &BeaconError,
    ) -> Result<(), PublisherError> {
        self.unverified += 1;
        error!(
            round,
            %error,
            attempt = self.unverified,
            relays = self.relay_count,
            "a relay served a body that does not verify"
        );
        if self.unverified >= self.relay_count {
            self.counters.unserviceable += 1;
            warn!(
                round,
                unserviceable = self.counters.unserviceable,
                "no relay served a body for this round that verifies; leaving it behind"
            );
            self.advance();
        }
        self.wait().await;
        Ok(())
    }

    fn advance(&mut self) {
        self.set_next(next_after(self.next, Disposition::Advance, self.next));
    }

    fn set_next(&mut self, next: u64) {
        if next != self.next {
            self.next = next;
            self.unverified = 0;
        }
    }

    async fn wait(&self) {
        time::sleep(self.poll_interval).await;
    }

    async fn wait_backoff(&mut self, reason: &str) {
        let delay = self.backoff;
        warn!(
            reason,
            delay_seconds = delay.as_secs(),
            "the chain link failed; backing off"
        );
        time::sleep(delay).await;
        if delay >= BACKOFF_CAP {
            self.resync_due = true;
            self.backoff = self.poll_interval;
        } else {
            self.backoff = (delay * 2).min(BACKOFF_CAP);
        }
    }
}

/// Neither of these is a failure the loop can retry its way out of, so both leave it.
#[derive(Debug)]
pub enum PublisherError {
    /// The chain would not answer while the counter was being derived from it.
    Startup(String),
    /// The configured address does not answer the oracle's ABI.
    Oracle(String),
}

impl PublisherError {
    fn from_contract(address: Address, error: &ContractError) -> Self {
        match classify_contract_error(error) {
            Failure::Broken(message) => Self::Oracle(format!(
                "{address} does not answer the DrandOracle ABI: {message}"
            )),
            Failure::Reverted(data) => Self::Startup(format!("{address} reverted with {data}")),
            Failure::Balance(message) | Failure::Link(message) => Self::Startup(message),
        }
    }
}

impl Display for PublisherError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Startup(message) => {
                write!(formatter, "the chain did not answer at startup: {message}")
            }
            Self::Oracle(message) => write!(formatter, "{message}"),
        }
    }
}

impl Error for PublisherError {}

fn classify_contract_error(error: &ContractError) -> Failure {
    match error {
        ContractError::TransportError(transport) => classify_transport_error(transport),
        ContractError::PendingTransactionError(pending) => Failure::Link(pending.to_string()),
        other => Failure::Broken(other.to_string()),
    }
}

fn classify_transport_error(error: &TransportError) -> Failure {
    if let Some(payload) = error.as_error_resp() {
        if let Some(data) = payload.as_revert_data() {
            return Failure::Reverted(data);
        }
        if payload
            .message
            .to_lowercase()
            .contains("insufficient funds")
        {
            return Failure::Balance(payload.message.to_string());
        }
    }
    Failure::Link(error.to_string())
}

/// A replacement transaction has to outbid the one it replaces by a margin no node
/// publishes, so the fee is doubled rather than nudged.
fn raised(fee: u128) -> u128 {
    fee.saturating_mul(2).max(1)
}

fn describe(failures: &[RelayFailure]) -> String {
    failures
        .iter()
        .map(|failure| format!("{}: {}", failure.relay, failure.reason))
        .collect::<Vec<_>>()
        .join("; ")
}
