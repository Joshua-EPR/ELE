//! Loader-level structure validation of every native image the ELE-written
//! backends produce from the repository fixtures:
//!
//! * every `examples/*.lir` through `native_cfg_demo` as ELF64 and as PE32+
//!   (`--pe64`);
//! * the official `.l` examples through Stage 1 (`main_sema --emit-lir`)
//!   and then both targets;
//! * the PE32+ images of `native_pe_demo` (plain, deep frames, relocated).
//!
//! `image_support::validate_elf64` checks W^X, the entry point inside an
//! executable PT_LOAD, segment bounds and alignment; `validate_pe32plus`
//! checks headers, alignment, W^X, entry, imports (KERNEL32.dll only, a
//! fixed set of functions) and `.reloc`. Every accepted ELF64 fixture is
//! also executed under `strace -f` (Linux, or WSL with
//! `ELE_TEST_WSL_DISTRO`): it must not die from a signal and may only use
//! the runtime's syscalls. A rejected fixture must not leave an image.
mod image_support;
#[allow(dead_code)]
mod stage1_support;

use image_support::{
    ALLOWED_SYSCALLS, Exec, not_run, run_elf, scratch, validate_elf64, validate_pe32plus,
};
use std::{
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
    B.get_or_init(|| stage1_support::build_self_executing("native_cfg_demo"))
}
fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("main_sema"))
}
fn pe_demo() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("native_pe_demo"))
}

/// Compiles `lir` with `native_cfg_demo`; `Some(image)` when accepted.
/// A rejected input must leave no file behind.
fn compile(lir: &Path, out: &Path, pe: bool) -> Result<Option<Vec<u8>>, String> {
    let _ = fs::remove_file(out);
    let mut cmd = Command::new(native());
    cmd.arg(lir).arg(out);
    if pe {
        cmd.arg("--pe64");
    }
    let result = cmd.output().unwrap();
    match result.status.code() {
        Some(0) => fs::read(out)
            .map(Some)
            .map_err(|e| format!("accepted but no image: {e}")),
        Some(3) => {
            if out.exists() {
                Err("rejected but an image was written".into())
            } else {
                Ok(None)
            }
        }
        other => Err(format!(
            "unexpected status {other:?}: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )),
    }
}

fn lir_fixtures() -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = fs::read_dir(root().join("examples"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "lir"))
        .collect();
    all.sort();
    all
}

/// Validates (and, for ELF64, executes) the images of one LIR file.
fn check_lir(
    name: &str,
    lir: &Path,
    dir: &Path,
    accepted: &mut [usize; 2],
    violations: &mut Vec<String>,
) {
    match compile(lir, &dir.join(format!("{name}.elf")), false) {
        Err(e) => violations.push(format!("{name} [ELF64]: {e}")),
        Ok(None) => {}
        Ok(Some(bytes)) => {
            accepted[0] += 1;
            if let Err(errors) = validate_elf64(&bytes) {
                violations.push(format!("{name} [ELF64]: {errors:?}"));
            }
            match run_elf(
                &dir.join(format!("{name}.elf")),
                &dir.join(format!("{name}-run")),
                &[],
                true,
            ) {
                Exec::NotRun(why) => not_run(&format!("{name}.elf"), &why),
                Exec::Ran(run) => {
                    if let Some(signal) = run.signal {
                        violations.push(format!("{name} [ELF64]: killed by {signal}"));
                    }
                    let bad: Vec<_> = run
                        .syscalls
                        .iter()
                        .filter(|s| !ALLOWED_SYSCALLS.contains(&s.as_str()))
                        .collect();
                    if !bad.is_empty() {
                        violations.push(format!("{name} [ELF64]: unexpected syscalls {bad:?}"));
                    }
                }
            }
        }
    }
    match compile(lir, &dir.join(format!("{name}.exe")), true) {
        Err(e) => violations.push(format!("{name} [PE32+]: {e}")),
        Ok(None) => {}
        Ok(Some(bytes)) => {
            accepted[1] += 1;
            match validate_pe32plus(&bytes) {
                Err(errors) => violations.push(format!("{name} [PE32+]: {errors:?}")),
                // The CFG backend always writes relocatable images.
                Ok(pe) if !pe.dynamic_base => {
                    violations.push(format!("{name} [PE32+]: not DYNAMIC_BASE"));
                }
                Ok(_) => {}
            }
        }
    }
}

/// Every `examples/*.lir` fixture through both targets.
#[test]
fn every_lir_fixture_image_is_structurally_valid() {
    let dir = scratch("native-image-structure/lir");
    let fixtures = lir_fixtures();
    assert!(fixtures.len() > 100, "{} fixtures", fixtures.len());
    let mut accepted = [0, 0];
    let mut violations = Vec::new();
    for lir in &fixtures {
        let name = lir.file_stem().unwrap().to_string_lossy().into_owned();
        check_lir(&name, lir, &dir, &mut accepted, &mut violations);
    }
    eprintln!(
        "{} fixtures: {} ELF64 and {} PE32+ images validated",
        fixtures.len(),
        accepted[0],
        accepted[1]
    );
    assert!(accepted[0] >= 40 && accepted[1] >= 30, "{accepted:?}");
    assert!(
        violations.is_empty(),
        "{} violations:\n{}",
        violations.len(),
        violations.join("\n")
    );
}

/// The official `.l` examples: Stage 1 emits ELE-LIR, both targets lower it.
#[test]
fn stage1_example_images_are_structurally_valid() {
    let dir = scratch("native-image-structure/stage1");
    let mut accepted = [0, 0];
    let mut violations = Vec::new();
    for name in [
        "arithmetic",
        "hello",
        "control_flow",
        "loops",
        "native_arith_stage1",
        "native_list_int_stage1",
        "native_list_owned_stage1",
        "native_list_replace_stage1",
        "native_loans_stage1",
        "native_platform_stage1",
    ] {
        let emitted = Command::new(sema())
            .arg(root().join(format!("examples/{name}.l")))
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(
            emitted.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&emitted.stderr)
        );
        let lir = dir.join(format!("{name}.lir"));
        fs::write(&lir, &emitted.stdout).unwrap();
        check_lir(name, &lir, &dir, &mut accepted, &mut violations);
    }
    // Every example builds cleanly on both ELF and PE: 10 ELF, 10 PE.
    assert_eq!(accepted, [10, 10]);
    assert!(
        violations.is_empty(),
        "{} violations:\n{}",
        violations.len(),
        violations.join("\n")
    );
}

