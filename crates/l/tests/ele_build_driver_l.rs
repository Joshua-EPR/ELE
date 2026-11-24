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

#[test]
fn driver_cli_self_overwrite_rejected() {
    let dir = work("self_overwrite");
    let src = dir.join("self.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();

    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--output",
            src.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no puede sobrescribir el archivo de entrada"));
}

#[test]
fn driver_cli_self_overwrite_relative_dot_slash() {
    let dir = work("self_overwrite_dotslash");
    let src = dir.join("self.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "self.l", "--output", "./self.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no puede sobrescribir el archivo de entrada"));
}

#[test]
fn driver_cli_self_overwrite_parent_traversal() {
    let dir = work("self_overwrite_parent");
    let sub = dir.join("sub");
    fs::create_dir_all(&sub).unwrap();
    let src = dir.join("self.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "self.l", "--output", "sub/../self.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no puede sobrescribir el archivo de entrada"));
}

#[test]
fn driver_cli_self_overwrite_slash_backslash() {
    let dir = work("self_overwrite_slashes");
    let sub = dir.join("sub");
    fs::create_dir_all(&sub).unwrap();
    let src = sub.join("self.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "sub/self.l", "--output", r"sub\self.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no puede sobrescribir el archivo de entrada"));
}

#[test]
#[cfg(windows)]
fn driver_cli_self_overwrite_case_windows() {
    let dir = work("self_overwrite_case");
    let src = dir.join("self.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "self.l", "--output", "SELF.L"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("no puede sobrescribir el archivo de entrada"));
}

#[test]
fn driver_default_target_windows_is_pe() {
    let dir = work("default_target");
    let src = dir.join("prog.l");
    let expected_exe = dir.join("prog.exe");
    let _ = fs::remove_file(&expected_exe);
    fs::write(
        &src,
        "flow main() => Int { print(\"Default target test\"); give 0 }\n",
    )
    .unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "prog.l"])
        .output()
        .expect("failed to run driver");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    #[cfg(windows)]
    {
        assert!(expected_exe.exists());
        let run = Command::new(&expected_exe)
            .output()
            .expect("failed to run exe");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Default target test");
    }

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let expected_bin = dir.join("prog");
        assert!(expected_bin.exists());
        let run = Command::new(&expected_bin)
            .output()
            .expect("failed to run elf");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Default target test");
    }
}

#[test]
fn driver_builds_self_rebuild_windows_fixpoint() {
    let dir = work("self_rebuild_win");
    let gen2_exe = dir.join("ele_gen2.exe");
    #[cfg(windows)]
    let gen3_exe = dir.join("ele_gen3.exe");
    let hello_src = dir.join("hello.l");
    #[cfg(windows)]
    let hello_bin = dir.join("hello_by_gen3.exe");
    fs::write(
        &hello_src,
        "flow main() => Int { print(\"Autonomy Gen 3\"); give 0 }\n",
    )
    .unwrap();

    let driver_src = root().join("compiler-l/src/main_driver.l");

    // Gen 1 (driver()) builds Gen 2
    let out_gen2 = Command::new(driver())
        .current_dir(root())
        .args([
            "build",
            driver_src.to_str().unwrap(),
            "--target",
            "pe",
            "--output",
            gen2_exe.to_str().unwrap(),
        ])
        .output()
        .expect("failed to build Gen 2");
    assert!(
        out_gen2.status.success(),
        "{}",
        String::from_utf8_lossy(&out_gen2.stderr)
    );
    assert!(gen2_exe.exists());

    let bytes_gen2 = fs::read(&gen2_exe).unwrap();
    assert!(bytes_gen2.starts_with(b"MZ"), "PE header MZ magic required");

    #[cfg(windows)]
    {
        // Gen 2 builds Gen 3
        let out_gen3 = Command::new(&gen2_exe)
            .current_dir(root())
            .args([
                "build",
                driver_src.to_str().unwrap(),
                "--target",
                "pe",
                "--output",
                gen3_exe.to_str().unwrap(),
            ])
            .output()
            .expect("failed to build Gen 3");
        assert!(
            out_gen3.status.success(),
            "{}",
            String::from_utf8_lossy(&out_gen3.stderr)
        );
        assert!(gen3_exe.exists());

        // Assert bitwise identical fixpoint
        let bytes_gen3 = fs::read(&gen3_exe).unwrap();
        assert_eq!(
            bytes_gen2, bytes_gen3,
            "Gen 2 and Gen 3 binaries must be bitwise identical fixpoint"
        );

        // Gen 3 compiles and runs hello
        let out_hello = Command::new(&gen3_exe)
            .current_dir(&dir)
            .args(["build", "hello.l", "--output", "hello_by_gen3.exe"])
            .output()
            .expect("Gen 3 failed to compile hello.l");
        assert!(
            out_hello.status.success(),
            "{}",
            String::from_utf8_lossy(&out_hello.stderr)
        );

        let run = Command::new(&hello_bin)
            .output()
            .expect("failed to run hello_by_gen3");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Autonomy Gen 3");

        // Exercise the autonomous writer and identity primitive, not only
        // Stage 0's Rust bootstrap implementation.
        let source_before = fs::read(&hello_src).unwrap();
        let alias = dir.join("hardlink-to-source.exe");
        let _ = fs::remove_file(&alias);
        fs::hard_link(&hello_src, &alias).unwrap();
        let rejected = Command::new(&gen3_exe)
            .current_dir(&dir)
            .args(["build", "hello.l", "--output", "hardlink-to-source.exe"])
            .output()
            .unwrap();
        assert_eq!(rejected.status.code(), Some(2));
        assert_eq!(fs::read(&hello_src).unwrap(), source_before);
        assert_eq!(fs::read(&alias).unwrap(), source_before);

        let occupied = dir.join("salida ñ.exe.tmp.0");
        fs::write(&occupied, b"occupied").unwrap();
        let unicode = Command::new(&gen3_exe)
            .current_dir(&dir)
            .args(["build", "hello.l", "--output", "salida ñ.exe"])
            .output()
            .unwrap();
        assert!(
            unicode.status.success(),
            "{}",
            String::from_utf8_lossy(&unicode.stderr)
        );
        assert!(
            fs::read(dir.join("salida ñ.exe"))
                .unwrap()
                .starts_with(b"MZ")
        );
        assert_eq!(fs::read(&occupied).unwrap(), b"occupied");
    }
}

#[test]
fn driver_builds_self_rebuild_linux_fixpoint() {
    let dir = work("self_rebuild_linux");
    let gen2_elf = dir.join("ele_gen2.elf");
    let gen3_elf = dir.join("ele_gen3.elf");
    let hello_src = dir.join("hello.l");
    let hello_elf = dir.join("hello_by_gen3.elf");
    fs::write(
        &hello_src,
        "flow main() => Int { print(\"Autonomy Gen 3 Linux\"); give 0 }\n",
    )
    .unwrap();
    let driver_src = root().join("compiler-l/src/main_driver.l");

    // Gen 1 (driver()) builds Gen 2 ELF64
    let out_gen2 = Command::new(driver())
        .current_dir(root())
        .args([
            "build",
            driver_src.to_str().unwrap(),
            "--target",
            "elf",
            "--output",
            gen2_elf.to_str().unwrap(),
        ])
        .output()
        .expect("failed to build Gen 2 ELF64");
    assert!(
        out_gen2.status.success(),
        "{}",
        String::from_utf8_lossy(&out_gen2.stderr)
    );
    assert!(gen2_elf.exists());

    let bytes_gen2 = fs::read(&gen2_elf).unwrap();
    assert_eq!(
        &bytes_gen2[..7],
        b"\x7fELF\x02\x01\x01",
        "ELF64 header magic required"
    );

    // If native Linux x86-64, execute directly
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        let chmod = Command::new("chmod")
            .args(["755", gen2_elf.to_str().unwrap()])
            .status()
            .expect("failed to chmod gen2_elf");
        assert!(chmod.success());

        // Gen 2 builds Gen 3
        let out_gen3 = Command::new(&gen2_elf)
            .current_dir(root())
            .args([
                "build",
                driver_src.to_str().unwrap(),
                "--target",
                "elf",
                "--output",
                gen3_elf.to_str().unwrap(),
            ])
            .output()
            .expect("Gen 2 failed to build Gen 3 on native Linux");
        assert!(
            out_gen3.status.success(),
            "Gen 2 ELF64 build failed: {}",
            String::from_utf8_lossy(&out_gen3.stderr)
        );
        assert!(gen3_elf.exists());

        let bytes_gen3 = fs::read(&gen3_elf).unwrap();
        assert_eq!(
            bytes_gen2, bytes_gen3,
            "Gen 2 and Gen 3 ELF64 binaries must be bitwise identical fixpoint on Linux"
        );

        let chmod3 = Command::new("chmod")
            .args(["755", gen3_elf.to_str().unwrap()])
            .status()
            .expect("failed to chmod gen3_elf");
        assert!(chmod3.success());

        // Gen 3 builds hello
        let out_hello = Command::new(&gen3_elf)
            .current_dir(&dir)
            .args([
                "build",
                hello_src.to_str().unwrap(),
                "--target",
                "elf",
                "--output",
                hello_elf.to_str().unwrap(),
            ])
            .output()
            .expect("Gen 3 failed to build hello on native Linux");
        assert!(
            out_hello.status.success(),
            "Gen 3 hello build failed: {}",
            String::from_utf8_lossy(&out_hello.stderr)
        );
        assert!(hello_elf.exists());

        let chmod_h = Command::new("chmod")
            .args(["755", hello_elf.to_str().unwrap()])
            .status()
            .expect("failed to chmod hello_elf");
        assert!(chmod_h.success());

        let run = Command::new(&hello_elf)
            .output()
            .expect("failed to run hello_elf");
        assert!(run.status.success());
        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(stdout.trim(), "Autonomy Gen 3 Linux");
    } else if let Ok(distro) = std::env::var("ELE_TEST_WSL_DISTRO") {
        let canonical_dir = dir.canonicalize().unwrap();
        let windows_dir = canonical_dir
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .replace('\\', "/");
        let (drive, rest) = windows_dir.split_once(":/").expect("absolute path");
        let linux_dir = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());

        let canonical_root = root().canonicalize().unwrap();
        let windows_root = canonical_root
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .replace('\\', "/");
        let (root_drive, root_rest) = windows_root.split_once(":/").expect("absolute path");
        let linux_root = format!("/mnt/{}/{root_rest}", root_drive.to_ascii_lowercase());

        let script = format!(
            "chmod 755 \"{linux_dir}/ele_gen2.elf\" && \
             \"{linux_dir}/ele_gen2.elf\" build \"{linux_root}/compiler-l/src/main_driver.l\" --target elf --output \"{linux_dir}/ele_gen3.elf\" && \
             chmod 755 \"{linux_dir}/ele_gen3.elf\" && \
             \"{linux_dir}/ele_gen3.elf\" build \"{linux_dir}/hello.l\" --target elf --output \"{linux_dir}/hello_by_gen3.elf\" && \
             chmod 755 \"{linux_dir}/hello_by_gen3.elf\" && \
             \"{linux_dir}/hello_by_gen3.elf\""
        );
        let run_wsl = Command::new("wsl")
            .args(["-d", &distro, "--exec", "sh", "-c", &script])
            .output()
            .unwrap();
        assert!(
            run_wsl.status.success(),
            "Gen 2 / Gen 3 execution failed in WSL: {}",
            String::from_utf8_lossy(&run_wsl.stderr)
        );
        let stdout = String::from_utf8_lossy(&run_wsl.stdout);
        assert_eq!(stdout.trim(), "Autonomy Gen 3 Linux");
        assert!(gen3_elf.exists());

        let bytes_gen3 = fs::read(&gen3_elf).unwrap();
        assert_eq!(
            bytes_gen2, bytes_gen3,
            "Gen 2 and Gen 3 ELF64 binaries must be bitwise identical fixpoint in WSL"
        );
    } else {
        if std::env::var_os("ELE_REQUIRE_NATIVE_EXEC").is_some_and(|v| v == "1") {
            panic!(
                "ELE_REQUIRE_NATIVE_EXEC=1 but host cannot run ELF64 (neither native Linux x86_64 nor ELE_TEST_WSL_DISTRO available)"
            );
        }
        eprintln!("[INFO] Skipping ELF64 Gen 2 execution on Windows without WSL configured");
    }
}

