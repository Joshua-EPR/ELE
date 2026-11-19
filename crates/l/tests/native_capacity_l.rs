//! Capacity of the ELE-written native backend (compiler-l/src/codegen):
//! functions, variables, structs, enums and lists live in growable lists,
//! frames larger than one page are probed page by page (x86_64.l), and
//! aggregates may exceed the former 512-byte cap up to the layout planner's
//! 1 MiB. Every program here sits above an old static limit (256 variables
//! per function, 16 structs, 16 enums, 256 functions, 512-byte aggregates,
//! 4 KiB frames). The ELF64 images run on Linux x86-64, and on Windows
//! through WSL when `ELE_TEST_WSL_DISTRO` names a distribution; the PE32+
//! image of the frame program runs on Windows itself.
//!
//! What stays bounded is rejected with a specific code and no image:
//! a frame beyond the disp32/imm32 encoding (69), an aggregate beyond the
//! layout planner (62), declared counts without their declarations,
//! a type count that would reach the platform routine indexes (48), and
//! unsound or not yet lowered returned references (140, 141).
mod stage1_support;
use std::{
    fmt::Write as _,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn temp(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/native-capacity");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// ELE-LIR encoded identifier: `<len>:<byte>,<byte>,...`.
fn name(s: &str) -> String {
    let bytes: Vec<String> = s.bytes().map(|b| b.to_string()).collect();
    format!("{}:{}", s.len(), bytes.join(","))
}

/// Writes `lir`, runs the backend and returns its output and image path.
fn build(file: &str, lir: &str, pe64: bool) -> (std::process::Output, PathBuf) {
    let input = temp(&format!("{file}.lir"));
    fs::write(&input, lir).unwrap();
    let image = temp(&format!("{file}.{}", if pe64 { "exe" } else { "elf" }));
    let _ = fs::remove_file(&image);
    let mut cmd = Command::new(native());
    cmd.arg(&input).arg(&image);
    if pe64 {
        cmd.arg("--pe64");
    }
    (cmd.output().unwrap(), image)
}

fn accepted(file: &str, lir: &str) -> PathBuf {
    let (out, image) = build(file, lir, false);
    assert!(
        out.status.success(),
        "{file}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01", "{file}");
    image
}

fn rejected(file: &str, lir: &str, code: i32) {
    let (out, image) = build(file, lir, false);
    assert_eq!(out.status.code(), Some(3), "{file}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(&format!("rechazado (código {code})")),
        "{file}: {stderr}"
    );
    assert!(!image.exists(), "{file}: no image may be written");
}

/// Exit status of `image` on Linux x86-64, or through WSL on Windows when
/// `ELE_TEST_WSL_DISTRO` is set; `None` when this host cannot run it
/// (`Some(None)`: killed by a signal).
fn execute(image: &Path) -> Option<Option<i32>> {
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(image, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let out = Command::new(image).output().unwrap();
        assert!(out.stdout.is_empty() && out.stderr.is_empty());
        return Some(out.status.code());
    }
    if !cfg!(windows) {
        return None;
    }
    let distro = std::env::var("ELE_TEST_WSL_DISTRO").ok()?;
    let canonical = image.canonicalize().unwrap();
    let windows = canonical
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .replace('\\', "/");
    let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
    let linux = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());
    let script = "chmod 700 \"$1\" && exec \"$1\"";
    let out = Command::new("wsl")
        .args(["-d", &distro, "--exec", "sh", "-c", script, "sh", &linux])
        .output()
        .unwrap();
    assert!(
        out.stdout.is_empty() && out.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    Some(out.status.code())
}

fn expect_exit(image: &Path, status: i32) {
    if let Some(code) = execute(image) {
        assert_eq!(code, Some(status), "{}", image.display());
    }
}

/// `count` Int variables in one chain `v[i] = v[i-1] + 1`, starting at
/// `start` (an operand), and `t return v[count-1]`.
fn chain(out: &mut String, count: usize, start: &str) {
    for i in 0..count {
        writeln!(out, "var v{i} val i").unwrap();
    }
    writeln!(out, "block 0 {count}").unwrap();
    writeln!(out, "{start}").unwrap();
    for i in 1..count {
        writeln!(out, "i binary v{i} add v{} ci1", i - 1).unwrap();
    }
    writeln!(out, "t return v{}", count - 1).unwrap();
    out.push_str("endfunc\n");
}

/// 600 variables in a called function and 1100 in `main` (8800-byte frame,
/// two probed pages plus a remainder): above the old 256-variable and
/// 512-slot limits.
fn frame_program() -> String {
    let mut s = String::from("ELE-LIR 1\nmodule structs 0 funcs 2 main f1\n");
    writeln!(
        s,
        "func f0 {} params 1 result i 0 0 vars 600 blocks 1",
        name("wide")
    )
    .unwrap();
    // v0 is the parameter: the chain starts from it.
    for i in 0..600 {
        writeln!(s, "var v{i} val i").unwrap();
    }
    s.push_str("block 0 599\n");
    for i in 1..600 {
        writeln!(s, "i binary v{i} add v{} ci1", i - 1).unwrap();
    }
    s.push_str("t return v599\nendfunc\n");
    writeln!(
        s,
        "func f1 {} params 0 result i 0 0 vars 1100 blocks 1",
        name("main")
    )
    .unwrap();
    chain(&mut s, 1100, "i call v0 f0 1 val ci3");
    s.push_str("end\n");
    s
}

#[test]
fn functions_with_more_than_256_variables_and_4k_frames_run() {
    let lir = frame_program();
    let image = accepted("frame", &lir);
    // 3 + 599 = 602, then 1099 more: 1701 = 165 (mod 256).
    expect_exit(&image, 165);
    // The prologue probes each page: OR QWORD [RSP],0 inside the loop.
    let bytes = fs::read(&image).unwrap();
    assert!(
        bytes
            .windows(5)
            .any(|w| w == [0x48, 0x83, 0x0c, 0x24, 0x00]),
        "page probe"
    );
    // Reproducible: the same LIR gives the same bytes.
    let (again, again_image) = build("frame-again", &lir, false);
    assert!(again.status.success());
    assert_eq!(bytes, fs::read(again_image).unwrap());
}

#[test]
fn large_frames_run_as_pe32_plus_too() {
    let (out, image) = build("frame-pe", &frame_program(), true);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..2], b"MZ");
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let run = Command::new(&image).output().unwrap();
        // ExitProcess keeps all 32 bits of the status.
        assert_eq!(run.status.code(), Some(1701));
    }
}

