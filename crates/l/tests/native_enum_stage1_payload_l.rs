//! Stage 1 source -> actual LIR -> ELE-written native ELF compiler.
//! Windows tests compilation and ELF bytes; Linux x86_64 executes the ELF.
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
fn enum_payload_match_from_source_compiles_to_native_elf() {
    let base = root();
    let source = base.join("examples/native_enum_payload_stage1.l");
    let temp = base.join("target/stage1-tests/native-enum-payload-stage1");
    fs::create_dir_all(&temp).unwrap();
    let lir_file = temp.join("payload.lir");
    let executable = temp.join("payload.elf");
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
    assert!(lir.contains("module structs 0 enums 1"), "{lir}");
    assert!(
        lir.contains("i variant ") && lir.contains(" 1 ci40"),
        "{lir}"
    );
    assert!(
        lir.contains("i disc ") && lir.contains("i payload "),
        "{lir}"
    );
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    fs::write(&lir_file, &lir).unwrap();
    let result = Command::new(native())
        .arg(&lir_file)
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "backend ELE: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let bytes = fs::read(&executable).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        let actual = Command::new(&executable).output().unwrap();
        assert_eq!(
            actual.status.code(),
            Some(42),
            "{}",
            String::from_utf8_lossy(&actual.stderr)
        );
    }
}

#[test]
fn canonical_ele_syntax_compiles_real_stage1_lir_to_native_elf() {
    let base = root();
    let source = base.join("examples/ele_original_syntax.l");
    let temp = base.join("target/stage1-tests/ele-syntax-v2");
    fs::create_dir_all(&temp).unwrap();
    let lir_file = temp.join("syntax.lir");
    let elf_file = temp.join("syntax.elf");

    let emitted = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "new ELE spelling must be understood by Stage 1: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("module structs 0 enums 1"), "{lir}");
    assert!(
        lir.contains("i variant ") && lir.contains("i payload "),
        "{lir}"
    );
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    fs::write(&lir_file, &lir).unwrap();

    let compiled = Command::new(native())
        .arg(&lir_file)
        .arg(&elf_file)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "backend ELE: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let bytes = fs::read(&elf_file).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
}

#[test]
fn stage1_accepts_ele_view_and_edit_borrow_spellings() {
    let file = root().join("examples/ele_borrow_syntax.l");
    let emitted = Command::new(sema())
        .arg(&file)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1 borrow syntax must lower to typed LIR: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.starts_with("ELE-LIR 1\n"), "{lir}");
    // Reference locals are currently not accepted by the ELE-native ELF
    // backend; this test does NOT claim native borrow execution.
}

#[test]
fn enum_payload_wrong_constructor_type_is_rejected_by_stage1() {
    let base = root();
    let temp = base.join("target/stage1-tests/enum-payload-negative");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("wrong_type.l");
    fs::write(
        &source,
        "enum Estado { No, Si(Int) }\nfn main() -> Int { let e = Estado.Si(true)\n return 0\n}\n",
    )
    .unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        !result.status.success(),
        "mismatched payload must be rejected"
    );
}

#[test]
fn enum_payload_incomplete_match_is_rejected_by_stage1() {
    let base = root();
    let temp = base.join("target/stage1-tests/enum-payload-negative");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("incomplete.l");
    fs::write(&source, "enum Estado { No, Si(Int) }\nfn main() -> Int { let e = Estado.Si(40)\n match e { Estado.No => { return 0 } }\n return 3\n}\n").unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        !result.status.success(),
        "non-exhaustive match must be rejected"
    );
}

#[test]
fn enum_payload_missing_argument_is_rejected_by_stage1() {
    let base = root();
    let temp = base.join("target/stage1-tests/enum-payload-negative");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("missing_arg.l");
    fs::write(
        &source,
        "enum Estado { No, Si(Int) }\nfn main() -> Int { let e = Estado.Si()\n return 0\n}\n",
    )
    .unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(!result.status.success(), "missing payload must be rejected");
}