/// The PE32+ images written directly by `native_pe_demo`.
#[test]
fn pe_demo_images_are_structurally_valid() {
    let dir = scratch("native-image-structure/pe-demo");
    for (flag, relocatable) in [
        (None, false),
        (Some("--deep-frames"), false),
        (Some("--relocated"), true),
    ] {
        let image = dir.join(format!(
            "{}.exe",
            flag.unwrap_or("demo").trim_start_matches('-')
        ));
        let _ = fs::remove_file(&image);
        let mut cmd = Command::new(pe_demo());
        if let Some(flag) = flag {
            cmd.arg(flag);
        }
        assert!(cmd.arg(&image).status().unwrap().success(), "{flag:?}");
        let pe = validate_pe32plus(&fs::read(&image).unwrap())
            .unwrap_or_else(|e| panic!("{flag:?}: {e:?}"));
        assert_eq!(pe.dynamic_base, relocatable, "{flag:?}");
        assert_eq!(pe.relocs.is_empty(), !relocatable, "{flag:?}");
        assert_eq!(pe.imports.len(), 1, "{flag:?}");
    }
}

type Corrupt = fn(&mut Vec<u8>);
type BoxedCorrupt = Box<dyn Fn(&mut Vec<u8>)>;

/// The validators are not vacuous: corrupting one field of a valid image
/// is reported.
#[test]
fn validators_reject_corrupted_images() {
    let dir = scratch("native-image-structure/corrupt");
    let lir = root().join("examples/native_cfg_text_literal_ok.lir");
    let elf = compile(&lir, &dir.join("ok.elf"), false).unwrap().unwrap();
    let exe = compile(&lir, &dir.join("ok.exe"), true).unwrap().unwrap();
    validate_elf64(&elf).unwrap();
    validate_pe32plus(&exe).unwrap();

    let elf_cases: [(&str, Corrupt); 4] = [
        ("W+X code segment", |b| b[64 + 4] = 7),
        ("entry outside", |b| {
            b[24..32].copy_from_slice(&0x10u64.to_le_bytes())
        }),
        ("p_filesz past EOF", |b| {
            b[64 + 32..64 + 40].copy_from_slice(&u64::MAX.to_le_bytes())
        }),
        ("truncated", |b| b.truncate(60)),
    ];
    for (what, corrupt) in elf_cases {
        let mut bad = elf.clone();
        corrupt(&mut bad);
        assert!(validate_elf64(&bad).is_err(), "ELF64 {what} accepted");
    }
    let pe = u32::from_le_bytes(exe[0x3c..0x40].try_into().unwrap()) as usize;
    let table = pe + 24 + 240;
    let pe_cases: Vec<(&str, BoxedCorrupt)> = vec![
        ("W+X .text", Box::new(move |b| b[table + 39] |= 0x80)),
        (
            "entry in .idata",
            Box::new(move |b| {
                let idata_rva = u32::from_le_bytes(b[table + 52..table + 56].try_into().unwrap());
                b[pe + 24 + 16..pe + 24 + 20].copy_from_slice(&idata_rva.to_le_bytes());
            }),
        ),
        (
            "foreign import",
            Box::new(|b| {
                let at = b.windows(9).position(|w| w == b"WriteFile").unwrap();
                b[at..at + 9].copy_from_slice(b"WinExec\0\0");
            }),
        ),
        (
            "foreign DLL",
            Box::new(|b| {
                let at = b.windows(8).position(|w| w == b"KERNEL32").unwrap();
                b[at..at + 8].copy_from_slice(b"USER32\0\0");
            }),
        ),
        (
            "bad file alignment",
            Box::new(move |b| {
                b[pe + 24 + 36..pe + 24 + 40].copy_from_slice(&0x300u32.to_le_bytes());
            }),
        ),
        (
            "reloc type 3",
            Box::new(move |b| {
                let reloc_raw =
                    u32::from_le_bytes(b[table + 80 + 20..table + 80 + 24].try_into().unwrap())
                        as usize;
                b[reloc_raw + 9] = (b[reloc_raw + 9] & 0x0f) | 0x30;
            }),
        ),
    ];
    for (what, corrupt) in pe_cases {
        let mut bad = exe.clone();
        corrupt(&mut bad);
        assert!(validate_pe32plus(&bad).is_err(), "PE32+ {what} accepted");
    }
}
