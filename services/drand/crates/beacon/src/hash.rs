use blst::blst_sha256;

pub(crate) fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut digest = [0u8; 32];
    // SAFETY: blst_sha256 reads `bytes.len()` bytes from the input and writes exactly
    // the 32 bytes of a SHA-256 digest to the output.
    unsafe { blst_sha256(digest.as_mut_ptr(), bytes.as_ptr(), bytes.len()) };
    digest
}
