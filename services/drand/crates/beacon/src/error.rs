use blst::BLST_ERROR;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum BeaconError {
    #[error("the body is not a drand round: {0}")]
    Body(#[from] serde_json::Error),

    #[error("`{field}` is not hex")]
    NotHex { field: &'static str },

    #[error("`{field}` decodes to {actual} bytes, not {expected}")]
    Width {
        field: &'static str,
        expected: usize,
        actual: usize,
    },

    #[error("the signature is not a well-formed compressed G1 point")]
    SignatureEncoding,

    #[error("the signature is not a point on G1")]
    SignatureNotOnCurve,

    #[error("the signature is outside the G1 subgroup")]
    SignatureNotInSubgroup,

    #[error("the signature is the point at infinity")]
    SignatureIsInfinity,

    #[error("the signature does not verify for round {round} under the pinned quicknet key")]
    SignatureMismatch { round: u64 },

    #[error("blst reported {code:?}")]
    Blst { code: BLST_ERROR },

    #[error("an EIP-2537 G1 point is 128 bytes, not {actual}")]
    PointWidth { actual: usize },

    #[error("an EIP-2537 coordinate's 16 high bytes must be zero")]
    PointPadding,

    #[error("round {round}'s randomness is not sha256 of the signature the relay served")]
    RandomnessMismatch { round: u64 },

    #[error(transparent)]
    Transport(#[from] reqwest::Error),
}

impl BeaconError {
    pub(crate) fn from_blst(code: BLST_ERROR) -> Self {
        match code {
            BLST_ERROR::BLST_BAD_ENCODING => Self::SignatureEncoding,
            BLST_ERROR::BLST_POINT_NOT_ON_CURVE => Self::SignatureNotOnCurve,
            BLST_ERROR::BLST_POINT_NOT_IN_GROUP => Self::SignatureNotInSubgroup,
            BLST_ERROR::BLST_PK_IS_INFINITY => Self::SignatureIsInfinity,
            code => Self::Blst { code },
        }
    }
}
