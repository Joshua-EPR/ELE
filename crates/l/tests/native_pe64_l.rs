//! Windows x64 PE32+ images written by the ELE-written backend
//! (`compiler-l/src/codegen/pe64.l`, `win64_rt.l`). Stage 0 only builds the
//! ELE entries; the images themselves are produced by ELE code without a
//! linker, CRT or Rust. Every host parses and validates the image headers;
//! Windows x86-64 also executes the images and checks stdout and exit code.
mod stage1_support;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

const DEMO_MESSAGE: &[u8] = b"Hola desde ELE: PE32+ nativo para Windows x64\n";

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn demo() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_pe_demo", false))
}
fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn temp(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/native-pe64");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
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

#[derive(Debug)]
struct Section {
    name: String,
    virtual_size: u32,
    rva: u32,
    raw_size: u32,
    raw_offset: u32,
    flags: u32,
}

impl Section {
    fn contains(&self, rva: u32, len: u32) -> bool {
        rva >= self.rva && rva + len <= self.rva + self.virtual_size
    }
    fn file_offset(&self, rva: u32) -> usize {
        (rva - self.rva + self.raw_offset) as usize
    }
}

fn c_string(b: &[u8], at: usize) -> String {
    let end = at + b[at..].iter().position(|&c| c == 0).expect("NUL");
    String::from_utf8(b[at..end].to_vec()).unwrap()
}

const IMAGE_BASE: u64 = 0x1_4000_0000;

/// What `validate_pe` found: sections, entry point RVA, and the RVAs patched
/// by IMAGE_REL_BASED_DIR64 base relocations (`None`: fixed-base image).
struct Pe {
    sections: Vec<Section>,
    entry: u32,
    relocs: Option<Vec<u32>>,
}

/// Parses and validates a PE32+ image as the Windows loader would need it.
/// The last `data_tail` bytes of `.text` are read-only data, not code. Two
/// kinds are accepted: fixed (2 sections, RELOCS_STRIPPED, no ASLR) and
/// relocatable (3 sections, `.reloc` covering every absolute address).
fn validate_pe(b: &[u8], data_tail: usize) -> Pe {
    assert_eq!(&b[..2], b"MZ");
    let pe = u32_at(b, 0x3c) as usize;
    assert_eq!(&b[pe..pe + 4], b"PE\0\0");
    let coff = pe + 4;
    assert_eq!(u16_at(b, coff), 0x8664, "machine AMD64");
    let sections = u16_at(b, coff + 2) as usize;
    assert!(sections == 2 || sections == 3, "{sections} sections");
    let relocatable = sections == 3;
    let opt_size = u16_at(b, coff + 16) as usize;
    assert_eq!(opt_size, 240);
    let characteristics = u16_at(b, coff + 18);
    assert_ne!(characteristics & 0x0002, 0, "EXECUTABLE_IMAGE");
    assert_ne!(characteristics & 0x0020, 0, "LARGE_ADDRESS_AWARE");
    // RELOCS_STRIPPED exactly when there is no relocation directory.
    assert_eq!(
        characteristics & 0x0001 != 0,
        !relocatable,
        "RELOCS_STRIPPED"
    );
    let opt = coff + 20;
    assert_eq!(u16_at(b, opt), 0x20b, "PE32+ magic");
    let entry = u32_at(b, opt + 16);
    assert_eq!(u64_at(b, opt + 24), IMAGE_BASE, "image base");
    let section_align = u32_at(b, opt + 32);
    let file_align = u32_at(b, opt + 36);
    assert_eq!(section_align, 0x1000);
    assert_eq!(file_align, 0x200);
    let image_size = u32_at(b, opt + 56);
    let headers_size = u32_at(b, opt + 60);
    assert_eq!(u16_at(b, opt + 68), 3, "console subsystem");
    let dll_characteristics = u16_at(b, opt + 70);
    assert_eq!(dll_characteristics & 0x0100, 0x0100, "NX_COMPAT");
    // DYNAMIC_BASE and HIGH_ENTROPY_VA only with relocations; no other bit.
    let aslr = if relocatable { 0x0060 } else { 0 };
    assert_eq!(dll_characteristics, 0x0100 | aslr, "DllCharacteristics");
    // No stack probes are emitted: the whole 8 MiB stack is committed.
    assert_eq!(u64_at(b, opt + 72), 0x80_0000, "SizeOfStackReserve");
    assert_eq!(u64_at(b, opt + 80), 0x80_0000, "SizeOfStackCommit");
    assert_eq!(u32_at(b, opt + 108), 16, "data directories");
    let dir = |i: usize| (u32_at(b, opt + 112 + 8 * i), u32_at(b, opt + 116 + 8 * i));
    if !relocatable {
        assert_eq!(dir(5), (0, 0), "no base relocations");
    }
    for d in [0, 2, 3, 4, 6, 7, 8, 9, 10, 11, 13, 14, 15] {
        assert_eq!(dir(d), (0, 0), "data directory {d}");
    }
    assert_eq!(headers_size % file_align, 0);
    assert!(headers_size as usize >= opt + opt_size + 40 * sections);

    let table = opt + opt_size;
    let parsed: Vec<Section> = (0..sections)
        .map(|i| {
            let s = table + 40 * i;
            Section {
                name: c_string(
                    &b[s..s + 8].iter().copied().chain([0]).collect::<Vec<_>>(),
                    0,
                ),
                virtual_size: u32_at(b, s + 8),
                rva: u32_at(b, s + 12),
                raw_size: u32_at(b, s + 16),
                raw_offset: u32_at(b, s + 20),
                flags: u32_at(b, s + 36),
            }
        })
        .collect();
    let mut next_rva = headers_size.div_ceil(section_align) * section_align;
    let mut next_raw = headers_size;
    for s in &parsed {
        assert_eq!(s.rva, next_rva, "{s:?}");
        assert_eq!(s.raw_offset, next_raw, "{s:?}");
        assert_eq!(s.raw_offset % file_align, 0);
        assert_eq!(s.raw_size % file_align, 0);
        assert!(s.virtual_size > 0 && s.virtual_size <= s.raw_size, "{s:?}");
        // W^X: no section is both writable and executable.
        assert!(s.flags & 0x2000_0000 == 0 || s.flags & 0x8000_0000 == 0);
        next_rva += s.virtual_size.div_ceil(section_align) * section_align;
        next_raw += s.raw_size;
    }
    assert_eq!(image_size, next_rva);
    assert_eq!(b.len() as u32, next_raw, "file size");
    let text = &parsed[0];
    assert_eq!(text.name, ".text");
    assert_eq!(text.flags, 0x6000_0020, "code, execute, read");
    assert!(text.contains(entry, 1), "entry {entry:#x} outside .text");
    assert_eq!(u32_at(b, opt + 4), text.raw_size, "SizeOfCode");
    assert_eq!(u32_at(b, opt + 20), text.rva, "BaseOfCode");
    let idata = &parsed[1];
    assert_eq!(idata.name, ".idata");
    assert_eq!(idata.flags, 0xc000_0040, "initialized data, read, write");

    // Import directory: one KERNEL32.dll descriptor plus the terminator.
    let (import_rva, import_size) = dir(1);
    assert_eq!(import_size, 40);
    assert!(idata.contains(import_rva, import_size));
    let d = idata.file_offset(import_rva);
    assert!(b[d + 20..d + 40].iter().all(|&x| x == 0), "terminator");
    let (ilt, name, iat) = (u32_at(b, d), u32_at(b, d + 12), u32_at(b, d + 16));
    assert!(idata.contains(name, 13));
    assert_eq!(c_string(b, idata.file_offset(name)), "KERNEL32.dll");
    let (iat_dir, iat_size) = dir(12);
    assert_eq!((iat_dir, iat_size), (iat, 48));
    let mut names = Vec::new();
    for table in [ilt, iat] {
        assert!(idata.contains(table, 48));
        let mut row = Vec::new();
        for k in 0..6 {
            let entry = u64_at(b, idata.file_offset(table + 8 * k));
            if k == 5 {
                assert_eq!(entry, 0, "table terminator");
                continue;
            }
            assert_eq!(entry >> 63, 0, "import by name");
            let hint_name = entry as u32;
            assert!(idata.contains(hint_name, 3));
            row.push(c_string(b, idata.file_offset(hint_name) + 2));
        }
        names.push(row);
    }
    assert_eq!(
        names[0],
        [
            "GetStdHandle",
            "WriteFile",
            "ExitProcess",
            "VirtualAlloc",
            "VirtualFree"
        ]
    );
    assert_eq!(names[0], names[1], "ILT and IAT name the same imports");

    // Every CALL [RIP+disp32] in .text must land on an IAT slot.
    let code_end = (text.raw_offset + text.virtual_size) as usize - data_tail;
    let code = &b[text.raw_offset as usize..code_end];
    let mut calls = 0;
    for at in 0..code.len().saturating_sub(5) {
        if code[at] == 0xff && code[at + 1] == 0x15 {
            let disp = i32::from_le_bytes(code[at + 2..at + 6].try_into().unwrap());
            let target = (i64::from(text.rva) + at as i64 + 6 + i64::from(disp)) as u32;
            assert!(
                target >= iat && target < iat + 40 && (target - iat).is_multiple_of(8),
                "call at {at:#x} reaches {target:#x}"
            );
            calls += 1;
        }
    }
    assert!(calls > 0, "no import call");
    let relocs = relocatable.then(|| validate_relocs(b, &parsed, dir(5), image_size, code_end));
    Pe {
        sections: parsed,
        entry,
        relocs,
    }
}

/// Parses `.reloc` and checks it the way the loader applies it: 4 KiB page
/// blocks inside the image, only DIR64 (10) and padding ABSOLUTE (0)
/// entries, each DIR64 target inside the code of `.text` and holding an
/// address of this image at its preferred base, no two targets overlapping.
/// Conversely, every MOVABS r64, imm64 in the code whose immediate is an
/// address of the image must be relocated. Returns the DIR64 target RVAs.
fn validate_relocs(
    b: &[u8],
    sections: &[Section],
    (rva, size): (u32, u32),
    image_size: u32,
    code_end: usize,
) -> Vec<u32> {
    let (text, idata, reloc) = (&sections[0], &sections[1], &sections[2]);
    assert_eq!(reloc.name, ".reloc");
    assert_eq!(
        reloc.flags, 0x4200_0040,
        "initialized data, discardable, read"
    );
    assert_eq!((rva, size), (reloc.rva, reloc.virtual_size), "reloc dir");
    assert!(reloc.rva > idata.rva, ".reloc follows .idata");
    let in_image = |v: u64| v >= IMAGE_BASE && v < IMAGE_BASE + u64::from(image_size);
    let code_rva_end = text.rva + (code_end - text.raw_offset as usize) as u32;
    let mut targets = Vec::new();
    let mut at = reloc.raw_offset as usize;
    let end = at + size as usize;
    let mut last_page = None;
    while at < end {
        let page = u32_at(b, at);
        let block = u32_at(b, at + 4) as usize;
        assert_eq!(page % 0x1000, 0, "page aligned");
        assert!(last_page.is_none_or(|p| page > p), "pages increase");
        last_page = Some(page);
        assert!(
            block >= 12 && block.is_multiple_of(4) && at + block <= end,
            "block {block}"
        );
        for k in (at + 8..at + block).step_by(2) {
            let entry = u16_at(b, k);
            match entry >> 12 {
                0 => assert_eq!(entry, 0, "padding"),
                10 => {
                    let target = page + (entry & 0xfff);
                    assert!(
                        target >= text.rva && target + 8 <= code_rva_end,
                        "{target:#x}"
                    );
                    let value = u64_at(b, text.file_offset(target));
                    assert!(in_image(value), "{target:#x} holds {value:#x}");
                    targets.push(target);
                }
                kind => panic!("relocation type {kind}"),
            }
        }
        at += block;
    }
    assert_eq!(at, end, "blocks fill the directory");
    let mut sorted = targets.clone();
    sorted.sort_unstable();
    assert!(
        sorted.windows(2).all(|w| w[1] >= w[0] + 8),
        "overlapping relocations"
    );
    let code = &b[text.raw_offset as usize..code_end];
    for k in 0..code.len().saturating_sub(9) {
        if code[k] & 0xf8 == 0x48 && (0xb8..0xc0).contains(&code[k + 1]) {
            let value = u64_at(code, k + 2);
            if in_image(value) {
                assert!(
                    targets.contains(&(text.rva + k as u32 + 2)),
                    "MOVABS at {k:#x} holds image address {value:#x} without relocation"
                );
            }
        }
    }
    targets
}

#[cfg(all(windows, target_arch = "x86_64"))]
fn execute(image: &Path) -> (Option<i32>, Vec<u8>) {
    let run = Command::new(image).output().unwrap();
    // A run-time check (native_trap.l) reports itself on stderr; these LIR
    // fixtures carry no ` @line:col`, so the line has no position. Every
    // other run writes nothing to stderr.
    let expected: &[u8] = match run.status.code() {
        Some(125) => "ELE: overflow entero o división/resto por cero\n".as_bytes(),
        Some(126) => b"ELE: acceso a variante enum inactiva\n",
        Some(127) => "ELE: índice fuera de rango\n".as_bytes(),
        _ => b"",
    };
    assert_eq!(
        String::from_utf8_lossy(&run.stderr),
        String::from_utf8_lossy(expected),
        "{}",
        image.display()
    );
    (run.status.code(), run.stdout)
}

#[test]
fn demo_writes_a_valid_pe32_plus_that_runs_on_windows() {
    let image = temp("demo.exe");
    let _ = fs::remove_file(&image);
    let out = Command::new(demo()).arg(&image).output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    let Pe {
        sections,
        entry,
        relocs,
    } = validate_pe(&bytes, DEMO_MESSAGE.len());
    assert_eq!(entry, sections[0].rva);
    // The demo addresses its message RIP-relative: a fixed-base image.
    assert!(relocs.is_none());
    // The message is read-only data at the end of .text.
    let text = &sections[0];
    let code = &bytes[text.raw_offset as usize..(text.raw_offset + text.virtual_size) as usize];
    assert!(code.ends_with(DEMO_MESSAGE));
    // Reproducible: no timestamp or other varying field.
    let again = temp("demo-again.exe");
    assert!(Command::new(demo()).arg(&again).status().unwrap().success());
    assert_eq!(fs::read(&again).unwrap(), bytes);
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        assert_eq!(stdout, DEMO_MESSAGE);
        assert_eq!(code, Some(42));
    }
}

