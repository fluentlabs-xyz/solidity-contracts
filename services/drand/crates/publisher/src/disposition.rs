use alloy::sol_types::SolError;

use crate::oracle::DrandOracle::{
    InfinityPoint, InvalidSignature, InvalidSignatureLength, PrecompileFailed,
    RoundAlreadyPublished, RoundInFuture, RoundTooOld, TimestampBeforeGenesis,
};

/// What one attempt at a round says about the loop's counter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    /// The round is settled — by us, by another publisher, or beyond this service's repair.
    Advance,
    /// The round is still ours to publish and nothing about it has changed.
    Retry,
    /// The counter is outside the chain's window and has to be re-derived from it.
    Resync,
    /// The chain, not the round, is what failed. Stop submitting and watch it.
    Halt(Probe),
}

/// The view a halted loop calls once per poll interval to learn whether the chain
/// property that stopped it still holds. `currentRound` is timestamp arithmetic and
/// answers on a chain with no EIP-2537 precompiles at all, so it cannot detect their
/// absence; `verifyRound` runs the same pairing path `publish` does and keeps reverting
/// exactly while they are missing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Probe {
    VerifyRound,
    CurrentRound,
}

/// Where the counter lands after one attempt. `current` is the chain's `currentRound()`,
/// which only a resync consults.
pub fn next_after(next: u64, disposition: Disposition, current: u64) -> u64 {
    match disposition {
        Disposition::Advance => next + 1,
        Disposition::Retry | Disposition::Halt(_) => next,
        Disposition::Resync => current,
    }
}

/// Classify the revert data a failed `publish` came back with.
///
/// `InvalidSignature`, `InvalidSignatureLength` and `InfinityPoint` are unreachable once
/// the beacon crate has accepted a payload, so each is a defect here rather than a state
/// a retry could change, and leaves the round behind like an already-published one. An
/// unrecognised selector — including empty revert data — is treated the same way: one
/// unexplained round must not stall every round behind it.
pub fn classify_revert(data: &[u8]) -> Disposition {
    const ROWS: [([u8; 4], Disposition); 8] = [
        (RoundAlreadyPublished::SELECTOR, Disposition::Advance),
        (RoundInFuture::SELECTOR, Disposition::Retry),
        (RoundTooOld::SELECTOR, Disposition::Resync),
        (InvalidSignature::SELECTOR, Disposition::Advance),
        (InvalidSignatureLength::SELECTOR, Disposition::Advance),
        (InfinityPoint::SELECTOR, Disposition::Advance),
        (
            PrecompileFailed::SELECTOR,
            Disposition::Halt(Probe::VerifyRound),
        ),
        (
            TimestampBeforeGenesis::SELECTOR,
            Disposition::Halt(Probe::CurrentRound),
        ),
    ];

    let Some(&selector) = data.first_chunk::<4>() else {
        return Disposition::Advance;
    };
    ROWS.iter()
        .find(|(known, _)| *known == selector)
        .map_or(Disposition::Advance, |(_, disposition)| *disposition)
}
