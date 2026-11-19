//! Stage 3 frontier of the ELE-written native backend on the REAL compiler
//! components (the reproducible experiment is
//! scripts/stage3_native_bootstrap_probe.ps1).
//!
//! Demonstrated on 2026-11-19 (integration/stage3-alpha-gamma) and asserted
//! here so that it cannot regress silently:
//! * Stage 1 `main_sema --emit-lir` is deterministic on main.l,
//!   main_parser.l, main_sema.l and native_cfg_demo.l;
//! * Stage 1 `native_cfg_demo` turns the LIR of main.l (lexer), main_parser.l
//!   (parser), main_sema.l (semantic analyser and LIR emitter, since shape-
//!   and union-typed fields are released through drop glue and whole owning
//!   referents can be replaced) and native_cfg_demo.l (the backend itself)
//!   into ELF64 images;
//! * on Linux x86-64, or through WSL when `ELE_TEST_WSL_DISTRO` names a
//!   distribution, the native lexer reproduces the Stage-0-built lexer byte
//!   for byte on a compiler source, and the native backend recompiles its
//!   own LIR into exactly the image that the Stage-0-built backend produced
//!   (generation 2 == generation 1).
//!
//! Opt-in (`ELE_TEST_NATIVE_SEMA=1`, about ten minutes through WSL): the
//! native semantic analyser emits, for main_sema.l itself, exactly the LIR
//! that Stage 1 emitted.
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
    // Two tests may ask for the same component; they write the same file.
    static WRITING: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _one_at_a_time = WRITING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
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
fn main_sema_lir_reaches_elf64() {
    let source = lir("main_sema");
    let image = accepted("main_sema", &source);
    if std::env::var_os("ELE_TEST_NATIVE_SEMA").is_none_or(|v| v != "1") {
        use std::io::Write;
        let _ = writeln!(
            std::io::stderr(),
            "SKIP[native-sema]: set ELE_TEST_NATIVE_SEMA=1 to run the native semantic analyser on main_sema.l"
        );
        return;
    }
    // Generation 2 of the LIR: the native analyser, run from a copy of the
    // compiler sources (imports are relative), on main_sema.l.
    let dir = work("main_sema-gen2");
    let tree = dir.join("compiler-l");
    let _ = fs::remove_dir_all(&tree);
    copy_tree(&root().join("compiler-l/src"), &tree.join("src"));
    if let Some(run) = execute(&image, &dir, &["compiler-l/src/main_sema.l", "--emit-lir"]) {
        assert_eq!(
            run.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&run.stderr)
        );
        assert!(
            run.stdout == fs::read(&source).unwrap(),
            "the native main_sema emits a different LIR for main_sema.l"
        );
    }
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
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
