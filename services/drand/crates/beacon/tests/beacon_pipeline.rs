//! Spec test for design.md:258 — one call takes a fetched round to a submittable
//! 128-byte payload, and returns none unless verification and the re-compression
//! self-check both pass (per R2, R3).
//!
//! The pinned rounds are data committed by the implementation (D9), a JSON array of
//! drand round bodies: `[{"round":N,"randomness":"..","signature":".."}, ..]`.

use drand_beacon::{submittable_payload, Beacon};

const FIXTURES: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/fixtures/quicknet_rounds.json"
);

#[test]
fn every_pinned_round_becomes_a_payload_and_a_tampered_body_becomes_none() {
    let raw = std::fs::read_to_string(FIXTURES).expect("the pinned quicknet fixtures");
    let rounds: Vec<serde_json::Value> =
        serde_json::from_str(&raw).expect("an array of drand round bodies");
    assert!(!rounds.is_empty(), "no pinned rounds to check");

    for round in &rounds {
        let body = serde_json::to_string(round).expect("re-serialise");
        let beacon = Beacon::from_json(&body).expect("a pinned body parses");
        let payload = submittable_payload(&beacon).expect("a pinned round is submittable");
        assert_eq!(payload.len(), 128);
    }

    // drand's own `randomness` is the self-check oracle: it is sha256 of the compressed
    // point, which is exactly what the contract stores. Break it and nothing is submittable.
    let mut tampered = rounds[0].clone();
    tampered["randomness"] = serde_json::Value::String("00".repeat(32));
    let body = serde_json::to_string(&tampered).expect("re-serialise");
    let refused = match Beacon::from_json(&body) {
        Err(_) => true,
        Ok(beacon) => submittable_payload(&beacon).is_err(),
    };
    assert!(
        refused,
        "a body whose randomness does not match its signature must not yield a payload"
    );
}
