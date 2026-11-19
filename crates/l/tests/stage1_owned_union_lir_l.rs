//! Owned Option/Result payloads in Stage 1 ELE-LIR (#5, owned part of #4).
//!
//! `Some(x)`/`Ok(x)`/`Err(x)` move an owned `x` (Text, List<T>, a nested
//! union) into the union; the union carries ONE atomic drop obligation for
//! its active payload; binding the payload in a `match` moves it out and
//! consumes the union. Both the ELE-written verifier (`lir_verify*.l`) and
//! the Rust protocol reader/validator (`lir_protocol.rs` + `drops::verify`)
//! check the result independently. The ELE native backend does not yet have
//! a layout for owned payloads and must reject such LIR without an image.
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
    let dir = root().join("target/stage1-tests/owned-union-lir");
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

const LABEL: &str = "fn label(n: Int) -> Text {\n    return \"item-{n}\"\n}\n\n";

/// Every requested instantiation, all CFG exits and Stage 0 parity.
const OWNED: &str = r#"fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    let t = label(n)
    return Some(t)
}

fn parse(n: Int) -> Result<Text, Int> {
    if n > 10 { return Err(n) }
    let t = label(n)
    return Ok(t)
}

fn invert(n: Int) -> Result<Int, Text> {
    if n > 10 { return Err(label(n)) }
    return Ok(n * 2)
}

fn digits(n: Int) -> Result<List<Int>, Int> {
    if n < 0 { return Err(n) }
    var out: List<Int> = List[]
    var k = n
    while k > 0 {
        out.push(k % 10)
        k = k / 10
    }
    return Ok(out)
}

fn nested(n: Int) -> Option<Result<Text, Int>> {
    if n == 0 { return None }
    if n > 5 { return Some(Err(n)) }
    let t = label(n)
    return Some(Ok(t))
}

fn consume(o: Option<Text>) -> Int {
    match o {
        Some(t) => { return t.byteLength }
        None => { return 0 }
    }
}

fn main() -> Int {
    var total = 0
    match maybe(3) {
        Some(t) => { print(t) }
        None => { print("none") }
    }
    match maybe(-1) {
        Some(_) => { total += 100 }
        None => { total += 1 }
    }
    let kept = maybe(4)
    match kept {
        Some(_) => { total += 2 }
        None => {}
    }
    let unused = parse(5)
    match parse(7) {
        Ok(t) => {
            print(t)
            total += t.byteLength
        }
        Err(code) => { total += code }
    }
    match parse(12) {
        Ok(t) => { print(t) }
        Err(code) => { total += code }
    }
    match invert(20) {
        Ok(v) => { total += v }
        Err(msg) => { print(msg) }
    }
    match invert(4) {
        Ok(v) => { total += v }
        Err(msg) => { print(msg) }
    }
    match digits(321) {
        Ok(list) => { total += list.length * 10 }
        Err(e) => { total += e }
    }
    for i in 0..8 {
        match nested(i) {
            Some(r) => {
                match r {
                    Ok(t) => { print(t) }
                    Err(e) => { total += e }
                }
            }
            None => { total += 1000 }
        }
        if i == 6 { break }
    }
    total += consume(maybe(9))
    let moved = maybe(2)
    total += consume(moved)
    return total % 256
}
"#;

/// Early returns, `continue` and `break` out of arms that own a payload or
/// an unbound owned temporary scrutinee; a union returned from an arm.
const LOOPS: &str = r#"fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    return Some(label(n))
}

fn relay(n: Int) -> Option<Text> {
    match maybe(n) {
        Some(t) => { return Some(t) }
        None => { return None }
    }
}

fn loops() -> Int {
    var count = 0
    var i = 0
    while i < 8 {
        i += 1
        match relay(i) {
            Some(t) => {
                if i == 2 { continue }
                if i == 5 { return count + t.byteLength }
                count += 1
            }
            None => { break }
        }
    }
    return count
}

