const L_MAX_READ: i64 = 64 * 1024 * 1024;
const L_MAX_PATH_BYTES: usize = 32767 * 4;

fn l_platform_path_valid(bytes: &[u8]) -> bool {
    let slash = |b| b == b'\\' || b == b'/';
    // Keep the standalone Win64 object independent of core's out-of-line memchr.
    let mut has_nul = false;
    for &byte in bytes {
        if byte == 0 {
            has_nul = true;
            break;
        }
    }
    !bytes.is_empty()
        && bytes.len() <= L_MAX_PATH_BYTES
        && !has_nul
        && !matches!(bytes, [a, b, b'.' | b'?', c, ..] if slash(*a) && slash(*b) && slash(*c))
}
