//! `print`, unit functions and owned Text through the ELE-written backend:
//! `.l` source -> Stage 1 -> ELE-LIR -> x86-64 -> ELF64. Every host checks
//! acceptance, rejection and the image header; Linux x86-64 also executes the
//! image and compares its stdout byte for byte.
mod stage1_support;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn temp(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/native-print");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// Compiles a `.l` source to an ELF64 image using only Stage 1 components.
fn compile(source: &Path, name: &str) -> PathBuf {
    let emitted = Command::new(sema())
        .arg(source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    let lir_file = temp(&format!("{name}.lir"));
    fs::write(&lir_file, &lir).unwrap();
    let image = temp(&format!("{name}.elf"));
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "backend ELE: {}\n{lir}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    image
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn execute(image: &Path) -> (Option<i32>, String) {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(image).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(image, permissions).unwrap();
    let run = Command::new(image).output().unwrap();
    assert!(run.stderr.is_empty());
    (run.status.code(), String::from_utf8(run.stdout).unwrap())
}

fn rejected(fixture: &str, code: u32) {
    let out = Command::new(native())
        .arg(root().join("examples").join(fixture))
        .arg(temp("rejected.elf"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3), "{fixture}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(&format!("rechazado (código {code})")),
        "{fixture}: {stderr}"
    );
}

#[test]
fn canonical_source_with_print_and_unit_functions_builds_native_elf() {
    let image = compile(
        &root().join("examples/native_print_stage1.l"),
        "print_stage1",
    );
    let lir = fs::read_to_string(temp("print_stage1.lir")).unwrap();
    assert!(lir.contains(" result u "), "{lir}");
    assert!(lir.contains("i print val "), "{lir}");
    let _ = &image;
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        let expected =
            fs::read_to_string(root().join("examples/native_print_stage1.expected")).unwrap();
        assert_eq!(stdout, expected);
        assert_eq!(code, Some(0));
    }
}

/// Official examples that Stage 0 already ran must also run natively.
#[test]
fn official_examples_with_print_build_native_elf() {
    for (name, _expected) in [
        ("arithmetic", "42\n"),
        ("hello", "42\n"),
        ("control_flow", "15\n"),
        ("loops", "12\n"),
    ] {
        let image = compile(&root().join(format!("examples/{name}.l")), name);
        let _ = &image;
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, _expected, "{name}");
            assert_eq!(code, Some(0), "{name}");
        }
    }
}

/// Programs without output must not carry the runtime.
#[test]
fn runtime_is_emitted_only_when_used() {
    let quiet = fs::read(compile(
        &root().join("examples/ele_original_syntax.l"),
        "quiet",
    ))
    .unwrap();
    let loud = fs::read(compile(&root().join("examples/hello.l"), "loud")).unwrap();
    // `0f 05` is SYSCALL. A quiet image only has its three exits.
    let syscalls = |bytes: &[u8]| {
        bytes[4096..]
            .windows(2)
            .filter(|w| w == b"\x0f\x05")
            .count()
    };
    assert_eq!(syscalls(&quiet), 3);
    assert!(syscalls(&loud) > 3);
}

/// Owned Text end to end: literals, interpolation, growth, by-value
/// parameters, Text results and deterministic release.
#[test]
fn text_programs_build_native_elf_and_match_stage0() {
    for name in ["fibonacci", "text", "interpolation", "native_text_stage1"] {
        let source = root().join(format!("examples/{name}.l"));
        let image = compile(&source, name);
        let _ = &image;
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            // Stage 0's reference backend is the oracle for the output.
            let reference = Command::new(env!("CARGO_BIN_EXE_l"))
                .current_dir(temp(""))
                .arg("run")
                .arg(&source)
                .output()
                .unwrap();
            assert!(reference.status.success(), "{name}");
            let expected: String = String::from_utf8(reference.stdout)
                .unwrap()
                .lines()
                .filter(|line| !line.starts_with("Build: "))
                .map(|line| format!("{line}\n"))
                .collect();
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, expected, "{name}");
            assert_eq!(code, Some(0), "{name}");
        }
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let (_, stdout) = execute(&temp("native_text_stage1.elf"));
        let expected =
            fs::read_to_string(root().join("examples/native_text_stage1.expected")).unwrap();
        assert_eq!(stdout, expected);
    }
}

/// Runtime guards and accepted LIR forms that no source program reaches.
#[test]
fn text_lir_fixtures_run_with_their_documented_status() {
    for (fixture, _status, _stdout) in [
        ("native_cfg_text_literal_ok.lir", 0, "hi\n\n"),
        ("native_cfg_text_flagged_drop.lir", 0, "false\n"),
        // Appending to a literal is caught at run time, before any write.
        ("native_cfg_text_append_literal.lir", 121, ""),
    ] {
        let image = temp(&format!("{fixture}.elf"));
        let out = Command::new(native())
            .arg(root().join("examples").join(fixture))
            .arg(&image)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{fixture}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(code, Some(_status), "{fixture}");
            assert_eq!(stdout, _stdout, "{fixture}");
        }
    }
}

#[test]
fn full_int_range_constants_are_accepted() {
    let image = temp("const_min.elf");
    let out = Command::new(native())
        .arg(root().join("examples/native_cfg_const_min.lir"))
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        assert_eq!(stdout, "-9223372036854775808\ntrue\n");
        assert_eq!(code, Some(0));
    }
}

#[test]
fn unsupported_or_invalid_print_and_unit_forms_are_rejected() {
    // Reading an uninitialized variable.
    rejected("native_cfg_print_uninit.lir", 57);
    // Aggregates have no textual form.
    rejected("native_cfg_print_struct.lir", 90);
    // A unit constant is not an Int result.
    rejected("native_cfg_unit_as_int.lir", 41);
    // Unit parameters have no ABI.
    rejected("native_cfg_unit_param.lir", 45);
    // One past the maximum Int.
    rejected("native_cfg_const_overflow.lir", 33);
    // Text ownership: every one of these would corrupt or leak memory.
    rejected("native_cfg_text_use_after_move.lir", 57);
    rejected("native_cfg_text_double_drop.lir", 57);
    rejected("native_cfg_text_leak.lir", 59);
    rejected("native_cfg_text_overwrite.lir", 59);
    rejected("native_cfg_text_append_self.lir", 93);
    // Forms the backend does not lower yet must not be accepted silently.
    rejected("native_cfg_text_append_by_value.lir", 90);
    rejected("native_cfg_text_in_struct.lir", 61);
    // A reference argument for a by-value parameter.
    rejected("native_cfg_call_ref_arg.lir", 54);
    rejected("native_cfg_text_drop_int.lir", 92);
    // Malformed literals.
    rejected("native_cfg_text_bad_literal.lir", 33);
    rejected("native_cfg_text_bad_byte.lir", 33);
}
