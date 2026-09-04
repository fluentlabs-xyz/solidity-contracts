//! Spec test for design.md:250 — the quicknet wire type parses a relay body strictly
//! (per R2: a beacon the service cannot fully check never reaches a transaction).
//!
//! Pinned vector: drand quicknet round 1000, fetched from
//! `https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000`.

use drand_beacon::Beacon;

const SIGNATURE_1000: &str =
    "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
const RANDOMNESS_1000: &str = "fe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd";

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect()
}

fn body(signature: &str) -> String {
    format!(r#"{{"round":1000,"randomness":"{RANDOMNESS_1000}","signature":"{signature}"}}"#)
}

#[test]
fn parses_a_quicknet_body_and_refuses_a_malformed_one() {
    let beacon = Beacon::from_json(&body(SIGNATURE_1000)).expect("a genuine quicknet body parses");
    assert_eq!(beacon.round, 1000);
    assert_eq!(beacon.signature.as_slice(), hex(SIGNATURE_1000).as_slice());

    // 47 bytes: not a compressed G1 point, so nothing downstream could check it.
    let short = &SIGNATURE_1000[..94];
    assert!(Beacon::from_json(&body(short)).is_err());

    let no_signature = format!(r#"{{"round":1000,"randomness":"{RANDOMNESS_1000}"}}"#);
    assert!(Beacon::from_json(&no_signature).is_err());
}