/// The largest frame x64FrameBegin emits (4 KiB), 1000 levels deep (about
/// 4 MiB): needs the fully committed 8 MiB stack. With the previous header
/// (1 MiB reserve, 4 KiB commit) this image died with 0xC00000FD.
#[test]
fn deep_maximum_frames_run_within_the_committed_stack() {
    let image = temp("deep-frames.exe");
    let _ = fs::remove_file(&image);
    let out = Command::new(demo())
        .arg("--deep-frames")
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(validate_pe(&fs::read(&image).unwrap(), 0).relocs.is_none());
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        assert!(stdout.is_empty());
        assert_eq!(code, Some(43));
    }
}

fn reloc_probe(flag: &str, name: &str) -> (PathBuf, Pe) {
    let image = temp(name);
    let _ = fs::remove_file(&image);
    let out = Command::new(demo()).arg(flag).arg(&image).output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    let pe = validate_pe(&bytes, 1);
    (image, pe)
}

/// A relocatable image (DYNAMIC_BASE | HIGH_ENTROPY_VA) compares a code
/// address taken RIP-relative with the same address stored as a 64-bit
/// absolute covered by a DIR64 relocation. Exit 0 means the loader placed
/// the image away from its preferred base AND the relocated value is exact;
/// 1 would mean it was not moved (the run proved nothing), 2 a stale value.
#[test]
fn relocatable_image_is_moved_by_the_loader_and_relocated_exactly() {
    let (_image, pe) = reloc_probe("--relocated", "reloc-probe.exe");
    let relocs = pe.relocs.expect("relocatable image");
    assert_eq!(relocs.len(), 1, "{relocs:x?}");
    // The relocated MOVABS immediate follows the 7-byte LEA and 48 B9.
    assert_eq!(relocs[0], pe.sections[0].rva + 9);
    #[cfg(all(windows, target_arch = "x86_64"))]
    for _ in 0..3 {
        let (code, stdout) = execute(&_image);
        assert!(stdout.is_empty());
        assert_eq!(code, Some(0), "1: not moved by ASLR, 2: stale address");
    }
}