/// Recursion with 8800-byte frames: 500 frames (4.4 MB) of stack growth,
/// each frame entered through the probe loop.
#[test]
fn deep_recursion_with_large_frames_runs() {
    let mut s = String::from("ELE-LIR 1\nmodule structs 0 funcs 2 main f1\n");
    writeln!(
        s,
        "func f0 {} params 1 result i 0 0 vars 1100 blocks 3",
        name("deep")
    )
    .unwrap();
    s.push_str("var v0 val i\nvar v1 val b\nvar v2 val i\nvar v3 val i\nvar v4 val i\n");
    for i in 5..1100 {
        writeln!(s, "var v{i} val i").unwrap();
    }
    // Touch the farthest slot so the whole frame is used.
    s.push_str("block 0 2\ni use v1099 ci0\ni binary v1 eq v0 ci0\nt branch v1 1 2\n");
    s.push_str("block 1 0\nt return v1099\n");
    s.push_str("block 2 3\ni binary v2 sub v0 ci1\ni call v3 f0 1 val v2\ni binary v4 add v3 ci1\nt return v4\n");
    s.push_str("endfunc\n");
    writeln!(
        s,
        "func f1 {} params 0 result i 0 0 vars 1 blocks 1",
        name("main")
    )
    .unwrap();
    s.push_str("var v0 val i\nblock 0 1\ni call v0 f0 1 val ci500\nt return v0\nendfunc\nend\n");
    let image = accepted("deep", &s);
    expect_exit(&image, 500 % 256);
}

