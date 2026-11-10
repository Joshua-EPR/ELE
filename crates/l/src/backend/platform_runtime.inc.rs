fn l_process_arg_count() -> i64 {
    std::env::args_os().skip(1).len() as i64
}

fn l_process_arg(index: i64) -> Result<LText, i64> {
    let index = usize::try_from(index).map_err(|_| 1i64)?;
    let arg = std::env::args_os().skip(1).nth(index).ok_or(1i64)?;
    arg.into_string()
        .map(|s| LText(std::borrow::Cow::Owned(s)))
        .map_err(|_| 2)
}

fn l_print_error(text: &LText) {
    use std::io::Write;
    let _ = writeln!(std::io::stderr().lock(), "{}", text.0);
}

fn l_read_text(path: &LText, limit: i64) -> Result<LText, i64> {
    use std::io::{ErrorKind, Read};
    if !(0..=L_MAX_READ).contains(&limit) || !l_platform_path_valid(path.0.as_bytes()) {
        return Err(1);
    }
    let limit = limit as usize;
    let mut file = std::fs::File::open(path.0.as_ref()).map_err(|e| {
        if e.kind() == ErrorKind::NotFound {
            2i64
        } else {
            3
        }
    })?;
    if !file.metadata().map_err(|_| 3i64)?.is_file() {
        return Err(3);
    }
    let mut bytes = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        let wanted = (limit - bytes.len() + 1).min(chunk.len());
        let count = match file.read(&mut chunk[..wanted]) {
            Ok(0) => break,
            Ok(count) => count,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return Err(3),
        };
        let needed = bytes.len() + count;
        if needed > limit {
            return Err(5);
        }
        if needed > bytes.capacity() {
            let capacity = (bytes.capacity() * 2).max(8192).max(needed).min(limit);
            bytes.reserve_exact(capacity - bytes.len());
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    drop(file);
    String::from_utf8(bytes)
        .map(|s| LText(std::borrow::Cow::Owned(s)))
        .map_err(|_| 4)
}

// Bootstrap-only implementation of ELE writeBytes(Text, List<Int>) -> Int.
// All bytes are validated before creating/truncating a file.
// 0=ok, 1=bad path/byte/length, 2=cannot create, 3=write failed.
fn l_write_bytes(path: &LText, bytes: &[i64]) -> i64 {
    if bytes.len() > 64 * 1024 * 1024 || !l_platform_path_valid(path.0.as_bytes()) {
        return 1;
    }
    let mut out = Vec::with_capacity(bytes.len());
    for byte in bytes {
        if !(0..=255).contains(byte) { return 1; }
        out.push(*byte as u8);
    }
    match std::fs::File::create(path.0.as_ref()) {
        Ok(mut file) => {
            use std::io::Write;
            if file.write_all(&out).is_err() { 3 } else { 0 }
        }
        Err(_) => 2,
    }
}
