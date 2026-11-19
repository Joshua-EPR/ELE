//! Whole owned-union drop glue in the ELE-written native backend
//! (codegen/native_cfg_list_emit.l `cfgEmitUnionGlue`): `i drop vN -` and the
//! flagged `i drop vN vF` of an Option/Result whose variants own heap storage
//! read the tag and release only the active payload, recursively for nested
//! unions; drop-free and unit variants release nothing.
//!
//! `.l` (ELE v2) -> Stage 1 -> ELE-LIR -> x86-64 -> ELF64. Every host checks
//! acceptance, rejection and the image; Linux x86-64 executes the images, and
//! so does Windows through WSL when `ELE_TEST_WSL_DISTRO` is set. With
//! `strace` on the executing host, every mapped buffer must be unmapped
//! exactly once (stage1_support/elf_exec.rs). On Windows the same LIR is also
//! built as PE32+ and executed natively.
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
    let dir = root().join("target/stage1-tests/native-union-drop");
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

/// Variables declared `val eK` in the LIR, as (function index, `vN`) pairs.
fn union_vars(lir: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut func = 0usize;
    for line in lir.lines() {
        if line.starts_with("func ") {
            func += 1;
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        if words.len() == 4 && words[0] == "var" && words[2] == "val" && words[3].starts_with('e') {
            out.push((func, words[1].to_string()));
        }
    }
    out
}

/// Number of `i drop` instructions whose owner is a whole union, and how many
/// of them carry a drop flag.
fn union_drops(lir: &str) -> (usize, usize) {
    let unions = union_vars(lir);
    let (mut whole, mut flagged) = (0, 0);
    let mut func = 0usize;
    for line in lir.lines() {
        if line.starts_with("func ") {
            func += 1;
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        let drop = words.len() >= 4 && words[0] == "i" && words[1] == "drop";
        if drop && unions.contains(&(func, words[2].to_string())) {
            whole += 1;
            if words[3] != "-" {
                flagged += 1;
            }
        }
    }
    (whole, flagged)
}

fn assert_elf(image: &Path) -> Vec<u8> {
    let bytes = fs::read(image).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    bytes
}

const OPTION_TEXT: &str = "flow label(n: Int) => Text {
    give \"item {n}\"
}

flow main() => Int {
    hold some: Option of[Text] = Some(label(4))
    hold none: Option of[Text] = None
    print(label(9))
    give 7
}
";

const RESULT_TEXT_INT: &str = "flow make(n: Int) => Result of[Text, Int] {
    when n > 0 { give Ok(\"ok {n}\") }
    give Err(n)
}

flow main() => Int {
    hold good = make(3)
    hold bad = make(0 - 2)
    give 11
}
";

const RESULT_INT_TEXT: &str = "flow make(n: Int) => Result of[Int, Text] {
    when n > 0 { give Ok(n) }
    give Err(\"bad {n}\")
}

flow main() => Int {
    hold good = make(5)
    hold bad = make(0 - 1)
    give 13
}
";

const NESTED: &str = "flow inner(n: Int) => Result of[Text, Int] {
    when n > 0 { give Ok(\"in {n}\") }
    give Err(n)
}

flow outer(n: Int) => Option of[Result of[Text, Int]] {
    when n == 0 { give None }
    give Some(inner(n))
}

flow main() => Int {
    hold a = outer(2)
    hold b = outer(0 - 3)
    hold c = outer(0)
    give 17
}
";

// `r` is moved on one path only: Stage 1 drops it with a flag (MAYBE).
const MAYBE_MOVED: &str = "flow make(n: Int) => Result of[Text, Int] {
    when n > 0 { give Ok(\"ok {n}\") }
    give Err(n)
}

flow consume(r: Result of[Text, Int]) => Int {
    choose r {
        Ok(text): { give text.byteLength },
        Err(code): { give code },
    }
}

flow pick(take: Bool) => Int {
    hold r = make(6)
    change total = 1
    when take { total = consume(r) }
    give total
}

flow main() => Int {
    hold a = pick(true)
    hold b = pick(false)
    print(a)
    print(b)
    give a * 10 + b
}
";

struct Case {
    name: &'static str,
    source: &'static str,
    /// Whole-union drops in the LIR (at least), and how many are flagged.
    drops: usize,
    flagged: usize,
    code: i32,
    stdout: &'static str,
    /// Buffers mapped by the run: only the active owning payloads (and
    /// printed temporaries) allocate.
    maps: usize,
}

const CASES: [Case; 5] = [
    Case {
        name: "option_text",
        source: OPTION_TEXT,
        drops: 2,
        flagged: 0,
        code: 7,
        stdout: "item 9\n",
        maps: 2,
    },
    Case {
        name: "result_text_int",
        source: RESULT_TEXT_INT,
        drops: 2,
        flagged: 0,
        code: 11,
        stdout: "",
        maps: 1,
    },
    Case {
        name: "result_int_text",
        source: RESULT_INT_TEXT,
        drops: 2,
        flagged: 0,
        code: 13,
        stdout: "",
        maps: 1,
    },
    Case {
        name: "nested_option_result",
        source: NESTED,
        drops: 3,
        flagged: 0,
        code: 17,
        stdout: "",
        maps: 1,
    },
    Case {
        name: "maybe_moved",
        source: MAYBE_MOVED,
        drops: 1,
        flagged: 1,
        code: 41,
        stdout: "4\n1\n",
        maps: 2,
    },
];

/// Option<Text>, Result<Text,Int>, Result<Int,Text>, Option<Result<Text,Int>>
/// and a conditionally moved Result: before union drop glue every one was
/// rejected with code 92. Each now builds, runs with the Stage 0 result and
/// releases exactly the buffers it mapped.
#[test]
fn stage1_owned_unions_release_only_their_active_payload() {
    for case in &CASES {
        let lir = emit_lir(case.name, case.source);
        let (whole, flagged) = union_drops(&lir);
        assert!(
            whole >= case.drops,
            "{}: {whole} union drops\n{lir}",
            case.name
        );
        assert_eq!(flagged, case.flagged, "{}: flagged drops\n{lir}", case.name);
        let lir_file = temp(&format!("{}.lir", case.name));
        fs::write(&lir_file, &lir).unwrap();
        let image = temp(&format!("{}.elf", case.name));
        let built = backend(&lir_file, &image, &[]);
        assert!(
            built.status.success(),
            "{}: {}",
            case.name,
            String::from_utf8_lossy(&built.stderr)
        );
        assert_elf(&image);
        let dir = fresh_dir(&format!("{}-run", case.name));
        if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
            assert_eq!(run.code, Some(case.code), "{}: {}", case.name, run.stderr);
            assert_eq!(run.stdout, case.stdout, "{}", case.name);
            assert_eq!(run.stderr, "", "{}", case.name);
            if let Some(heap) = run.heap {
                heap.assert_balanced(case.name);
                assert_eq!(heap.maps, case.maps, "{}: {heap:?}", case.name);
            }
        }

        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            // The same glue on PE32+ releases through VirtualFree, which
            // exits 124 if a buffer is released twice (win64_heap).
            let exe = temp(&format!("{}.exe", case.name));
            let built = backend(&lir_file, &exe, &["--pe64"]);
            assert!(
                built.status.success(),
                "{} PE32+: {}",
                case.name,
                String::from_utf8_lossy(&built.stderr)
            );
            let run = Command::new(&exe).output().unwrap();
            assert_eq!(run.status.code(), Some(case.code), "{} PE32+", case.name);
            assert_eq!(
                String::from_utf8(run.stdout).unwrap().replace("\r\n", "\n"),
                case.stdout,
                "{} PE32+",
                case.name
            );
        }
    }
}

/// A list of Option<Text>: the list glue releases each element through the
/// union glue (before, the missing union glue made the backend fail with
/// code 71 while patching the call).
#[test]
fn list_of_owned_unions_releases_each_active_element() {
    let lir = "ELE-LIR 1
module structs 0 enums 1 lists 1 funcs 1 main f0
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 t
list l0 e0
func f0 4:109,97,105,110 params 0 result i 0 0 vars 7 blocks 1
var v0 val t
var v1 val e0
var v2 val e0
var v3 val l0
var v4 val t
var v5 val e0
var v6 val i
block 0 11
i textbuf v0 8
i append v0 val ci11
i variant v1 e0 1 1 v0
i variant v2 e0 0 0
i listlit v3 l0 2 v1 v2
i textbuf v4 8
i append v4 val ci22
i variant v5 e0 1 1 v4
i listpush p3 v5
i len v6 p3
i drop v3 -
t return v6
endfunc
end
";
    let lir_file = temp("list_option.lir");
    fs::write(&lir_file, lir).unwrap();
    let image = temp("list_option.elf");
    let built = backend(&lir_file, &image, &[]);
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert_elf(&image);
    let dir = fresh_dir("list_option-run");
    if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
        assert_eq!(run.code, Some(3), "{}", run.stderr);
        if let Some(heap) = run.heap {
            heap.assert_balanced("list of Option<Text>");
            // Two Text payloads and the list buffer.
            assert_eq!(heap.maps, 3, "{heap:?}");
        }
    }
}

/// Explicit drop flags: the payload of `v1` is moved out (consuming the
/// union), so its flag is false and the drop must not release anything;
/// `v4` is still owned, its flag is true and its buffer is released.
#[test]
fn flagged_union_drops_follow_their_flag() {
    let lir = "ELE-LIR 1
module structs 0 enums 1 funcs 1 main f0
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 t
func f0 4:109,97,105,110 params 0 result i 0 0 vars 9 blocks 1
var v0 val t
var v1 val e0
var v2 val t
var v3 val t
var v4 val e0
var v5 val b
var v6 val b
var v7 val i
var v8 val i
block 0 15
i textbuf v0 8
i append v0 val ci5
i variant v1 e0 1 1 v0
i textbuf v3 8
i append v3 val ci66
i len v8 p3
i variant v4 e0 1 1 v3
i use v5 cb0
i use v6 cb1
i payload v2 p1 e0 1
i len v7 p2
i drop v2 -
i drop v1 v5
i drop v4 v6
i binary v7 add v7 v8
t return v7
endfunc
end
";
    let lir_file = temp("flags.lir");
    fs::write(&lir_file, lir).unwrap();
    let image = temp("flags.elf");
    let built = backend(&lir_file, &image, &[]);
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert_elf(&image);
    let dir = fresh_dir("flags-run");
    if let Some(run) = elf_exec::execute(&image, &dir, &[]) {
        assert_eq!(run.code, Some(3), "{}", run.stderr);
        if let Some(heap) = run.heap {
            heap.assert_balanced("flagged union drops");
            assert_eq!(heap.maps, 2, "{heap:?}");
        }
    }
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

const OPTION_TEXT_HEADER: &str = "ELE-LIR 1
module structs 0 enums 1 funcs 1 main f0
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 t
";

/// Shapes still have no whole-value drop (fields are released with
/// `dropfield`), and a union that owns nothing has nothing to release: both
/// stay fail-closed with code 92 and no image.
#[test]
fn unsupported_whole_drops_stay_fail_closed() {
    assert_rejected(
        "whole_shape_drop",
        "ELE-LIR 1
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
",
        92,
    );
    assert_rejected(
        "drop_free_union_drop",
        "ELE-LIR 1
module structs 0 enums 1 funcs 1 main f0
enum e0 6:79,112,116,105,111,110 variants 2
variant 4:78,111,110,101 types 0
variant 4:83,111,109,101 types 1 i
func f0 4:109,97,105,110 params 0 result i 0 0 vars 1 blocks 1
var v0 val e0
block 0 2
i variant v0 e0 1 1 ci5
i drop v0 -
t return ci0
endfunc
end
",
        92,
    );
    // `append` into a union is not a Text buffer.
    assert_rejected(
        "append_into_union",
        &format!(
            "{OPTION_TEXT_HEADER}func f0 4:109,97,105,110 params 0 result i 0 0 vars 1 blocks 1
var v0 val e0
block 0 3
i variant v0 e0 1 1 ct2:104,105
i append v0 val ci1
i drop v0 -
t return ci0
endfunc
end
"
        ),
        92,
    );
}

/// The verifier still owns the moved state: an unflagged drop of a union
/// that was moved, dropped, or consumed by an owning payload extraction is a
/// use after move (57), and a drop flag must be a Bool (94).
#[test]
fn malformed_union_drops_are_rejected_by_verification() {
    let body = |vars: usize, insts: &str| {
        let count = insts.lines().count();
        let mut decl = String::new();
        let types = ["e0", "e0", "t", "i"];
        for (n, ty) in types.iter().enumerate().take(vars) {
            decl.push_str(&format!("var v{n} val {ty}\n"));
        }
        format!(
            "{OPTION_TEXT_HEADER}func f0 4:109,97,105,110 params 0 result i 0 0 vars {vars} blocks 1
{decl}block 0 {count}
{insts}t return ci0
endfunc
end
"
        )
    };
    assert_rejected(
        "drop_after_move",
        &body(
            2,
            "i variant v0 e0 1 1 ct2:104,105
i use v1 v0
i drop v1 -
i drop v0 -
",
        ),
        57,
    );
    assert_rejected(
        "double_union_drop",
        &body(
            1,
            "i variant v0 e0 1 1 ct2:104,105
i drop v0 -
i drop v0 -
",
        ),
        57,
    );
    assert_rejected(
        "drop_after_payload_move",
        &body(
            3,
            "i variant v0 e0 1 1 ct2:104,105
i payload v2 p0 e0 1
i drop v2 -
i drop v0 -
",
        ),
        57,
    );
    assert_rejected(
        "drop_flag_not_bool",
        &body(
            4,
            "i variant v0 e0 1 1 ct2:104,105
i use v3 ci1
i drop v0 v3
",
        ),
        94,
    );
}

/// The same LIR gives the same bytes.
#[test]
fn union_drop_images_are_reproducible() {
    let lir = emit_lir("repro_nested", NESTED);
    let lir_file = temp("repro_nested.lir");
    fs::write(&lir_file, &lir).unwrap();
    let first = temp("repro_nested_1.elf");
    let second = temp("repro_nested_2.elf");
    assert!(backend(&lir_file, &first, &[]).status.success());
    assert!(backend(&lir_file, &second, &[]).status.success());
    assert_eq!(assert_elf(&first), assert_elf(&second));
}

#[test]
fn heap_trace_matches_releases_by_address() {
    let trace = "1 mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, -1, 0) = 0x7f00\n\
                 1 mremap(0x7f00, 4096, 8192, MREMAP_MAYMOVE) = 0x7e00\n\
                 1 munmap(0x7e00, 8192)      = 0\n\
                 1 munmap(0x7e00, 8192)      = 0\n\
                 1 +++ exited with 0 +++\n";
    let heap = elf_exec::parse_heap_trace(trace);
    assert_eq!(
        (heap.maps, heap.unmaps, heap.remaps, heap.leaked),
        (1, 2, 1, 0)
    );
    assert_eq!(heap.bad_releases.len(), 1, "double munmap is detected");
    let leak = elf_exec::parse_heap_trace("1 mmap(NULL, 4096) = 0x1000\n");
    assert_eq!(leak.leaked, 1);
}
