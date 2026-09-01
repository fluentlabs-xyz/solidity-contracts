use crate::error::BeaconError;

pub(crate) fn decode<const N: usize>(
    field: &'static str,
    text: &str,
) -> Result<[u8; N], BeaconError> {
    if !text.len().is_multiple_of(2) || !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(BeaconError::NotHex { field });
    }
    if text.len() != 2 * N {
        return Err(BeaconError::Width {
            field,
            expected: N,
            actual: text.len() / 2,
        });
    }

    let mut bytes = [0u8; N];
    for (byte, pair) in bytes.iter_mut().zip(text.as_bytes().chunks_exact(2)) {
        *byte = nibble(pair[0]) << 4 | nibble(pair[1]);
    }
    Ok(bytes)
}

fn nibble(digit: u8) -> u8 {
    match digit {
        b'0'..=b'9' => digit - b'0',
        b'a'..=b'f' => digit - b'a' + 10,
        _ => digit - b'A' + 10,
    }
}
