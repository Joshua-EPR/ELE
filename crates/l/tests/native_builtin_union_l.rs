//! Vertical Stage 1 primitive Option/Result lowering tests.
//! The Rust harness builds Stage 1 (bootstrap only), validates the
//! serialized ELE-LIR, and executes the *ELE-written* ELF backend.
#[path = "stage1_support/elf_exec.rs"]
mod elf_exec;
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

    let dir = temp.join("primitive-run");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    if let Some(run) = elf_exec::execute(&executable, &dir, &[]) {
        assert_eq!(run.code, Some(50), "native Option/Result: {}", run.stderr);
    }
}

#[test]
fn owned_union_whole_drop_runs_through_union_drop_glue() {
    // #5: Stage 1 lowers Option<Text> (moved payload, atomic drop) and the
    // Rust protocol validator accepts it. Layout code 82 is resolved
    // (Option<Text> is laid out with 32 bytes, align 8) and the whole-union
    // `i drop` that used to be rejected with code 92 is now lowered through
    // the union drop glue (native_cfg_list_emit.l cfgEmitUnionGlue): the
    // image is written and, where ELF64 can run, exits 0 with no output.
    let temp = root().join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("owned_whole_drop.l");
    fs::write(
        &source,
        "flow main() {\n    hold value: Option of[Text] = Some(\"owned\")\n}\n",
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
    assert!(lir.contains("i drop v"), "{lir}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    let lir_file = temp.join("owned_whole_drop.lir");
    let image = temp.join("owned_whole_drop.elf");
    fs::write(&lir_file, &lir).unwrap();
    let _ = fs::remove_file(&image);
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "whole Option<Text> drop: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    let dir = temp.join("owned_whole_drop-run");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
        assert_eq!(run.code, Some(0), "{}", run.stderr);
        assert_eq!(run.stdout, "");
        if let Some(heap) = run.heap {
            // A literal payload owns no mapping: the glue must not release one.
            heap.assert_balanced("Option<Text> literal");
            assert_eq!(heap.maps, 0, "{heap:?}");
        }
    }
}

#[test]
fn whole_shape_drop_remains_fail_closed() {
    // Still unsupported after union drop glue: a whole shape has no drop of
    // its own (its owned fields are released with `dropfield`), so `i drop`
    // of a shape keeps code 92 and writes no image.
    let temp = root().join("target/stage1-tests/option-result");
    fs::create_dir_all(&temp).unwrap();
    let lir = "ELE-LIR 1
module structs 1 enums 0 funcs 1 main f0
struct s0 1:80 fields 1
field 1:120 t
func f0 4:109,97,105,110 params 0 result i 0 0 vars 1 blocks 1
var v0 val s0
block 0 2
i struct v0 s0 1 ct2:104,105
i drop v0 -
t return ci0
endfunc
end
";
    let lir_file = temp.join("whole_shape_drop.lir");
    let image = temp.join("whole_shape_drop.elf");
    fs::write(&lir_file, lir).unwrap();
    let _ = fs::remove_file(&image);
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert_eq!(
        built.status.code(),
        Some(3),
        "whole shape drop reached native code"
    );
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

    // ELF magic alone cannot establish valid payload moves, length reads,
    // or drop semantics: execute the emitted program on a compatible host.
    let dir = temp.join("owned_layout_ok-run");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
        assert_eq!(
            run.code,
            Some(5),
            "Option<Text> payload extraction must return its five-byte length: {}",
            run.stderr
        );
        if let Some(heap) = run.heap {
            heap.assert_balanced("Option<Text> payload extraction");
        }
    }
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