/// Negative control: the same code and DYNAMIC_BASE header but the MOVABS
/// gets no relocation. The loader still moves the image and the program
/// sees the stale preferred-base address (exit 2). This is what any CFG
/// image with Text literals would do if the writer missed one of them; the
/// validator also rejects it statically.
#[test]
fn relocatable_image_without_its_relocation_sees_a_stale_address() {
    let image = temp("reloc-missing.exe");
    let _ = fs::remove_file(&image);
    let out = Command::new(demo())
        .arg("--relocated-missing")
        .arg(&image)
        .output()
        .unwrap();
    assert!(out.status.success());
    let bytes = fs::read(&image).unwrap();
    let caught = std::panic::catch_unwind(|| validate_pe(&bytes, 1));
    assert!(caught.is_err(), "validator accepted an unrelocated MOVABS");
    #[cfg(all(windows, target_arch = "x86_64"))]
    {
        let (code, stdout) = execute(&image);
        assert!(stdout.is_empty());
        assert_eq!(code, Some(2));
    }
}

/// Text literals are the CFG backend's only absolute addresses: on PE32+
/// each one gets a DIR64 relocation, so the images run under ASLR.
#[test]
fn cfg_text_literals_are_relocated_under_aslr() {
    for (fixture, literals, stdout, status) in [
        ("native_cfg_text_literal_ok", 2, "hi\n\n", 0),
        ("native_cfg_text_append_by_value_ok", 0, "42\n", 0),
        ("native_cfg_branch", 0, "", 42),
    ] {
        let lir = root().join(format!("examples/{fixture}.lir"));
        let image = cfg_pe(&lir, &format!("aslr-{fixture}"));
        let pe = validate_pe(&fs::read(&image).unwrap(), 0);
        let relocs = pe.relocs.expect("CFG images are relocatable");
        assert_eq!(relocs.len(), literals, "{fixture}: {relocs:x?}");
        let _ = (stdout, status);
        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            let (code, out) = execute(&image);
            assert_eq!(String::from_utf8(out).unwrap(), stdout, "{fixture}");
            assert_eq!(code, Some(status), "{fixture}");
        }
    }
}

