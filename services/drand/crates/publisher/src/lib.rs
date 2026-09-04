//! The chain half of the drand publisher: the oracle binding, the environment the service
//! is configured from, the revert classifier and the loop that carries one counter.

mod config;
mod disposition;
mod oracle;
mod publisher;

pub use crate::config::{Config, ConfigError};
pub use crate::disposition::{classify_revert, next_after, Disposition, Probe};
pub use crate::oracle::DrandOracle;
pub use crate::publisher::{wait_before_retry, Publisher, PublisherError};
