use serde::Deserialize;

use crate::error::BeaconError;
use crate::hex;

pub const SIGNATURE_BYTES: usize = 48;
pub const RANDOMNESS_BYTES: usize = 32;

/// One quicknet round as a relay serves it: the round number, the beacon's compressed
/// G1 signature, and drand's own sha256 of that signature.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Beacon {
    pub round: u64,
    pub randomness: [u8; RANDOMNESS_BYTES],
    pub signature: [u8; SIGNATURE_BYTES],
}

#[derive(Deserialize)]
struct RoundBody {
    round: u64,
    randomness: String,
    signature: String,
}

impl Beacon {
    pub fn from_json(body: &str) -> Result<Self, BeaconError> {
        let body: RoundBody = serde_json::from_str(body)?;
        Ok(Self {
            round: body.round,
            randomness: hex::decode("randomness", &body.randomness)?,
            signature: hex::decode("signature", &body.signature)?,
        })
    }
}
