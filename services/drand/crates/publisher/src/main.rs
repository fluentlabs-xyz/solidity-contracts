use std::process::ExitCode;

use drand_beacon::HttpRelays;
use drand_publisher::{Config, Publisher};
use tokio::time;
use tracing::error;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env()
                .add_directive("drand_publisher=info".parse().expect("a valid directive")),
        )
        .init();

    let config = match Config::from_env() {
        Ok(config) => config,
        Err(error) => {
            error!(%error, "the publisher cannot start");
            return ExitCode::FAILURE;
        }
    };

    loop {
        match HttpRelays::new(config.relays.clone()) {
            Ok(relays) => match Publisher::new(config.clone(), relays).await {
                Ok(mut publisher) => {
                    if let Err(error) = publisher.run().await {
                        error!(%error, "the publisher lost its chain and will re-derive it");
                    }
                }
                Err(error) => error!(%error, "the publisher could not derive its counter"),
            },
            Err(error) => error!(%error, "the relay list could not be opened"),
        }
        time::sleep(config.poll_interval).await;
    }
}
