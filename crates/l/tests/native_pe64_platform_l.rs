//! Platform builtins (`i platform`: processArgCount, processArg, readText,
//! printError, writeBytes) on Windows x64 PE32+ through the ELE-written
//! backend: codegen/win64_rt_platform.l implements them on KERNEL32 only
//! (GetCommandLineW with the Microsoft argv rules, WideCharToMultiByte,
//! MultiByteToWideChar, CreateFileW, ReadFile, GetFileType, GetLastError,
//! CloseHandle, WriteFile, GetStdHandle) and codegen/pe64.l imports exactly
//! what the code calls beyond its base set.
//!
//! Every host checks the image structure and the rejections. Windows x86-64
//! also executes the images with real arguments and compares stdout, stderr,
//! exit status and written files with the contract the ELF64 images
//! (native_platform_l.rs) and Stage 0 follow.
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
    let dir = root().join("target/stage1-tests/native-pe64-platform");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}
#[cfg(all(windows, target_arch = "x86_64"))]
fn fresh_dir(name: &str) -> PathBuf {
    let dir = temp(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn u16_at(b: &[u8], at: usize) -> u32 {
    u32::from(u16::from_le_bytes([b[at], b[at + 1]]))
}
fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}
fn c_string(b: &[u8], at: usize) -> String {
    let end = at + b[at..].iter().position(|&c| c == 0).expect("NUL");
    String::from_utf8(b[at..end].to_vec()).unwrap()
}

/// The base imports every CFG image has, in IAT order.
const BASE_IMPORTS: [&str; 5] = [
    "GetStdHandle",
    "WriteFile",
    "ExitProcess",
    "VirtualAlloc",
    "VirtualFree",
];
/// The imports of an image using every platform builtin, in IAT order.
const PLATFORM_IMPORTS: [&str; 21] = [
    "GetStdHandle",
    "WriteFile",
    "ExitProcess",
    "VirtualAlloc",
    "VirtualFree",
    "GetCommandLineW",
    "WideCharToMultiByte",
    "MultiByteToWideChar",
    "CreateFileW",
    "ReadFile",
    "CloseHandle",
    "GetFileType",
    "GetLastError",
    "GetFileInformationByHandle",
    "FlushFileBuffers",
    "MoveFileExW",
    "DeleteFileW",
    "GetFileAttributesW",
    "LoadLibraryExW",
    "GetProcAddress",
    "FreeLibrary",
];

/// Parses the headers of a relocatable PE32+ image and returns its import
/// table as (DLL, functions in IAT order). Checks the parts the loader needs:
/// AMD64, PE32+, console, ASLR + NX, three sections (.text, .idata, .reloc),
/// one import descriptor plus terminator, ILT and IAT naming the same
/// functions by name, the IAT directory covering exactly the IAT, and every
/// CALL [RIP+disp32] of the import fixups landing on an IAT slot.
fn imports_of(b: &[u8]) -> (String, Vec<String>) {
    assert_eq!(&b[..2], b"MZ");
    let pe = u32_at(b, 0x3c) as usize;
    assert_eq!(&b[pe..pe + 4], b"PE\0\0");
    let coff = pe + 4;
    assert_eq!(u16_at(b, coff), 0x8664, "machine AMD64");
    assert_eq!(u16_at(b, coff + 2), 3, "sections");
    let opt = coff + 20;
    assert_eq!(u16_at(b, opt), 0x20b, "PE32+");
    assert_eq!(u16_at(b, opt + 68), 3, "console subsystem");
    assert_eq!(
        u16_at(b, opt + 70),
        0x160,
        "NX | DYNAMIC_BASE | HIGH_ENTROPY_VA"
    );
    let dir = |i: usize| (u32_at(b, opt + 112 + 8 * i), u32_at(b, opt + 116 + 8 * i));
    let table = opt + 240;
    let section = |i: usize| {
        let s = table + 40 * i;
        (
            u32_at(b, s + 8),
            u32_at(b, s + 12),
            u32_at(b, s + 16),
            u32_at(b, s + 20),
            u32_at(b, s + 36),
        )
    };
    let (_, text_rva, _, _, text_flags) = section(0);
    assert_eq!(text_flags, 0x6000_0020, ".text is code, execute, read");
    let (idata_size, idata_rva, idata_raw, idata_off, idata_flags) = section(1);
    assert_eq!(idata_flags, 0xc000_0040, ".idata is data, read, write");
    assert!(idata_size <= idata_raw);
    let file = |rva: u32| {
        assert!(rva >= idata_rva && rva < idata_rva + idata_size, "{rva:#x}");
        (rva - idata_rva + idata_off) as usize
    };
    let (import_rva, import_size) = dir(1);
    assert_eq!(import_size, 40, "one descriptor and the terminator");
    let d = file(import_rva);
    assert!(b[d + 20..d + 40].iter().all(|&x| x == 0), "terminator");
    let (ilt, name, iat) = (u32_at(b, d), u32_at(b, d + 12), u32_at(b, d + 16));
    let dll = c_string(b, file(name));
    let mut rows = Vec::new();
    for t in [ilt, iat] {
        let mut row = Vec::new();
        for k in 0.. {
            let entry = u64_at(b, file(t + 8 * k));
            if entry == 0 {
                break;
            }
            assert_eq!(entry >> 63, 0, "import by name");
            row.push(c_string(b, file(entry as u32) + 2));
        }
        rows.push(row);
    }
    assert_eq!(rows[0], rows[1], "ILT and IAT name the same imports");
    let count = rows[0].len() as u32;
    assert_eq!(dir(12), (iat, (count + 1) * 8), "IAT directory");
    // The code reaches each import through CALL [RIP+disp32] (FF 15) into
    // the IAT: count the calls that do, and require one per import.
    let (text_size, _, _, text_off, _) = section(0);
    let code = &b[text_off as usize..(text_off + text_size) as usize];
    let mut used = vec![false; count as usize];
    for at in 0..code.len().saturating_sub(5) {
        if code[at] == 0xff && code[at + 1] == 0x15 {
            let disp = i32::from_le_bytes(code[at + 2..at + 6].try_into().unwrap());
            let target = (i64::from(text_rva) + at as i64 + 6 + i64::from(disp)) as u32;
            if target >= iat && target < iat + 8 * count && (target - iat).is_multiple_of(8) {
                used[((target - iat) / 8) as usize] = true;
            }
        }
    }
    for (k, name) in rows[0].iter().enumerate() {
        if k >= BASE_IMPORTS.len() {
            assert!(used[k], "{name} imported but never called");
        }
    }
    (dll, rows.swap_remove(0))
}

fn build_pe(lir: &Path, image: &Path) -> std::process::Output {
    let _ = fs::remove_file(image);
    Command::new(native())
        .arg(lir)
        .arg(image)
        .arg("--pe64")
        .output()
        .unwrap()
}

fn built_pe(lir: &Path, name: &str) -> (PathBuf, Vec<u8>) {
    let image = temp(&format!("{name}.exe"));
    let out = build_pe(lir, &image);
    assert!(
        out.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    let (dll, names) = imports_of(&bytes);
    assert_eq!(dll, "KERNEL32.dll");
    assert_eq!(names, PLATFORM_IMPORTS, "{name}");
    // Reproducible: the same LIR gives the same bytes.
    let again = temp(&format!("{name}-again.exe"));
    assert!(build_pe(lir, &again).status.success());
    assert_eq!(bytes, fs::read(&again).unwrap(), "{name}: not reproducible");
    (image, bytes)
}

#[allow(dead_code)]
struct Run {
    code: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

/// Executes `image` (copied into `dir`) inside `dir` with `args`.
#[cfg(all(windows, target_arch = "x86_64"))]
fn execute<I, S>(image: &Path, dir: &Path, args: I) -> Run
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let program = dir.join("prog.exe");
    fs::copy(image, &program).unwrap();
    let out = Command::new(&program)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    Run {
        code: out.status.code(),
        stdout: out.stdout,
        stderr: out.stderr,
    }
}

/// `.l` -> Stage 1 -> ELE-LIR -> PE32+: processArgCount, printError and
/// writeBytes (and its rejected byte, empty path and missing directory)
/// behave as the ELF64 image and Stage 0 do.
#[test]
fn stage1_platform_program_runs_as_pe32_plus() {
    let emitted = Command::new(sema())
        .arg(root().join("examples/native_platform_stage1.l"))
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "{}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = temp("stage1.lir");
    fs::write(&lir, &emitted.stdout).unwrap();
    let (_image, _) = built_pe(&lir, "stage1");
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let dir = fresh_dir("stage1-run");
        let occupied_temp = dir.join("native_platform_out.bin.tmp.0");
        fs::write(&occupied_temp, b"occupied").unwrap();
        let run = execute(&_image, &dir, ["uno", "dos"]);
        eprintln!(
            "DEBUG run code: {:?}, stdout: {:?}, stderr: {:?}",
            run.code,
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(String::from_utf8(run.stdout).unwrap(), "2\n0\n1\n1\n2\n");
        assert_eq!(
            String::from_utf8(run.stderr).unwrap(),
            "aviso: plataforma nativa\n"
        );
        assert_eq!(run.code, Some(42));
        assert_eq!(
            fs::read(dir.join("native_platform_out.bin")).unwrap(),
            b"ELE\n"
        );
        assert_eq!(fs::read(&occupied_temp).unwrap(), b"occupied");

        // Every process needs its own exclusive temporary while targeting
        // the same output. The published bytes stay complete.
        let mut children = Vec::new();
        for _ in 0..4 {
            children.push(
                Command::new(&_image)
                    .current_dir(&dir)
                    .args(["uno", "dos"])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .unwrap(),
            );
        }
        for mut child in children {
            assert_eq!(child.wait().unwrap().code(), Some(42));
        }
        assert_eq!(
            fs::read(dir.join("native_platform_out.bin")).unwrap(),
            b"ELE\n"
        );
        assert_eq!(fs::read(&occupied_temp).unwrap(), b"occupied");
        // An existing file is truncated and rewritten.
        let dir = fresh_dir("stage1-rerun");
        fs::write(dir.join("native_platform_out.bin"), vec![b'x'; 10000]).unwrap();
        let run = execute(&_image, &dir, Vec::<&str>::new());
        assert_eq!(String::from_utf8(run.stdout).unwrap(), "0\n0\n1\n1\n2\n");
        assert_eq!(run.code, Some(40));
        assert_eq!(
            fs::read(dir.join("native_platform_out.bin")).unwrap(),
            b"ELE\n"
        );
    }
}

/// processArg and readText through the hand-written LIR of the ELF64 test:
/// every Ok and Err code of the contract, with the same stdout and stderr.
#[test]
fn process_arg_and_read_text_follow_the_platform_contract_on_windows() {
    let (_image, _) = built_pe(
        &root().join("examples/native_cfg_platform_args.lir"),
        "args",
    );
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let dir = fresh_dir("args-run");
        fs::write(dir.join("in.txt"), "hola ñandú\n").unwrap();
        fs::write(dir.join("bad.bin"), b"ok\xff\n").unwrap();
        let run = execute(&_image, &dir, ["in.txt", "bad.bin"]);
        // argc; Err(1) past the last argument and for index -1; the file
        // (13 bytes); Err(5) over the limit; Err(1) for limits -1 and
        // 64 MiB + 1; Err(2) missing file; Err(3) directory; Err(1) empty
        // path; Err(4) for the non-UTF-8 file, returned as the exit status.
        assert_eq!(
            String::from_utf8(run.stdout).unwrap(),
            "2\n1\n1\nhola ñandú\n\n13\n-5\n-1\n-1\n-2\n-3\n-1\n"
        );
        assert_eq!(String::from_utf8(run.stderr).unwrap(), "in.txt\nbad.bin\n");
        // main's -4: ExitProcess keeps 32 bits (Linux keeps 8: 252), the
        // same as Stage 0's own Windows images.
        assert_eq!(run.code, Some(-4));

        // A path with non-ASCII characters, a file of exactly the limit,
        // and the second argument a missing file (Err(2)).
        let dir = fresh_dir("args-run-unicode");
        fs::write(dir.join("ñandú €.txt"), "x".repeat(100)).unwrap();
        let run = execute(&_image, &dir, ["ñandú €.txt", "falta.txt"]);
        let stdout = String::from_utf8(run.stdout).unwrap();
        assert!(
            stdout.starts_with(&format!("2\n1\n1\n{}\n100\n", "x".repeat(100))),
            "{stdout}"
        );
        assert_eq!(
            String::from_utf8(run.stderr).unwrap(),
            "ñandú €.txt\nfalta.txt\n"
        );
        assert_eq!(run.code, Some(-2));
    }
}

/// The argument echo program: argcount on stdout, then every argument
/// (processArg) on stderr, one per line, or its Err code on stdout; the
/// last index (== argcount) is always Err(1).
fn echo_lir() -> PathBuf {
    let lir = "\
ELE-LIR 1
module structs 0 enums 1 funcs 1 main f0
enum e0 6:82,101,115,117,108,116 variants 2
variant 2:79,107 types 1 t
variant 3:69,114,114 types 1 i
func f0 4:109,97,105,110 params 0 result i 0 0 vars 8 blocks 7
var v0 val i
var v1 val i
var v2 val b
var v3 val e0
var v4 val i
var v5 val b
var v6 val t
var v7 val i
block 0 3
i platform v0 argcount 0
i print val v0
i use v1 ci0
t jump 1
block 1 1
i binary v2 le v1 v0
t branch v2 2 6
block 2 3
i platform v3 arg 1 val v1
i disc v4 p3
i binary v5 eq v4 ci0
t branch v5 3 4
block 3 3
i payload v6 p3 e0 0
i platform v12 printerror 1 ref p6 0
i drop v6 -
t jump 5
block 4 2
i payload v7 p3 e0 1
i print val v7
t jump 5
block 5 1
i binary v1 add v1 ci1
t jump 1
block 6 0
t return v0
endfunc
end
"
    .replace("vars 8", "vars 13")
    .replace(
        "var v7 val i\n",
        "var v7 val i\nvar v8 val i\nvar v9 val i\nvar v10 val i\nvar v11 val i\nvar v12 val u\n",
    );
    let file = temp("echo.lir");
    fs::write(&file, lir).unwrap();
    file
}

/// Command lines split with the Microsoft C runtime rules (the ones Rust
/// std and so Stage 0 use): arguments quoted by Rust's `Command`, raw
/// command-line fragments with quoting a quoting library would not produce,
/// non-ASCII arguments (UTF-16 -> UTF-8), and a lone surrogate (Err(2)).
#[test]
fn command_line_arguments_follow_the_windows_rules() {
    let (_image, _) = built_pe(&echo_lir(), "echo");
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        use std::ffi::OsString;
        use std::os::windows::{ffi::OsStringExt, process::CommandExt};
        let dir = fresh_dir("echo-run");
        let program = dir.join("prog.exe");
        fs::copy(&_image, &program).unwrap();

        // No arguments at all.
        let run = execute(&_image, &dir, Vec::<&str>::new());
        assert_eq!(String::from_utf8(run.stdout).unwrap(), "0\n1\n");
        assert!(run.stderr.is_empty());
        assert_eq!(run.code, Some(0));

        // Quoted by Rust's Command: every argument comes back unchanged.
        let args = [
            "plain",
            "con espacio",
            r"C:\dir with space\",
            r"back\slash",
            r#"quote"in"#,
            r#"two\\"x"#,
            "",
            "tab\there",
            r"a\\b",
            "ñandú € 𝄞 日本",
            "  lead and trail  ",
        ];
        let run = execute(&_image, &dir, args);
        assert_eq!(
            String::from_utf8(run.stdout).unwrap(),
            format!("{}\n1\n", args.len())
        );
        let expected: String = args.iter().map(|a| format!("{a}\n")).collect();
        assert_eq!(String::from_utf8(run.stderr).unwrap(), expected);
        assert_eq!(run.code, Some(args.len() as i32));

        // Raw command-line text, and how the rules split it.
        for (raw, parsed) in [
            (r#"a"b c"d"#, vec![r"ab cd"]),
            (r#""a""b""#, vec![r#"a"b"#]),
            (r#"\\\"x"#, vec![r#"\"x"#]),
            (r#"\\\\"y z""#, vec![r"\\y z"]),
            (r"x\\y \z\", vec![r"x\\y", r"\z\"]),
            ("one\t\t two   three", vec!["one", "two", "three"]),
            (r#""""#, vec![""]),
            (r#""" """#, vec!["", ""]),
            (r#""unterminated quote"#, vec!["unterminated quote"]),
            (r#""a"""b"#, vec![r#"a"b"#]),
        ] {
            let out = Command::new(&program)
                .raw_arg(raw)
                .current_dir(&dir)
                .output()
                .unwrap();
            let expected: String = parsed.iter().map(|a| format!("{a}\n")).collect();
            assert_eq!(
                String::from_utf8(out.stdout).unwrap(),
                format!("{}\n1\n", parsed.len()),
                "{raw}"
            );
            assert_eq!(String::from_utf8(out.stderr).unwrap(), expected, "{raw}");
        }

        // A quoted program name with spaces is one name, not arguments.
        let spaced = dir.join("prog with space.exe");
        fs::copy(&_image, &spaced).unwrap();
        let out = Command::new(&spaced)
            .arg("solo")
            .current_dir(&dir)
            .output()
            .unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), "1\n1\n");
        assert_eq!(String::from_utf8(out.stderr).unwrap(), "solo\n");

        // Ill-formed UTF-16 (a lone surrogate) is Err(2), like a non-UTF-8
        // argument on Linux; its neighbours are unaffected.
        let lone = OsString::from_wide(&[0x61, 0xD800, 0x62]);
        let out = Command::new(&program)
            .arg("antes")
            .arg(&lone)
            .arg("después")
            .current_dir(&dir)
            .output()
            .unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), "3\n2\n1\n");
        assert_eq!(String::from_utf8(out.stderr).unwrap(), "antes\ndespués\n");
        assert_eq!(out.status.code(), Some(3));
    }
}

fn platform_case(name: &str, body: &[&str]) -> PathBuf {
    let mut lir = String::from(
        "ELE-LIR 1\nmodule structs 0 enums 1 lists 1 funcs 1 main f0\n\
         enum e0 6:82,101,115,117,108,116 variants 2\n\
         variant 2:79,107 types 1 t\nvariant 3:69,114,114 types 1 i\n\
         list l0 i\n",
    );
    lir.push_str(&format!(
        "func f0 4:109,97,105,110 params 0 result i 0 0 vars 5 blocks 1\n\
         var v0 val i\nvar v1 val t\nvar v2 val u\nvar v3 val l0\nvar v4 val e0\n\
         block 0 {}\n",
        body.len()
    ));
    for line in body {
        lir.push_str(line);
        lir.push('\n');
    }
    lir.push_str("t return ci0\nendfunc\nend\n");
    let file = temp(&format!("{name}.lir"));
    fs::write(&file, lir).unwrap();
    file
}

/// Malformed or ill-typed platform calls are rejected for PE32+ exactly as
/// for ELF64, with a diagnostic and no image written.
#[test]
fn invalid_platform_calls_are_rejected_for_pe32_plus() {
    let cases: &[(&str, &[&str], u32)] = &[
        ("unknown_op", &["i platform v0 getenv 0"], 130),
        ("argcount_arity", &["i platform v0 argcount 1 val ci0"], 130),
        ("arg_arity", &["i platform v4 arg 2 val ci0 val ci1"], 130),
        ("readtext_arity", &["i platform v4 readtext 0"], 130),
        (
            "printerror_by_value",
            &["i platform v2 printerror 1 val ci7"],
            131,
        ),
        (
            "arg_text_index",
            &[
                "i use v1 ct1:120",
                "i platform v4 arg 1 val v1",
                "i drop v1 -",
            ],
            131,
        ),
        ("arg_into_int", &["i platform v0 arg 1 val ci0"], 132),
        ("argcount_into_unit", &["i platform v2 argcount 0"], 132),
        (
            "writebytes_exclusive",
            &[
                "i use v1 ct1:120",
                "i listlit v3 l0 0",
                "i platform v0 writebytes 2 ref p1 0 ref p3 1",
                "i drop v3 -",
                "i drop v1 -",
            ],
            131,
        ),
        (
            "printerror_uninit",
            &["i platform v2 printerror 1 ref p1 0"],
            57,
        ),
    ];
    for (name, body, code) in cases {
        let file = platform_case(name, body);
        let image = temp(&format!("{name}.exe"));
        let out = build_pe(&file, &image);
        assert_eq!(out.status.code(), Some(3), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(&format!("rechazado (código {code})")),
            "{name}: {stderr}"
        );
        assert!(!image.exists(), "{name}: image written");
    }
}

/// Images without platform calls keep exactly the base import set: the
/// import table grows only with what the code calls.
#[test]
fn images_without_platform_calls_keep_the_base_imports() {
    let image = temp("loop.exe");
    let out = build_pe(
        &root().join("examples/native_cfg_text_literal_ok.lir"),
        &image,
    );
    assert!(out.status.success());
    let (dll, names) = imports_of(&fs::read(&image).unwrap());
    assert_eq!(dll, "KERNEL32.dll");
    assert_eq!(names, BASE_IMPORTS);
}