/// 300 functions (old limit 256): f[i] = f[i+1](x) + 1, f[298] = x.
#[test]
fn more_than_256_functions_run() {
    let total = 300;
    let mut s = format!(
        "ELE-LIR 1\nmodule structs 0 funcs {total} main f{}\n",
        total - 1
    );
    for i in 0..total - 2 {
        writeln!(
            s,
            "func f{i} {} params 1 result i 0 0 vars 3 blocks 1",
            name(&format!("f{i}"))
        )
        .unwrap();
        writeln!(
            s,
            "var v0 val i\nvar v1 val i\nvar v2 val i\nblock 0 2\ni call v1 f{} 1 val v0\ni binary v2 add v1 ci1\nt return v2\nendfunc",
            i + 1
        )
        .unwrap();
    }
    writeln!(
        s,
        "func f{} {} params 1 result i 0 0 vars 1 blocks 1",
        total - 2,
        name("last")
    )
    .unwrap();
    s.push_str("var v0 val i\nblock 0 0\nt return v0\nendfunc\n");
    writeln!(
        s,
        "func f{} {} params 0 result i 0 0 vars 1 blocks 1",
        total - 1,
        name("main")
    )
    .unwrap();
    s.push_str("var v0 val i\nblock 0 1\ni call v0 f0 1 val ci0\nt return v0\nendfunc\nend\n");
    let image = accepted("functions", &s);
    expect_exit(&image, 298 % 256);
}

/// Structs s0..s19 (old limit 16) with fields (k, 1), plus s20 (40 Int
/// fields, 320 bytes) and s21 (two s20, 640 bytes, above the old 512-byte
/// cap) returned through the hidden result pointer and passed by value.
#[test]
fn more_than_16_structs_and_aggregates_above_512_bytes_run() {
    let mut s = String::from("ELE-LIR 1\nmodule structs 22 funcs 3 main f2\n");
    for k in 0..20 {
        writeln!(s, "struct s{k} {} fields 2", name(&format!("S{k}"))).unwrap();
        writeln!(s, "field {} i\nfield {} i", name("a"), name("b")).unwrap();
    }
    writeln!(s, "struct s20 {} fields 40", name("Wide")).unwrap();
    for k in 0..40 {
        writeln!(s, "field {} i", name(&format!("w{k}"))).unwrap();
    }
    writeln!(s, "struct s21 {} fields 2", name("Big")).unwrap();
    writeln!(s, "field {} s20\nfield {} s20", name("l"), name("r")).unwrap();
    // f0() -> s21: left w_k = k, right w_k = 100 + k.
    writeln!(
        s,
        "func f0 {} params 0 result s21 0 0 vars 3 blocks 1",
        name("make")
    )
    .unwrap();
    s.push_str("var v0 val s20\nvar v1 val s20\nvar v2 val s21\nblock 0 3\n");
    let left: Vec<String> = (0..40).map(|k| format!("ci{k}")).collect();
    let right: Vec<String> = (0..40).map(|k| format!("ci{}", 100 + k)).collect();
    writeln!(s, "i struct v0 s20 40 {}", left.join(" ")).unwrap();
    writeln!(s, "i struct v1 s20 40 {}", right.join(" ")).unwrap();
    s.push_str("i struct v2 s21 2 v0 v1\nt return v2\nendfunc\n");
    // f1(b: s21) -> Int: b.r.w39 - b.l.w5 = 139 - 5 = 134.
    writeln!(
        s,
        "func f1 {} params 1 result i 0 0 vars 4 blocks 1",
        name("take")
    )
    .unwrap();
    s.push_str("var v0 val s21\nvar v1 val i\nvar v2 val i\nvar v3 val i\nblock 0 3\n");
    s.push_str(
        "i read v1 p0.1.39\ni read v2 p0.0.5\ni binary v3 sub v1 v2\nt return v3\nendfunc\n",
    );
    // main: sum of field a of s0..s19 (0+...+19 = 190), plus field b (20),
    // plus f1(f0()) - 134 = 0: 210.
    let vars = 20 + 20 * 2 + 3 + 21;
    writeln!(
        s,
        "func f2 {} params 0 result i 0 0 vars {vars} blocks 1",
        name("main")
    )
    .unwrap();
    for k in 0..20 {
        writeln!(s, "var v{k} val s{k}").unwrap();
    }
    for i in 20..vars {
        if i == 60 {
            s.push_str("var v60 val s21\n");
        } else {
            writeln!(s, "var v{i} val i").unwrap();
        }
    }
    // v20..v59: field reads; v60 big; v61 f1 result; v62 adjusted;
    // v63..v83: running sum.
    let mut body = Vec::new();
    for k in 0..20 {
        body.push(format!("i struct v{k} s{k} 2 ci{k} ci1"));
    }
    for k in 0..20 {
        body.push(format!("i read v{} p{k}.0", 20 + 2 * k));
        body.push(format!("i read v{} p{k}.1", 21 + 2 * k));
    }
    body.push("i call v60 f0 0".to_string());
    body.push("i call v61 f1 1 val v60".to_string());
    body.push("i binary v62 sub v61 ci134".to_string());
    body.push("i use v63 v62".to_string());
    for k in 0..20 {
        body.push(format!(
            "i binary v{} add v{} v{}",
            64 + k,
            63 + k,
            20 + 2 * k
        ));
    }
    // v83 = 190. The 20 `b` fields are all 1: their sum is v21 * 20.
    body.push("i binary v62 mul v21 ci20".to_string());
    writeln!(s, "block 0 {}", body.len() + 1).unwrap();
    for line in &body {
        writeln!(s, "{line}").unwrap();
    }
    s.push_str("i binary v63 add v83 v62\nt return v63\nendfunc\nend\n");
    let image = accepted("structs", &s);
    expect_exit(&image, 210);
}