#[test]
fn driver_cli_rejects_overwrite_of_imported_module() {
    let dir = work("reject_overwrite_imported_mod");
    let main_src = dir.join("main.l");
    let helper_src = dir.join("helper.l");
    let helper_content = "flow helperValue() => Int { give 42 }\n";
    fs::write(
        &main_src,
        "take helper\nflow main() => Int { give helperValue() }\n",
    )
    .unwrap();
    fs::write(&helper_src, helper_content).unwrap();

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "main.l", "--output", "helper.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("no puede sobrescribir el módulo fuente")
            || stderr.contains("no puede sobrescribir"),
        "unexpected stderr: {stderr}"
    );

    // Verify imported source file remains completely intact
    let preserved = fs::read_to_string(&helper_src).unwrap();
    assert_eq!(preserved, helper_content);
}

#[test]
fn driver_preserves_preexisting_predictable_temporary() {
    let dir = work("preexisting_predictable_temp");
    let source = dir.join("main.l");
    let output = dir.join("salida ñ.exe");
    let old_temp = dir.join("salida ñ.exe.tmp.0");
    let sentinel = b"another user's file";
    fs::write(&source, "flow main() => Int { give 0 }\n").unwrap();
    fs::write(&old_temp, sentinel).unwrap();

    let result = Command::new(driver())
        .current_dir(&dir)
        .args([
            "build",
            "main.l",
            "--target",
            "pe",
            "--output",
            "salida ñ.exe",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(fs::read(&output).unwrap().starts_with(b"MZ"));
    assert_eq!(fs::read(&old_temp).unwrap(), sentinel);
    assert_eq!(
        fs::read_to_string(&source).unwrap(),
        "flow main() => Int { give 0 }\n"
    );
}

#[test]
fn driver_reports_missing_output_parent_without_touching_source() {
    let dir = work("missing_output_parent");
    let source = dir.join("main.l");
    let content = "flow main() => Int { give 0 }\n";
    fs::write(&source, content).unwrap();
    let result = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "main.l", "--output", "absent-parent/out.exe"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(4));
    assert!(String::from_utf8_lossy(&result.stderr).contains("no se pudo verificar la identidad"));
    assert_eq!(fs::read_to_string(&source).unwrap(), content);
}

#[test]
fn driver_cli_source_intact_on_failed_compilation_and_overwrite() {
    let dir = work("source_intact_safety");
    let src = dir.join("prog.l");
    let src_content = "flow main() => Int { give 100 }\n";
    fs::write(&src, src_content).unwrap();

    // 1. Direct overwrite rejection
    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "prog.l", "--output", "prog.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(fs::read_to_string(&src).unwrap(), src_content);

    // 2. Syntax error in another file with --output prog.l
    let bad_src = dir.join("bad.l");
    fs::write(&bad_src, "flow main() => Int { hold x = \n").unwrap();
    let out_bad = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "bad.l", "--output", "prog.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out_bad.status.success());
    assert_eq!(fs::read_to_string(&src).unwrap(), src_content);
}

#[test]
fn driver_cli_rejects_overwrite_of_hardlink_source() {
    let dir = work("reject_overwrite_hardlink");
    let src = dir.join("main.l");
    let link = dir.join("main_alias.l");
    let src_content = "flow main() => Int { give 0 }\n";
    let _ = fs::remove_file(&link);
    fs::write(&src, src_content).unwrap();

    // Attempt to create hardlink
    if fs::hard_link(&src, &link).is_err() {
        eprintln!("[INFO] hardlink creation unsupported on this filesystem, skipping test");
        return;
    }

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "main.l", "--output", "main_alias.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("alias detectado") || stderr.contains("no puede sobrescribir"),
        "unexpected stderr: {stderr}"
    );

    // Verify source and link are untouched and still contain source code
    assert_eq!(fs::read_to_string(&src).unwrap(), src_content);
    assert_eq!(fs::read_to_string(&link).unwrap(), src_content);
}

