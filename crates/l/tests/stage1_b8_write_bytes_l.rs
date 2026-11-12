//! B8: the `writeBytes(ruta: Text, bytes: List<Int>) -> Int` builtin in
//! Stage 1, mirroring Stage 0 (`sema.rs`): the path is a Text (a Text
//! reference is read through), the bytes are a List<Int>, both are only
//! lent to the call (never moved), and the result is an Int. Stage 1 lowers
//! it to ELE-LIR platform op `writebytes` with two shared borrows, the form
//! the Stage 0 protocol reader and CFG verifier accept.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn case_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/b8-write-bytes")
        .join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

struct Out {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn exec(cmd: &mut Command) -> Out {
    let o = cmd.output().unwrap();
    Out {
        code: o.status.code(),
        stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
    }
}

fn stage1(dir: &Path, name: &str, source: &str, flag: &str) -> Out {
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    exec(Command::new(sema()).arg(file).arg(flag).env("PATH", ""))
}

fn check_ok(name: &str, source: &str) {
    let dir = case_dir(name);
    let out = stage1(&dir, name, source, "--check-ownership");
    assert_eq!(out.code, Some(0), "{name}: {}", out.stderr);
    assert!(!out.stderr.contains("error["), "{name}: {}", out.stderr);
}

fn check_err(name: &str, source: &str, code: &str, message: &str) {
    let dir = case_dir(name);
    let out = stage1(&dir, name, source, "--check-ownership");
    assert_ne!(out.code, Some(0), "{name} must be rejected");
    assert!(
        out.stderr.contains(&format!("error[{code}]")) && out.stderr.contains(message),
        "{name}: expected {code} '{message}', got: {}",
        out.stderr
    );
}

/// Builds `lir` with the provisional backend (allocation traced) and runs it
/// inside `dir`, where the program writes its files.
fn build_and_run_lir(dir: &Path, name: &str, lir: &str) -> Out {
    let file = dir.join(format!("{name}.lir"));
    fs::write(&file, lir).unwrap();
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(dir)
            .arg("build-lir")
            .arg(&file)
            .arg("--trace-alloc"),
    );
    assert_eq!(
        build.code,
        Some(0),
        "{name}: {}{}",
        build.stdout,
        build.stderr
    );
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    exec(Command::new(exe).current_dir(dir))
}

fn run_lir(dir: &Path, name: &str, lir: &str) -> Out {
    let file = dir.join(format!("{name}.lir"));
    fs::write(&file, lir).unwrap();
    exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(dir)
            .arg("run-lir")
            .arg(&file),
    )
}

fn stage0_run(dir: &Path, name: &str, source: &str) -> Out {
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(dir)
            .arg("build")
            .arg(&file)
            .args(["--backend", "cranelift"]),
    );
    assert_eq!(build.code, Some(0), "{name} stage0: {}", build.stderr);
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    exec(Command::new(exe).current_dir(dir))
}

const PROGRAM: &str = r#"struct Image { image: List<Int> }

fn bytesOf(n: Int) -> List<Int> {
    var out: List<Int> = List[]
    for i in 0..n { out.push(48 + i) }
    return out
}

fn viaRefs(path: &Text, bytes: &List<Int>) -> Int {
    return writeBytes(path, bytes)
}

fn main() -> Int {
    let path = "a.bin"
    var bytes: List<Int> = List[0, 127, 128, 255, 10]
    let status = writeBytes(path, bytes)
    // The list was only lent: it is still owned and usable.
    bytes.push(65)
    print(bytes.length)
    print(path)
    let named = "b"
    writeBytes("{named}.bin", bytesOf(3))
    let img = Image(image: List[1, 2, 3])
    let field = writeBytes("c.bin", img.image)
    print(img.image.length)
    let refs = viaRefs(&path, &bytes)
    let bad = writeBytes("d.bin", List[1, 256])
    let empty: List<Int> = List[]
    if writeBytes("e.bin", empty) != 0 { return 90 }
    return 7 + status + field + refs + bad * 30
}
"#;