/// Enums e0..e19 (old limit 16), each `None | Some(Int)`: Some(k) for each,
/// payloads summed: 190.
#[test]
fn more_than_16_enums_run() {
    let mut s = String::from("ELE-LIR 1\nmodule structs 0 enums 20 funcs 1 main f0\n");
    for k in 0..20 {
        writeln!(s, "enum e{k} {} variants 2", name(&format!("E{k}"))).unwrap();
        writeln!(
            s,
            "variant {} types 0\nvariant {} types 1 i",
            name("None"),
            name("Some")
        )
        .unwrap();
    }
    let vars = 20 + 20 + 20;
    writeln!(
        s,
        "func f0 {} params 0 result i 0 0 vars {vars} blocks 1",
        name("main")
    )
    .unwrap();
    for k in 0..20 {
        writeln!(s, "var v{k} val e{k}").unwrap();
    }
    for i in 20..vars {
        writeln!(s, "var v{i} val i").unwrap();
    }
    let mut body = Vec::new();
    for k in 0..20 {
        body.push(format!("i variant v{k} e{k} 1 1 ci{k}"));
        body.push(format!("i payload v{} p{k} e{k} 1", 20 + k));
    }
    body.push("i use v40 v20".to_string());
    for k in 1..20 {
        body.push(format!("i binary v{} add v{} v{}", 40 + k, 39 + k, 20 + k));
    }
    writeln!(s, "block 0 {}", body.len()).unwrap();
    for line in &body {
        writeln!(s, "{line}").unwrap();
    }
    s.push_str("t return v59\nendfunc\nend\n");
    let image = accepted("enums", &s);
    expect_exit(&image, 190);
}

