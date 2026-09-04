//! Spec test for design.md:256 — the relay's HTTP status is classified into readiness,
//! a body, or a source error naming the relay (per R1: the service polls the next round
//! until the API serves it; per R7: a bad response is surfaced, not fatal).

use drand_beacon::{classify, Fetched};

const RELAY_A: &str = "https://api.drand.sh";
const RELAY_B: &str = "https://api2.drand.sh";
const BODY_1000: &str = r#"{"round":1000,"randomness":"fe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd","signature":"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39"}"#;

#[test]
fn a_future_round_is_not_ready_a_served_round_is_a_body_and_anything_else_names_the_relay() {
    // What the live relay answers for a round that does not exist yet.
    assert!(matches!(
        classify(RELAY_A, 425, "Requested future beacon"),
        Fetched::NotReady
    ));
    // What the published documentation promises instead; both mean the same thing.
    assert!(matches!(
        classify(RELAY_A, 404, "Round or chain not found"),
        Fetched::NotReady
    ));

    match classify(RELAY_B, 500, "internal error") {
        Fetched::SourceError { relay, .. } => assert_eq!(relay, RELAY_B),
        other => panic!("a 5xx is a source error carrying the relay, got {other:?}"),
    }

    assert!(matches!(
        classify(RELAY_A, 200, BODY_1000),
        Fetched::Beacon(_)
    ));
}
