//! B11: an isolated Stage 1 -> ELE-LIR -> ELE-native ELF64 pipeline.
//! Stage 0 is used only to bootstrap the two executables and as a *separate*
//! reference oracle. This is not Stage 2 or compiler self-recompilation.
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

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn native() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

/// An empty PATH prevents invoking the Stage 0 CLI, cargo, rustc or a shell by
/// program name. On CI Linux, strace additionally rejects *any* child exec,
/// including an attempt to invoke Stage 0 by absolute path.
fn isolated(bin: &Path, args: &[&OsStr], trace: &Path) -> Output {
    let trace_available = cfg!(target_os = "linux") && Path::new("/usr/bin/strace").is_file();
    if cfg!(target_os = "linux") && std::env::var_os("ELE_REQUIRE_STRACE").is_some() {
        assert!(trace_available, "CI must trace Stage 1 subprocess creation");
    }
    let mut command = if trace_available {
        let mut cmd = Command::new("/usr/bin/strace");
        cmd.args(["-f", "-qq", "-e", "trace=execve,execveat", "-o"])
            .arg(trace)
            .arg(bin);
        cmd
    } else {
        Command::new(bin)
    };
    let output = command
        .args(args)
        .env("PATH", "")
        .env_remove("CARGO")
        .env_remove("RUSTC")
        .env_remove("CARGO_HOME")
        .env_remove("RUSTUP_HOME")
        .output()
        .expect("Stage 1 executable must launch without frontend tools");
    if trace_available {
        let entries = fs::read_to_string(trace).unwrap();
        let exec_count = entries
            .lines()
            .filter(|line| line.contains("execve(") || line.contains("execveat("))
            .count();
        assert_eq!(
            exec_count, 1,
            "Stage 1/native backend invoked a second executable:\n{entries}"
        );
    }
    output
}

#[test]
fn b11_real_compiler_source_produces_native_elf_without_rust_frontend() {
    let base = root();
    let scratch = base.join("target/stage1-tests/stage2-hook");
    fs::create_dir_all(&scratch).unwrap();
    let source = base.join("compiler-l/src/flow_self_harness.l");
    let lir_file = scratch.join("real-flow.lir");
    let elf = scratch.join("real-flow.elf");

    let emitted = isolated(
        sema(),
        &[source.as_os_str(), OsStr::new("--emit-lir")],
        &scratch.join("stage1-execve.log"),
    );
    assert!(
        emitted.status.success(),
        "Stage 1 ownership/LIR: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    assert!(
        emitted.stdout.starts_with(b"ELE-LIR 1\n"),
        "Stage 1 emitted no LIR v1"
    );
    fs::write(&lir_file, &emitted.stdout).unwrap();
    // A previous successful run must not mask a backend failure.
    if elf.exists() {
        fs::remove_file(&elf).unwrap();
    }
    let built = isolated(
        native(),
        &[lir_file.as_os_str(), elf.as_os_str()],
        &scratch.join("backend-execve.log"),
    );
    assert!(
        built.status.success(),
        "ELE native backend: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let image = fs::read(&elf).unwrap();
    assert!(image.len() > 4096, "native image is too small");
    assert_eq!(&image[..7], b"\x7fELF\x02\x01\x01");

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&elf).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(&elf, perms).unwrap();
        let result = Command::new(&elf).output().unwrap();
        assert_eq!(
            result.status.code(),
            Some(2),
            "real flow_cfg.l source must return 2: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
}

#[test]
fn b11_fixed_accept_reject_corpus_agrees_with_stage0() {
    let base = root();
    let scratch = base.join("target/stage1-tests/stage2-hook");
    fs::create_dir_all(&scratch).unwrap();
    for (name, source, accepted) in [
        ("valid", "fn main() -> Int { return 42 }\n", true),
        (
            "invalid",
            "fn main() { let x = \"owned\"; let y = x; print(x) }\n",
            false,
        ),
    ] {
        let source_file = scratch.join(format!("{name}.l"));
        fs::write(&source_file, source).unwrap();
        let oracle = project_l::check(source);
        assert_eq!(oracle.is_ok(), accepted, "Stage 0: {name}");
        let output = isolated(
            sema(),
            &[source_file.as_os_str(), OsStr::new("--check-ownership")],
            &scratch.join(format!("{name}-execve.log")),
        );
        assert_eq!(
            output.status.success(),
            accepted,
            "Stage 1: {name}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        if !accepted {
            let code = oracle.unwrap_err().code;
            assert!(
                String::from_utf8_lossy(&output.stderr).contains(&format!("error[{code}]")),
                "Stage 0/Stage 1 must use the same error code: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}