/// The layout and writer reject every invalid input with a fixed code.
#[test]
fn writer_rejects_invalid_layouts_deterministically() {
    let out = Command::new(demo()).arg("--self-check").output().unwrap();
    assert!(out.status.success());
    let expected = "\
ok=0
ok.text_rva=4096
ok.idata_rva=8192
ok.image_size=12288
ok.file_size=5120
empty_code=1
code_too_large=2
code_huge=2
section_not_pow2=4
file_not_pow2=4
file_too_small=4
file_too_large=4
section_below_file=4
section_zero=4
section_negative=4
section_huge=4
image_overflow=5
idata_overflow=5
writer_empty=1
writer_bad_byte=3
writer_bad_entry=6
writer_fixup_out_of_code=7
writer_unknown_import=7
writer_fixup_not_call=7
writer_fixup_duplicate=7
writer_fixup_overlap=7
writer_fixups_ok=0
writer_bad_alignment=4
writer_ok=0
writer_ok.length=1536
reloc_layout=0
reloc_layout.reloc_rva=12288
reloc_layout.image_size=16384
reloc_layout.file_size=5632
reloc_layout_negative=5
reloc_ok=0
reloc_ok.length=2048
reloc_none_ok=0
reloc_negative=8
reloc_out_of_code=8
reloc_overlap=8
reloc_duplicate=8
reloc_outside_image=8
reloc_past_image=8
reloc_on_import=8
";
    assert_eq!(String::from_utf8(out.stdout).unwrap(), expected);
}

