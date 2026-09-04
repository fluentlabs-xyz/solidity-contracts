//! Spec test for design.md:254 — drand's compressed 48-byte G1 signature becomes the
//! 128-byte EIP-2537 uncompressed encoding the contract accepts, and back (per R3).
//!
//! Pinned vector: drand quicknet round 1000 from `api.drand.sh`.

use drand_beacon::{compress_g1, uncompress_g1};

const SIGNATURE_1000: &str =
    "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect()
}

#[test]
fn produces_the_eip2537_point_and_recompresses_to_the_bytes_drand_served() {
    let compressed = hex(SIGNATURE_1000);

    let point = uncompress_g1(&compressed).expect("a real quicknet signature decompresses");

    // EIP-2537: `pad16 ‖ x[48] ‖ pad16 ‖ y[48]`, and the padding is checked on chain.
    assert_eq!(point.len(), 128);
    assert!(point[..16].iter().all(|b| *b == 0), "x is not zero-padded");
    assert!(point[64..80].iter().all(|b| *b == 0), "y is not zero-padded");

    // The inverse the self-check rides on: the contract hashes exactly these bytes.
    assert_eq!(
        compress_g1(&point).expect("the point recompresses").as_slice(),
        compressed.as_slice()
    );
}
