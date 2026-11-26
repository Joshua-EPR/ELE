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
    // Sections: null, .text, .rodata, .data, .bss, .symtab, .strtab,
    // .shstrtab.
    assert_eq!(u16_at(&b, 60), 8);
    assert_eq!(u16_at(&b, 62), 7);

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

const STATIC_KERNEL: &str = "take nucleo.cpu\n\
take nucleo.mem\n\
\n\
flow kinterrupcion(marco: Int) {\n\
    escribir64(reservar(8, 8), marco)\n\
}\n\
\n\
flow kmain() {\n\
    hold d = datos64(0x1122334455667788, -1)\n\
    hold r = reservar(4096, 4096)\n\
    hold c = cadena(\"hola\")\n\
    hold s = stubInterrupcion(3)\n\
    escribir64(r, leer64(d) + leer64(c) + s)\n\
    hold buf = reservar(16, 16)\n\
    cpuid(0, 0, buf)\n\
    lgdt(buf)\n\
    lidt(buf)\n\
    ltr(0x28)\n\
    recargarSegmentos(8, 16)\n\
    escribirCr3(leerCr3())\n\
    wrmsr(0x1B, rdmsr(0x1B))\n\
    xmmCero(6)\n\
    xmmCargar(15, buf)\n\
    xmmSumar(6, 15)\n\
    int3()\n\
}\n";

/// (flags, offset, vaddr, filesz, memsz) of every program header.
fn segments(b: &[u8]) -> Vec<(u32, u64, u64, u64, u64)> {
    (0..u16_at(b, 56) as usize)
        .map(|i| {
            let ph = &b[64 + 56 * i..64 + 56 * (i + 1)];
            (
                u32_at(ph, 4),
                u64_at(ph, 8),
                u64_at(ph, 16),
                u64_at(ph, 32),
                u64_at(ph, 40),
            )
        })
        .collect()
}

#[test]
fn kernel_target_lays_out_static_data_and_interrupt_stubs() {
    let dir = work("static");
    let (out, image) = build(&dir, STATIC_KERNEL, &[]);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let b = fs::read(&image).unwrap();
    let segs = segments(&b);
    assert_eq!(segs.len(), 3, "{segs:x?}");
    let (text, rodata, rw) = (segs[0], segs[1], segs[2]);
    assert_eq!(text.0, 5, "text R+X");
    assert_eq!(rodata.0, 4, "rodata R");
    assert_eq!(rw.0, 6, "data/bss R+W");
    for s in &segs {
        assert_eq!(s.1 % 0x1000, 0);
        assert_eq!(s.2, 0xffff_ffff_8000_0000 + s.1);
    }
    // .data: the two datos64 words; .bss after it, page-aligned, not in the file.
    assert_eq!(rw.3, 16);
    let data = &b[rw.1 as usize..rw.1 as usize + 16];
    assert_eq!(&data[..8], &0x1122_3344_5566_7788u64.to_le_bytes());
    assert_eq!(&data[8..], &[0xFF; 8]);
    assert!(rw.4 >= 0x1000 + 4096 + 8 + 16, "bss in memsz: {rw:x?}");
    // .rodata: the cadena record [length u64]["hola"].
    let ro = &b[rodata.1 as usize..(rodata.1 + rodata.3) as usize];
    let mut record = 4u64.to_le_bytes().to_vec();
    record.extend_from_slice(b"hola");
    assert!(contains(ro, &record));

    let code = &b[text.1 as usize..(text.1 + text.3) as usize];
    // Stubs: vector 0 pushes a zero error code, vector 8 does not.
    assert!(contains(code, &[0x6A, 0x00, 0x68, 0, 0, 0, 0, 0xE9]));
    assert!(contains(code, &[0x66, 0x90, 0x68, 8, 0, 0, 0, 0xE9]));
    // Common entry: CLD, PUSH RAX RCX RDX RBX RBP RSI RDI R8.., IRETQ.
    assert!(contains(
        code,
        &[0xFC, 0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x57, 0x41, 0x50]
    ));
    assert!(contains(code, &[0x48, 0xCF]));
    for seq in [
        &[0x0F, 0xA2][..],         // CPUID
        &[0x0F, 0x01, 0x10],       // LGDT [RAX]
        &[0x0F, 0x01, 0x18],       // LIDT [RAX]
        &[0x0F, 0x00, 0xD8],       // LTR AX
        &[0x48, 0xCB],             // RETFQ (segment reload)
        &[0x0F, 0x20, 0xD8],       // MOV RAX,CR3
        &[0x0F, 0x22, 0xD8],       // MOV CR3,RAX
        &[0x0F, 0x32],             // RDMSR
        &[0x0F, 0x30],             // WRMSR
        &[0x0F, 0x57, 0xF6],       // XORPS XMM6,XMM6
        &[0x44, 0x0F, 0x10, 0x38], // MOVUPS XMM15,[RAX]
        &[0x41, 0x0F, 0x58, 0xF7], // ADDPS XMM6,XMM15
        &[0xCC],                   // INT3
    ] {
        assert!(contains(code, seq), "missing {seq:02x?}");
    }
    let names: Vec<String> = symbols(&b).into_iter().map(|s| s.0).collect();
    assert!(names.contains(&"kinterrupcion".to_string()));
}

