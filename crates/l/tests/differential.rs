//! Differential tests: every program is built with the rustc backend and with
//! the Cranelift backend; both executables must produce identical stdout,
//! stderr and exit status.
//!
//! To add a case, drop a `.l` file into `tests/differential/`. Programs the
//! native backend does not support yet go into `tests/differential/unsupported/`
//! and must be rejected with a clear diagnostic (never miscompiled). Every
//! example in `examples/` and `ejemplos/` that the native backend accepts is
//! also compared automatically.
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(args)
        .output()
        .expect("CLI")
}

/// Builds `source_path` with `backend` inside `dir` and returns the executable.
fn build(dir: &Path, source_path: &Path, backend: &str) -> PathBuf {
    let out = cli(
        dir,
        &["build", source_path.to_str().unwrap(), "--backend", backend],
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{backend} build of {} failed:\n{stdout}{}",
        source_path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    let exe = stdout
        .lines()
        .find_map(|l| l.strip_prefix("Build: "))
        .expect("Build: line");
    dir.join(exe)
}

fn execute(exe: &Path) -> (String, String, Option<i32>) {
    let out = Command::new(exe).output().expect("run executable");
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code(),
    )
}

/// Builds with both backends and compares observable behaviour.
fn compare(name: &str, source_path: &Path) -> (String, String, Option<i32>) {
    let dir = root().join("../../target/differential").join(name);
    fs::create_dir_all(&dir).unwrap();
    let reference = execute(&build(&dir, source_path, "rustc"));
    let native = execute(&build(&dir, source_path, "cranelift"));
    assert_eq!(
        reference, native,
        "{name}: rustc (izquierda) y cranelift (derecha) difieren"
    );
    native
}

fn l_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "l"))
        .collect();
    files.sort();
    files
}

fn natively_supported(path: &Path) -> bool {
    let source = fs::read_to_string(path).unwrap();
    project_l::check(&source)
        .ok()
        .and_then(|ir| project_l::lower_to_cfg(&ir).ok())
        .is_some_and(|cfg| project_l::native::check_supported(&cfg).is_ok())
}

#[test]
fn differential_programs_match() {
    let files = l_files(&root().join("tests/differential"));
    assert!(files.len() >= 5);
    for path in files {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let (stdout, _, code) = compare(&name, &path);
        assert_eq!(code, Some(0), "{name}");
        assert!(!stdout.is_empty(), "{name}");
    }
}

#[test]
fn supported_repository_examples_match() {
    let mut compared = 0;
    for dir in ["../../examples", "../../ejemplos"] {
        for path in l_files(&root().join(dir)) {
            if natively_supported(&path) {
                let name = format!("ex_{}", path.file_stem().unwrap().to_string_lossy());
                compare(&name, &path);
                compared += 1;
            }
        }
    }
    assert!(compared >= 6, "only {compared} examples compared");
}

#[test]
fn checked_arithmetic_panics_match() {
    let dir = root().join("../../target/differential/panics");
    fs::create_dir_all(&dir).unwrap();
    for (name, expr) in [
        ("add", "9223372036854775807 + uno()"),
        ("sub", "-9223372036854775808 - uno()"),
        ("mul", "4611686018427387904 * (uno() + 1)"),
        ("div_zero", "10 / (uno() - 1)"),
        ("rem_zero", "10 % (uno() - 1)"),
        ("div_min", "-9223372036854775808 / -uno()"),
        ("rem_min", "-9223372036854775808 % -uno()"),
        ("neg_min", "-(-9223372036854775807 - uno())"),
    ] {
        let path = dir.join(format!("{name}.l"));
        fs::write(
            &path,
            format!("fn uno() -> Int = 1\nfn main() {{\n    print(7)\n    print({expr})\n    print(8)\n}}\n"),
        )
        .unwrap();
        let (stdout, stderr, code) = compare(&format!("panic_{name}"), &path);
        assert_eq!(stdout, "7\n", "{name}");
        assert!(
            stderr.starts_with("ELE 4:") && stderr.contains("overflow entero"),
            "{name}: {stderr}"
        );
        assert_ne!(code, Some(0), "{name}");
    }
}

#[test]
fn unsupported_programs_are_rejected_not_miscompiled() {
    let files = l_files(&root().join("tests/differential/unsupported"));
    for path in files {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let dir = root()
            .join("../../target/differential/unsupported")
            .join(&name);
        fs::create_dir_all(&dir).unwrap();
        let p = path.to_str().unwrap();
        for command in ["check", "build", "run"] {
            let out = cli(&dir, &[command, p, "--backend", "cranelift"]);
            let stderr = String::from_utf8_lossy(&out.stderr);
            assert!(!out.status.success(), "{name} {command}");
            assert!(
                stderr.contains("L0008") && stderr.contains("use --backend rustc"),
                "{name} {command}: {stderr}"
            );
            assert!(out.stdout.is_empty(), "{name} {command}");
        }
        assert!(
            !dir.join("target/cranelift").exists(),
            "{name}: no native artifact may be produced"
        );
        // The reference backend still builds and runs it.
        let out = cli(&dir, &["run", p]);
        assert!(
            out.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn cli_rejects_unknown_backend() {
    let dir = root().join("../../target/differential/cli");
    fs::create_dir_all(&dir).unwrap();
    let path = root().join("tests/differential/arithmetic.l");
    let out = cli(
        &dir,
        &["build", path.to_str().unwrap(), "--backend", "llvm"],
    );
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("backend desconocido: llvm"));
    let out = cli(&dir, &["build", path.to_str().unwrap(), "--backend"]);
    assert!(!out.status.success());
}
