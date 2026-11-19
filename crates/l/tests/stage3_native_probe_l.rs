//! Stage 3 frontier of the ELE-written native backend on the REAL compiler
//! components (the reproducible experiment is
//! scripts/stage3_native_bootstrap_probe.ps1).
//!
//! Demonstrated on 2026-11-19 (integration/stage3-alpha-gamma) and asserted
//! here so that it cannot regress silently:
//! * Stage 1 `main_sema --emit-lir` is deterministic on main.l,
//!   main_parser.l, main_sema.l and native_cfg_demo.l;
//! * Stage 1 `native_cfg_demo` turns the LIR of main.l (lexer), main_parser.l
//!   (parser) and native_cfg_demo.l (the backend itself) into ELF64 images;
//! * on Linux x86-64, or through WSL when `ELE_TEST_WSL_DISTRO` names a
//!   distribution, the native lexer reproduces the Stage-0-built lexer byte
//!   for byte on a compiler source, and the native backend recompiles its
//!   own LIR into exactly the image that the Stage-0-built backend produced
//!   (generation 2 == generation 1).
//!
//! Not asserted (still open): main_sema.l's LIR is rejected by the backend
//! (code 92: `dropfield` of a whole struct-typed field, first at
//! `ctx.flow = flowNew()` in sema.l), so the semantic analyser cannot yet be
//! built natively and Stage 3 is not autonomous.
//!
//! The images run without strace (stage1_support/elf_exec.rs traces every
//! mmap, and the backend's trace is megabytes written through WSL's /mnt).
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
fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn backend() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn lexer() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main", false))
}
fn work(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/stage3-probe").join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Runs `image` with `args` inside `dir`: natively on Linux x86-64, through
/// WSL on Windows when `ELE_TEST_WSL_DISTRO` is set, otherwise `None`.
fn execute(image: &Path, dir: &Path, args: &[&str]) -> Option<Output> {
    let program = dir.join("prog");
    fs::copy(image, &program).unwrap();
    let script = "cd \"$1\" && shift && chmod 700 prog && exec ./prog \"$@\"";
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return Some(
            Command::new("sh")
                .args(["-c", script, "sh"])
                .arg(dir)
                .args(args)
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
            .args(args)
            .output()
            .unwrap(),
    )
}

/// LIR of `compiler-l/src/<component>.l`, emitted twice from the repository
/// root; both runs must succeed with identical bytes.
fn lir(component: &str) -> PathBuf {
    let source = format!("compiler-l/src/{component}.l");
    let run = || {
        let out = Command::new(sema())
            .args([source.as_str(), "--emit-lir"])
            .current_dir(root())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{component}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        out.stdout
    };
    let first = run();
    assert!(first.starts_with(b"ELE-LIR 1\n"), "{component}");
    assert_eq!(first, run(), "{component}: --emit-lir is not deterministic");
    let path = work(component).join(format!("{component}.lir"));
    fs::write(&path, &first).unwrap();
    path
}

/// The Stage 1 backend must accept `lir` and write an ELF64 image.
fn accepted(component: &str, lir: &Path) -> PathBuf {
    let image = work(component).join(format!("{component}.elf"));
    let _ = fs::remove_file(&image);
    let out = Command::new(backend())
        .arg(lir)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{component}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01", "{component}");
    image
}

#[test]
fn main_sema_lir_is_deterministic() {
    lir("main_sema");
}

#[test]
fn native_lexer_matches_the_stage0_built_lexer() {
    let image = accepted("main", &lir("main"));
    let dir = work("main-run");
    fs::copy(
        root().join("compiler-l/src/main_sema.l"),
        dir.join("input.l"),
    )
    .unwrap();
    let reference = Command::new(lexer())
        .arg("input.l")
        .current_dir(&dir)
        .output()
        .unwrap();
    assert!(reference.status.success());
    if let Some(run) = execute(&image, &dir, &["input.l"]) {
        assert_eq!(
            run.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(run.stdout, reference.stdout);
        assert_eq!(run.stderr, reference.stderr);
    }
}

#[test]
fn parser_lir_reaches_elf64() {
    accepted("main_parser", &lir("main_parser"));
}

#[test]
fn native_backend_rebuilds_itself_bit_for_bit() {
    let source = lir("native_cfg_demo");
    let image = accepted("native_cfg_demo", &source);
    let dir = work("native_cfg_demo-gen2");
    fs::copy(&source, dir.join("self.lir")).unwrap();
    let _ = fs::remove_file(dir.join("gen2.elf"));
    if let Some(run) = execute(&image, &dir, &["self.lir", "gen2.elf"]) {
        assert_eq!(
            run.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(
            fs::read(dir.join("gen2.elf")).unwrap(),
            fs::read(&image).unwrap(),
            "generation 2 differs from the Stage 1 backend's image"
        );
    }
}
