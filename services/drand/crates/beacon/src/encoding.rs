use blst::min_sig::Signature;

use crate::error::BeaconError;
use crate::wire::SIGNATURE_BYTES;

/// EIP-2537 encodes a base field element in 64 bytes — 16 zero bytes then the 48-byte
/// big-endian coordinate — so a G1 point is `pad16 ‖ x[48] ‖ pad16 ‖ y[48]`, and the
/// zero padding is checked by the precompiles.
/// <https://eips.ethereum.org/EIPS/eip-2537>
pub const POINT_BYTES: usize = 128;

const COORDINATE_BYTES: usize = 48;
const PAD_BYTES: usize = 16;
const X_AT: usize = PAD_BYTES;
const Y_AT: usize = 2 * PAD_BYTES + COORDINATE_BYTES;

/// A coordinate is smaller than the 381-bit base field modulus, so the three high bits
/// of its leading byte belong to ZCash's compression flags rather than to the number;
/// EIP-2537 takes the bare integer and rejects anything above the modulus.
const COORDINATE_MASK: u8 = 0x1f;

pub fn uncompress_g1(compressed: &[u8]) -> Result<[u8; POINT_BYTES], BeaconError> {
    let serialized = parse_signature(compressed)?.serialize();
    let (x, y) = serialized.split_at(COORDINATE_BYTES);

    let mut point = [0u8; POINT_BYTES];
    point[X_AT..X_AT + COORDINATE_BYTES].copy_from_slice(x);
    point[Y_AT..Y_AT + COORDINATE_BYTES].copy_from_slice(y);
    point[X_AT] &= COORDINATE_MASK;
    point[Y_AT] &= COORDINATE_MASK;
    Ok(point)
}

pub fn compress_g1(point: &[u8]) -> Result<[u8; SIGNATURE_BYTES], BeaconError> {
    if point.len() != POINT_BYTES {
        return Err(BeaconError::PointWidth {
            actual: point.len(),
        });
    }
    let padded = point[..X_AT]
        .iter()
        .chain(&point[X_AT + COORDINATE_BYTES..Y_AT])
        .all(|byte| *byte == 0);
    if !padded {
        return Err(BeaconError::PointPadding);
    }

    let mut serialized = [0u8; 2 * COORDINATE_BYTES];
    serialized[..COORDINATE_BYTES].copy_from_slice(&point[X_AT..X_AT + COORDINATE_BYTES]);
    serialized[COORDINATE_BYTES..].copy_from_slice(&point[Y_AT..Y_AT + COORDINATE_BYTES]);
    Ok(Signature::deserialize(&serialized)
        .map_err(BeaconError::from_blst)?
        .compress())
}

pub(crate) fn parse_signature(compressed: &[u8]) -> Result<Signature, BeaconError> {
    Signature::sig_validate(compressed, true).map_err(BeaconError::from_blst)
}