/// s0: 64 Int (512 B), s1: 64 x s0 (32 KiB), s2: 31 x s1 (992 KiB, near the
/// layout planner's 1 MiB bound).
fn megabyte_structs(extra: &str, structs: usize) -> String {
    let mut s = format!("ELE-LIR 1\nmodule structs {structs} funcs 1 main f0\n");
    writeln!(s, "struct s0 {} fields 64", name("A")).unwrap();
    for k in 0..64 {
        writeln!(s, "field {} i", name(&format!("a{k}"))).unwrap();
    }
    writeln!(s, "struct s1 {} fields 64", name("B")).unwrap();
    for k in 0..64 {
        writeln!(s, "field {} s0", name(&format!("b{k}"))).unwrap();
    }
    writeln!(s, "struct s2 {} fields 31", name("C")).unwrap();
    for k in 0..31 {
        writeln!(s, "field {} s1", name(&format!("c{k}"))).unwrap();
    }
    s.push_str(extra);
    s
}

#[test]
fn frames_beyond_the_disp32_encoding_are_rejected() {
    // 2115 variables of 126976 slots: 268554240, above x64MaxFrameSlots().
    let mut s = megabyte_structs("", 3);
    writeln!(
        s,
        "func f0 {} params 0 result i 0 0 vars 2116 blocks 1",
        name("main")
    )
    .unwrap();
    for i in 0..2115 {
        writeln!(s, "var v{i} val s2").unwrap();
    }
    s.push_str("var v2115 val i\nblock 0 0\nt return ci0\nendfunc\nend\n");
    rejected("frame-overflow", &s, 69);
}

#[test]
fn aggregates_beyond_the_layout_planner_are_rejected() {
    let mut extra = String::new();
    writeln!(extra, "struct s3 {} fields 2", name("D")).unwrap();
    writeln!(extra, "field {} s2\nfield {} s2", name("x"), name("y")).unwrap();
    let mut s = megabyte_structs(&extra, 4);
    writeln!(
        s,
        "func f0 {} params 0 result i 0 0 vars 1 blocks 1",
        name("main")
    )
    .unwrap();
    s.push_str("var v0 val i\nblock 0 0\nt return ci0\nendfunc\nend\n");
    rejected("too-big", &s, 62);
}

#[test]
fn declared_counts_without_their_declarations_are_rejected() {
    let main = format!(
        "func f0 {} params 0 result i 0 0 vars 1 blocks 1\nvar v0 val i\nblock 0 0\nt return ci0\nendfunc\n",
        name("main")
    );
    // 20 structs declared, 19 present.
    let mut s = String::from("ELE-LIR 1\nmodule structs 20 funcs 1 main f0\n");
    for k in 0..19 {
        writeln!(
            s,
            "struct s{k} {} fields 1\nfield {} i",
            name("S"),
            name("a")
        )
        .unwrap();
    }
    s.push_str(&main);
    s.push_str("end\n");
    rejected("structs-missing", &s, 60);
    // 300 functions declared, 1 present.
    rejected(
        "funcs-missing",
        &format!("ELE-LIR 1\nmodule structs 0 funcs 300 main f0\n{main}end\n"),
        44,
    );
    // 300 variables declared, 299 present.
    let mut s = String::from("ELE-LIR 1\nmodule structs 0 funcs 1 main f0\n");
    writeln!(
        s,
        "func f0 {} params 0 result i 0 0 vars 300 blocks 1",
        name("main")
    )
    .unwrap();
    for i in 0..299 {
        writeln!(s, "var v{i} val i").unwrap();
    }
    s.push_str("block 0 0\nt return ci0\nendfunc\nend\n");
    rejected("vars-missing", &s, 45);
    // Type codes would reach the platform routine indexes (cfgPlatformBase).
    rejected(
        "types-overflow",
        &format!("ELE-LIR 1\nmodule structs 1048575 funcs 1 main f0\n{main}end\n"),
        48,
    );
    rejected(
        "negative-count",
        &format!("ELE-LIR 1\nmodule structs 0 enums -1 funcs 1 main f0\n{main}end\n"),
        48,
    );
}

