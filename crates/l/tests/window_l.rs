//! P0-D native windows through the autonomous driver (Stage 1).
//!
//! - `tests/std/window_events.l` (PE32+, Windows): open, back-buffer
//!   drawing read back pixel by pixel, synthetic input through the real
//!   WndProc and message loop (key, UTF-16 surrogate pair, mouse, wheel),
//!   the close request, close, and a failed open.
//! - `tests/std/window_headless.l` (ELF64, Linux or WSL): without a graphical
//!   backend, windowOpen reports -7 and nothing pretends to work.
//! - `tests/std/window_invalid/*.l`: the Window is linear and opaque.
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

fn work(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/window").join(name);
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

fn assert_built(out: &Output) {
    assert!(
        out.status.success(),
        "build failed: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Runs an ELF64 image natively on Linux x86-64 or through WSL on Windows.
fn execute_elf(image: &Path, dir: &Path) -> Option<Output> {
    let program = dir.join("prog_elf");
    fs::copy(image, &program).unwrap();
    let script = "cd \"$1\" && chmod 700 prog_elf && exec ./prog_elf";
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return Some(
            Command::new("sh")
                .args(["-c", script, "sh"])
                .arg(dir)
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
            .args(["-d", &distro, "--exec", "sh", "-c", script, "sh", &linux])
            .output()
            .unwrap(),
    )
}

#[test]
fn window_events_pe64() {
    let dir = work("pe64");
    let exe = dir.join("window_events.exe");
    assert_built(&build(
        &root().join("tests/std/window_events.l"),
        "pe",
        &exe,
    ));
    // user32 and gdi32 are loaded at run time: the import table stays
    // KERNEL32-only and passes the PE validator.
    let pe = image_support::validate_pe32plus(&fs::read(&exe).unwrap()).expect("valid PE32+");
    for (dll, _) in &pe.imports {
        assert!(
            dll.eq_ignore_ascii_case("KERNEL32.dll"),
            "unexpected DLL {dll}"
        );
    }
    #[cfg(windows)]
    {
        let run = Command::new(&exe).output().unwrap();
        assert!(
            run.status.success(),
            "window_events failed with {:?} (the exit code names the check)\nstdout: {}\nstderr: {}",
            run.status.code(),
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&run.stdout).trim(),
            "window-events-ok"
        );
    }
}

#[test]
fn window_headless_elf64_reports_no_graphical_session() {
    let dir = work("elf64");
    let elf = dir.join("window_headless.elf");
    assert_built(&build(
        &root().join("tests/std/window_headless.l"),
        "elf",
        &elf,
    ));
    if let Some(run) = execute_elf(&elf, &dir) {
        assert!(
            run.status.success(),
            "window_headless failed with {:?}: {}",
            run.status.code(),
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&run.stdout).trim(),
            "window-unavailable-ok"
        );
    }
}

#[test]
fn window_rejects_unsafe_programs() {
    let cases = [
        ("leak", "L0005", "Window abierto al salir"),
        ("double_close", "L0005", "uso de valor movido"),
        ("use_after_close", "L0005", "uso de valor movido"),
        ("forged_int", "L0004", "(ventana: Window)"),
        ("file_as_window", "L0004", "(ventana: Window)"),
        ("in_list", "L0016", "Window es lineal"),
    ];
    let dir = work("invalid");
    let sources = root().join("tests/std/window_invalid");
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
        let all = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
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
