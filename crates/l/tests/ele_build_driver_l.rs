//! Stage 3.1 Integration Test Suite for `ele build` and Autonomous Driver
//!
//! Verifies:
//! - Hito A: CLI options (`--version`, `--help`, `build <file.l>`, error propagation)
//! - Hito B: Native backend generation and execution (PE32+ on Windows, ELF64 on Linux/WSL)
//! - Hito C: Multi-module projects (`take` resolution, cross-module functions)
//! - Hito D: Security, borrow checking, ownership invariants and error diagnostics
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
    let dir = root().join("target/stage1-tests/driver-tests").join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Runs an ELF64 image through WSL Ubuntu on Windows or natively on Linux x86-64
fn execute_elf(image: &Path, dir: &Path) -> Option<Output> {
    let program = dir.join("prog_elf");
    fs::copy(image, &program).unwrap();
    let script = "cd \"$1\" && shift && chmod 700 prog_elf && exec ./prog_elf \"$@\"";
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
fn driver_cli_version_flag() {
    let out = Command::new(driver())
        .arg("--version")
        .output()
        .expect("failed to execute driver");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("ele 0.3.0"));
}

#[test]
fn driver_cli_help_flag() {
    let out = Command::new(driver())
        .arg("--help")
        .output()
        .expect("failed to execute driver");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("ELE Compiler Driver"));
    assert!(stdout.contains("build <archivo.l>"));
}

#[test]
fn driver_cli_missing_command_error() {
    let out = Command::new(driver())
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error[CLI]: falta el comando"));
}

#[test]
fn driver_cli_missing_input_file_error() {
    let out = Command::new(driver())
        .arg("build")
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error[CLI]: falta el archivo de entrada"));
}

#[test]
fn driver_cli_nonexistent_file_error() {
    let out = Command::new(driver())
        .args(["build", "non_existent_file_xyz.l"])
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("archivo inexistente"));
}

#[test]
fn driver_cli_syntax_error_reported() {
    let dir = work("syntax_err");
    let src = dir.join("bad.l");
    fs::write(&src, "flow main() => Int {\n    hold x =\n}\n").unwrap();

    let out = Command::new(driver())
        .args(["build", src.to_str().unwrap()])
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error[PARSER]: se esperaba expresión"));
}

#[test]
fn driver_cli_ownership_error_reported() {
    let dir = work("ownership_err");
    let src = dir.join("use_after_move.l");
    fs::write(
        &src,
        "flow consume(s: Text) {}\nflow main() => Int {\n    hold s = \"msg\"\n    consume(s)\n    consume(s)\n    give 0\n}\n",
    )
    .unwrap();

    let out = Command::new(driver())
        .args(["build", src.to_str().unwrap()])
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error[L0005]: uso de valor movido"));
}

#[test]
fn driver_cli_cycle_import_error_reported() {
    let dir = work("cycle_err");
    let a = dir.join("cycle_a.l");
    let b = dir.join("cycle_b.l");
    fs::write(&a, "take cycle_b\nflow main() => Int { give 0 }\n").unwrap();
    fs::write(&b, "take cycle_a\nexpose flow f() => Int { give 1 }\n").unwrap();

    let out = Command::new(driver())
        .args(["build", a.to_str().unwrap()])
        .output()
        .expect("failed to execute driver");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("error[L0014]: ciclo de dependencias detectado"));
}

#[test]
fn driver_builds_and_executes_pe64_hello() {
    let dir = work("hello_pe64");
    let src = dir.join("hello.l");
    let bin = dir.join("hello.exe");
    fs::write(
        &src,
        "flow main() => Int {\n    print(\"Hola desde ELE\")\n    give 0\n}\n",
    )
    .unwrap();

    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--target",
            "pe",
            "--output",
            bin.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run driver");
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(bin.exists());

    #[cfg(windows)]
    {
        let run = Command::new(&bin).output().expect("failed to run binary");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Hola desde ELE");
    }
}

#[test]
fn driver_builds_and_executes_elf64_hello() {
    let dir = work("hello_elf64");
    let src = dir.join("hello.l");
    let bin = dir.join("hello.elf");
    fs::write(
        &src,
        "flow main() => Int {\n    print(\"Hola desde ELE\")\n    give 0\n}\n",
    )
    .unwrap();

    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--target",
            "elf",
            "--output",
            bin.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run driver");
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(bin.exists());

    let bytes = fs::read(&bin).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");

    if let Some(run) = execute_elf(&bin, &dir) {
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Hola desde ELE");
    }
}

#[test]
fn driver_builds_and_executes_multimodule_project() {
    let dir = work("multimodule");
    let helper = dir.join("math_helper.l");
    let main_src = dir.join("main.l");
    let bin = dir.join("multi.exe");

    fs::write(
        &helper,
        "expose flow addNums(a: Int, b: Int) => Int { give a + b }\nexpose flow mulNums(a: Int, b: Int) => Int { give a * b }\n",
    )
    .unwrap();

    fs::write(
        &main_src,
        "take math_helper\nflow main() => Int {\n    hold x = addNums(20, 22)\n    hold y = mulNums(x, 2)\n    print(\"Resultado: {y}\")\n    give 0\n}\n",
    )
    .unwrap();

    let out = Command::new(driver())
        .args([
            "build",
            main_src.to_str().unwrap(),
            "--target",
            "pe",
            "--output",
            bin.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run driver");
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(bin.exists());

    #[cfg(windows)]
    {
        let run = Command::new(&bin).output().expect("failed to run binary");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Resultado: 84");
    }
}