/// A function returning a reference into its reference parameter's list
/// (the shape of cursor.l's `cursorCurrent`) is accepted; `main` does not
/// call it, since calls of such functions are not lowered yet.
fn cursor_current(result: &str, loan_mode: u8) -> String {
    format!(
        "func f0 {} params 2 result {result} vars 4 blocks 2\nvar v0 ref s0\nvar v1 ref l0\nvar v2 val i\nvar v3 ref i\nblock 0 2\ni read v2 p0.0\ni loan v3 p1[v2] {loan_mode}\nt returnref v3\nblock 1 0\nt unreachable\nendfunc\n",
        name("cursorCurrent")
    )
}

fn returnref_module(functions: &str, count: usize, main_body: &str) -> String {
    format!(
        "ELE-LIR 1\nmodule structs 1 lists 1 funcs {} main f{count}\nstruct s0 {} fields 1\nfield {} i\nlist l0 i\n{functions}func f{count} {} params 0 result i 0 0 vars 4 blocks 1\nvar v0 val i\nvar v1 val s0\nvar v2 val l0\nvar v3 val i\n{main_body}endfunc\nend\n",
        count + 1,
        name("Cursor"),
        name("index"),
        name("main")
    )
}

#[test]
fn functions_returning_references_are_accepted_but_not_called() {
    let main = "block 0 0\nt return ci42\n";
    let image = accepted(
        "returnref",
        &returnref_module(&cursor_current("i 1 0", 0), 1, main),
    );
    expect_exit(&image, 42);
    // Exclusive result through an exclusive loan.
    accepted(
        "returnref-mut",
        &returnref_module(&cursor_current("i 1 1", 1), 1, main),
    );
}

#[test]
fn unsound_or_unlowered_returned_references_are_rejected() {
    let main = "block 0 0\nt return ci42\n";
    // An exclusive result through a shared loan.
    rejected(
        "returnref-shared-as-mut",
        &returnref_module(&cursor_current("i 1 1", 0), 1, main),
        140,
    );
    // A reference into a local: it would dangle.
    let local = format!(
        "func f0 {} params 0 result i 1 0 vars 2 blocks 1\nvar v0 val i\nvar v1 ref i\nblock 0 2\ni use v0 ci1\ni loan v1 p0 0\nt returnref v1\nendfunc\n",
        name("dangling")
    );
    rejected("returnref-local", &returnref_module(&local, 1, main), 140);
    // A by-value result returned with `t return`.
    let plain = format!(
        "func f0 {} params 1 result i 1 0 vars 1 blocks 1\nvar v0 ref i\nblock 0 0\nt return ci1\nendfunc\n",
        name("plain")
    );
    rejected(
        "returnref-plain-return",
        &returnref_module(&plain, 1, main),
        140,
    );
    // A reference killed by a write before it is returned.
    let killed = format!(
        "func f0 {} params 1 result i 1 0 vars 2 blocks 1\nvar v0 ref s0\nvar v1 ref i\nblock 0 2\ni loan v1 p0.0 0\ni store p0.0 ci5\nt returnref v1\nendfunc\n",
        name("killed")
    );
    rejected("returnref-killed", &returnref_module(&killed, 1, main), 57);
    // `ref 0, mut 1` is not a valid mode.
    let mode = format!(
        "func f0 {} params 1 result i 0 1 vars 1 blocks 1\nvar v0 ref i\nblock 0 0\nt returnref v0\nendfunc\n",
        name("mode")
    );
    rejected("returnref-mode", &returnref_module(&mode, 1, main), 44);
    // Calls are not lowered yet.
    let call = "block 0 3\ni struct v1 s0 1 ci0\ni listlit v2 l0 1 ci7\ni call v3 f0 2 ref p1 0 ref p2 0\nt return v3\n";
    rejected(
        "returnref-call",
        &returnref_module(&cursor_current("i 1 0", 0), 1, call),
        141,
    );
}