#[test]
fn driver_cli_rejects_overwrite_of_imported_module_hardlink() {
    let dir = work("reject_overwrite_imported_hardlink");
    let main_src = dir.join("main.l");
    let helper_src = dir.join("helper.l");
    let helper_link = dir.join("helper_alias.l");
    let helper_content = "flow helperValue() => Int { give 99 }\n";
    let _ = fs::remove_file(&helper_link);
    fs::write(
        &main_src,
        "take helper\nflow main() => Int { give helperValue() }\n",
    )
    .unwrap();
    fs::write(&helper_src, helper_content).unwrap();

    if fs::hard_link(&helper_src, &helper_link).is_err() {
        eprintln!("[INFO] hardlink creation unsupported on this filesystem, skipping test");
        return;
    }

    let out = Command::new(driver())
        .current_dir(&dir)
        .args(["build", "main.l", "--output", "helper_alias.l"])
        .output()
        .expect("failed to run driver");
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("alias detectado") || stderr.contains("no puede sobrescribir"),
        "unexpected stderr: {stderr}"
    );

    // Verify helper and alias remain intact
    assert_eq!(fs::read_to_string(&helper_src).unwrap(), helper_content);
    assert_eq!(fs::read_to_string(&helper_link).unwrap(), helper_content);
}