#[test]
fn kernel_static_intrinsics_are_checked() {
    let dir = work("static_rejects");
    let cases = [
        (
            "take nucleo.mem\n\nflow kmain() {\n    hold n = 8\n    hold r = reservar(n, 8)\n}\n",
            "código 78",
        ),
        (
            "take nucleo.mem\n\nflow kmain() {\n    hold r = reservar(64, 3)\n}\n",
            "código 78",
        ),
        (
            "take nucleo.cpu\n\nflow kmain() {\n    hold s = stubInterrupcion(1)\n}\n",
            "código 79",
        ),
        (
            "take nucleo.cpu\n\nflow kmain() {\n    xmmCero(0)\n}\n",
            "código 80",
        ),
    ];
    for (source, expected) in cases {
        let (out, image) = build(&dir, source, &[]);
        let err = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(3), "{source}: {err}");
        assert!(err.contains(expected), "{source}: {err}");
        assert!(!image.exists());
    }
    // Static storage needs the kernel image layout.
    let src = dir.join("user.l");
    fs::write(
        &src,
        "take nucleo.mem\n\nflow main() => Int {\n    hold r = reservar(8, 8)\n    give 0\n}\n",
    )
    .unwrap();
    let out = Command::new(driver())
        .arg("build")
        .arg(&src)
        .args(["--target", "elf", "-o"])
        .arg(dir.join("user.elf"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&out.stderr).contains("código 77"));
}

#[test]
fn kernel_fused_sse_forms_and_panic_hook() {
    let dir = work("fused");
    let source = "take nucleo.cpu\n\
take nucleo.mem\n\
\n\
fixed PASO = 64\n\
\n\
flow kpanico(codigo: Int, posicion: Int) {\n\
    hlt()\n\
}\n\
\n\
flow kmain() {\n\
    hold p = reservar(256, 16)\n\
    xmmDifundirEn(10, p, 4 * 2)\n\
    xmmMulSumar4(12, 10, p, PASO)\n\
    hold x = leer64(p) + 1\n\
}\n";
    let (out, image) = build(&dir, source, &[]);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let b = fs::read(&image).unwrap();
    let text = &b[0x1000..];
    // MOVSS XMM10,[RAX+8]; SHUFPS XMM10,XMM10,0.
    assert!(contains(text, &[0xF3, 0x44, 0x0F, 0x10, 0x90, 8, 0, 0, 0]));
    assert!(contains(text, &[0x45, 0x0F, 0xC6, 0xD2, 0x00]));
    // Fourth step of xmmMulSumar4: MOVUPS XMM0,[RAX+64+48]; MULPS XMM0,XMM10;
    // ADDPS XMM15,XMM0.
    assert!(contains(
        text,
        &[
            0x0F, 0x10, 0x80, 112, 0, 0, 0, 0x41, 0x0F, 0x59, 0xC2, 0x44, 0x0F, 0x58, 0xF8
        ]
    ));
    // Failed checks reach kpanico(status, position): PUSH RAX; PUSH RDI; CALL.
    assert!(contains(text, &[0x50, 0x57, 0xE8]));

    for (bad, why) in [
        ("xmmMulSumar4(13, 6, p, 0)", "acc + 3 > 15"),
        ("xmmMulSumar4(6, 8, p, 0)", "factor inside the accumulators"),
        ("xmmDifundirEn(10, p, p)", "non-constant displacement"),
    ] {
        let src = format!(
            "take nucleo.cpu\ntake nucleo.mem\n\nflow kmain() {{\n    hold p = reservar(64, 16)\n    {bad}\n}}\n"
        );
        let (out, _) = build(&dir, &src, &[]);
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains("código 80"), "{why}: {err}");
    }
}

#[test]
fn kernel_reads_the_stack_pointer() {
    let dir = work("rsp");
    let source = "take nucleo.cpu\ntake nucleo.mem\n\nflow kmain() {\n    escribir64(reservar(8, 8), leerRsp())\n}\n";
    let (out, image) = build(&dir, source, &[]);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // MOV RAX,RSP.
    assert!(contains(
        &fs::read(&image).unwrap()[0x1000..],
        &[0x48, 0x89, 0xE0]
    ));
}

#[test]
fn kernel_memory_operand_multiply_add() {
    let dir = work("mem4");
    let source = "take nucleo.cpu\ntake nucleo.mem\n\nflow kmain() {\n    hold p = reservar(256, 64)\n    xmmMulSumar4M(4, 1, p, 64)\n}\n";
    let (out, image) = build(&dir, source, &[]);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // MOVAPS XMM0,XMM1; MULPS XMM0,[RAX+64]; ADDPS XMM4,XMM0.
    assert!(contains(
        &fs::read(&image).unwrap()[0x1000..],
        &[
            0x0F, 0x28, 0xC1, 0x0F, 0x59, 0x80, 64, 0, 0, 0, 0x0F, 0x58, 0xE0
        ]
    ));
}
