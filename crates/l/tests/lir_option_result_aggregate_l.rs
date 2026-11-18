//! Option/Result with DROP-FREE aggregate payloads (shapes and choices whose
//! parts are Int, Bool, unit/primitive choices or other drop-free shapes).
//! Stage 1 lowers them to checked `i variant` / `i disc` / `i payload`
//! enums; the Stage 0 protocol reader and the ELE-written native backend
//! accept and type-check them. Owned payloads (Text, lists, shapes owning
//! them) are verified ELE-LIR since #5, but the ELE backend still rejects
//! them without an image; extracting an aggregate payload is a MOVE.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

const EXPECTED_STDOUT: &str = "42\n205\n8\n156\n3\n";
const EXPECTED_EXIT: i32 = 158;

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
fn temp() -> PathBuf {
    let dir = root().join("target/stage1-tests/option-result-aggregate");
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn emit_lir(source: &Path) -> String {
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
    String::from_utf8(emitted.stdout).unwrap()
}

/// Builds an ELF64 with the ELE backend; `None` when it rejects the LIR.
fn native_build(lir: &Path, name: &str) -> Option<PathBuf> {
    let executable = temp().join(format!("{name}.elf"));
    let _ = fs::remove_file(&executable); // no stale successful image
    let built = Command::new(native())
        .arg(lir)
        .arg(&executable)
        .output()
        .unwrap();
    if !built.status.success() {
        assert!(!executable.exists(), "{name}: ELF written for rejected LIR");
        return None;
    }
    let bytes = fs::read(&executable).unwrap();
    assert!(bytes.len() > 4096, "{name}");
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01", "{name}");
    Some(executable)
}

#[allow(unused_variables)]
fn run_elf(path: &Path, stdout: Option<&str>, code: i32) {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(path, perms).unwrap();
        let actual = Command::new(path).output().unwrap();
        assert_eq!(actual.status.code(), Some(code), "{}", path.display());
        if let Some(expected) = stdout {
            assert_eq!(String::from_utf8_lossy(&actual.stdout), expected);
        }
    }
}

#[test]
fn stage1_aggregate_union_payloads_reach_verified_lir_and_native_elf() {
    let source = root().join("examples/native_option_result_aggregate_stage1.l");
    let lir = emit_lir(&source);
    // Problem { kind: Kind, offset: Int, fatal: Bool } refers to a choice
    // declared as an enum after it; Point { x, y } is all Int.
    assert!(lir.contains("module structs 2 enums 3"), "{lir}");
    assert!(lir.contains("field 4:107,105,110,100 e0"), "{lir}");
    assert!(lir.contains("variant 3:69,114,114 types 1 s0"), "{lir}");
    assert!(lir.contains("variant 4:83,111,109,101 types 1 s1"), "{lir}");
    assert!(lir.contains("variant 2:79,107 types 1 i"), "{lir}");
    assert!(lir.matches("i payload ").count() >= 3, "{lir}");
    assert!(lir.contains("i disc "), "{lir}");
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    let file = temp().join("aggregate.lir");
    fs::write(&file, &lir).unwrap();
    let elf = native_build(&file, "aggregate").expect("ELE backend rejected Stage 1 LIR");
    run_elf(&elf, Some(EXPECTED_STDOUT), EXPECTED_EXIT);

    // Stage 0 parity: its protocol reader + Cranelift run the same LIR, and
    // its own front end runs the source, with identical observable output.
    #[cfg(windows)]
    for args in [
        vec!["run-lir".to_string(), file.display().to_string()],
        vec![
            "run".to_string(),
            source.display().to_string(),
            "--backend".to_string(),
            "cranelift".to_string(),
        ],
    ] {
        let out = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(temp())
            .args(&args)
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(EXPECTED_EXIT),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
            EXPECTED_STDOUT,
            "{args:?}"
        );
    }
}

