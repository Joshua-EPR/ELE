//! Text fields of `shape` through the ELE-written backend: construction,
//! borrowed reads, replacement through `edit`, moves and per-field release
//! (`dropfield`, flagged too). `.l` source -> Stage 1 -> ELE-LIR -> x86-64 ->
//! ELF64. Every host checks acceptance, rejection and the image header;
//! Linux x86-64 also executes the images and compares their stdout byte for
//! byte with the output Stage 0 produced for the same sources.
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
    let dir = root().join("target/stage1-tests/native-text-fields");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn backend(lir: &Path, image: &Path) -> std::process::Output {
    Command::new(native()).arg(lir).arg(image).output().unwrap()
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

#[test]
fn text_fields_match_stage0() {
    for (name, forms) in [
        (
            "native_text_fields_stage1",
            &[
                "field 6:110,111,109,98,114,101 t",
                "i dropfield p0.0 -",
                "i store p0.0 v1",
                "i print ref p1.0 0",
                "i len v1 p0.0",
                "i read v1 p0.0",
            ][..],
        ),
        (
            "native_text_fields_heap_stage1",
            &["i append v1 ref p0.0 0", "i dropfield"][..],
        ),
        (
            "native_text_fields_flags_stage1",
            &["i dropfield p0.0 v"][..],
        ),
    ] {
        let emitted = Command::new(sema())
            .arg(root().join(format!("examples/{name}.l")))
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(
            emitted.status.success(),
            "Stage 1: {}",
            String::from_utf8_lossy(&emitted.stderr)
        );
        let lir = String::from_utf8(emitted.stdout).unwrap();
        for form in forms {
            assert!(lir.contains(form), "{name}: {form}\n{lir}");
        }
        let lir_file = temp(&format!("{name}.lir"));
        fs::write(&lir_file, &lir).unwrap();
        let image = temp(&format!("{name}.elf"));
        let built = backend(&lir_file, &image);
        assert!(
            built.status.success(),
            "backend ELE: {}\n{lir}",
            String::from_utf8_lossy(&built.stderr)
        );
        let bytes = fs::read(&image).unwrap();
        assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let expected =
                fs::read_to_string(root().join(format!("examples/{name}.expected"))).unwrap();
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, expected, "{name}");
            assert_eq!(code, Some(0), "{name}");
        }
    }
}

/// Releasing a field through `edit`, filling it with a new owned Text and
/// reading it back: prints 42 and exits with its byte length.
#[test]
fn replacing_a_text_field_through_edit_runs() {
    let image = temp("tfield_replace_ok.elf");
    let out = backend(
        &root().join("examples/native_cfg_tfield_replace_ok.lir"),
        &image,
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        assert_eq!(stdout, "42\n");
        assert_eq!(code, Some(2));
    }
}

#[test]
fn unsound_text_field_ownership_is_rejected() {
    for (fixture, code) in [
        // Leaks: a live field at return, a store over a live field.
        ("native_cfg_tfield_leak.lir", 59),
        ("native_cfg_tfield_store_live.lir", 59),
        // Double release, use after move, whole use after release.
        ("native_cfg_tfield_double_drop.lir", 57),
        ("native_cfg_tfield_use_after_move.lir", 57),
        ("native_cfg_tfield_whole_after_drop.lir", 57),
        // Only Text fields are released.
        ("native_cfg_tfield_drop_int.lir", 92),
        // Through references: no move out, give the referent back whole,
        // and only an exclusive reference may replace a field.
        ("native_cfg_tfield_ref_move.lir", 95),
        ("native_cfg_tfield_ref_not_restored.lir", 95),
        ("native_cfg_tfield_shared_replace.lir", 98),
    ] {
        let out = backend(
            &root().join("examples").join(fixture),
            &temp("rejected.elf"),
        );
        assert_eq!(out.status.code(), Some(3), "{fixture}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(&format!("rechazado (código {code})")),
            "{fixture}: {stderr}"
        );
    }
}
