//! Vertical Stage 1 primitive Option/Result lowering tests.
//! The Rust harness builds Stage 1 (bootstrap only), validates the
//! serialized ELE-LIR, and executes the *ELE-written* ELF backend.
mod stage1_support;

use std::{fs, path::PathBuf, process::Command, sync::OnceLock};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn sema() -> &'static std::path::Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn native() -> &'static std::path::Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

#[test]
fn primitive_option_result_uses_checked_variant_disc_payload_protocol() {
    let base = root();
    let source = base.join("examples/native_option_result_primitive_stage1.l");
    let temp = base.join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let lir_file = temp.join("primitive.lir");
    let executable = temp.join("primitive.elf");
    let emitted = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("module structs 0 enums 2"), "{lir}");
    assert!(lir.contains("variants 2"), "{lir}");
    assert!(lir.contains("variant 4:83,111,109,101 types 1 i"), "{lir}");
    assert!(lir.contains("variant 2:79,107 types 1 i"), "{lir}");
    assert!(lir.contains("variant 3:69,114,114 types 1 b"), "{lir}");
    assert!(lir.matches("i variant ").count() >= 4, "{lir}");
    assert!(lir.matches("i payload ").count() >= 3, "{lir}");
    assert!(lir.contains("i disc "), "{lir}");
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    fs::write(&lir_file, &lir).unwrap();
    let _ = fs::remove_file(&executable); // no stale successful image
    let compiled = Command::new(native())
        .arg(&lir_file)
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "backend ELE: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let bytes = fs::read(&executable).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&executable).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(&executable, perms).unwrap();
        let actual = Command::new(&executable).output().unwrap();
        assert_eq!(
            actual.status.code(),
            Some(50),
            "native Option/Result: {}",
            String::from_utf8_lossy(&actual.stderr)
        );
    }
}

#[test]
fn owned_union_payload_is_verified_lir_but_not_native_code() {
    // #5: Stage 1 lowers Option<Text> (moved payload, atomic drop) and the
    // Rust protocol validator accepts it; the ELE backend has no verified
    // owned-payload layout yet and must reject it without writing an ELF.
    let temp = root().join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("owned_not_lowerable.l");
    fs::write(
        &source,
        "fn main() { let value: Option<Text> = Some(\"owned\") }\n",
    )
    .unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&result.stderr);
    assert_eq!(result.status.code(), Some(0), "{err}");
    let lir = String::from_utf8(result.stdout).unwrap();
    assert!(lir.contains("variant 4:83,111,109,101 types 1 t"), "{lir}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    let lir_file = temp.join("owned_not_lowerable.lir");
    let image = temp.join("owned_not_lowerable.elf");
    fs::write(&lir_file, &lir).unwrap();
    let _ = fs::remove_file(&image);
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(!built.status.success(), "owned payload reached native code");
    // Layout code 82 is resolved (Option<Text> is laid out with 32 bytes, align 8);
    // whole-union drop remains fail-closed (code 92) until union drop glue is implemented.
    assert_eq!(built.status.code(), Some(3));
    assert!(
        String::from_utf8_lossy(&built.stderr).contains("ELE-LIR/CFG rechazado (código 92)"),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert!(!image.exists(), "ELF written for rejected LIR");
}

#[test]
fn owned_union_payload_layout_and_codegen_succeeds_without_whole_drop() {
    // Verified layout: Option<Text> is laid out with 32 bytes (8 discriminant + 24 Text payload), align 8.
    // When the payload is extracted and dropped directly without dropping the union itself,
    // the ELE native backend succeeds in generating a valid ELF64 image.
    let temp = root().join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let lir = r#"ELE-LIR 1
module structs 0 enums 1 funcs 1 main f0
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 t
func f0 4:109,97,105,110 params 0 result i 0 0 vars 3 blocks 1
var v0 val e0
var v1 val t
var v2 val i
block 0 4
i variant v0 e0 1 1 ct5:104,101,108,108,111 @1:1
i payload v1 p0 e0 1 @1:2
i len v2 p1 @1:3
i drop v1 - @1:4
t return v2 @1:5
endfunc
end
"#;
    let lir_file = temp.join("owned_layout_ok.lir");
    let image = temp.join("owned_layout_ok.elf");
    fs::write(&lir_file, lir).unwrap();
    let _ = fs::remove_file(&image);
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "backend ELE failed: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert!(image.exists(), "ELF not written for valid owned union LIR");
    let bytes = fs::read(&image).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
}

#[test]
fn result_constructor_rejects_mismatched_primitive_payload_type() {
    let temp = root().join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("mismatch.l");
    fs::write(
        &source,
        "fn main() { let value: Result<Int, Bool> = Err(42) }\n",
    )
    .unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&result.stderr);
    assert_eq!(result.status.code(), Some(1), "{err}");
    assert!(err.contains("L0004"), "{err}");
}
