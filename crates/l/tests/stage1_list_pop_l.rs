//! Vertical tests for `List.pop()` in Stage 1 (#3).
//!
//! Full pipeline: `List.pop() -> Option<T> -> match/choose -> ELE-LIR -> native backend`.
//! Both Stage 0 / Cranelift parity (with allocs == frees tracing) and the self-hosted
//! ELE native backend (`native_cfg_demo`) are tested.
//!
//! Unblocks `loans_l.l:133` and `ownership_l.l:123`.

mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
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

fn temp() -> PathBuf {
    let dir = root().join("target/stage1-tests/list-pop");
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(name: &str, text: &str) -> PathBuf {
    let path = temp().join(name);
    fs::write(&path, text).unwrap();
    path
}

fn stage1(path: &Path, flag: &str) -> Output {
    Command::new(sema())
        .arg(path)
        .arg(flag)
        .env("PATH", "")
        .output()
        .unwrap()
}

fn emit(name: &str, text: &str) -> String {
    let out = stage1(&write(name, text), "--emit-lir");
    assert!(
        out.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn validate(lir: &str) -> Result<(), String> {
    let module = project_l::lir_protocol::parse(lir).map_err(|e| format!("{e:?}"))?;
    project_l::lir_protocol::validate(&module).map_err(|e| format!("{e:?}"))
}

#[cfg(windows)]
fn run_lir_and_stage0(name: &str, source: &str) -> (i32, String) {
    let lir = emit(&format!("{name}.l"), source);
    validate(&lir).unwrap_or_else(|e| panic!("{name}: {e}\n{lir}"));
    let file = write(&format!("{name}.lir"), &lir);
    let run = |args: Vec<String>| {
        let out = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(temp())
            .args(&args)
            .output()
            .unwrap();
        (
            out.status.code().unwrap(),
            String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
            String::from_utf8_lossy(&out.stderr).to_string(),
        )
    };
    let (code, stdout, stderr) = run(vec![
        "run-lir".into(),
        file.display().to_string(),
        "--trace-alloc".into(),
    ]);
    let (_, trace) = stderr.rsplit_once("l-alloc: ").expect(&stderr);
    let field = |key: &str| -> u64 {
        trace
            .split_whitespace()
            .find_map(|w| w.strip_prefix(key))
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| panic!("{name}: missing {key}: {trace}"))
    };
    assert_eq!(field("allocs="), field("frees="), "{name}: {trace}");
    assert_eq!(field("heap_ok="), 1, "{name}: {trace}");
    let source_file = temp().join(format!("{name}.l"));
    let (code0, stdout0, stderr0) = run(vec![
        "run".into(),
        source_file.display().to_string(),
        "--backend".into(),
        "cranelift".into(),
    ]);
    assert_eq!((code, &stdout), (code0, &stdout0), "{name}: {stderr0}");
    (code, stdout)
}

#[test]
fn list_pop_int_empty_single_multiple_parity() {
    let source = r#"fn main() -> Int {
    var xs: List<Int> = List[]
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    xs.push(10)
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    xs.push(1)
    xs.push(2)
    xs.push(3)
    while xs.length > 0 {
        match xs.pop() {
            Some(v) => { print(v) }
            None => { break }
        }
    }
    return 0
}
"#;
    #[cfg(windows)]
    {
        let (code, stdout) = run_lir_and_stage0("pop_int", source);
        assert_eq!(code, 0);
        assert_eq!(stdout, "0\n10\n0\n3\n2\n1\n");
    }
    #[cfg(not(windows))]
    {
        let lir = emit("pop_int.l", source);
        validate(&lir).unwrap();
    }
}

#[test]
fn list_pop_owned_text_balanced_heap() {
    let source = r#"fn main() -> Int {
    var xs: List<Text> = List[]
    xs.push("first")
    xs.push("second")
    xs.push("third")
    match xs.pop() {
        Some(t) => { print(t) }
        None => { print("none") }
    }
    match xs.pop() {
        Some(t) => { print(t) }
        None => { print("none") }
    }
    match xs.pop() {
        Some(t) => { print(t) }
        None => { print("none") }
    }
    match xs.pop() {
        Some(t) => { print(t) }
        None => { print("none") }
    }
    return 0
}
"#;
    #[cfg(windows)]
    {
        let (code, stdout) = run_lir_and_stage0("pop_text", source);
        assert_eq!(code, 0);
        assert_eq!(stdout, "third\nsecond\nfirst\nnone\n");
    }
    #[cfg(not(windows))]
    {
        let lir = emit("pop_text.l", source);
        validate(&lir).unwrap();
    }
}

