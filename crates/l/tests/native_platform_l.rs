//! Platform builtins (`i platform`: processArgCount, processArg, readText,
//! printError, writeBytes) through the ELE-written native backend:
//! codegen/native_cfg_platform.l lowers them to the raw Linux system calls
//! of codegen/native_rt_platform.l, and codegen/elf64.l adds a read-write
//! data page that keeps the initial stack pointer (argc, argv).
//!
//! Every host checks acceptance, rejection and the image layout. The images
//! are executed on Linux x86-64, and on Windows too when
//! `ELE_TEST_WSL_DISTRO` names a WSL distribution (e.g. `Ubuntu`); their
//! stdout, stderr, exit status and written files are compared with what
//! Stage 0 produces for the same program.
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
    let dir = root().join("target/stage1-tests/native-platform");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn backend(lir: &Path, image: &Path) -> std::process::Output {
    let _ = fs::remove_file(image);
    Command::new(native()).arg(lir).arg(image).output().unwrap()
}

fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

/// Two PT_LOAD segments: the RX code at 0x400000 and one RW (never X)
/// zero-filled data page stored in the file right after the code.
fn assert_platform_layout(bytes: &[u8]) {
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(u16_at(bytes, 56), 2, "e_phnum");
    let code = 64;
    assert_eq!(u32_at(bytes, code), 1);
    assert_eq!(u32_at(bytes, code + 4), 5, "code segment is R+X");
    let code_end = u64_at(bytes, code + 32);
    let data = 64 + 56;
    assert_eq!(u32_at(bytes, data), 1, "PT_LOAD");
    assert_eq!(u32_at(bytes, data + 4), 6, "data segment is R+W, not X");
    let offset = u64_at(bytes, data + 8);
    let vaddr = u64_at(bytes, data + 16);
    assert_eq!(offset % 4096, 0);
    assert!(offset >= code_end);
    assert_eq!(vaddr, 0x400000 + offset);
    assert_eq!(u64_at(bytes, data + 32), 4096, "p_filesz");
    assert_eq!(u64_at(bytes, data + 40), 4096, "p_memsz");
    assert_eq!(bytes.len() as u64, offset + 4096);
    assert!(bytes[offset as usize..].iter().all(|&b| b == 0));
}

struct Run {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

/// Executes `image` with `args` inside `dir`, natively on Linux or through
/// WSL on Windows when `ELE_TEST_WSL_DISTRO` is set. `None` elsewhere.
fn execute(image: &Path, dir: &Path, args: &[&str]) -> Option<Run> {
    let program = dir.join("prog");
    fs::copy(image, &program).unwrap();
    let output = if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        }
        Command::new(&program)
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap()
    } else if cfg!(windows) {
        let distro = std::env::var("ELE_TEST_WSL_DISTRO").ok()?;
        // C:\a\b -> /mnt/c/a/b, without `..` components or a `\\?\` prefix.
        let canonical = dir.canonicalize().unwrap();
        let windows = canonical
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .replace('\\', "/");
        let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
        let linux = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());
        // `wsl --cd` is unreliable here; change directory inside the shell.
        let script = "cd \"$1\" && shift && chmod 700 prog && exec ./prog \"$@\"";
        Command::new("wsl")
            .args(["-d", &distro, "--exec", "sh", "-c", script, "sh", &linux])
            .args(args)
            .output()
            .unwrap()
    } else {
        return None;
    };
    Some(Run {
        code: output.status.code(),
        stdout: String::from_utf8(output.stdout).unwrap(),
        stderr: String::from_utf8(output.stderr).unwrap(),
    })
}