fn pickOne(flag: Bool) -> Int {
    let o = maybe(7)
    if flag {
        match o {
            Some(t) => { return t.byteLength }
            None => { return 0 }
        }
    }
    return 1
}

fn main() -> Int {
    let a = loops()
    let b = pickOne(true)
    let c = pickOne(false)
    print(a)
    print(b)
    print(c)
    return a + b + c
}
"#;

/// The shape of `lexSource` (compiler-l/src/lexer.l:297): a drop-free
/// Result scrutinee, then `return Ok(tokens)` of an owned List<shape>.
const LEXLIKE: &str = r#"struct Tok {
    kind: Int,
    start: Int,
}

fn scan(n: Int, tokens: &mut List<Tok>) -> Result<Int, Int> {
    if n < 0 { return Err(n) }
    tokens.push(Tok(kind: 1, start: n))
    return Ok(n)
}

fn lex(n: Int) -> Result<List<Tok>, Int> {
    var tokens: List<Tok> = List[]
    match scan(n, &mut tokens) {
        Ok(last) => {
            tokens.push(Tok(kind: 0, start: last))
            return Ok(tokens)
        }
        Err(e) => {
            return Err(e)
        }
    }
}

fn main() -> Int {
    match lex(3) {
        Ok(list) => { return list.length }
        Err(e) => { return 100 + e }
    }
}
"#;

const RESULT_TEXT_TEXT: &str = r#"fn mk(n: Int) -> Result<Text, Text> {
    if n > 0 { return Ok(label(n)) }
    return Err(label(0))
}

fn main() -> Int {
    match mk(1) {
        Ok(t) => { print(t) }
        Err(e) => { print(e) }
    }
    return 0
}
"#;

/// Review regression (Agent H): wildcards, `Some(_)`, `Ok(_)`/`Err(_)`, Err arm first.
const B_WILD: &str = r#"fn label(n: Int) -> Text {
    return "item-{n}"
}
fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    return Some(label(n))
}
fn res(n: Int) -> Result<Text, Text> {
    if n > 0 { return Ok(label(n)) }
    return Err(label(0 - n))
}
fn nested(n: Int) -> Option<Result<Text, Int>> {
    if n == 0 { return None }
    if n > 5 { return Some(Err(n)) }
    return Some(Ok(label(n)))
}

fn main() -> Int {
    var total = 0
    let o = maybe(1)
    match o {
        Some(t) => { print(t) }
        _ => { total += 1 }
    }
    let p = maybe(-1)
    match p {
        Some(t) => { print(t) }
        _ => { total += 2 }
    }
    match maybe(3) {
        _ => { total += 4 }
    }
    match res(-2) {
        Ok(_) => { total += 8 }
        Err(_) => { total += 16 }
    }
    match res(2) {
        Err(e) => { print(e) }
        Ok(_) => { total += 32 }
    }
    return total
}
"#;

/// Review regression (Agent H): partially matched Option<Result<Text,Int>>, `continue` in a nested arm.
const D_NESTED: &str = r#"fn label(n: Int) -> Text {
    return "item-{n}"
}
fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    return Some(label(n))
}
fn res(n: Int) -> Result<Text, Text> {
    if n > 0 { return Ok(label(n)) }
    return Err(label(0 - n))
}
fn nested(n: Int) -> Option<Result<Text, Int>> {
    if n == 0 { return None }
    if n > 5 { return Some(Err(n)) }
    return Some(Ok(label(n)))
}

