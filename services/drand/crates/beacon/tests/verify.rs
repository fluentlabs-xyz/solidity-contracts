//! Spec test for design.md:252 — a beacon is verified locally against the pinned quicknet
//! key before any gas is spent (per R2), and the round is part of the signed message, so a
//! real signature served under another round number does not verify.
//!
//! Pinned vector: drand quicknet round 1000 from `api.drand.sh`.

use drand_beacon::{verify, Beacon};

const SIGNATURE_1000: &str =
    "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
const RANDOMNESS_1000: &str = "fe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd";

fn body(round: u64) -> String {
    format!(
        r#"{{"round":{round},"randomness":"{RANDOMNESS_1000}","signature":"{SIGNATURE_1000}"}}"#
    )
}

#[test]
fn verifies_the_real_round_and_rejects_the_same_signature_under_another_round() {
    let genuine = Beacon::from_json(&body(1000)).expect("body parses");
    verify(&genuine).expect("round 1000's real quicknet beacon verifies against the pinned key");

    let relabelled = Beacon::from_json(&body(1001)).expect("body parses");
    assert!(
        verify(&relabelled).is_err(),
        "round 1000's signature must not verify as round 1001"
    );
}