fn write_case(name: &str, text: &str) -> PathBuf {
    let path = temp().join(name);
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn owned_payloads_are_verified_lir_but_rejected_by_the_ele_backend() {
    let cases = [
        (
            "result_text.l",
            "flow main() => Int {\n    hold value: Result of[Int, Text] = Err(\"bad\")\n    give 0\n}\n",
        ),
        (
            "option_text.l",
            "flow main() => Int {\n    hold value: Option of[Text] = Some(\"owned\")\n    give 0\n}\n",
        ),
        (
            "result_shape_text.l",
            "shape Named {\n    id: Int,\n    label: Text,\n}\n\nflow make() => Result of[Int, Named] {\n    give Err(Named(id: 1, label: \"x\"))\n}\n\nflow main() => Int {\n    hold r = make()\n    give 0\n}\n",
        ),
        (
            "option_shape_list.l",
            "shape Bag {\n    items: List of[Int],\n}\n\nflow main() => Int {\n    hold b: Option of[Bag] = None\n    give 0\n}\n",
        ),
        (
            "nested_shape_text.l",
            "shape Label {\n    text: Text,\n}\n\nshape Outer {\n    id: Int,\n    label: Label,\n}\n\nflow main() => Int {\n    hold o: Option of[Outer] = None\n    give 0\n}\n",
        ),
    ];
    for (name, text) in cases {
        let path = write_case(name, text);
        let lir = emit_lir(&path);
        let parsed = project_l::lir_protocol::parse(&lir).unwrap();
        project_l::lir_protocol::validate(&parsed).unwrap();
        let file = temp().join(format!("{name}.lir"));
        fs::write(&file, &lir).unwrap();
        // Fail closed: no verified owned-payload layout in the ELE backend.
        assert!(native_build(&file, name).is_none(), "{name}: ELF built");
        let rejected = Command::new(native())
            .arg(&file)
            .arg(temp().join(format!("{name}.rejected.elf")))
            .output()
            .unwrap();
        assert_eq!(rejected.status.code(), Some(3), "{name}: not a rejection");
        assert!(
            String::from_utf8_lossy(&rejected.stderr).contains("ELE-LIR/CFG rechazado (código 82)"),
            "{name}: {}",
            String::from_utf8_lossy(&rejected.stderr)
        );
    }
    // A nominal choice with an owned payload stays outside ELE-LIR.
    let path = write_case(
        "option_choice_text.l",
        "choice Note {\n    Said(Text),\n    Quiet,\n}\n\nflow main() => Int {\n    hold n: Option of[Note] = None\n    give 0\n}\n",
    );
    let result = Command::new(sema())
        .arg(&path)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&result.stderr);
    assert_eq!(result.status.code(), Some(1), "{err}");
    assert!(err.contains("L0016"), "{err}");
    assert!(!String::from_utf8_lossy(&result.stdout).contains("ELE-LIR 1"));
}

const POINT: &str = "shape Point {\n    x: Int,\n    y: Int,\n}\n\nflow take(p: Point) => Int {\n    give p.x\n}\n\n";

#[test]
fn aggregate_payload_binding_moves_the_scrutinee() {
    let cases = [
        // The bound shape is moved by `take`, then used again.
        (
            "binding_used_after_move.l",
            "flow area(o: Option of[Point]) => Int {\n    choose o {\n        Some(point): {\n            hold a = take(point)\n            give a + point.y\n        },\n        None: { give 3 },\n    }\n}\n\nflow main() => Int {\n    give area(Some(Point(x: 1, y: 2)))\n}\n",
        ),
        // Binding the payload consumed `o`; matching it again is a use after move.
        (
            "scrutinee_used_after_move.l",
            "flow twice(o: Option of[Point]) => Int {\n    change total = 0\n    choose o {\n        Some(point): { total = total + take(point) },\n        None: { total = 1 },\n    }\n    choose o {\n        Some(again): { total = total + take(again) },\n        None: { total = total + 1 },\n    }\n    give total\n}\n\nflow main() => Int {\n    give twice(Some(Point(x: 1, y: 2)))\n}\n",
        ),
        // A borrowed union cannot give its payload away.
        (
            "borrowed_scrutinee.l",
            "flow peek(o: view Option of[Point]) => Int {\n    choose o {\n        Some(point): { give point.x },\n        None: { give 0 },\n    }\n}\n\nflow main() => Int {\n    hold o: Option of[Point] = Some(Point(x: 4, y: 5))\n    give peek(view o)\n}\n",
        ),
    ];
    for (name, body) in cases {
        let path = write_case(name, &format!("{POINT}{body}"));
        let result = Command::new(sema())
            .arg(&path)
            .arg("--check-ownership")
            .output()
            .unwrap();
        let err = String::from_utf8_lossy(&result.stderr);
        assert_eq!(result.status.code(), Some(1), "{name}: {err}");
        assert!(err.contains("L0005"), "{name}: {err}");
    }
}

