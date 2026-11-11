//! `shape` and `choice` by value through the ELE-written backend: parameters,
//! results through a hidden pointer, nesting, and partial moves of fields
//! tracked as move paths. `.l` source -> Stage 1 -> ELE-LIR -> x86-64 ->
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
    let dir = root().join("target/stage1-tests/native-aggregates");
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
fn shapes_and_choices_by_value_match_stage0() {
    for (name, forms) in [
        (
            "native_shape_abi_stage1",
            &[
                "result s0",
                "result s1",
                "result e0",
                "var v0 val s0",
                "val v",
            ][..],
        ),
        (
            "native_shape_moves_stage1",
            &["result s1", "i read", "ref p", "result e0"][..],
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

/// Moving disjoint fields and subfields out of a nested shape, storing new
/// values back and then using the whole value: 5 + 30 + 100.
#[test]
fn partial_moves_with_reinitialization_run() {
    let image = temp("partial_move_ok.elf");
    let out = backend(
        &root().join("examples/native_cfg_partial_move_ok.lir"),
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
        assert_eq!(stdout, "");
        assert_eq!(code, Some(135));
    }
}

#[test]
fn invalid_aggregate_moves_and_signatures_are_rejected() {
    for (fixture, code) in [
        // Using a value, or a parent, after moving one of its fields.
        ("native_cfg_partial_use_whole.lir", 57),
        ("native_cfg_partial_read_parent.lir", 57),
        ("native_cfg_partial_twice.lir", 57),
        // Moved in one branch only: maybe moved at the join.
        ("native_cfg_partial_join.lir", 57),
        // Returning a value with a field moved out.
        ("native_cfg_partial_return.lir", 57),
        ("native_cfg_nested_bad_read_struct.lir", 57),
        // Signatures and moves of whole aggregates.
        ("native_cfg_agg_main_result.lir", 50),
        ("native_cfg_agg_arg_type.lir", 54),
        ("native_cfg_agg_use_after_call.lir", 57),
        ("native_cfg_agg_result_type.lir", 41),
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
