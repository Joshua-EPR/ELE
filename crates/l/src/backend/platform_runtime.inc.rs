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

// The first path is the proposed output; the second is an existing source.
// 0 = different (including an absent output), 1 = same, 2 = identity error.
fn l_same_file(path_a: &LText, path_b: &LText) -> i64 {
    if !l_platform_path_valid(path_a.0.as_bytes()) || !l_platform_path_valid(path_b.0.as_bytes()) {
        return 2;
    }
    let Ok(file_b) = std::fs::File::open(path_b.0.as_ref()) else { return 2 };
    let dest = std::path::Path::new(path_a.0.as_ref());
    let file_a = match std::fs::File::open(dest) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A dangling symlink or absent parent does not prove a safe destination.
            match std::fs::symlink_metadata(dest) {
                Ok(_) => return 2,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return 2,
            }
            let parent = dest.parent().filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| std::path::Path::new("."));
            return match std::fs::metadata(parent) {
                Ok(metadata) if metadata.is_dir() => 0,
                _ => 2,
            };
        }
        Err(_) => return 2,
    };
    let (Ok(meta_a), Ok(meta_b)) = (file_a.metadata(), file_b.metadata()) else { return 2 };
    if !meta_a.is_file() || !meta_b.is_file() { return 2; }

    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        struct FileInfo {
            attributes: u32,
            creation_time: [u32; 2],
            access_time: [u32; 2],
            write_time: [u32; 2],
            volume: u32,
            size_high: u32,
            size_low: u32,
            links: u32,
            index_high: u32,
            index_low: u32,
        }
        unsafe extern "system" {
            fn GetFileInformationByHandle(
                handle: *mut std::ffi::c_void,
                info: *mut FileInfo,
            ) -> i32;
        }
        let mut info_a = std::mem::MaybeUninit::<FileInfo>::uninit();
        let mut info_b = std::mem::MaybeUninit::<FileInfo>::uninit();
        let ok_a = unsafe {
            GetFileInformationByHandle(file_a.as_raw_handle(), info_a.as_mut_ptr())
        };
        let ok_b = unsafe {
            GetFileInformationByHandle(file_b.as_raw_handle(), info_b.as_mut_ptr())
        };
        if ok_a == 0 || ok_b == 0 { return 2; }
        let info_a = unsafe { info_a.assume_init() };
        let info_b = unsafe { info_b.assume_init() };
        i64::from(info_a.volume == info_b.volume
            && info_a.index_high == info_b.index_high
            && info_a.index_low == info_b.index_low)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        i64::from(meta_a.dev() == meta_b.dev() && meta_a.ino() == meta_b.ino())
    }
    #[cfg(not(any(windows, unix)))]
    {
        2
    }
}

#[cfg(windows)]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    let mut wide_src: Vec<u16> = tmp.as_os_str().encode_wide().collect();
    wide_src.push(0);
    let mut wide_dst: Vec<u16> = dest.as_os_str().encode_wide().collect();
    wide_dst.push(0);
    unsafe extern "system" {
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
#[cfg(windows)]
fn l_random_nonce() -> Option<[u8; 16]> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LoadLibraryExW(path: *const u16, file: *mut std::ffi::c_void, flags: u32) -> *mut std::ffi::c_void;
        fn GetProcAddress(module: *mut std::ffi::c_void, name: *const u8) -> *mut std::ffi::c_void;
        fn FreeLibrary(module: *mut std::ffi::c_void) -> i32;
    }
    type RandomFn = unsafe extern "system" fn(*mut std::ffi::c_void, *mut u8, u32, u32) -> i32;
    let dll = "bcrypt.dll".encode_utf16().chain(std::iter::once(0)).collect::<Vec<_>>();
    let module = unsafe { LoadLibraryExW(dll.as_ptr(), std::ptr::null_mut(), 0x800) };
    if module.is_null() { return None; }
    let proc = unsafe { GetProcAddress(module, b"BCryptGenRandom\0".as_ptr()) };
    if proc.is_null() {
        unsafe { FreeLibrary(module) };
        return None;
    }
    let random: RandomFn = unsafe { std::mem::transmute(proc) };
    let mut nonce = [0u8; 16];
    let status = unsafe { random(std::ptr::null_mut(), nonce.as_mut_ptr(), 16, 2) };
    unsafe { FreeLibrary(module) };
    (status == 0).then_some(nonce)
}

#[cfg(unix)]
fn l_random_nonce() -> Option<[u8; 16]> {
    use std::io::Read;
    let mut nonce = [0u8; 16];
    std::fs::File::open("/dev/urandom").ok()?.read_exact(&mut nonce).ok()?;
    Some(nonce)
}

#[cfg(not(any(windows, unix)))]
fn l_random_nonce() -> Option<[u8; 16]> { None }

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
    let file_stem = dest_path.file_name().and_then(|s| s.to_str()).unwrap_or("out");
    let mut attempts = 0u8;
    let (mut tmp_file, tmp_path) = loop {
        let nonce = match l_random_nonce() { Some(nonce) => nonce, None => return 2 };
        let suffix = nonce.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let candidate_name = format!("{file_stem}.tmp.{suffix}");
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
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempts < 15 => {
                attempts += 1;
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