/// A rejected image is never written, not even partially.
#[test]
fn invalid_alignment_writes_no_file() {
    let image = temp("bad-alignment.exe");
    let _ = fs::remove_file(&image);
    let out = Command::new(demo())
        .arg("--bad-alignment")
        .arg(&image)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&out.stderr).contains("PE64 rechazado (código 4)"));
    assert!(!image.exists());
}

fn cfg_pe(lir: &Path, name: &str) -> PathBuf {
    let image = temp(&format!("{name}.exe"));
    let _ = fs::remove_file(&image);
    let out = Command::new(native())
        .arg(lir)
        .arg(&image)
        .arg("--pe64")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(validate_pe(&fs::read(&image).unwrap(), 0).relocs.is_some());
    image
}

/// The same ELE-LIR the ELF64 tests use, lowered by the same CFG backend,
/// now targeting PE32+. Results match the ELF64 images run on Linux.
#[test]
fn cfg_backend_lir_fixtures_run_as_pe32_plus() {
    for (fixture, _stdout, _status) in [
        ("native_cfg_const_min", "-9223372036854775808\ntrue\n", 0),
        ("native_without_rust", "42\n", 0),
        ("native_cfg_branch", "", 42),
        ("native_cfg_recursive", "", 120),
        ("native_cfg_loop_call", "", 8),
        ("native_cfg_struct_copy", "", 42),
        ("native_cfg_option_some", "", 42),
        ("native_cfg_wide_64", "", 42),
        // Trap handlers: checked overflow (125), inactive variant (126).
        ("native_int_subset_invalid", "", 125),
        ("native_cfg_enum_payload_wrong_active", "", 126),
    ] {
        let image = cfg_pe(&root().join(format!("examples/{fixture}.lir")), fixture);
        let _ = &image;
        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(String::from_utf8(stdout).unwrap(), _stdout, "{fixture}");
            assert_eq!(code, Some(_status), "{fixture}");
        }
    }
}

