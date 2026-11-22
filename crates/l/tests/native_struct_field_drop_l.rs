//! Releasing whole shape- and union-typed fields, and replacing a whole
//! owning referent, in the ELE-written native backend:
//! * `i dropfield <place> -|vF` of a field whose type is a shape or a union
//!   that owns heap storage goes through cfgDropAt and the shape/union drop
//!   glue, through owned locals and reference parameters, honoring flags;
//! * `i store pN vM` through a reference to an owning value (a Text, list,
//!   shape or union) releases the old referent through its glue and then
//!   moves the new value in; the verifier requires the old value whole.
//!
//! `.l` (ELE v2) -> Stage 1 -> ELE-LIR -> x86-64 -> ELF64, executed on Linux
//! x86-64 or through WSL (`ELE_TEST_WSL_DISTRO`) with an strace heap-balance
//! check (stage1_support/elf_exec.rs); on Windows the same LIR also runs as
//! PE32+. Expected results are those of the Stage-0-built programs.
#[path = "stage1_support/elf_exec.rs"]
mod elf_exec;
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
    let dir = root().join("target/stage1-tests/native-struct-field-drop");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}
fn fresh_dir(name: &str) -> PathBuf {
    let dir = temp(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn backend(lir: &Path, image: &Path, extra: &[&str]) -> std::process::Output {
    let _ = fs::remove_file(image);
    Command::new(native())
        .arg(lir)
        .arg(image)
        .args(extra)
        .output()
        .unwrap()
}

fn emit_lir(name: &str, source: &str) -> String {
    let file = temp(&format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let emitted = Command::new(sema())
        .arg(&file)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1 {name}: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    lir
}

/// Builds `lir` as ELF64 (and PE32+ on Windows), runs both and checks the
/// exit status, stdout and the heap balance of the ELF64 run.
fn build_and_run(name: &str, lir: &str, code: i32, stdout: &str) {
    let lir_file = temp(&format!("{name}.lir"));
    fs::write(&lir_file, lir).unwrap();
    let image = temp(&format!("{name}.elf"));
    let built = backend(&lir_file, &image, &[]);
    assert!(
        built.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01", "{name}");
    let dir = fresh_dir(&format!("{name}-run"));
    if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
        assert_eq!(run.code, Some(code), "{name}: {}", run.stderr);
        assert_eq!(run.stdout, stdout, "{name}");
        assert_eq!(run.stderr, "", "{name}");
        if let Some(heap) = run.heap {
            heap.assert_balanced(name);
            assert!(heap.maps > 0, "{name}: nothing was allocated");
        }
    }

    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        // VirtualFree of a released buffer exits 124 (win64_heap).
        let exe = temp(&format!("{name}.exe"));
        let built = backend(&lir_file, &exe, &["--pe64"]);
        assert!(
            built.status.success(),
            "{name} PE32+: {}",
            String::from_utf8_lossy(&built.stderr)
        );
        let run = Command::new(&exe).output().unwrap();
        assert_eq!(run.status.code(), Some(code), "{name} PE32+");
        assert_eq!(
            String::from_utf8(run.stdout).unwrap().replace("\r\n", "\n"),
            stdout,
            "{name} PE32+"
        );
    }
}

const FIELDS: &str = "shape Inner {
    names: List of[Text]
    rows: List of[List of[Int]]
    label: Text
}

shape Outer {
    id: Int
    inner: Inner
    note: Option of[Text]
}

flow makeInner(n: Int) => Inner {
    change names: List of[Text] = List[\"name {n}\"]
    names@push(\"other {n}\")
    change rows: List of[List of[Int]] = List[]
    rows@push(List[n, n + 1])
    give Inner(names: names, rows: rows, label: \"label {n}\")
}

flow refresh(outer: edit Outer, n: Int) {
    outer.inner = makeInner(n)
    outer.note = Some(\"note {n}\")
}

flow replace(target: edit Inner, n: Int) {
    target = makeInner(n)
}

flow grow(text: edit Text) {
    text = \"{text}!\"
}

flow main() => Int {
    hold empty: Option of[Text] = None
    change outer = Outer(id: 1, inner: makeInner(1), note: empty)
    outer.inner = makeInner(2)
    refresh(edit outer, 3)
    hold cleared: Option of[Text] = None
    outer.note = cleared
    replace(edit outer.inner, 4)
    change word = \"w{outer.id}\"
    grow(edit word)
    print(outer.inner.label)
    print(word)
    give outer.inner.names.length
}
";

/// Shape field (nested lists and Text) and union field replaced through an
/// `edit` parameter, a union field replaced in an owned local, and whole
/// referents (a shape and a Text) replaced through `edit` parameters. Before,
/// the first `dropfield` of the shape field was rejected with code 92.
#[test]
fn shape_and_union_fields_are_released_through_their_glue() {
    let lir = emit_lir("fields", FIELDS);
    for form in [
        "i dropfield p0.1 -",
        "i dropfield p0.2 -",
        "i dropfield p4.2 -",
        "i store p0 v2",
        "i store p0 v1",
    ] {
        assert!(lir.contains(form), "{form}\n{lir}");
    }
    build_and_run("fields", &lir, 2, "label 4\nw1!\n");
}

const MAYBE_FIELD: &str = "shape Inner {
    names: List of[Text]
    label: Text
}

shape Outer {
    id: Int
    inner: Inner
    note: Option of[Text]
}

flow makeInner(n: Int) => Inner {
    change names: List of[Text] = List[\"name {n}\"]
    names@push(\"other {n}\")
    give Inner(names: names, label: \"label {n}\")
}

flow count(inner: Inner) => Int {
    give inner.names.length
}

flow measure(note: Option of[Text]) => Int {
    choose note {
        Some(text): { give text.byteLength },
        None: { give 0 },
    }
}

flow pick(take: Bool) => Int {
    change outer = Outer(id: 7, inner: makeInner(5), note: Some(\"note {take}\"))
    change total = outer.id
    when take {
        total = total + count(outer.inner)
        total = total + measure(outer.note)
    }
    give total
}

flow main() => Int {
    hold a = pick(true)
    hold b = pick(false)
    print(a)
    print(b)
    give a + b
}
";

/// Fields moved on one path only: Stage 1 releases them with drop flags,
/// including the flagged `dropfield` of the union field.
#[test]
fn flagged_union_field_drop_follows_its_flag() {
    let lir = emit_lir("maybe_field", MAYBE_FIELD);
    let flagged: Vec<&str> = lir
        .lines()
        .filter(|l| l.starts_with("i dropfield ") && !l.contains(" - "))
        .collect();
    assert!(
        flagged.iter().any(|l| l.contains(".2 v")),
        "flagged union field drop\n{lir}"
    );
    build_and_run("maybe_field", &lir, 25, "18\n7\n");
}

/// The same program with the two flagged subfield releases of `outer.inner`
/// replaced by ONE flagged `dropfield` of the whole shape field (both flags
/// are equal: the field is moved whole), which goes through the shape glue.
#[test]
fn flagged_whole_shape_field_drop_follows_its_flag() {
    let lir = emit_lir("maybe_whole_field", MAYBE_FIELD);
    let lines: Vec<&str> = lir.lines().collect();
    let sub = |s: &str| {
        lines
            .iter()
            .position(|l| {
                let w: Vec<&str> = l.split_whitespace().collect();
                w.len() >= 4 && w[1] == "dropfield" && w[2].ends_with(s) && w[3] != "-"
            })
            .unwrap_or_else(|| panic!("flagged dropfield of {s}\n{lir}"))
    };
    let (one, zero) = (sub(".1.1"), sub(".1.0"));
    let mut out: Vec<String> = Vec::new();
    let mut header = 0;
    for (n, line) in lines.iter().enumerate() {
        if line.starts_with("block ") {
            header = out.len();
        }
        if n == zero {
            // One instruction fewer in this block.
            let w: Vec<String> = out[header].split(' ').map(str::to_string).collect();
            let count: usize = w[2].parse().unwrap();
            out[header] = format!("block {} {}", w[1], count - 1);
            continue;
        }
        if n == one {
            let w: Vec<&str> = line.split_whitespace().collect();
            let place = w[2].strip_suffix(".1").unwrap();
            out.push(format!("i dropfield {place} {}", w[3]));
            continue;
        }
        out.push(line.to_string());
    }
    let edited = out.join("\n") + "\n";
    assert!(edited.contains(" dropfield p") && !edited.contains(".1.0 v"));
    build_and_run("maybe_whole_field", &edited, 25, "18\n7\n");
}

const HEADER: &str = "struct s0 5:73,110,110,101,114 fields 3
field 5:110,97,109,101,115 l0
field 4:114,111,119,115 l2
field 5:108,97,98,101,108 t
struct s1 5:79,117,116,101,114 fields 3
field 2:105,100 i
field 5:105,110,110,101,114 s0
field 4:110,111,116,101 e0
struct s2 4:80,97,105,114 fields 2
field 1:97 i
field 1:98 i
struct s3 6:72,111,108,100,101,114 fields 2
field 4:112,97,105,114 s2
field 4:116,101,120,116 t
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 t
list l0 t
list l1 i
list l2 l1
";

/// A module with `helper` as f0 (when given) and a trivial `main`.
fn module(helper: &str) -> String {
    let funcs = if helper.is_empty() { 1 } else { 2 };
    format!(
        "ELE-LIR 1\nmodule structs 4 enums 1 lists 3 funcs {funcs} main f{}\n{HEADER}{helper}\
         func f{} 4:109,97,105,110 params 0 result i 0 0 vars 0 blocks 1\nblock 0 0\nt return ci0\nendfunc\nend\n",
        funcs - 1,
        funcs - 1
    )
}

fn assert_rejected(name: &str, lir: &str, code: u32) {
    let lir_file = temp(&format!("{name}.lir"));
    fs::write(&lir_file, lir).unwrap();
    let image = temp(&format!("{name}.elf"));
    let built = backend(&lir_file, &image, &[]);
    assert_eq!(built.status.code(), Some(3), "{name} reached native code");
    let stderr = String::from_utf8_lossy(&built.stderr);
    assert!(
        stderr.contains(&format!("ELE-LIR/CFG rechazado (código {code})")),
        "{name}: {stderr}"
    );
    assert!(!image.exists(), "{name}: image written for rejected LIR");
}

#[test]
fn hand_written_module_is_accepted_as_a_baseline() {
    // The rejections below differ from this module only in their helper.
    let lir_file = temp("baseline.lir");
    fs::write(&lir_file, module("")).unwrap();
    let image = temp("baseline.elf");
    let built = backend(&lir_file, &image, &[]);
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
}

/// Still unsupported, or ownership errors the verifier keeps rejecting.
#[test]
fn unsupported_and_malformed_field_releases_are_rejected() {
    // A shape field that owns nothing has nothing to release.
    assert_rejected(
        "drop_free_shape_field",
        &module(
            "func f0 1:102 params 1 result u 0 0 vars 1 blocks 1
var v0 val s3
block 0 2
i dropfield p0.0 -
i dropfield p0.1 -
t return cu
endfunc
",
        ),
        92,
    );
    // Releasing the same shape field twice.
    assert_rejected(
        "double_shape_field_drop",
        &module(
            "func f0 1:102 params 1 result u 0 0 vars 1 blocks 1
var v0 val s1
block 0 3
i dropfield p0.1 -
i dropfield p0.1 -
i dropfield p0.2 -
t return cu
endfunc
",
        ),
        57,
    );
    // A reference parameter must give its referent back whole.
    assert_rejected(
        "ref_field_not_refilled",
        &module(
            "func f0 1:102 params 1 result u 0 0 vars 1 blocks 1
var v0 ref s1
block 0 1
i dropfield p0.1 -
t return cu
endfunc
",
        ),
        95,
    );
    // A whole store releases the old referent: it must still be whole.
    assert_rejected(
        "whole_store_over_partial_referent",
        &module(
            "func f0 1:102 params 2 result u 0 0 vars 2 blocks 1
var v0 ref s0
var v1 val s0
block 0 2
i dropfield p0.2 -
i store p0 v1
t return cu
endfunc
",
        ),
        57,
    );
    // Moving an owning value out of a referent stays rejected.
    assert_rejected(
        "whole_read_of_owning_referent",
        &module(
            "func f0 1:102 params 1 result u 0 0 vars 2 blocks 1
var v0 ref s0
var v1 val s0
block 0 2
i read v1 p0
i dropfield p1.0 -
t return cu
endfunc
",
        ),
        95,
    );
}