fn expected_files(dir: &Path) {
    let read = |name: &str| fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    // a.bin is written twice: the second call sees the pushed byte.
    assert_eq!(read("a.bin"), [0, 127, 128, 255, 10, 65]);
    assert_eq!(read("b.bin"), b"012");
    assert_eq!(read("c.bin"), [1, 2, 3]);
    assert_eq!(read("e.bin"), [] as [u8; 0]);
}

#[test]
fn b8_write_bytes_lowers_to_platform_op_and_writes_exact_bytes() {
    let dir = case_dir("program");
    let check = stage1(&dir, "program", PROGRAM, "--check-ownership");
    assert_eq!(check.code, Some(0), "{}", check.stderr);

    let lir = stage1(&dir, "program", PROGRAM, "--emit-lir");
    assert_eq!(lir.code, Some(0), "{}", lir.stderr);
    assert!(lir.stdout.starts_with("ELE-LIR 1\n"), "{}", lir.stdout);
    let platform: Vec<&str> = lir
        .stdout
        .lines()
        .filter(|l| l.starts_with("i platform v"))
        .collect();
    assert_eq!(platform.len(), 6, "{}", lir.stdout);
    for line in &platform {
        let words: Vec<&str> = line.split_whitespace().collect();
        // i platform vN writebytes 2 ref pA 0 ref pB 0 @l:c
        assert_eq!(&words[3..5], ["writebytes", "2"], "{line}");
        assert_eq!(words[5], "ref", "{line}");
        assert_eq!(words[7], "0", "{line}");
        assert_eq!(words[8], "ref", "{line}");
        assert_eq!(words[10], "0", "{line}");
    }

    // Stage 0 provisional backend: the Stage 1 LIR runs, writes the files
    // byte for byte and frees every allocation.
    let run = build_and_run_lir(&dir, "program", &lir.stdout);
    assert_eq!(run.code, Some(37), "{}{}", run.stdout, run.stderr);
    assert_eq!(run.stdout.replace("\r\n", "\n"), "6\na.bin\n3\n");
    stage1_support::assert_heap(&run.stderr);
    expected_files(&dir);
    assert!(!dir.join("d.bin").exists() || fs::read(dir.join("d.bin")).unwrap().is_empty());

    // Same source through Stage 0: same output, exit code and files.
    let zero_dir = case_dir("program-stage0");
    let zero = stage0_run(&zero_dir, "program", PROGRAM);
    assert_eq!(zero.code, run.code, "{}", zero.stderr);
    assert_eq!(zero.stdout, run.stdout);
    expected_files(&zero_dir);
}

#[test]
fn b8_write_bytes_borrows_its_arguments() {
    check_ok(
        "mut_refs",
        "fn w(p: &mut Text, b: &mut List<Int>) -> Int { return writeBytes(p, b) }\nfn main() -> Int {\n    var p = \"x.bin\"\n    var b: List<Int> = List[1]\n    let r = w(&mut p, &mut b)\n    b.push(2)\n    return r + b.length\n}\n",
    );
    check_ok(
        "literals",
        "fn main() -> Int { return writeBytes(\"x.bin\", List[65, 66]) }\n",
    );
    // A list moved before the call cannot be lent to it.
    check_err(
        "use_after_move",
        "fn eat(b: List<Int>) -> Int { return b.length }\nfn main() -> Int {\n    let b: List<Int> = List[1]\n    let n = eat(b)\n    return writeBytes(\"x.bin\", b)\n}\n",
        "L0005",
        "",
    );
    check_err(
        "path_after_move",
        "fn eat(t: Text) -> Int { return 0 }\nfn main() -> Int {\n    let p = \"x.bin\"\n    let n = eat(p)\n    let b: List<Int> = List[1]\n    return writeBytes(p, b)\n}\n",
        "L0005",
        "",
    );
    // As in Stage 0, an explicit borrow is not a Text argument.
    check_err(
        "explicit_borrow",
        "fn main() -> Int {\n    let p = \"x.bin\"\n    let b: List<Int> = List[1]\n    return writeBytes(&p, b)\n}\n",
        "L0001",
        "préstamo",
    );
}

