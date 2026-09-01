//! Spec test for design.md:265 — every revert reachable on the publish path classifies to
//! the response D8 gives it (per R5: an already-published round is skipped without an error
//! and without retry; per R7: no revert is fatal, each one has a named continuation).

use drand_publisher::{classify_revert, Disposition, Probe};

/// Revert data as the node returns it: the 4-byte selector followed by the error's
/// ABI-encoded arguments, whose values none of these decisions depends on.
fn revert(selector: &str, words: usize) -> Vec<u8> {
    let mut data: Vec<u8> = (0..8)
        .step_by(2)
        .map(|i| u8::from_str_radix(&selector[i..i + 2], 16).expect("hex"))
        .collect();
    data.resize(4 + 32 * words, 0);
    data
}

#[test]
fn each_reachable_selector_maps_to_its_row() {
    let cases = [
        // Someone else got there first: advance, not an error and not a retry.
        ("affe132d", 1, Disposition::Advance),
        // The chain clock lags drand: hold the round.
        ("21a99841", 2, Disposition::Retry),
        // The counter fell behind the ring: resume from the chain's current round.
        ("395f4fd6", 2, Disposition::Resync),
        // Impossible after local verification, so a bug here: count it and move on.
        ("d615d706", 2, Disposition::Advance),
        ("dc5fdae5", 1, Disposition::Advance),
        ("5a3dde75", 0, Disposition::Advance),
        // Properties of the chain, not of the round: stop submitting and probe.
        ("84e81692", 0, Disposition::Halt(Probe::VerifyRound)),
        ("8f4711c2", 2, Disposition::Halt(Probe::CurrentRound)),
        // Anything unrecognised.
        ("deadbeef", 0, Disposition::Advance),
    ];

    for (selector, words, expected) in cases {
        assert_eq!(
            classify_revert(&revert(selector, words)),
            expected,
            "selector 0x{selector}"
        );
    }
}
