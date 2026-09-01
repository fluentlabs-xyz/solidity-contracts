//! drand quicknet beacons, from a relay's JSON to the 128 bytes the oracle's
//! `publish(uint64,bytes)` accepts — everything that is true without a chain.

mod encoding;
mod error;
mod hash;
mod hex;
mod source;
mod verify;
mod wire;

pub use crate::encoding::{compress_g1, uncompress_g1, POINT_BYTES};
pub use crate::error::BeaconError;
pub use crate::source::{
    classify, BeaconSource, Fetched, HttpRelays, RelayFailure, QUICKNET_CHAIN_HASH,
};
pub use crate::verify::verify;
pub use crate::wire::{Beacon, RANDOMNESS_BYTES, SIGNATURE_BYTES};

use crate::hash::sha256;

/// Take a fetched round to the bytes `publish` accepts, or refuse it.
///
/// Two independent checks stand between a relay's body and a transaction: the beacon
/// verifies against the pinned quicknet key, and re-compressing the encoded point
/// reproduces the hash the contract will store — which is drand's own `randomness`
/// field, so a padding or ordering slip cannot survive it.
pub fn submittable_payload(beacon: &Beacon) -> Result<[u8; POINT_BYTES], BeaconError> {
    verify(beacon)?;

    let point = uncompress_g1(&beacon.signature)?;
    if sha256(&compress_g1(&point)?) != beacon.randomness {
        return Err(BeaconError::RandomnessMismatch {
            round: beacon.round,
        });
    }
    Ok(point)
}