#[test]
fn b8_write_bytes_rejects_wrong_arity_and_types() {
    let shape = "writeBytes requiere (ruta: Text, bytes: List<Int>)";
    check_err(
        "one_arg",
        "fn main() -> Int { return writeBytes(\"x.bin\") }\n",
        "L0004",
        shape,
    );
    check_err(
        "three_args",
        "fn main() -> Int {\n    let b: List<Int> = List[1]\n    return writeBytes(\"x.bin\", b, 1)\n}\n",
        "L0004",
        shape,
    );
    check_err(
        "bool_list",
        "fn main() -> Int {\n    let b: List<Bool> = List[true]\n    return writeBytes(\"x.bin\", b)\n}\n",
        "L0004",
        "writeBytes requiere una lista List<Int> de bytes",
    );
    check_err(
        "int_path",
        "fn main() -> Int {\n    let b: List<Int> = List[1]\n    return writeBytes(1, b)\n}\n",
        "L0004",
        "writeBytes requiere una ruta Text",
    );
    check_err(
        "int_bytes",
        "fn main() -> Int { return writeBytes(\"x.bin\", 7) }\n",
        "L0004",
        "writeBytes requiere una lista List<Int> de bytes",
    );
    check_err(
        "result_is_int",
        "fn main() -> Int {\n    let b: List<Int> = List[1]\n    let r: Bool = writeBytes(\"x.bin\", b)\n    return 0\n}\n",
        "L0003",
        "",
    );
}

#[test]
fn b8_stage0_protocol_rejects_malformed_write_bytes() {
    let dir = case_dir("malformed");
    let source = "fn main() -> Int {\n    let p = \"m.bin\"\n    let b: List<Int> = List[65]\n    return writeBytes(p, b)\n}\n";
    let lir = stage1(&dir, "base", source, "--emit-lir");
    assert_eq!(lir.code, Some(0), "{}", lir.stderr);
    let line = lir
        .stdout
        .lines()
        .find(|l| l.starts_with("i platform v"))
        .unwrap()
        .to_string();
    let words: Vec<&str> = line.split_whitespace().collect();
    let (dst, path, bytes, at) = (words[2], words[6], words[9], words[11]);
    let ok = run_lir(&dir, "base", &lir.stdout);
    assert_eq!(ok.code, Some(0), "{}", ok.stderr);
    assert_eq!(fs::read(dir.join("m.bin")).unwrap(), b"A");

    let cases = [
        (
            "value_path",
            format!("i platform {dst} writebytes 2 val v0 ref {bytes} 0 {at}"),
            "ruta Text prestada",
        ),
        (
            "one_arg",
            format!("i platform {dst} writebytes 1 ref {path} 0 {at}"),
            "dos argumentos",
        ),
        (
            "three_args",
            format!("i platform {dst} writebytes 3 ref {path} 0 ref {bytes} 0 val ci1 {at}"),
            "dos argumentos",
        ),
        (
            "mut_bytes",
            format!("i platform {dst} writebytes 2 ref {path} 0 ref {bytes} 1 {at}"),
            "List<Int> prestada",
        ),
        (
            "swapped",
            format!("i platform {dst} writebytes 2 ref {bytes} 0 ref {path} 0 {at}"),
            "ruta de writeBytes",
        ),
    ];
    for (name, bad, message) in cases {
        let text = lir.stdout.replace(&line, &bad);
        assert_ne!(text, lir.stdout, "{name}");
        let out = run_lir(&dir, name, &text);
        assert_ne!(out.code, Some(0), "{name} must be rejected");
        assert!(out.stderr.contains(message), "{name}: {}", out.stderr);
    }
}