fn fixture(name: &str) -> String {
    fs::read_to_string(root().join("examples").join(name)).unwrap()
}

#[test]
fn protocol_reader_type_checks_aggregate_payloads() {
    let good = fixture("native_cfg_enum_aggregate_payload.lir");
    let parsed = project_l::lir_protocol::parse(&good).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();

    let reject = |label: &str, text: String| {
        let parsed = project_l::lir_protocol::parse(&text);
        let ok = parsed
            .as_ref()
            .is_ok_and(|m| project_l::lir_protocol::validate(m).is_ok());
        assert!(!ok, "{label}: malformed LIR accepted\n{text}");
    };
    // A shape owning Text is not drop-free: `payload` must refuse it.
    reject(
        "text field",
        good.replace("field 2:111,107 b", "field 2:111,107 t")
            .replace(
                "i struct v1 s0 3 v0 ci42 cb1",
                "i struct v1 s0 3 v0 ci42 ct1:120",
            ),
    );
    // Payload destination of the wrong type (Int for a shape).
    reject(
        "wrong dst",
        good.replace("i payload v3 p2 e1 1", "i payload v4 p2 e1 1"),
    );
    // Payload of the unit variant.
    reject(
        "unit variant",
        good.replace("i payload v3 p2 e1 1", "i payload v3 p2 e1 0"),
    );
    // Projected place and enum mismatch.
    reject(
        "projected place",
        good.replace("i payload v3 p2 e1 1", "i payload v3 p1.0 e1 1"),
    );
    reject(
        "wrong enum",
        good.replace("i payload v3 p2 e1 1", "i payload v3 p2 e0 1"),
    );
    // Constructor operand that is not the declared payload shape.
    reject(
        "variant operand",
        good.replace("i variant v2 e1 1 1 v1", "i variant v2 e1 1 1 v0"),
    );
    // Payload declared with a list type (owned).
    reject(
        "list payload",
        fixture("native_cfg_enum_aggregate_list_payload.lir"),
    );
    // A choice nested in a drop-free shape may carry at most one Int/Bool.
    reject(
        "choice with two fields",
        good.replace(
            "variant 5:76,97,114,103,101 types 0",
            "variant 5:76,97,114,103,101 types 2 i b",
        )
        .replace("i variant v0 e0 1 0", "i variant v0 e0 1 2 ci1 cb1"),
    );
}

#[test]
fn native_backend_copies_aggregate_payloads_after_tag_check() {
    let dir = root().join("examples");
    let elf = native_build(
        &dir.join("native_cfg_enum_aggregate_payload.lir"),
        "payload",
    )
    .expect("positive aggregate payload rejected");
    run_elf(&elf, None, 42);
    let elf = native_build(
        &dir.join("native_cfg_enum_aggregate_wrong_active.lir"),
        "wrong_active",
    )
    .expect("runtime-checked payload rejected");
    // Built as None, read as Some: the discriminant check exits with 126.
    run_elf(&elf, None, 126);
}

#[test]
fn native_backend_rejects_owned_cyclic_or_moved_aggregate_payloads() {
    for name in [
        "native_cfg_enum_aggregate_text_payload.lir",
        "native_cfg_enum_aggregate_text_field.lir",
        "native_cfg_enum_aggregate_list_payload.lir",
        "native_cfg_enum_aggregate_cycle.lir",
        "native_cfg_enum_aggregate_use_after_move.lir",
        "native_cfg_enum_aggregate_double_payload.lir",
        "native_cfg_enum_aggregate_moved_owner.lir",
        "native_cfg_enum_aggregate_wrong_dst.lir",
    ] {
        let path = root().join("examples").join(name);
        assert!(
            native_build(&path, name).is_none(),
            "{name}: ELE backend accepted invalid LIR"
        );
    }
}
