//! `ele build --target kernel`: the freestanding higher-half ELF64 image
//! (no runtime, no system calls) and the kernel intrinsics of
//! `take nucleo.cpu` / `take nucleo.mem`.
//!
//! The image cannot run as a process; these tests check its structure and
//! the exact bytes of the entry stub and intrinsics. Booting it under QEMU
//! with Limine is done by `kernel/herramientas/construir.ps1 -Prueba`.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::OnceLock,
};

const KERNEL_TEXT: u64 = 0xffff_ffff_8000_1000;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_driver", false))
}

fn work(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/kernel-target").join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(dir: &Path, source: &str, extra: &[&str]) -> (Output, PathBuf) {
    let src = dir.join("kmain.l");
    let image = dir.join("kernel.elf");
    let _ = fs::remove_file(&image);
    fs::write(&src, source).unwrap();
    let out = Command::new(driver())
        .arg("build")
        .arg(&src)
        .args(["--target", "kernel", "-o"])
        .arg(&image)
        .args(extra)
        .output()
        .expect("failed to run driver");
    (out, image)
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

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// (name, value, size) of every symbol in .symtab.
fn symbols(b: &[u8]) -> Vec<(String, u64, u64)> {
    let shoff = u64_at(b, 40) as usize;
    let shnum = u16_at(b, 60) as usize;
    let section = |i: usize| &b[shoff + 64 * i..shoff + 64 * (i + 1)];
    let symtab = (0..shnum)
        .find(|&i| u32_at(section(i), 4) == 2)
        .expect(".symtab");
    let sh = section(symtab);
    let (off, size) = (u64_at(sh, 24) as usize, u64_at(sh, 32) as usize);
    let strtab = section(u32_at(sh, 40) as usize);
    let str_off = u64_at(strtab, 24) as usize;
    (1..size / 24)
        .map(|k| {
            let e = &b[off + 24 * k..off + 24 * (k + 1)];
            let name_at = str_off + u32_at(e, 0) as usize;
            let end = b[name_at..].iter().position(|&c| c == 0).unwrap();
            let name = String::from_utf8(b[name_at..name_at + end].to_vec()).unwrap();
            (name, u64_at(e, 8), u64_at(e, 16))
        })
        .collect()
}

const SERIAL_KERNEL: &str = "take nucleo.cpu\n\
take nucleo.mem\n\
\n\
flow enviar(b: Int) {\n\
    during in8(0x3FD) & 0x20 == 0 {\n\
        pause()\n\
    }\n\
    out8(0x3F8, b)\n\
}\n\
\n\
flow kmain() {\n\
    enviar(79)\n\
    hold v = leer32(0xFFFF_FFFF_8000_1000)\n\
    escribir16(0x1000, v)\n\
    cli()\n\
    during true {\n\
        hlt()\n\
    }\n\
}\n";

#[test]
fn kernel_target_writes_a_higher_half_exec_image() {
    let dir = work("image");
    let (out, image) = build(&dir, SERIAL_KERNEL, &[]);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let b = fs::read(&image).unwrap();
    assert_eq!(&b[..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(u16_at(&b, 16), 2, "ET_EXEC");
    assert_eq!(u16_at(&b, 18), 62, "EM_X86_64");
    assert_eq!(u64_at(&b, 24), KERNEL_TEXT, "entry");
    // One PT_LOAD (no Text literal): R+X at file offset 0x1000.
    assert_eq!(u16_at(&b, 56), 1);
    let ph = &b[64..120];
    assert_eq!(u32_at(ph, 0), 1, "PT_LOAD");
    assert_eq!(u32_at(ph, 4), 5, "R+X, never W");
    assert_eq!(u64_at(ph, 8), 0x1000);
    assert_eq!(u64_at(ph, 16), KERNEL_TEXT);
    // Sections: null, .text, .rodata, .symtab, .strtab, .shstrtab.
    assert_eq!(u16_at(&b, 60), 6);
    assert_eq!(u16_at(&b, 62), 5);

    // Entry stub: CALL kmain; CLI; HLT; JMP back to the HLT.
    let text = &b[0x1000..0x1000 + u64_at(ph, 32) as usize];
    assert_eq!(text[0], 0xE8);
    assert_eq!(&text[5..9], &[0xFA, 0xF4, 0xEB, 0xFD]);
    let call = i32::from_le_bytes(text[1..5].try_into().unwrap()) as i64;
    let kmain_at = KERNEL_TEXT.wrapping_add((5 + call) as u64);

    let syms = symbols(&b);
    let names: Vec<&str> = syms.iter().map(|s| s.0.as_str()).collect();
    assert_eq!(names, ["enviar", "kmain"]);
    assert_eq!(syms[1].1, kmain_at, "the stub calls kmain");
    assert!(syms.iter().all(|s| s.2 > 0));

    // Intrinsics, inline: IN AL,DX after XOR EAX,EAX; OUT DX,AL; PAUSE;
    // MOV EAX,[RAX]; MOV [RAX],CX; CLI; HLT.
    assert!(contains(text, &[0x31, 0xC0, 0xEC]));
    assert!(contains(text, &[0xEE]));
    assert!(contains(text, &[0xF3, 0x90]));
    assert!(contains(text, &[0x8B, 0x00]));
    assert!(contains(text, &[0x66, 0x89, 0x08]));
    // The higher-half constant reaches the code as a 64-bit immediate.
    assert!(contains(text, &0xffff_ffff_8000_1000u64.to_le_bytes()));
    // No system call anywhere.
    assert!(!contains(text, &[0x0F, 0x05]), "syscall in a kernel image");
}

#[test]
fn kernel_target_entry_flow_is_selectable() {
    let dir = work("entry");
    let source = "take nucleo.cpu\n\nflow arranque() {\n    hlt()\n}\n";
    let (out, _) = build(&dir, source, &[]);
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("no existe la flow de entrada 'kmain'"),
        "{err}"
    );
    let (out, image) = build(&dir, source, &["--entry", "arranque"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let syms = symbols(&fs::read(&image).unwrap());
    assert_eq!(syms[0].0, "arranque");
}

#[test]
fn kernel_target_rejects_programs_that_need_the_runtime() {
    let dir = work("runtime");
    let (out, image) = build(&dir, "flow kmain() {\n    print(1)\n}\n", &[]);
    assert_eq!(out.status.code(), Some(3));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("código 75"), "{err}");
    assert!(!image.exists());

    let (out, _) = build(&dir, "flow kmain(x: Int) {\n}\n", &[]);
    assert_eq!(out.status.code(), Some(3));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("'kmain' debe no tener parámetros"), "{err}");
}
