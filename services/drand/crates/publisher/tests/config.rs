//! Spec test for design.md:263 — every endpoint, the oracle address and the signing key
//! come from the process environment, and the signing key has no default (per R6).

use alloy::primitives::address;
use drand_publisher::Config;

// `unsafe` is required from edition 2024 on and harmless before it.
#[allow(unused_unsafe)]
fn set(key: &str, value: &str) {
    unsafe { std::env::set_var(key, value) }
}

#[allow(unused_unsafe)]
fn unset(key: &str) {
    unsafe { std::env::remove_var(key) }
}

#[test]
fn reads_the_environment_and_refuses_to_start_without_a_signing_key() {
    set(
        "DRAND_SIGNING_KEY",
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    );
    set("DRAND_RPC_URL", "http://127.0.0.1:8545");
    set(
        "DRAND_ORACLE_ADDRESS",
        "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    );
    set(
        "DRAND_RELAYS",
        "https://api.drand.sh,https://api2.drand.sh",
    );

    let config = Config::from_env().expect("a fully populated environment loads");
    assert_eq!(
        config.oracle,
        address!("5FbDB2315678afecb367f032d93F642f64180aa3")
    );
    assert_eq!(
        config.relays,
        vec![
            "https://api.drand.sh".to_string(),
            "https://api2.drand.sh".to_string()
        ]
    );

    unset("DRAND_SIGNING_KEY");
    let error = Config::from_env().expect_err("no signing key is compiled in or defaulted");
    assert!(
        error.to_string().contains("DRAND_SIGNING_KEY"),
        "the startup failure must name the missing variable, got: {error}"
    );
}
