//! P0-B native file streams through the autonomous driver (Stage 1).
//!
//! - `tests/std/file_streams.l` exercises open modes, block reads and writes,
//!   EOF, seek, size, flush, append, create-new, truncation, error codes and a
//!   1 MiB round trip. It runs as PE32+ on Windows and as ELF64 on Linux
//!   (or through WSL when `ELE_TEST_WSL_DISTRO` names a distribution).
//! - `tests/std/file_streams_invalid/*.l` must be rejected at compile time:
//!   the File is linear (no leak, double close or use after close), opaque
//!   (no Int handle) and never stored inside an aggregate.
//! - Programs that do not use files keep their images: no file-stream import.
mod image_support;
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_driver", false))
}

/// A fresh, empty work directory (left in place for inspection on failure).
fn work(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/file-streams").join(name);
    if dir.exists() {
        fs::remove_dir_all(&dir).unwrap();
    }
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(source: &Path, target: &str, output: &Path) -> Output {
    Command::new(driver())
        .arg("build")
        .arg(source)
        .arg("--lib")
        .arg(root())
        .args(["--target", target, "--output"])
        .arg(output)
        .output()
        .expect("failed to run the autonomous driver")
}

fn streams_source() -> PathBuf {
    root().join("tests/std/file_streams.l")
}

/// Runs an ELF64 image with the scratch directory `data` (relative to `dir`)
/// natively on Linux x86-64 or through WSL on Windows.
fn execute_elf(image: &Path, dir: &Path, data: &str) -> Option<Output> {
    let program = dir.join("prog_elf");
    fs::copy(image, &program).unwrap();
    let script = "cd \"$1\" && chmod 700 prog_elf && exec ./prog_elf \"$2\"";
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return Some(
            Command::new("sh")
                .args(["-c", script, "sh"])
                .arg(dir)
                .arg(data)
                .output()
                .unwrap(),
        );
    }
    if !cfg!(windows) {
        return None;
    }
    let distro = std::env::var("ELE_TEST_WSL_DISTRO").ok()?;
    let canonical = dir.canonicalize().unwrap();
    let windows = canonical
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .replace('\\', "/");
    let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
    let linux = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());
    Some(
        Command::new("wsl")
            .args([
                "-d", &distro, "--exec", "sh", "-c", script, "sh", &linux, data,
            ])
            .output()
            .unwrap(),
    )
}

fn assert_streams_ok(run: &Output, data: &Path) {
    assert!(
        run.status.success(),
        "file_streams failed with {:?} (the exit code names the check)\nstdout: {}\nstderr: {}",
        run.status.code(),
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&run.stdout).trim(),
        "file-streams-ok"
    );
    // The 1 MiB round trip is checked by the program; verify it from outside too.
    let large = fs::read(data.join("large.bin")).unwrap();
    assert_eq!(large.len(), 1 << 20);
    for (k, byte) in large.iter().enumerate() {
        assert_eq!(*byte as usize, (k * 7) % 256, "large.bin byte {k}");
    }
    assert_eq!(fs::read(data.join("streams.bin")).unwrap(), b"");
    assert_eq!(fs::read(data.join("errors.bin")).unwrap(), b"");
}

#[test]
fn file_streams_pe64() {
    let dir = work("pe64");
    let exe = dir.join("file_streams.exe");
    let out = build(&streams_source(), "pe", &exe);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let image = fs::read(&exe).unwrap();
    let pe = image_support::validate_pe32plus(&image).expect("valid PE32+ image");
    let kernel32 = &pe
        .imports
        .iter()
        .find(|(dll, _)| dll.eq_ignore_ascii_case("KERNEL32.dll"))
        .expect("KERNEL32 import")
        .1;
    for name in ["SetFilePointerEx", "GetFileSizeEx", "FlushFileBuffers"] {
        assert!(kernel32.iter().any(|n| n == name), "missing import {name}");
    }
    #[cfg(windows)]
    {
        let data = dir.join("data");
        fs::create_dir_all(&data).unwrap();
        let run = Command::new(&exe).arg(&data).output().unwrap();
        assert_streams_ok(&run, &data);
    }
}

#[test]
fn file_streams_elf64() {
    let dir = work("elf64");
    let elf = dir.join("file_streams.elf");
    let out = build(&streams_source(), "elf", &elf);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(&fs::read(&elf).unwrap()[..7], b"\x7fELF\x02\x01\x01");
    let data = dir.join("data");
    fs::create_dir_all(&data).unwrap();
    if let Some(run) = execute_elf(&elf, &dir, "data") {
        assert_streams_ok(&run, &data);
    }
}

#[test]
fn file_streams_reject_unsafe_programs() {
    // (file, diagnostic code, fragment of the message)
    let cases = [
        ("leak", "L0005", "File abierto al salir"),
        ("discarded", "L0005", "File abierto al salir"),
        ("maybe_closed", "L0005", "File abierto al salir"),
        ("double_close", "L0005", "uso de valor movido"),
        ("use_after_close", "L0005", "uso de valor movido"),
        ("move_twice", "L0005", "uso de valor movido"),
        ("forged_int", "L0004", "requiere (archivo: File)"),
        ("forged_annotation", "L0003", ""),
        ("in_list", "L0016", "File es lineal"),
        ("in_shape", "L0016", "File es lineal"),
        ("read_immutable", "L0001", "prestar mutablemente"),
    ];
    let dir = work("invalid");
    let sources = root().join("tests/std/file_streams_invalid");
    let mut on_disk: Vec<String> = fs::read_dir(&sources)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "l"))
        .map(|p| p.file_stem().unwrap().to_string_lossy().into_owned())
        .collect();
    on_disk.sort();
    let mut listed: Vec<String> = cases.iter().map(|c| c.0.to_string()).collect();
    listed.sort();
    assert_eq!(
        on_disk, listed,
        "every invalid case must have an expectation"
    );
    for (name, code, fragment) in cases {
        let exe = dir.join(format!("{name}.exe"));
        let out = build(&sources.join(format!("{name}.l")), "pe", &exe);
        let stderr = String::from_utf8_lossy(&out.stderr);
        let stdout = String::from_utf8_lossy(&out.stdout);
        let all = format!("{stdout}{stderr}");
        assert!(!out.status.success(), "{name}: compiled, expected {code}");
        assert!(!exe.exists(), "{name}: an executable was written");
        assert!(
            all.contains(&format!("[{code}]")),
            "{name}: expected {code}, got:\n{all}"
        );
        assert!(
            all.contains(fragment),
            "{name}: expected '{fragment}', got:\n{all}"
        );
    }
}

#[test]
fn programs_without_files_import_nothing_new() {
    let dir = work("no_files");
    let src = dir.join("hello.l");
    fs::write(
        &src,
        "flow main() => Int {\n    hold path = \"x\"\n    choose readText(path, 4) {\n        Ok(t): { print(t) },\n        Err(e): { give e },\n    }\n    give 0\n}\n",
    )
    .unwrap();
    let exe = dir.join("hello.exe");
    let out = build(&src, "pe", &exe);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let pe = image_support::validate_pe32plus(&fs::read(&exe).unwrap()).expect("valid PE32+");
    for (_, names) in &pe.imports {
        for name in ["SetFilePointerEx", "GetFileSizeEx"] {
            assert!(!names.iter().any(|n| n == name), "unexpected import {name}");
        }
    }
}