#[test]
fn driver_resolves_elepad_std_console_with_explicit_library_root() {
    let dir = work("std_console_lib_root");
    let src = root().join("apps/elepad/probes/console_import.l");
    let image = dir.join(if cfg!(windows) {
        "elepad_std_probe.exe"
    } else {
        "elepad_std_probe.elf"
    });
    let target = if cfg!(windows) { "pe" } else { "elf" };
    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--target",
            target,
            "--lib",
            root().to_str().unwrap(),
            "--output",
            image.to_str().unwrap(),
        ])
        .output()
        .expect("failed to compile ELEPad std console probe");
    assert!(
        out.status.success(),
        "ELEPad should import std.io.console from --lib: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(image.is_file());

    let run = if cfg!(windows) {
        Command::new(&image).output().unwrap()
    } else {
        execute_elf(&image, &dir).expect("Linux ELF execution unavailable")
    };
    assert!(
        run.status.success(),
        "console probe exited: {:?}",
        run.status
    );
    assert_eq!(
        String::from_utf8_lossy(&run.stdout).trim(),
        "elepad-std-import-ok"
    );

    // No implicit CWD/std lookup: the same source must fail without --lib.
    let without_lib = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--target",
            target,
            "--output",
            dir.join("without_lib.bin").to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!without_lib.status.success());
    assert!(
        String::from_utf8_lossy(&without_lib.stderr).contains("error[L0014]"),
        "missing explicit library root must not be silently ignored"
    );
}