/// `.l` source -> Stage 1 -> ELE-LIR -> ELE CFG backend -> PE32+.
#[test]
fn official_examples_build_native_pe32_plus() {
    let list_int_exp = fs::read_to_string(root().join("examples/native_list_int_stage1.expected"))
        .unwrap()
        .replace("\r\n", "\n");
    let list_owned_exp =
        fs::read_to_string(root().join("examples/native_list_owned_stage1.expected"))
            .unwrap()
            .replace("\r\n", "\n");
    let list_repl_exp =
        fs::read_to_string(root().join("examples/native_list_replace_stage1.expected"))
            .unwrap()
            .replace("\r\n", "\n");
    let loans_exp = fs::read_to_string(root().join("examples/native_loans_stage1.expected"))
        .unwrap()
        .replace("\r\n", "\n");
    for (name, _expected) in [
        ("arithmetic", "42\n"),
        ("hello", "42\n"),
        ("control_flow", "15\n"),
        ("loops", "12\n"),
        ("native_list_int_stage1", list_int_exp.as_str()),
        ("native_list_owned_stage1", list_owned_exp.as_str()),
        ("native_list_replace_stage1", list_repl_exp.as_str()),
        ("native_loans_stage1", loans_exp.as_str()),
    ] {
        let emitted = Command::new(sema())
            .arg(root().join(format!("examples/{name}.l")))
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(
            emitted.status.success(),
            "Stage 1: {}",
            String::from_utf8_lossy(&emitted.stderr)
        );
        let lir = temp(&format!("{name}.lir"));
        fs::write(&lir, &emitted.stdout).unwrap();
        let image = cfg_pe(&lir, name);
        let _ = &image;
        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(String::from_utf8(stdout).unwrap(), _expected, "{name}");
            assert_eq!(code, Some(0), "{name}");
        }
    }
}