fn fresh_dir(name: &str) -> PathBuf {
    let dir = temp(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// `.l` -> Stage 1 -> ELE-LIR -> native ELF64: processArgCount, printError
/// and writeBytes (including its rejected byte and path) behave as in
/// Stage 0.
#[test]
fn stage1_platform_program_runs_like_stage0() {
    let source = root().join("examples/native_platform_stage1.l");
    let emitted = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "{}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    for form in ["argcount 0", "printerror 1 ref p", "writebytes 2 ref p"] {
        assert!(lir.contains(form), "{form}\n{lir}");
    }
    let lir_file = temp("stage1.lir");
    fs::write(&lir_file, &lir).unwrap();
    let image = temp("stage1.elf");
    let built = backend(&lir_file, &image);
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_platform_layout(&bytes);
    // Reproducible: the same LIR gives the same bytes.
    let again = temp("stage1-again.elf");
    assert!(backend(&lir_file, &again).status.success());
    assert_eq!(bytes, fs::read(&again).unwrap());

    let dir = fresh_dir("stage1-run");
    let occupied_temp = dir.join("native_platform_out.bin.tmp.0");
    fs::write(&occupied_temp, b"occupied").unwrap();
    if let Some(run) = execute(&image, &dir, &["uno", "dos"]) {
        assert_eq!(run.stdout, "2\n0\n1\n1\n2\n");
        assert_eq!(run.stderr, "aviso: plataforma nativa\n");
        assert_eq!(run.code, Some(42));
        assert_eq!(
            fs::read(dir.join("native_platform_out.bin")).unwrap(),
            b"ELE\n"
        );
        assert_eq!(fs::read(&occupied_temp).unwrap(), b"occupied");
        if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            let mut children = Vec::new();
            for _ in 0..4 {
                children.push(
                    Command::new(dir.join("prog"))
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
        }
    }
}

/// processArg and readText through hand-written LIR (written before
/// whole-union drop glue existed, so it never drops a whole Result<Text,Int>;
/// see native_union_drop_l.rs): every Ok and Err code of the Stage 0 contract.
#[test]
fn process_arg_and_read_text_follow_the_platform_contract() {
    let image = temp("args.elf");
    let built = backend(
        &root().join("examples/native_cfg_platform_args.lir"),
        &image,
    );
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert_platform_layout(&fs::read(&image).unwrap());
    let dir = fresh_dir("args-run");
    fs::write(dir.join("in.txt"), "hola ñandú\n").unwrap();
    fs::write(dir.join("bad.bin"), b"ok\xff\n").unwrap();
    if let Some(run) = execute(&image, &dir, &["in.txt", "bad.bin"]) {
        // argc; Err(1) past the last argument and for index -1; the file
        // (13 bytes); Err(5) over the limit; Err(1) for limits -1 and
        // 64 MiB + 1; Err(2) missing file; Err(3) directory; Err(1) empty
        // path; Err(4) for the non-UTF-8 file, returned as the exit status.
        assert_eq!(
            run.stdout,
            "2\n1\n1\nhola ñandú\n\n13\n-5\n-1\n-1\n-2\n-3\n-1\n"
        );
        assert_eq!(run.stderr, "in.txt\nbad.bin\n");
        assert_eq!(run.code, Some(252));
    }
}

fn platform_case(name: &str, decls: &str, body: &[&str]) -> PathBuf {
    let mut lir = String::from(
        "ELE-LIR 1\nmodule structs 0 enums 1 lists 1 funcs 1 main f0\n\
         enum e0 6:82,101,115,117,108,116 variants 2\n\
         variant 2:79,107 types 1 t\nvariant 3:69,114,114 types 1 i\n\
         list l0 i\n",
    );
    lir.push_str(&format!(
        "func f0 4:109,97,105,110 params 0 result i 0 0 vars 5 blocks 1\n\
         var v0 val i\nvar v1 val t\nvar v2 val u\nvar v3 val l0\nvar v4 val {decls}\n\
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

/// Malformed or ill-typed platform calls are rejected with a diagnostic and
/// no image is written; well-formed ones also build for PE32+.
#[test]
fn invalid_platform_calls_are_rejected() {
    let cases: &[(&str, &[&str], u32)] = &[
        ("unknown_op", &["i platform v0 getenv 0"], 130),
        ("argcount_arity", &["i platform v0 argcount 1 val ci0"], 130),
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
            "writebytes_text_bytes",
            &[
                "i use v1 ct1:120",
                "i platform v0 writebytes 2 ref p1 0 ref p1 0",
                "i drop v1 -",
            ],
            131,
        ),
        // A Text read before it is defined.
        (
            "printerror_uninit",
            &["i platform v2 printerror 1 ref p1 0"],
            57,
        ),
    ];
    for (name, body, code) in cases {
        let file = platform_case(name, "e0", body);
        let image = temp(&format!("{name}.elf"));
        let out = backend(&file, &image);
        assert_eq!(out.status.code(), Some(3), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(&format!("rechazado (código {code})")),
            "{name}: {stderr}"
        );
        assert!(!image.exists(), "{name}: image written");
    }
    // A Result whose variants are not (Text, Int) is not processArg's.
    let mut file = platform_case("arg_wrong_result", "e0", &["i platform v4 arg 1 val ci0"]);
    let lir = fs::read_to_string(&file).unwrap().replace(
        "variant 3:69,114,114 types 1 i",
        "variant 3:69,114,114 types 1 b",
    );
    file = temp("arg_wrong_result2.lir");
    fs::write(&file, lir).unwrap();
    let out = backend(&file, &temp("arg_wrong_result.elf"));
    assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado (código 132)"));

    // The Windows PE32+ target now has its platform runtime
    // (win64_rt_platform, exercised by native_pe64_platform_l.rs): the same
    // LIR builds there instead of being rejected with 133.
    let pe = temp("platform.exe");
    let _ = fs::remove_file(&pe);
    let out = Command::new(native())
        .arg(root().join("examples/native_cfg_platform_args.lir"))
        .arg(&pe)
        .arg("--pe64")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!String::from_utf8_lossy(&out.stderr).contains("código 133"));
    assert_eq!(&fs::read(&pe).unwrap()[..2], b"MZ");
}

/// Programs without platform calls keep the historical single-segment image.
#[test]
fn images_without_platform_calls_keep_one_segment() {
    let image = temp("loop.elf");
    let out = backend(&root().join("examples/native_cfg_loop_call.lir"), &image);
    assert!(out.status.success());
    let bytes = fs::read(&image).unwrap();
    assert_eq!(u16_at(&bytes, 56), 1);
    assert_eq!(bytes.len() as u64, u64_at(&bytes, 64 + 32));
}
