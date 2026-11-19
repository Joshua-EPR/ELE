//! Stage 2 & Stage 3 Bootstrap Integration & Determinism Test.
//!
//! Validates:
//! 1. Successful compilation of all 4 Stage 1/Stage 2 executables:
//!    - `main.l` (lexer-l)
//!    - `main_parser.l` (parser-l)
//!    - `main_sema.l` (sema-l)
//!    - `native_cfg_demo.l` (native-cfg-demo)
//! 2. Bit-by-bit determinism and parity:
//!    - `main_sema.exe compiler-l/src/main_sema.l --emit-lir` produces bit-identical
//!      LIR on repeated executions (intra-phase determinism).
//!    - `l build-lir` builds Stage 2 `main_sema.exe` directly from Stage 1 LIR
//!      (no Rust frontend involved).
//!    - Stage 2 `main_sema.exe` emits bit-for-bit identical LIR when compiling
//!      `compiler-l/src/main_sema.l` (inter-phase parity between Stage 1 & Stage 2).
//! 3. Complete pipeline test:
//!    - `main_parser.exe` parses source to canonical AST.
//!    - `main_sema.exe --emit-lir` produces valid ELE-LIR 1.
//!    - `native_cfg_demo.exe` consumes LIR and emits a valid ELF64 executable.
mod stage1_support;

use std::{
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn bin_lexer() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main", false))
}

fn bin_parser() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_parser", false))
}

fn bin_sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn bin_native() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

fn run_isolated(bin: &Path, args: &[&OsStr]) -> Output {
    Command::new(bin)
        .args(args)
        .env("PATH", "")
        .env_remove("CARGO")
        .env_remove("RUSTC")
        .env_remove("CARGO_HOME")
        .env_remove("RUSTUP_HOME")
        .output()
        .unwrap_or_else(|err| panic!("Failed to run {}: {err}", bin.display()))
}

#[test]
fn test_all_four_stage2_executables_build_cleanly() {
    let lexer = bin_lexer();
    let parser = bin_parser();
    let sema = bin_sema();
    let native = bin_native();

    assert!(lexer.is_file(), "lexer binary missing: {}", lexer.display());
    assert!(parser.is_file(), "parser binary missing: {}", parser.display());
    assert!(sema.is_file(), "sema binary missing: {}", sema.display());
    assert!(native.is_file(), "native backend binary missing: {}", native.display());
}

#[test]
fn test_stage2_determinism_and_bit_for_bit_parity() {
    let base = root();
    let scratch = base.join("target/stage1-tests/stage2-bootstrap-determinism");
    fs::create_dir_all(&scratch).unwrap();

    let sema_src = base.join("compiler-l/src/main_sema.l");
    let sema_exe = bin_sema();

    // 1. Run 1: Stage 1 emits LIR for its own compiler frontend
    let run1 = run_isolated(
        sema_exe,
        &[sema_src.as_os_str(), OsStr::new("--emit-lir")],
    );
    assert!(
        run1.status.success(),
        "Stage 1 Run 1 failed: {}",
        String::from_utf8_lossy(&run1.stderr)
    );
    assert!(
        run1.stdout.starts_with(b"ELE-LIR 1\n"),
        "Missing ELE-LIR 1 header in Run 1"
    );

    // 2. Run 2: Repeat to guarantee intra-phase determinism
    let run2 = run_isolated(
        sema_exe,
        &[sema_src.as_os_str(), OsStr::new("--emit-lir")],
    );
    assert!(
        run2.status.success(),
        "Stage 1 Run 2 failed: {}",
        String::from_utf8_lossy(&run2.stderr)
    );
    assert_eq!(
        run1.stdout, run2.stdout,
        "Non-deterministic LIR emission within Stage 1"
    );

    let lir_path = scratch.join("main_sema_stage1.lir");
    fs::write(&lir_path, &run1.stdout).unwrap();

    // 3. Build Stage 2 executable using `l build-lir` (Cranelift backend, no Rust frontend)
    let build_out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&scratch)
        .arg("build-lir")
        .arg(&lir_path)
        .output()
        .expect("Failed to invoke l build-lir for Stage 2");
    assert!(
        build_out.status.success(),
        "l build-lir failed: {}",
        String::from_utf8_lossy(&build_out.stderr)
    );

    let stdout_str = String::from_utf8_lossy(&build_out.stdout);
    let rel_exe = stdout_str
        .lines()
        .find_map(|line| line.strip_prefix("Build: "))
        .expect("Build output must indicate executable path");
    let stage2_exe = scratch.join(rel_exe);
    assert!(
        stage2_exe.is_file(),
        "Stage 2 executable does not exist at {}",
        stage2_exe.display()
    );

    // 4. Run Stage 2 executable on `main_sema.l` to produce Stage 2 LIR
    let run_stage2 = run_isolated(
        &stage2_exe,
        &[sema_src.as_os_str(), OsStr::new("--emit-lir")],
    );
    assert!(
        run_stage2.status.success(),
        "Stage 2 executable failed to compile main_sema.l: {}",
        String::from_utf8_lossy(&run_stage2.stderr)
    );

    // A comparison against Stage 1 must not accidentally pass on
    // matching empty or non-protocol output after an executable failure.
    assert!(
        run_stage2.stdout.starts_with(b"ELE-LIR 1\n"),
        "Stage 2 did not emit the canonical ELE-LIR protocol header"
    );

    // 5. Bit-for-bit equality check: Stage 1 output vs Stage 2 output
    assert_eq!(
        run1.stdout, run_stage2.stdout,
        "Bit-by-bit mismatch between Stage 1 and Stage 2 LIR output"
    );
}