/// Owned Text and lists execute on Windows PE32+ via VirtualAlloc and VirtualFree.
#[test]
fn cfg_pe32_plus_executes_owned_text_and_lists() {
    let cases: &[(&str, Option<i32>, &str)] = &[
        ("native_cfg_text_literal_ok", Some(0), "hi\n\n"),
        ("native_cfg_text_flagged_drop", Some(0), "false\n"),
        ("native_cfg_text_append_by_value_ok", Some(0), "42\n"),
        ("native_cfg_list_index_ok", Some(2), ""),
        ("native_cfg_list_reserve_negative", Some(123), ""),
    ];
    for &(fixture, _expected_code, _expected_stdout) in cases {
        let image = temp(&format!("{fixture}.exe"));
        let _ = fs::remove_file(&image);
        let out = Command::new(native())
            .arg(root().join(format!("examples/{fixture}.lir")))
            .arg(&image)
            .arg("--pe64")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{fixture} compile failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(image.exists(), "{fixture} no image written");
        let bytes = fs::read(&image).unwrap();
        assert!(validate_pe(&bytes, 0).relocs.is_some());
        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(code, _expected_code, "{fixture} exit code mismatch");
            if !_expected_stdout.is_empty() {
                assert_eq!(
                    String::from_utf8(stdout).unwrap(),
                    _expected_stdout,
                    "{fixture} stdout mismatch"
                );
            }
        }
    }
}

/// Options in invalid positions or unknown targets are rejected cleanly.
#[test]
fn cfg_pe32_plus_rejects_runtime_it_lacks() {
    let out = Command::new(native())
        .arg(root().join("examples/native_cfg_branch.lir"))
        .arg(temp("unknown-flag.exe"))
        .arg("--pe32")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    // An option in the output slot is a usage error, never a file name.
    let dir = temp("flag-slot");
    fs::create_dir_all(&dir).unwrap();
    let _ = fs::remove_file(dir.join("--pe64"));
    let out = Command::new(native())
        .current_dir(&dir)
        .arg(root().join("examples/native_cfg_branch.lir"))
        .arg("--pe64")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(!dir.join("--pe64").exists());
}

/// Dynamic memory runtime on Windows: traps (121 literal append, 127 OOB/neg index),
/// structs with owned text fields, references into lists, and fail-closed compilation
/// rejection on malformed LIR (double drops).
#[test]
fn cfg_pe32_plus_memory_runtime_security_and_traps() {
    let runtime_traps: &[(&str, Option<i32>)] = &[
        ("native_cfg_text_append_literal", Some(121)),
        ("native_cfg_text_in_struct", Some(0)),
        ("native_cfg_list_elem_ref_ok", Some(42)),
        ("native_cfg_list_elem_store_owned", Some(0)),
        ("native_cfg_loan_ok", Some(42)),
        ("native_cfg_loan_disjoint_fields", Some(42)),
        ("native_cfg_list_index_oob", Some(127)),
        ("native_cfg_list_index_negative", Some(127)),
    ];
    for &(fixture, _expected_code) in runtime_traps {
        let image = temp(&format!("{fixture}.exe"));
        let _ = fs::remove_file(&image);
        let out = Command::new(native())
            .arg(root().join(format!("examples/{fixture}.lir")))
            .arg(&image)
            .arg("--pe64")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{fixture} compile failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let bytes = fs::read(&image).unwrap();
        assert!(validate_pe(&bytes, 0).relocs.is_some());
        #[cfg(all(windows, target_arch = "x86_64"))]
        {
            let (code, _) = execute(&image);
            assert_eq!(code, _expected_code, "{fixture} trap code mismatch");
        }
    }

    // Negative compile-time tests: unsound memory and drop patterns must be rejected without creating PE images
    for fixture in [
        "native_cfg_list_double_drop",
        "native_cfg_text_double_drop",
        "native_cfg_list_leak",
        "native_cfg_list_overwrite",
        "native_cfg_list_elem_move",
        "native_cfg_list_shared_push",
        "native_cfg_list_alias",
    ] {
        let image = temp(&format!("{fixture}.exe"));
        let _ = fs::remove_file(&image);
        let out = Command::new(native())
            .arg(root().join(format!("examples/{fixture}.lir")))
            .arg(&image)
            .arg("--pe64")
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(3), "{fixture} was not rejected");
        assert!(!image.exists(), "{fixture} emitted image on double drop");
    }
}
