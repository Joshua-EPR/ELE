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

fn l_same_file(path_a: &LText, path_b: &LText) -> bool {
    if !l_platform_path_valid(path_a.0.as_bytes()) || !l_platform_path_valid(path_b.0.as_bytes()) {
        return false;
    }
    let Ok(file_a) = std::fs::File::open(path_a.0.as_ref()) else { return false };
    let Ok(file_b) = std::fs::File::open(path_b.0.as_ref()) else { return false };

    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        let (Ok(meta_a), Ok(meta_b)) = (file_a.metadata(), file_b.metadata()) else { return false };
        meta_a.volume_serial_number() == meta_b.volume_serial_number()
            && meta_a.file_index() == meta_b.file_index()
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let (Ok(meta_a), Ok(meta_b)) = (file_a.metadata(), file_b.metadata()) else { return false };
        meta_a.dev() == meta_b.dev() && meta_a.ino() == meta_b.ino()
    }
    #[cfg(not(any(windows, unix)))]
    {
        false
    }
}

#[cfg(windows)]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    let mut wide_src: Vec<u16> = tmp.as_os_str().encode_wide().collect();
    wide_src.push(0);
    let mut wide_dst: Vec<u16> = dest.as_os_str().encode_wide().collect();
    wide_dst.push(0);
    extern "system" {
        fn MoveFileExW(existing: *const u16, new_file: *const u16, flags: u32) -> i32;
    }
    unsafe { MoveFileExW(wide_src.as_ptr(), wide_dst.as_ptr(), 1 | 8) != 0 }
}

#[cfg(unix)]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    std::fs::rename(tmp, dest).is_ok()
}

#[cfg(not(any(windows, unix)))]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    std::fs::rename(tmp, dest).is_ok()
}

// Bootstrap implementation of ELE writeBytes(Text, List<Int>) -> Int with Atomic Write & Safe Publish Contract.
// All bytes are validated before creating temporary file.
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
    let dest_path = std::path::Path::new(path.0.as_ref());
    let parent = dest_path.parent().unwrap_or_else(|| std::path::Path::new(""));
    let pid = std::process::id();
    let file_stem = dest_path.file_name().and_then(|s| s.to_str()).unwrap_or("out");
    let mut attempt = 0u64;
    let (mut tmp_file, tmp_path) = loop {
        let candidate_name = format!("{file_stem}.tmp.{pid}.{attempt}");
        let candidate = if parent.as_os_str().is_empty() {
            std::path::PathBuf::from(candidate_name)
        } else {
            parent.join(candidate_name)
        };
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => break (file, candidate),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempt < 100 => {
                attempt += 1;
                continue;
            }
            Err(_) => return 2,
        }
    };
    use std::io::Write;
    if tmp_file.write_all(&out).is_err() {
        drop(tmp_file);
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    if tmp_file.sync_all().is_err() {
        drop(tmp_file);
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    drop(tmp_file);

    if !move_file_atomic(&tmp_path, dest_path) {
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    0
}
