use std::sync::OnceLock;

use blst::min_sig::PublicKey;
use blst::BLST_ERROR;

use crate::encoding::parse_signature;
use crate::error::BeaconError;
use crate::hash::sha256;
use crate::hex;
use crate::wire::Beacon;

/// drand quicknet's RFC 9380 domain separation tag, the 43-byte constant the oracle's
/// verifier holds at contracts/libraries/DrandQuicknetVerifier.sol:45.
const DST: &[u8] = b"BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

/// drand quicknet's group public key, the same G2 constant the verifier holds at
/// contracts/libraries/DrandQuicknetVerifier.sol:51, in EIP-2537 form
/// (`pad‖x.c0‖pad‖x.c1‖pad‖y.c0‖pad‖y.c1`). It is pinned here rather than read from a
/// relay's `/info`, because the relay is the party this verification is checking.
const PUBLIC_KEY_EIP2537: &str = "000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f045152730000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

const EIP2537_WORD_BYTES: usize = 64;
const EIP2537_PAD_BYTES: usize = 16;
const COORDINATE_BYTES: usize = 48;

/// Verify one round's beacon against the pinned quicknet key, the check the oracle
/// repeats on chain — so a beacon that fails here would only buy a reverted transaction.
pub fn verify(beacon: &Beacon) -> Result<(), BeaconError> {
    let signature = parse_signature(&beacon.signature)?;
    // The signed message is the round's eight big-endian bytes under sha256, which is what
    // the verifier hashes to G1 at contracts/libraries/DrandQuicknetVerifier.sol:70.
    let message = sha256(&beacon.round.to_be_bytes());

    // Both `false`s are earned: `parse_signature` already ran the subgroup and infinity
    // checks, and the pinned key is validated once when it is deserialised.
    match signature.verify(false, &message, DST, &[], quicknet_public_key(), false) {
        BLST_ERROR::BLST_SUCCESS => Ok(()),
        BLST_ERROR::BLST_VERIFY_FAIL => Err(BeaconError::SignatureMismatch {
            round: beacon.round,
        }),
        code => Err(BeaconError::from_blst(code)),
    }
}

fn quicknet_public_key() -> &'static PublicKey {
    static KEY: OnceLock<PublicKey> = OnceLock::new();
    KEY.get_or_init(|| {
        let eip2537: [u8; 4 * EIP2537_WORD_BYTES] =
            hex::decode("public key", PUBLIC_KEY_EIP2537).expect("the pinned key is 256 bytes");

        // blst reads a G2 point as `x.c1 ‖ x.c0 ‖ y.c1 ‖ y.c0` with no padding, where
        // EIP-2537 pads every coordinate and puts `c0` first.
        let mut serialized = [0u8; 4 * COORDINATE_BYTES];
        for (slot, word) in [1, 0, 3, 2].into_iter().enumerate() {
            let start = word * EIP2537_WORD_BYTES + EIP2537_PAD_BYTES;
            serialized[slot * COORDINATE_BYTES..(slot + 1) * COORDINATE_BYTES]
                .copy_from_slice(&eip2537[start..start + COORDINATE_BYTES]);
        }
        PublicKey::key_validate(&serialized).expect("the pinned quicknet key is a G2 point")
    })
}