#[test]
fn enum_text_payload_is_dropped_by_the_native_backend() {
    let base = root();
    let temp = base.join("target/stage1-tests/enum-text-payload-drop");
    fs::create_dir_all(&temp).unwrap();
    let source = temp.join("owned_text_drop.l");
    fs::write(&source, "enum Estado { No, Texto(Text) }\nfn main() -> Int { let e = Estado.Texto(\"abc\")\n return 0\n}\n").unwrap();
    let result = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "Text enum payload must be accepted once native drop glue is available: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let lir = String::from_utf8(result.stdout).unwrap();
    assert!(lir.contains("i variant "), "{lir}");
    assert!(lir.contains("i drop "), "owned enum must be dropped on return: {lir}");

    let lir_file = temp.join("owned_text_drop.lir");
    let executable = temp.join("owned_text_drop.elf");
    fs::write(&lir_file, &lir).unwrap();
    let compiled = Command::new(native())
        .arg(&lir_file)
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "native backend must emit enum Text drop glue: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let bytes = fs::read(&executable).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        let actual = Command::new(&executable).output().unwrap();
        assert_eq!(actual.status.code(), Some(0), "{}", String::from_utf8_lossy(&actual.stderr));
    }
}

fn reject_match_source(name: &str, source: &str) {
    let base = root();
    let temp = base.join("target/stage1-tests/enum-payload-negative");
    fs::create_dir_all(&temp).unwrap();
    let path = temp.join(name);
    fs::write(&path, source).unwrap();
    let result = Command::new(sema())
        .arg(&path)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(!result.status.success(), "invalid match accepted: {name}");
}

#[test]
fn enum_match_rejects_a_variant_from_another_nominal_enum() {
    reject_match_source(
        "wrong_nominal_match.l",
        r#"
enum Estado { No, Si(Int) }
enum Otro { No, Si(Int) }
fn main() -> Int {
    let e = Estado.Si(40)
    match e {
        Otro.No => { return 0 },
        Estado.Si(v) => { return v },
    }
    return 1
}
"#,
    );
}

#[test]
fn enum_match_rejects_missing_payload_pattern() {
    reject_match_source(
        "missing_payload_pattern.l",
        r#"
enum Estado { No, Si(Int) }
fn main() -> Int {
    let e = Estado.Si(40)
    match e {
        Estado.No => { return 0 },
        Estado.Si => { return 1 },
    }
    return 2
}
"#,
    );
}

#[test]
fn enum_match_rejects_payload_pattern_on_unit_variant() {
    reject_match_source(
        "unit_payload_pattern.l",
        r#"
enum Estado { No, Si(Int) }
fn main() -> Int {
    let e = Estado.No
    match e {
        Estado.No(v) => { return 0 },
        Estado.Si(v) => { return v },
    }
    return 2
}
"#,
    );
}

#[test]
fn nested_nominal_choose_from_real_ele_source_compiles_to_elf() {
    let base = root();
    let source = base.join("examples/ele_nested_nominal_match.l");
    let temp = base.join("target/stage1-tests/ele-nested-nominal");
    fs::create_dir_all(&temp).unwrap();
    let lir_file = temp.join("nested-match.lir");
    let elf_file = temp.join("nested-match.elf");

    let emitted = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1 nested match: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("module structs 0 enums 2"), "{lir}");
    assert!(
        lir.matches("i disc ").count() >= 2,
        "both nominal discriminants must be checked: {lir}"
    );
    assert!(
        lir.matches("i payload ").count() >= 2,
        "both primitive payloads must be guarded: {lir}"
    );
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    fs::write(&lir_file, &lir).unwrap();

    let compiled = Command::new(native())
        .arg(&lir_file)
        .arg(&elf_file)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "ELE backend nested match: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let bytes = fs::read(&elf_file).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
}

#[test]
fn enum_match_rejects_literal_and_multiple_payload_binders() {
    for (file, pattern) in [
        ("numeric_pattern.l", "Estado.Si(42)"),
        ("multiple_binders.l", "Estado.Si(a, b)"),
        ("expression_pattern.l", "Estado.Si(v+1)"),
    ] {
        let source = format!(
            "choice Estado {{ No, Si(Int) }}\nflow main() => Int {{\n hold e = Estado@Si(40)\n choose e {{ Estado.No: {{ give 0 }}, {pattern}: {{ give 1 }} }}\n give 2\n}}\n"
        );
        reject_match_source(file, &source);
    }
}