fn main() -> Int {
    var total = 0
    for i in 0..8 {
        match nested(i) {
            Some(r) => {
                match r {
                    Ok(_) => { total += 1 }
                    Err(e) => { total += e }
                }
            }
            None => { total += 100 }
        }
        match nested(i) {
            Some(r) => { total += 1000 }
            None => {}
        }
        match nested(i) {
            Some(r) => {
                match r {
                    Ok(t) => {
                        if i == 3 { continue }
                        print(t)
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    return total % 256
}
"#;

/// Review regression (Agent H): readText Ok/Err, unbound result, loop with continue/break.
const V_READ: &str = r#"fn main() -> Int {
    var total = 0
    let path = "payload.txt"
    match readText(path, 64) {
        Ok(t) => { print(t) }
        Err(e) => { total += 1 }
    }
    let missing = "nope.txt"
    match readText(missing, 64) {
        Ok(t) => { print(t) }
        Err(e) => { total += 2 }
    }
    let kept = readText(path, 64)
    match readText(path, 64) {
        Ok(_) => { total += 4 }
        Err(_) => { total += 8 }
    }
    for i in 0..3 {
        match readText(path, 64) {
            Ok(t) => {
                if i == 1 { continue }
                if i == 2 { break }
                total += t.byteLength
            }
            Err(_) => { return 99 }
        }
    }
    return total
}
"#;

/// Review regression (Agent H): Result<shape{Text, List<Text>}, Text>.
const X_SHAPE: &str = r#"fn label(n: Int) -> Text {
    return "item-{n}"
}
fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    return Some(label(n))
}
struct Named {
    name: Text,
    tags: List<Text>,
}
fn mk(n: Int) -> Result<Named, Text> {
    if n < 0 { return Err(label(n)) }
    var tags: List<Text> = List[]
    tags.push(label(n + 1))
    return Ok(Named(name: label(n), tags: tags))
}
fn main() -> Int {
    var total = 0
    match mk(1) {
        Ok(v) => {
            print(v.name)
            total += v.tags.length
        }
        Err(e) => { print(e) }
    }
    match mk(-1) {
        Ok(_) => { total += 10 }
        Err(e) => { print(e) }
    }
    let k = mk(2)
    match k {
        Err(_) => { total += 100 }
        Ok(v) => { total += v.name.byteLength }
    }
    let unused = mk(3)
    return total
}
"#;

fn program(body: &str) -> String {
    format!("{LABEL}{body}")
}

/// `ELE 1.0` header bytes of enum `e{k}` variant names.
const OK: &str = "variant 2:79,107 types 1";
const ERR: &str = "variant 3:69,114,114 types 1";
const SOME: &str = "variant 4:83,111,109,101 types 1";

#[test]
fn owned_union_lir_is_emitted_with_distinct_generic_identities() {
    let lir = emit("identities.l", &program(OWNED));
    validate(&lir).unwrap();
    // Option<Text>, Result<Text,Int>, Result<Int,Text>, Result<List<Int>,Int>,
    // Result<Text,Int> nested in Option: each is its own enum; the two
    // Text/Int results differ by variant order of their payloads.
    assert!(lir.contains(&format!("{SOME} t")), "{lir}");
    assert!(lir.contains(&format!("{OK} t\n{ERR} i")), "{lir}");
    assert!(lir.contains(&format!("{OK} i\n{ERR} t")), "{lir}");
    let list = lir
        .lines()
        .find_map(|l| l.strip_prefix(&format!("{OK} l")))
        .expect("Result<List<Int>,Int>");
    assert!(lir.contains(&format!("list l{list} i")), "{lir}");
    // Option<Result<Text,Int>> names the earlier Result<Text,Int> enum.
    let inner = lir
        .lines()
        .position(|l| l == format!("{OK} t"))
        .map(|at| lir.lines().nth(at - 1).unwrap().to_string())
        .unwrap();
    let inner_id = inner.split_whitespace().nth(1).unwrap();
    assert!(
        lir.contains(&format!("{SOME} {inner_id}")),
        "nested union must reuse {inner_id}: {lir}"
    );
    // Owned payloads leave their unions with a checked `payload`; unions
    // are dropped by `drop` (atomically: only the active payload).
    assert!(lir.matches("i payload ").count() >= 8, "{lir}");
    assert!(lir.contains("i drop "), "{lir}");
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
    // Every reservation is released exactly once; the heap stays valid.
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

#[cfg(windows)]
#[test]
fn owned_unions_run_from_stage1_lir_with_stage0_parity_and_balanced_heap() {
    let (code, stdout) = run_lir_and_stage0("owned", &program(OWNED));
    assert_eq!(code, 53);
    assert_eq!(
        stdout,
        "item-3\nitem-7\nitem-20\nitem-1\nitem-2\nitem-3\nitem-4\nitem-5\n"
    );
    let (code, stdout) = run_lir_and_stage0("loops", &program(LOOPS));
    assert_eq!((code, stdout.as_str()), (16, "9\n6\n1\n"));
    let (code, _) = run_lir_and_stage0("lexlike", LEXLIKE);
    assert_eq!(code, 2);
}

#[cfg(windows)]
#[test]
fn review_regressions_run_balanced_with_stage0_parity() {
    // v_read reads this file relative to the working directory.
    fs::write(temp().join("payload.txt"), "hello-file").unwrap();
    for (name, source, expected) in [
        ("b_wild", B_WILD, 54),
        ("d_nested", D_NESTED, 206),
        ("v_read", V_READ, 16),
        ("x_shape", X_SHAPE, 7),
    ] {
        let (code, _) = run_lir_and_stage0(name, source);
        assert_eq!(code, expected, "{name}");
    }
}

#[test]
fn payload_of_the_final_arm_carries_its_own_pattern_position() {
    let source = program(
        "fn maybe(n: Int) -> Option<Text> {\n    if n < 0 { return None }\n    return Some(label(n))\n}\nfn main() -> Int {\n    let o = maybe(1)\n    match o {\n        None => { print(\"none\") }\n        Some(t) => { print(t) }\n    }\n    return 0\n}\n",
    );
    let lir = emit("final_arm_span.l", &source);
    // `Some(t)` is on line 13, column 9 (after the 4-line `label` prelude).
    let payload = lir.lines().find(|l| l.starts_with("i payload ")).unwrap();
    assert!(payload.ends_with("@13:9"), "{payload}");
}

#[test]
fn lexer_return_ok_tokens_no_longer_blocks_stage1() {
    // The measured first blocker: `return Ok(tokens)` in lexSource.
    let lir = emit("lexlike_shape.l", LEXLIKE);
    validate(&lir).unwrap();
    assert!(lir.contains(&format!("{OK} l0")), "{lir}");
    let real = stage1(&root().join("compiler-l/src/lexer.l"), "--emit-lir");
    let stderr = String::from_utf8_lossy(&real.stderr);
    assert!(real.status.success(), "lexer.l: {stderr}");
    assert!(!stderr.contains("lexer.l:297"), "{stderr}");
    let text = String::from_utf8(real.stdout).unwrap();
    assert!(text.starts_with("ELE-LIR 1\n"), "{text}");
    assert!(text.contains(&format!("{OK} l0")), "{text}");
}

#[test]
fn ele_native_backend_rejects_owned_union_lir_without_an_image() {
    // Fail closed: layout code 82 is resolved, but whole-union drop glue
    // is not implemented yet in the native backend (code 92), so no ELF is written.
    let lir = emit("native_reject.l", &program(LOOPS));
    validate(&lir).unwrap();
    let file = write("native_reject.lir", &lir);
    let image = temp().join("native_reject.elf");
    let _ = fs::remove_file(&image);
    let out = Command::new(native())
        .arg(&file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(!out.status.success(), "owned union LIR reached native code");
    assert_eq!(out.status.code(), Some(3), "a crash is not a rejection");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("ELE-LIR/CFG rechazado (código 92)"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!image.exists(), "ELF written for rejected LIR");
}

/// Remove (`dup == false`) or duplicate the first line matching `pred`,
/// keeping the enclosing `block N K` instruction count consistent.
fn mutate(lir: &str, pred: impl Fn(&str) -> bool, dup: bool) -> String {
    let mut lines: Vec<String> = lir.lines().map(str::to_string).collect();
    let at = lines.iter().position(|l| pred(l)).expect("line to mutate");
    let header = (0..at)
        .rev()
        .find(|&i| lines[i].starts_with("block "))
        .unwrap();
    let mut parts: Vec<String> = lines[header]
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let count: usize = parts[2].parse().unwrap();
    parts[2] = if dup { count + 1 } else { count - 1 }.to_string();
    lines[header] = parts.join(" ");
    if dup {
        let copy = lines[at].clone();
        lines.insert(at, copy);
    } else {
        lines.remove(at);
    }
    lines.join("\n") + "\n"
}

#[test]
fn rust_validator_rejects_mutated_owned_union_lir() {
    let source = format!(
        "{LABEL}fn main() -> Int {{\n    let o = Some(label(1))\n    match o {{\n        Some(s) => {{ print(s) }}\n        None => {{}}\n    }}\n    let kept: Result<Text, Int> = Ok(label(2))\n    return 0\n}}\n"
    );
    let lir = emit("mutations.l", &source);
    validate(&lir).unwrap();
    // Union-typed variables of `main` (the last function); `kept`
    // (Result<Text,Int>) is dropped unconditionally at return.
    let main_fn = &lir[lir.rfind("\nfunc ").unwrap()..];
    let unions: Vec<String> = main_fn
        .lines()
        .filter_map(|l| {
            let rest = l.strip_prefix("var ")?;
            let mut w = rest.split_whitespace();
            let var = w.next()?;
            (w.next()? == "val" && w.next()?.starts_with('e')).then(|| var.to_string())
        })
        .collect();
    assert!(unions.len() >= 2, "{main_fn}");
    let last_union_drop = |l: &str| {
        l.starts_with("i drop ")
            && l.contains(" - ")
            && unions
                .iter()
                .any(|v| l.starts_with(&format!("i drop {v} ")))
    };
    assert!(lir.lines().any(last_union_drop), "{lir}");
    // Leak: the active payload of the dropped union is never released.
    let missing = mutate(&lir, last_union_drop, false);
    assert!(validate(&missing).is_err(), "missing drop accepted");
    // Double drop of the same union.
    let double = mutate(&lir, last_union_drop, true);
    assert!(validate(&double).is_err(), "double drop accepted");
    // Moving the owned payload out twice: the first `payload` consumed `o`.
    let twice = mutate(&lir, |l| l.starts_with("i payload "), true);
    assert!(validate(&twice).is_err(), "double move out accepted");
    // A payload of the wrong type for its variant.
    let wrong = lir.replacen("types 1 t", "types 1 i", 1);
    assert!(validate(&wrong).is_err(), "payload type confusion accepted");
}

#[test]
fn rust_validator_rejects_forged_drop_flag_values() {
    let lir = emit("b_wild.l", B_WILD);
    validate(&lir).expect("clean b_wild must validate");

    // Attack 1: Double free (change cb0 to cb1 after payload move-out)
    let forged_df = lir.replacen(
        "i payload v5 p2 e0 1 @22:9\r\ni use v32 cb0",
        "i payload v5 p2 e0 1 @22:9\r\ni use v32 cb1",
        1,
    );
    let forged_df = if forged_df == lir {
        lir.replacen(
            "i payload v5 p2 e0 1 @22:9\ni use v32 cb0",
            "i payload v5 p2 e0 1 @22:9\ni use v32 cb1",
            1,
        )
    } else {
        forged_df
    };
    assert_ne!(forged_df, lir, "replacement for double free must succeed");
    let err_df = validate(&forged_df).expect_err("tampered flag cb1 must be rejected");
    assert!(
        err_df.contains("doble liberación o fuga")
            || err_df.contains("no coincide")
            || err_df.contains("no refleja"),
        "unexpected error: {err_df}"
    );

    // Attack 2: Leak (change cb1 to cb0 when value is owned)
    let forged_leak = lir.replacen(
        "i use v2 v1 @20:5\r\ni use v32 cb1",
        "i use v2 v1 @20:5\r\ni use v32 cb0",
        1,
    );
    let forged_leak = if forged_leak == lir {
        lir.replacen(
            "i use v2 v1 @20:5\ni use v32 cb1",
            "i use v2 v1 @20:5\ni use v32 cb0",
            1,
        )
    } else {
        forged_leak
    };
    assert_ne!(forged_leak, lir, "replacement for leak must succeed");
    let err_leak = validate(&forged_leak).expect_err("tampered flag cb0 must be rejected");
    assert!(
        err_leak.contains("doble liberación o fuga")
            || err_leak.contains("no coincide")
            || err_leak.contains("no refleja"),
        "unexpected error: {err_leak}"
    );
}

const STRUCT_PARTIAL_MOVE_TEXT: &str = r#"struct Pair {
    first: Text,
    second: Text,
}
fn take(t: Text) {}
fn cond_field(c: Bool) {
    var p = Pair(first: "a", second: "b")
    if c {
        take(p.first)
    }
}
fn main() -> Int {
    cond_field(true)
    return 0
}
"#;

const STRUCT_PARTIAL_MOVE_LIST: &str = r#"struct Holder {
    items: List<Int>,
    name: Text,
}
fn take_items(l: List<Int>) {}
fn cond_list(c: Bool) {
    var h = Holder(items: List[1, 2, 3], name: "holder")
    if c {
        take_items(h.items)
    }
}
fn main() -> Int {
    cond_list(true)
    return 0
}
"#;

#[test]
fn rust_validator_rejects_forged_dropfield_flags() {
    // 1. Text field partial move in a struct
    let lir_text = emit("struct_text.l", STRUCT_PARTIAL_MOVE_TEXT);
    validate(&lir_text).expect("clean text struct must validate");
    assert!(
        lir_text.contains("i dropfield p2.0 v5"),
        "LIR must contain flagged dropfield: {lir_text}"
    );

    // Attack 1: Double free (change cb0 to cb1 after partial move)
    let forged_df = if lir_text.contains("val v3 @9:9\r\ni use v5 cb0") {
        lir_text.replacen(
            "val v3 @9:9\r\ni use v5 cb0",
            "val v3 @9:9\r\ni use v5 cb1",
            1,
        )
    } else {
        lir_text.replacen("val v3 @9:9\ni use v5 cb0", "val v3 @9:9\ni use v5 cb1", 1)
    };
    assert_ne!(
        forged_df, lir_text,
        "replacement for double free must succeed"
    );
    let err_df = validate(&forged_df).expect_err("tampered dropfield flag cb1 must be rejected");
    assert!(
        err_df.contains("doble liberación o fuga")
            || err_df.contains("no coincide")
            || err_df.contains("no refleja"),
        "unexpected error: {err_df}"
    );

    // Attack 2: Leak (change cb1 to cb0 when field is owned)
    let forged_leak = lir_text.replacen("i use v5 cb1", "i use v5 cb0", 1);
    assert_ne!(forged_leak, lir_text, "replacement for leak must succeed");
    let err_leak =
        validate(&forged_leak).expect_err("tampered dropfield flag cb0 must be rejected");
    assert!(
        err_leak.contains("doble liberación o fuga")
            || err_leak.contains("no coincide")
            || err_leak.contains("no refleja"),
        "unexpected error: {err_leak}"
    );

    // 2. List field partial move in a struct
    let lir_list = emit("struct_list.l", STRUCT_PARTIAL_MOVE_LIST);
    validate(&lir_list).expect("clean list struct must validate");
    assert!(
        lir_list.contains("i dropfield p3.0 v6"),
        "LIR must contain flagged dropfield: {lir_list}"
    );

    // Attack 1: Double free (change cb0 to cb1 after partial move)
    let forged_df_l = if lir_list.contains("val v4 @9:9\r\ni use v6 cb0") {
        lir_list.replacen(
            "val v4 @9:9\r\ni use v6 cb0",
            "val v4 @9:9\r\ni use v6 cb1",
            1,
        )
    } else {
        lir_list.replacen("val v4 @9:9\ni use v6 cb0", "val v4 @9:9\ni use v6 cb1", 1)
    };
    assert_ne!(
        forged_df_l, lir_list,
        "replacement for double free must succeed"
    );
    let err_df_l =
        validate(&forged_df_l).expect_err("tampered dropfield list flag cb1 must be rejected");
    assert!(
        err_df_l.contains("doble liberación o fuga")
            || err_df_l.contains("no coincide")
            || err_df_l.contains("no refleja"),
        "unexpected error: {err_df_l}"
    );

    // Attack 2: Leak (change cb1 to cb0 when field is owned)
    let forged_leak_l = lir_list.replacen("i use v6 cb1", "i use v6 cb0", 1);
    assert_ne!(forged_leak_l, lir_list, "replacement for leak must succeed");
    let err_leak_l =
        validate(&forged_leak_l).expect_err("tampered dropfield list flag cb0 must be rejected");
    assert!(
        err_leak_l.contains("doble liberación o fuga")
            || err_leak_l.contains("no coincide")
            || err_leak_l.contains("no refleja"),
        "unexpected error: {err_leak_l}"
    );
}

#[cfg(windows)]
#[test]
fn reading_the_inactive_variant_traps_at_run_time() {
    // Result<Text,Text>: both payloads have the same type, so only the
    // runtime discriminant check can refuse an inactive-variant read.
    let lir = emit("inactive.l", &program(RESULT_TEXT_TEXT));
    validate(&lir).unwrap();
    let bad = lir.replacen(" e0 0 @", " e0 1 @", 1);
    assert_ne!(bad, lir, "{lir}");
    validate(&bad).unwrap();
    let file = write("inactive_bad.lir", &bad);
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(temp())
        .arg("run-lir")
        .arg(&file)
        .output()
        .unwrap();
    assert_ne!(out.status.code(), Some(0));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("variante enum inactiva"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn ele_verifier_rejects_owned_union_faults() {
    // 14: owned payload read from the other variant (type, rule 3);
    // 15: flagged drop of a maybe-moved union made unconditional (rule 6);
    // 16: use of a union after an owned payload consumed it (rule 5);
    // 17: drop flag forged to cb1 after move-out (double free, rule 6);
    // 18: drop flag forged to cb0 when owned (leak, rule 6).
    let maybe_moved = format!(
        "{LABEL}fn main() -> Int {{\n    let o = Some(label(1))\n    match o {{\n        Some(s) => {{ print(s) }}\n        None => {{ print(\"none\") }}\n    }}\n    return 0\n}}\n"
    );
    let path = write("faults.l", &maybe_moved);
    let clean = stage1(&path, "--emit-lir");
    assert!(clean.status.success());
    for (fault, rule) in [(14, 3), (15, 6), (16, 5), (17, 6), (18, 6)] {
        let out = stage1(&path, &format!("--lir-fault={fault}"));
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(!out.status.success(), "fault {fault} escaped the verifier");
        assert!(
            stderr.contains("error[ICE]") && stderr.contains(&format!("(regla {rule},")),
            "fault {fault}: {stderr}"
        );
        assert!(out.stdout.is_empty(), "fault {fault} emitted unchecked LIR");
    }

    let b_wild_path = write("b_wild_faults.l", B_WILD);
    for fault in [17, 18] {
        let out = stage1(&b_wild_path, &format!("--lir-fault={fault}"));
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            !out.status.success(),
            "b_wild fault {fault} escaped the verifier"
        );
        assert!(
            stderr.contains("error[ICE]") && stderr.contains("(regla 6,"),
            "b_wild fault {fault}: {stderr}"
        );
        assert!(
            out.stdout.is_empty(),
            "b_wild fault {fault} emitted unchecked LIR"
        );
    }
}

#[test]
fn ele_verifier_rejects_dropfield_faults() {
    for (name, source) in [
        ("struct_text_faults.l", STRUCT_PARTIAL_MOVE_TEXT),
        ("struct_list_faults.l", STRUCT_PARTIAL_MOVE_LIST),
    ] {
        let path = write(name, source);
        let clean = stage1(&path, "--emit-lir");
        assert!(
            clean.status.success(),
            "{name}: clean build failed: {}",
            String::from_utf8_lossy(&clean.stderr)
        );
        for fault in [17, 18] {
            let out = stage1(&path, &format!("--lir-fault={fault}"));
            let stderr = String::from_utf8_lossy(&out.stderr);
            assert!(
                !out.status.success(),
                "{name} fault {fault} escaped the verifier"
            );
            assert!(
                stderr.contains("error[ICE]") && stderr.contains("(regla 6,"),
                "{name} fault {fault}: {stderr}"
            );
            assert!(
                out.stdout.is_empty(),
                "{name} fault {fault} emitted unchecked LIR"
            );
        }
    }
}

#[test]
fn unsafe_owned_union_programs_are_rejected_with_diagnostics() {
    let cases = [
        // Use after move into Ok.
        (
            "use_after_ok.l",
            "fn main() -> Int {\n    let t = label(1)\n    let r: Result<Text, Int> = Ok(t)\n    print(t)\n    return 0\n}\n",
            "L0005",
        ),
        // The same owned value moved into two unions.
        (
            "double_move.l",
            "fn main() -> Int {\n    let t = label(1)\n    let a = Some(t)\n    let b = Some(t)\n    return 0\n}\n",
            "L0005",
        ),
        // A borrowed union cannot give its owned payload away.
        (
            "borrowed_escape.l",
            "fn peek(o: &Option<Text>) -> Text {\n    match o {\n        Some(s) => { return s }\n        None => { return label(0) }\n    }\n}\nfn main() -> Int {\n    let o = Some(label(2))\n    let t = peek(&o)\n    return 0\n}\n",
            "L0005",
        ),
        // Assigning the examined place inside an arm with a non-Copy
        // binding (SEMANTICS.md "Enums y match"; Stage 0 rejects it too).
        (
            "assign_examined.l",
            "fn maybe(n: Int) -> Option<Text> {\n    return Some(label(n))\n}\nfn main() -> Int {\n    var q = maybe(2)\n    match q {\n        Some(t) => {\n            print(t)\n            q = maybe(3)\n        }\n        None => {}\n    }\n    return 0\n}\n",
            "L0005",
        ),
        // The scrutinee was consumed by binding its payload.
        (
            "scrutinee_reused.l",
            "fn main() -> Int {\n    let o = Some(label(4))\n    match o {\n        Some(s) => { print(s) }\n        None => {}\n    }\n    match o {\n        Some(s) => { print(s) }\n        None => {}\n    }\n    return 0\n}\n",
            "L0005",
        ),
        // Generic identity: Result<Text,Int> is not Result<Int,Text>.
        (
            "identity.l",
            "fn main() -> Int {\n    let r: Result<Text, Int> = Ok(label(5))\n    let x: Result<Int, Text> = r\n    return 0\n}\n",
            "L0003",
        ),
    ];
    for (name, body, code) in cases {
        let out = stage1(&write(name, &program(body)), "--emit-lir");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "{name}: {stderr}");
        assert!(
            stderr.contains(&format!("error[{code}]")),
            "{name}: {stderr}"
        );
        assert!(out.stdout.is_empty(), "{name}");
    }
    // A projected owned scrutinee would be copied by `read` (aliasing its
    // owner): accepted by ownership checking, but outside ELE-LIR.
    let projected = write(
        "projected.l",
        &program(
            "struct Holder {\n    o: Option<Text>,\n}\nfn main() -> Int {\n    let h = Holder(o: Some(label(3)))\n    match h.o {\n        Some(_) => { print(\"some\") }\n        None => { print(\"none\") }\n    }\n    return 0\n}\n",
        ),
    );
    assert!(stage1(&projected, "--check-ownership").status.success());
    let out = stage1(&projected, "--emit-lir");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("error[L0016]"), "{stderr}");
    assert!(out.stdout.is_empty());
}