#[test]
fn list_pop_nested_lists_balanced_heap() {
    let source = r#"fn main() -> Int {
    var xs: List<List<Int>> = List[]
    var a: List<Int> = List[]
    a.push(1)
    a.push(2)
    var b: List<Int> = List[]
    b.push(3)
    b.push(4)
    xs.push(a)
    xs.push(b)
    match xs.pop() {
        Some(sub) => {
            print(sub.length)
            print(sub[0])
            print(sub[1])
        }
        None => { print(0) }
    }
    match xs.pop() {
        Some(sub) => {
            print(sub.length)
            print(sub[0])
            print(sub[1])
        }
        None => { print(0) }
    }
    match xs.pop() {
        Some(_) => { print(99) }
        None => { print(0) }
    }
    return 0
}
"#;
    #[cfg(windows)]
    {
        let (code, stdout) = run_lir_and_stage0("pop_nested", source);
        assert_eq!(code, 0);
        assert_eq!(stdout, "2\n3\n4\n2\n1\n2\n0\n");
    }
    #[cfg(not(windows))]
    {
        let lir = emit("pop_nested.l", source);
        validate(&lir).unwrap();
    }
}

#[test]
fn list_pop_struct_with_text_balanced_heap() {
    let source = r#"struct Item {
    id: Int,
    name: Text,
}

fn main() -> Int {
    var items: List<Item> = List[]
    items.push(Item(id: 1, name: "alpha"))
    items.push(Item(id: 2, name: "beta"))
    match items.pop() {
        Some(item) => {
            print(item.id)
            print(item.name)
        }
        None => { print(0) }
    }
    match items.pop() {
        Some(item) => {
            print(item.id)
            print(item.name)
        }
        None => { print(0) }
    }
    match items.pop() {
        Some(_) => { print(99) }
        None => { print(0) }
    }
    return 0
}
"#;
    #[cfg(windows)]
    {
        let (code, stdout) = run_lir_and_stage0("pop_struct", source);
        assert_eq!(code, 0);
        assert_eq!(stdout, "2\nbeta\n1\nalpha\n0\n");
    }
    #[cfg(not(windows))]
    {
        let lir = emit("pop_struct.l", source);
        validate(&lir).unwrap();
    }
}

#[test]
fn ele_native_backend_compiles_list_pop_elf() {
    let source = r#"fn main() -> Int {
    var xs: List<Int> = List[]
    xs.push(42)
    xs.push(99)
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    match xs.pop() {
        Some(v) => { print(v) }
        None => { print(0) }
    }
    return 0
}
"#;
    let lir = emit("native_pop.l", source);
    validate(&lir).unwrap();
    let lir_path = write("native_pop.lir", &lir);
    let elf_path = temp().join("native_pop.elf");
    let out = Command::new(native())
        .arg(&lir_path)
        .arg(&elf_path)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "native backend error: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&elf_path).unwrap();
    assert!(bytes.len() >= 64, "image must be valid ELF64");
    assert_eq!(&bytes[0..4], b"\x7FELF", "ELF magic");
}

#[test]
fn loans_l_unblocked_at_line_133() {
    let loans_path = root().join("compiler-l/src/loans_l.l");
    let out = stage1(&loans_path, "--emit-lir");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "loans_l.l failed to compile with --emit-lir: {stderr}"
    );
    assert!(!stderr.contains("loans_l.l:133"), "{stderr}");
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(stdout.contains("i listpop "), "LIR must contain listpop");
}

#[test]
fn ownership_l_unblocked_at_line_123() {
    let ownership_path = root().join("compiler-l/src/ownership_l.l");
    let out = stage1(&ownership_path, "--emit-lir");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "ownership_l.l failed to compile with --emit-lir: {stderr}"
    );
    assert!(!stderr.contains("ownership_l.l:123"), "{stderr}");
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(stdout.contains("i listpop "), "LIR must contain listpop");
}

#[test]
fn list_pop_negative_checks() {
    // 1. pop on non-list rejected
    let bad1 = stage1(
        &write("bad1.l", "fn main() { var x = 42; x.pop() }"),
        "--emit-lir",
    );
    assert!(!bad1.status.success());
    assert!(String::from_utf8_lossy(&bad1.stderr).contains("error[L0003]"));

    // 2. pop with arguments rejected
    let bad2 = stage1(
        &write(
            "bad2.l",
            "fn main() { var xs: List<Int> = List[]; xs.pop(1) }",
        ),
        "--emit-lir",
    );
    assert!(!bad2.status.success());
    assert!(String::from_utf8_lossy(&bad2.stderr).contains("error[L0003]"));

    // 3. immutable pop rejected
    let bad3 = stage1(
        &write("bad3.l", "fn main() { let xs = List[1]; xs.pop() }"),
        "--emit-lir",
    );
    assert!(!bad3.status.success());
    assert!(String::from_utf8_lossy(&bad3.stderr).contains("error[L0006]"));
}