#[test]
fn driver_library_search_preserves_local_module_precedence() {
    let dir = work("library_local_precedence");
    let std_dir = dir.join("std/io");
    fs::create_dir_all(&std_dir).unwrap();
    let src = dir.join("entry.l");
    let image = dir.join(if cfg!(windows) {
        "local.exe"
    } else {
        "local.elf"
    });
    fs::write(
        std_dir.join("console.l"),
        "expose flow localTag() => Int { give 73 }\n",
    )
    .unwrap();
    fs::write(
        &src,
        "take std.io.console\nflow main() => Int { give localTag() }\n",
    )
    .unwrap();
    let target = if cfg!(windows) { "pe" } else { "elf" };
    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--target",
            target,
            "--lib",
            root().to_str().unwrap(),
            "--output",
            image.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "local override should be compiled: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let run = if cfg!(windows) {
        Command::new(&image).output().unwrap()
    } else {
        execute_elf(&image, &dir).expect("Linux ELF execution unavailable")
    };
    assert_eq!(run.status.code(), Some(73));
}

#[test]
fn driver_library_root_fails_closed_on_invalid_local_module() {
    let dir = work("library_invalid_local");
    let std_dir = dir.join("std/io");
    fs::create_dir_all(&std_dir).unwrap();
    fs::write(std_dir.join("console.l"), [0xff, 0xfe, 0xfd]).unwrap();
    let src = dir.join("entry.l");
    fs::write(&src, "take std.io.console\nflow main() => Int { give 0 }\n").unwrap();
    let image = dir.join("must_not_exist.bin");
    let _ = fs::remove_file(&image);
    let out = Command::new(driver())
        .args([
            "build",
            src.to_str().unwrap(),
            "--lib",
            root().to_str().unwrap(),
            "--output",
            image.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        !out.status.success(),
        "invalid local UTF-8 must not fall back"
    );
    assert!(
        !image.exists(),
        "invalid local module unexpectedly produced output"
    );
    assert!(String::from_utf8_lossy(&out.stderr).contains("error[L0014]"));
}

#[test]
fn driver_library_root_output_cannot_overwrite_library_source() {
    let dir = work("library_source_protection");
    let std_dir = dir.join("lib_root/std/io");
    fs::create_dir_all(&std_dir).unwrap();
    let entry = dir.join("entry.l");
    let lib_source = std_dir.join("console.l");
    let original = "expose flow libraryTag() => Int { give 19 }\n";
    fs::write(&lib_source, original).unwrap();
    fs::write(
        &entry,
        "take std.io.console\nflow main() => Int { give libraryTag() }\n",
    )
    .unwrap();
    let out = Command::new(driver())
        .args([
            "build",
            entry.to_str().unwrap(),
            "--lib",
            dir.join("lib_root").to_str().unwrap(),
            "--output",
            lib_source.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert_eq!(fs::read_to_string(&lib_source).unwrap(), original);
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("no puede sobrescribir") || err.contains("alias detectado"),
        "library source must be protected: {err}"
    );
}

#[test]
fn driver_library_root_cli_validation() {
    let dir = work("library_cli_validation");
    let src = dir.join("entry.l");
    fs::write(&src, "flow main() => Int { give 0 }\n").unwrap();
    let source = src.to_str().unwrap();
    for arguments in [
        vec!["build", source, "--lib"],
        vec!["build", source, "--lib", ""],
        vec!["build", source, "--lib", "--target", "pe"],
        vec!["build", source, "--lib", ".", "--lib", "."],
    ] {
        let out = Command::new(driver()).args(&arguments).output().unwrap();
        assert_eq!(
            out.status.code(),
            Some(2),
            "must reject invalid --lib usage {:?}: {}",
            arguments,
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

// ---------------------------------------------------------------------------
// Compile-time constants (`fixed`). The driver folds constant expressions with
// Stage 0's rules (crates/l/src/consteval.rs): references to other constants
// in any order, checked Int arithmetic, comparisons, short-circuit `&&`/`||`,
// and the same diagnostics for overflow, division by zero, runtime operands,
// calls and dependency cycles. Expected outputs were taken from Stage 0.

/// Builds `name` (already written in `dir`) for `target`, run from `dir` so
/// diagnostics carry the bare file name.
fn build_in(dir: &Path, name: &str, target: &str, output: &str) -> Output {
    Command::new(driver())
        .current_dir(dir)
        .args(["build", name, "--target", target, "--output", output])
        .output()
        .expect("failed to run driver")
}

fn assert_constant_program_output(dir: &Path, name: &str, expected: &str) {
    let pe = build_in(dir, name, "pe", "prog.exe");
    assert!(
        pe.status.success(),
        "{name}: PE build failed: {}",
        String::from_utf8_lossy(&pe.stderr)
    );
    #[cfg(windows)]
    {
        let run = Command::new(dir.join("prog.exe")).output().unwrap();
        assert!(run.status.success(), "{name}: PE image failed");
        let stdout = String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n");
        assert_eq!(stdout, expected, "{name}: PE output");
    }
    let elf = build_in(dir, name, "elf", "prog.elf");
    assert!(
        elf.status.success(),
        "{name}: ELF build failed: {}",
        String::from_utf8_lossy(&elf.stderr)
    );
    if let Some(run) = execute_elf(&dir.join("prog.elf"), dir) {
        assert!(run.status.success(), "{name}: ELF image failed");
        let stdout = String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n");
        assert_eq!(stdout, expected, "{name}: ELF output");
    }
}

#[test]
fn driver_folds_examples_constants_like_stage0() {
    let dir = work("const_example");
    let source = fs::read_to_string(root().join("examples/constants.l")).unwrap();
    fs::write(dir.join("constants.l"), source).unwrap();
    assert_constant_program_output(&dir, "constants.l", "42\n43\ntrue\n");
}

#[test]
fn driver_folds_constant_expressions() {
    let dir = work("const_expressions");
    let source = "\
fixed ANSWER: Int = BASE * 2
fixed BASE = 21
fixed NEG = -5
fixed MIX = BASE * 6 - 2 / 2 + BASE % 4 - NEG
fixed FLAG: Bool = ANSWER == 42 && !(MIX <= 0) || false
fixed LAZY_AND = false && 1 / 0 == 1
fixed LAZY_OR = true || 1 % 0 == 1
fixed EDGE = -9223372036854775807 - 1
fixed GREETING = \"hola\"
fixed ALIAS: Text = GREETING
fixed SAME = () == ()
flow main() {
    fixed next = ANSWER + 1
    print(ANSWER)
    print(next)
    print(MIX)
    print(FLAG)
    print(LAZY_AND)
    print(LAZY_OR)
    print(EDGE)
    print(ALIAS)
    print(SAME)
    change total = next
    total = total + NEG
    when total > 0 {
        fixed inner = next * 10
        print(inner)
    }
    print(total)
}
";
    fs::write(dir.join("const_expr.l"), source).unwrap();
    assert_constant_program_output(
        &dir,
        "const_expr.l",
        "42\n43\n131\ntrue\nfalse\ntrue\n-9223372036854775808\nhola\ntrue\n430\n38\n",
    );
}

#[test]
fn driver_rejects_invalid_constants_with_stage0_diagnostics() {
    const OVERFLOW: &str = "panic en const: overflow entero o división/resto por cero";
    const RUNTIME: &str =
        "const requiere expresión constante; variables runtime y llamadas no permitidas";
    let example = |path: &str| fs::read_to_string(root().join(path)).unwrap();
    let cases: Vec<(&str, String, String)> = vec![
        (
            "const_overflow.l",
            example("examples/invalid/const_overflow.l"),
            format!("1:15: error[L0004]: {OVERFLOW}"),
        ),
        (
            "const_runtime.l",
            example("examples/invalid/const_runtime.l"),
            format!("3:23: error[L0004]: {RUNTIME}"),
        ),
        (
            "div_zero.l",
            "fixed X = 1 / 0\nflow main() {}\n".into(),
            format!("1:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "rem_zero.l",
            "fixed X = 1 % 0\nflow main() {}\n".into(),
            format!("1:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "div_min.l",
            "fixed X = -9223372036854775807 - 1\nfixed Y = X / -1\nflow main() {}\n".into(),
            format!("2:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "neg_min.l",
            "fixed X = -9223372036854775807 - 1\nfixed Y = -X\nflow main() {}\n".into(),
            format!("2:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "mul_overflow.l",
            "fixed X = 4611686018427387904 * 2\nflow main() {}\n".into(),
            format!("1:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "sub_overflow.l",
            "fixed X = -9223372036854775807 - 2\nflow main() {}\n".into(),
            format!("1:11: error[L0004]: {OVERFLOW}"),
        ),
        (
            "local_overflow.l",
            "fixed BIG = 9223372036854775807\nflow main() {\n    fixed X = BIG + 1\n}\n".into(),
            format!("3:15: error[L0004]: {OVERFLOW}"),
        ),
        (
            "call.l",
            "flow f() => Int { give 1 }\nfixed X = f()\nflow main() {}\n".into(),
            format!("2:11: error[L0004]: {RUNTIME}"),
        ),
        (
            "print_call.l",
            "flow main() {\n    fixed X = print(1)\n}\n".into(),
            format!("2:15: error[L0004]: {RUNTIME}"),
        ),
        (
            "param.l",
            "flow f(x: Int) {\n    fixed X = x\n}\nflow main() {}\n".into(),
            format!("2:15: error[L0004]: {RUNTIME}"),
        ),
        (
            "short_circuit_runtime.l",
            "flow main() {\n    change x = 2\n    fixed X = false && x == 1\n}\n".into(),
            format!("3:24: error[L0004]: {RUNTIME}"),
        ),
        (
            "struct_ctor.l",
            "shape P {\n    x: Int\n}\nfixed X = P(x: 1)\nflow main() {}\n".into(),
            "4:11: error[L0001]: const requiere expresión constante; constructores de struct no permitidos aquí".into(),
        ),
        (
            "cycle.l",
            "fixed X = Y\nfixed Y = X\nflow main() {}\n".into(),
            "1:1: error[L0001]: dependencia circular entre constantes".into(),
        ),
        (
            "self_cycle.l",
            "fixed X = X + 1\nflow main() {}\n".into(),
            "1:1: error[L0001]: dependencia circular entre constantes".into(),
        ),
        (
            "cycle_dependent.l",
            "fixed A = 1\nfixed X = B + 1\nfixed B = C\nfixed C = B\nflow main() {}\n".into(),
            "2:1: error[L0001]: dependencia circular entre constantes".into(),
        ),
    ];
    for (name, source, diagnostic) in cases {
        let dir = work(&format!("const_reject_{}", name.trim_end_matches(".l")));
        fs::write(dir.join(name), source).unwrap();
        let image = dir.join("prog.exe");
        let _ = fs::remove_file(&image);
        let out = build_in(&dir, name, "pe", "prog.exe");
        let stderr = String::from_utf8_lossy(&out.stderr).replace("\r\n", "\n");
        assert_eq!(out.status.code(), Some(1), "{name}: {stderr}");
        assert_eq!(stderr, format!("{name}:{diagnostic}\n"), "{name}");
        assert!(!image.exists(), "{name}: no image may be written");
    }
}