#[test]
fn test_stage2_full_pipeline_end_to_end() {
    let base = root();
    let scratch = base.join("target/stage1-tests/stage2-bootstrap-pipeline");
    fs::create_dir_all(&scratch).unwrap();

    let harness_src = base.join("compiler-l/src/flow_self_harness.l");
    let parser_exe = bin_parser();
    let sema_exe = bin_sema();
    let native_exe = bin_native();

    // Step 1: Parser
    let parsed = run_isolated(parser_exe, &[harness_src.as_os_str()]);
    assert!(
        parsed.status.success(),
        "Parser failed on harness: {}",
        String::from_utf8_lossy(&parsed.stderr)
    );
    let parser_out = String::from_utf8_lossy(&parsed.stdout);
    assert!(
        parser_out.contains("AstSummary"),
        "Parser output missing AstSummary: {parser_out}"
    );

    // Step 2: Semantic analysis and LIR emission
    let emitted = run_isolated(
        sema_exe,
        &[harness_src.as_os_str(), OsStr::new("--emit-lir")],
    );
    assert!(
        emitted.status.success(),
        "Sema failed on harness: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    assert!(
        emitted.stdout.starts_with(b"ELE-LIR 1\n"),
        "Missing ELE-LIR 1 header"
    );

    let lir_file = scratch.join("pipeline_flow.lir");
    let elf_file = scratch.join("pipeline_flow.elf");
    fs::write(&lir_file, &emitted.stdout).unwrap();
    if elf_file.exists() {
        let _ = fs::remove_file(&elf_file);
    }

    // Step 3: Native CFG ELF64 generation
    let built = run_isolated(
        native_exe,
        &[lir_file.as_os_str(), elf_file.as_os_str()],
    );
    assert!(
        built.status.success(),
        "Native backend failed: {}",
        String::from_utf8_lossy(&built.stderr)
    );

    // Step 4: Verification of ELF64 image
    let image = fs::read(&elf_file).unwrap_or_else(|err| panic!("Cannot read {}: {err}", elf_file.display()));
    assert!(image.len() > 4096, "ELF64 image too small ({} bytes)", image.len());
    assert_eq!(
        &image[..7],
        b"\x7fELF\x02\x01\x01",
        "Invalid ELF64 little-endian magic bytes"
    );

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&elf_file).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(&elf_file, perms).unwrap();
        let result = Command::new(&elf_file).output().unwrap();
        assert_eq!(
            result.status.code(),
            Some(2),
            "flow_self_harness ELF execution expected exit code 2, got: {:?}",
            result.status.code()
        );
    }
}
