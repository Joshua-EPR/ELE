//! Shared harness for adversarial and structural tests of the native images
//! written by the ELE backends (`native_cfg_demo`, `native_pe_demo`):
//!
//! * `validate_elf64` / `validate_pe32plus`: generic, loader-level structure
//!   checks that return every violation found instead of stopping at the
//!   first one (W^X, entry point, bounds, alignment, imports, `.reloc`).
//! * `sha256`: a dependency-free SHA-256 for reproducibility checks.
//! * `run_elf`: executes an ELF64 image natively on Linux x86-64 or through
//!   WSL on Windows (`ELE_TEST_WSL_DISTRO`), optionally under `strace -f`,
//!   and reports the exit status, the killing signal and the syscalls made.
//!   When the image cannot be executed it returns `Exec::NotRun` with the
//!   reason; callers must print it and use `require_exec` so that
//!   `ELE_REQUIRE_NATIVE_EXEC=1` turns the skip into a failure.
#![allow(dead_code)]

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

pub const REQUIRE_NATIVE_EXEC: &str = "ELE_REQUIRE_NATIVE_EXEC";
pub const WSL_DISTRO: &str = "ELE_TEST_WSL_DISTRO";

fn u16_at(b: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        b.get(at..at.checked_add(2)?)?.try_into().ok()?,
    ))
}
fn u32_at(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        b.get(at..at.checked_add(4)?)?.try_into().ok()?,
    ))
}
fn u64_at(b: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_le_bytes(
        b.get(at..at.checked_add(8)?)?.try_into().ok()?,
    ))
}

// ---------------------------------------------------------------- ELF64 ---

#[derive(Debug, Clone)]
pub struct Segment {
    pub kind: u32,
    pub flags: u32,
    pub offset: u64,
    pub vaddr: u64,
    pub filesz: u64,
    pub memsz: u64,
    pub align: u64,
}

#[derive(Debug)]
pub struct Elf {
    pub entry: u64,
    pub segments: Vec<Segment>,
}

const PT_LOAD: u32 = 1;
const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;

/// Validates a static Linux x86-64 ELF64 executable the way the kernel
/// loader consumes it. Returns the parsed image, or every violation found.
pub fn validate_elf64(b: &[u8]) -> Result<Elf, Vec<String>> {
    let mut errors = Vec::new();
    macro_rules! check {
        ($cond:expr, $($msg:tt)*) => {
            if !$cond { errors.push(format!($($msg)*)); }
        };
    }
    if b.len() < 64 {
        return Err(vec![format!(
            "file of {} bytes is shorter than the ELF header",
            b.len()
        )]);
    }
    check!(&b[..4] == b"\x7fELF", "bad ELF magic {:02x?}", &b[..4]);
    check!(b[4] == 2, "EI_CLASS {} is not ELFCLASS64", b[4]);
    check!(b[5] == 1, "EI_DATA {} is not little-endian", b[5]);
    check!(b[6] == 1, "EI_VERSION {}", b[6]);
    let e_type = u16_at(b, 16).unwrap();
    check!(e_type == 2, "e_type {e_type} is not ET_EXEC");
    let machine = u16_at(b, 18).unwrap();
    check!(machine == 0x3e, "e_machine {machine:#x} is not x86-64");
    check!(u32_at(b, 20) == Some(1), "e_version");
    let entry = u64_at(b, 24).unwrap();
    let phoff = u64_at(b, 32).unwrap();
    let shoff = u64_at(b, 40).unwrap();
    check!(u16_at(b, 52) == Some(64), "e_ehsize");
    let phentsize = u16_at(b, 54).unwrap();
    let phnum = u16_at(b, 56).unwrap();
    let shnum = u16_at(b, 60).unwrap();
    check!(phentsize == 56, "e_phentsize {phentsize}");
    check!(phnum >= 1, "no program headers");
    check!(
        shoff == 0
            || shoff
                .checked_add(u64::from(shnum) * 64)
                .is_some_and(|e| e <= b.len() as u64),
        "section header table at {shoff:#x} (x{shnum}) outside the file"
    );
    let table_end = phoff.checked_add(u64::from(phnum) * u64::from(phentsize));
    if !table_end.is_some_and(|e| e <= b.len() as u64) || phentsize != 56 {
        errors.push(format!(
            "program header table at {phoff:#x} (x{phnum}) outside the file"
        ));
        return Err(errors);
    }
    let segments: Vec<Segment> = (0..usize::from(phnum))
        .map(|i| {
            let at = phoff as usize + 56 * i;
            Segment {
                kind: u32_at(b, at).unwrap(),
                flags: u32_at(b, at + 4).unwrap(),
                offset: u64_at(b, at + 8).unwrap(),
                vaddr: u64_at(b, at + 16).unwrap(),
                filesz: u64_at(b, at + 32).unwrap(),
                memsz: u64_at(b, at + 40).unwrap(),
                align: u64_at(b, at + 48).unwrap(),
            }
        })
        .collect();
    let mut loads: Vec<&Segment> = Vec::new();
    for (i, s) in segments.iter().enumerate() {
        // A static image needs no interpreter, dynamic section or TLS.
        check!(
            !matches!(s.kind, 2..=3 | 7),
            "segment {i}: unexpected p_type {} in a static image",
            s.kind
        );
        check!(
            s.flags & (PF_W | PF_X) != (PF_W | PF_X),
            "segment {i}: W^X violated (p_flags {:#x})",
            s.flags
        );
        check!(
            s.flags & !(PF_R | PF_W | PF_X) == 0,
            "segment {i}: unknown p_flags {:#x}",
            s.flags
        );
        check!(
            s.offset
                .checked_add(s.filesz)
                .is_some_and(|e| e <= b.len() as u64),
            "segment {i}: p_offset {:#x} + p_filesz {:#x} past the end of the {}-byte file",
            s.offset,
            s.filesz,
            b.len()
        );
        check!(
            s.filesz <= s.memsz,
            "segment {i}: p_filesz {:#x} > p_memsz {:#x}",
            s.filesz,
            s.memsz
        );
        if s.kind == PT_LOAD {
            check!(s.flags & PF_R != 0, "segment {i}: PT_LOAD is not readable");
            check!(
                s.align.is_power_of_two() && s.align >= 4096,
                "segment {i}: p_align {:#x} is not a power of two >= page size",
                s.align
            );
            if s.align.is_power_of_two() {
                check!(
                    s.offset % s.align == s.vaddr % s.align,
                    "segment {i}: p_offset {:#x} and p_vaddr {:#x} disagree modulo p_align",
                    s.offset,
                    s.vaddr
                );
            }
            check!(
                s.vaddr >= 0x10000,
                "segment {i}: p_vaddr {:#x} below mmap_min_addr",
                s.vaddr
            );
            check!(
                s.vaddr
                    .checked_add(s.memsz)
                    .is_some_and(|e| e <= 0x7fff_ffff_f000),
                "segment {i}: p_vaddr {:#x} + p_memsz {:#x} outside user space",
                s.vaddr,
                s.memsz
            );
            check!(s.memsz > 0, "segment {i}: empty PT_LOAD");
            loads.push(s);
        }
    }
    check!(!loads.is_empty(), "no PT_LOAD segment");
    // PT_LOAD segments must be sorted by p_vaddr and must not overlap, even
    // after rounding to pages (the kernel maps whole pages).
    for w in loads.windows(2) {
        let end = w[0].vaddr.saturating_add(w[0].memsz).div_ceil(4096) * 4096;
        check!(
            w[1].vaddr >= end,
            "PT_LOAD at {:#x} overlaps the page-rounded end {end:#x} of the previous one",
            w[1].vaddr
        );
    }
    let entry_segment = loads
        .iter()
        .find(|s| entry >= s.vaddr && entry < s.vaddr.saturating_add(s.filesz));
    match entry_segment {
        None => errors.push(format!(
            "entry {entry:#x} is not inside the file bytes of any PT_LOAD"
        )),
        Some(s) => check!(
            s.flags & PF_X != 0,
            "entry {entry:#x} lies in a non-executable segment"
        ),
    }
    if errors.is_empty() {
        Ok(Elf { entry, segments })
    } else {
        Err(errors)
    }
}

// -------------------------------------------------------------- PE32+ ---

#[derive(Debug, Clone)]
pub struct Section {
    pub name: String,
    pub virtual_size: u32,
    pub rva: u32,
    pub raw_size: u32,
    pub raw_offset: u32,
    pub flags: u32,
}

#[derive(Debug)]
pub struct Pe {
    pub entry: u32,
    pub sections: Vec<Section>,
    pub imports: Vec<(String, Vec<String>)>,
    pub relocs: Vec<u32>,
    pub dynamic_base: bool,
}

/// KERNEL32 functions the ELE Windows runtime (codegen/win64_rt.l,
/// codegen/win64_heap.l, codegen/win64_rt_platform.l) is allowed to import. Anything else is a violation.
pub const ALLOWED_KERNEL32: [&str; 32] = [
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
    // Stage 3.5 native filesystem identity, safe publication, and OS entropy.
    // The PE validator continues to reject every other import and DLL.
    "GetFileInformationByHandle",
    "FlushFileBuffers",
    "MoveFileExW",
    "DeleteFileW",
    "GetFileAttributesW",
    "LoadLibraryExW",
    "GetProcAddress",
    "FreeLibrary",
    // Console input (consoleInputMode, readConsoleEvent), imported only by
    // images that call those operations.
    "GetConsoleMode",
    "SetConsoleMode",
    "ReadConsoleInputW",
    // File streams (fileSeek, fileSize), imported only by images that call
    // those operations.
    "SetFilePointerEx",
    "GetFileSizeEx",
    // CF_UNICODETEXT clipboard memory; user32 functions remain dynamically
    // resolved from system32.
    "GlobalAlloc",
    "GlobalLock",
    "GlobalUnlock",
    "GlobalFree",
    "GlobalSize",
    "Sleep",
];

const SCN_CODE: u32 = 0x20;
const SCN_EXECUTE: u32 = 0x2000_0000;
const SCN_READ: u32 = 0x4000_0000;
const SCN_WRITE: u32 = 0x8000_0000;

/// Validates a PE32+ AMD64 console image as the Windows loader consumes it:
/// headers, alignment, section layout, W^X, entry point, the import
/// directory (only KERNEL32.dll and only `ALLOWED_KERNEL32`) and `.reloc`.
pub fn validate_pe32plus(b: &[u8]) -> Result<Pe, Vec<String>> {
    let mut errors = Vec::new();
    macro_rules! check {
        ($cond:expr, $($msg:tt)*) => {
            if !$cond { errors.push(format!($($msg)*)); }
        };
    }
    macro_rules! bail {
        ($($msg:tt)*) => {{ errors.push(format!($($msg)*)); return Err(errors); }};
    }
    if b.len() < 0x40 || &b[..2] != b"MZ" {
        bail!("missing DOS header");
    }
    let pe = u32_at(b, 0x3c).unwrap() as usize;
    check!(pe.is_multiple_of(8), "e_lfanew {pe:#x} not 8-byte aligned");
    if u32_at(b, pe) != Some(0x4550) {
        bail!("missing PE\\0\\0 signature at {pe:#x}");
    }
    let coff = pe + 4;
    let Some(machine) = u16_at(b, coff) else {
        bail!("truncated COFF header")
    };
    check!(machine == 0x8664, "machine {machine:#x} is not AMD64");
    let nsections = usize::from(u16_at(b, coff + 2).unwrap_or(0));
    check!((1..=96).contains(&nsections), "{nsections} sections");
    check!(
        u32_at(b, coff + 4) == Some(0),
        "TimeDateStamp is not 0 (irreproducible)"
    );
    let opt_size = usize::from(u16_at(b, coff + 16).unwrap_or(0));
    let characteristics = u16_at(b, coff + 18).unwrap_or(0);
    check!(
        characteristics & 0x0002 != 0,
        "not IMAGE_FILE_EXECUTABLE_IMAGE"
    );
    check!(characteristics & 0x2000 == 0, "image is a DLL");
    let opt = coff + 20;
    if opt_size < 112 || b.len() < opt + opt_size {
        bail!("optional header of {opt_size} bytes truncated or too small");
    }
    check!(
        u16_at(b, opt) == Some(0x20b),
        "optional header magic is not PE32+"
    );
    let entry = u32_at(b, opt + 16).unwrap();
    let image_base = u64_at(b, opt + 24).unwrap();
    check!(
        image_base.is_multiple_of(0x1_0000),
        "ImageBase {image_base:#x} not 64 KiB aligned"
    );
    let section_align = u32_at(b, opt + 32).unwrap();
    let file_align = u32_at(b, opt + 36).unwrap();
    check!(
        file_align.is_power_of_two() && (512..=65536).contains(&file_align),
        "FileAlignment {file_align:#x}"
    );
    check!(
        section_align.is_power_of_two() && section_align >= file_align,
        "SectionAlignment {section_align:#x} < FileAlignment"
    );
    if !(file_align.is_power_of_two() && section_align.is_power_of_two()) {
        return Err(errors);
    }
    let image_size = u32_at(b, opt + 56).unwrap();
    let headers_size = u32_at(b, opt + 60).unwrap();
    check!(
        image_size.is_multiple_of(section_align),
        "SizeOfImage {image_size:#x} not section aligned"
    );
    check!(
        headers_size.is_multiple_of(file_align),
        "SizeOfHeaders {headers_size:#x} not file aligned"
    );
    let subsystem = u16_at(b, opt + 68).unwrap();
    check!(subsystem == 3, "subsystem {subsystem} is not the console");
    let dll = u16_at(b, opt + 70).unwrap();
    check!(dll & 0x0100 != 0, "NX_COMPAT not declared");
    let dynamic_base = dll & 0x0040 != 0;
    check!(
        !dynamic_base || characteristics & 0x0001 == 0,
        "DYNAMIC_BASE together with RELOCS_STRIPPED"
    );
    check!(
        dll & 0x0020 == 0 || dynamic_base,
        "HIGH_ENTROPY_VA without DYNAMIC_BASE"
    );
    let reserve = u64_at(b, opt + 72).unwrap();
    let commit = u64_at(b, opt + 80).unwrap();
    check!(
        commit <= reserve,
        "stack commit {commit:#x} > reserve {reserve:#x}"
    );
    let ndirs = u32_at(b, opt + 108).unwrap() as usize;
    check!(
        ndirs == 16 && opt_size == 112 + 8 * ndirs,
        "{ndirs} data directories in {opt_size} bytes"
    );
    let ndirs = ndirs.min(16).min((opt_size - 112) / 8);
    let dir = |i: usize| -> (u32, u32) {
        if i < ndirs {
            (
                u32_at(b, opt + 112 + 8 * i).unwrap(),
                u32_at(b, opt + 116 + 8 * i).unwrap(),
            )
        } else {
            (0, 0)
        }
    };
    let table = opt + opt_size;
    check!(
        headers_size as usize >= table + 40 * nsections,
        "SizeOfHeaders {headers_size:#x} does not cover the section table"
    );
    if b.len() < table + 40 * nsections {
        bail!("section table truncated");
    }
    let sections: Vec<Section> = (0..nsections)
        .map(|i| {
            let s = table + 40 * i;
            let raw = &b[s..s + 8];
            let len = raw.iter().position(|&c| c == 0).unwrap_or(8);
            Section {
                name: String::from_utf8_lossy(&raw[..len]).into_owned(),
                virtual_size: u32_at(b, s + 8).unwrap(),
                rva: u32_at(b, s + 12).unwrap(),
                raw_size: u32_at(b, s + 16).unwrap(),
                raw_offset: u32_at(b, s + 20).unwrap(),
                flags: u32_at(b, s + 36).unwrap(),
            }
        })
        .collect();
    let mut next_rva =
        u64::from(headers_size).div_ceil(u64::from(section_align)) * u64::from(section_align);
    for s in &sections {
        let n = &s.name;
        check!(
            s.rva.is_multiple_of(section_align),
            "{n}: RVA {:#x} not section aligned",
            s.rva
        );
        check!(
            u64::from(s.rva) >= next_rva,
            "{n}: RVA {:#x} overlaps the previous section",
            s.rva
        );
        check!(
            s.raw_offset.is_multiple_of(file_align),
            "{n}: raw offset {:#x} not file aligned",
            s.raw_offset
        );
        check!(
            s.raw_size.is_multiple_of(file_align),
            "{n}: raw size {:#x} not file aligned",
            s.raw_size
        );
        check!(
            u64::from(s.raw_offset) + u64::from(s.raw_size) <= b.len() as u64,
            "{n}: raw data {:#x}+{:#x} past the end of the {}-byte file",
            s.raw_offset,
            s.raw_size,
            b.len()
        );
        check!(
            s.raw_size == 0 || s.raw_offset >= headers_size,
            "{n}: raw data overlaps the headers"
        );
        check!(s.virtual_size > 0, "{n}: empty section");
        check!(
            s.flags & (SCN_WRITE | SCN_EXECUTE) != (SCN_WRITE | SCN_EXECUTE),
            "{n}: W^X violated (characteristics {:#x})",
            s.flags
        );
        check!(s.flags & SCN_READ != 0, "{n}: not readable");
        next_rva = u64::from(s.rva)
            + u64::from(s.virtual_size).div_ceil(u64::from(section_align))
                * u64::from(section_align);
    }
    check!(
        u64::from(image_size) == next_rva,
        "SizeOfImage {image_size:#x} != end of the last section {next_rva:#x}"
    );
    let find = |rva: u32, len: u32| {
        sections.iter().find(|s| {
            rva >= s.rva
                && u64::from(rva) + u64::from(len)
                    <= u64::from(s.rva)
                        + u64::from(s.virtual_size.max(s.raw_size).min(s.virtual_size))
        })
    };
    let offset_of = |s: &Section, rva: u32| -> Option<usize> {
        let delta = rva - s.rva;
        (delta < s.raw_size).then(|| (s.raw_offset + delta) as usize)
    };
    match find(entry, 1) {
        None => errors.push(format!("entry RVA {entry:#x} outside every section")),
        Some(s) => check!(
            s.flags & SCN_EXECUTE != 0 && s.flags & SCN_CODE != 0,
            "entry RVA {entry:#x} in non-executable section {}",
            s.name
        ),
    }
    // Import directory.
    let mut imports = Vec::new();
    let (import_rva, import_size) = dir(1);
    if import_rva != 0 {
        match find(import_rva, import_size.max(20)) {
            None => errors.push(format!(
                "import directory {import_rva:#x} outside every section"
            )),
            Some(s) => {
                let read_name = |rva: u32| -> Option<String> {
                    let s = find(rva, 1)?;
                    let at = offset_of(s, rva)?;
                    let end = at + b.get(at..)?.iter().position(|&c| c == 0)?;
                    String::from_utf8(b[at..end].to_vec()).ok()
                };
                let mut k = 0;
                loop {
                    let Some(d) = offset_of(s, import_rva + 20 * k) else {
                        errors.push("import descriptor table runs past its section".into());
                        break;
                    };
                    let Some(row) = b.get(d..d + 20) else {
                        errors.push("import descriptor truncated".into());
                        break;
                    };
                    if row.iter().all(|&x| x == 0) {
                        break;
                    }
                    let ilt = u32_at(b, d).unwrap();
                    let name_rva = u32_at(b, d + 12).unwrap();
                    let iat = u32_at(b, d + 16).unwrap();
                    let dll_name = read_name(name_rva).unwrap_or_else(|| {
                        errors.push(format!("import DLL name at {name_rva:#x} unreadable"));
                        String::new()
                    });
                    check!(
                        dll_name.eq_ignore_ascii_case("KERNEL32.dll"),
                        "imports from {dll_name:?}, only KERNEL32.dll is expected"
                    );
                    let mut lists = Vec::new();
                    for (label, table) in [("ILT", ilt), ("IAT", iat)] {
                        let mut names = Vec::new();
                        for slot in 0..4096u32 {
                            let entry = find(table + 8 * slot, 8)
                                .and_then(|s| offset_of(s, table + 8 * slot))
                                .and_then(|at| u64_at(b, at));
                            let Some(entry) = entry else {
                                errors.push(format!(
                                    "{label} of {dll_name} at {table:#x} unreadable"
                                ));
                                break;
                            };
                            if entry == 0 {
                                break;
                            }
                            if entry >> 63 != 0 {
                                errors.push(format!("{label} imports ordinal {}", entry & 0xffff));
                                continue;
                            }
                            match read_name(entry as u32 + 2) {
                                Some(n) => names.push(n),
                                None => {
                                    errors.push(format!("{label} hint/name {entry:#x} unreadable"))
                                }
                            }
                        }
                        lists.push(names);
                    }
                    check!(
                        lists[0] == lists[1],
                        "ILT {:?} and IAT {:?} differ",
                        lists[0],
                        lists[1]
                    );
                    for n in &lists[0] {
                        check!(
                            ALLOWED_KERNEL32.contains(&n.as_str()),
                            "unexpected import {dll_name}!{n}"
                        );
                    }
                    if let Some(iat_section) = find(iat, 8) {
                        check!(
                            iat_section.flags & SCN_EXECUTE == 0,
                            "IAT lives in executable section {}",
                            iat_section.name
                        );
                    }
                    imports.push((dll_name, lists.swap_remove(0)));
                    k += 1;
                }
            }
        }
    }
    // Base relocations.
    let mut relocs = Vec::new();
    let (reloc_rva, reloc_size) = dir(5);
    check!(
        !dynamic_base || reloc_rva != 0,
        "DYNAMIC_BASE without a base relocation directory"
    );
    if reloc_rva != 0 {
        match find(reloc_rva, reloc_size) {
            None => errors.push(format!(
                "relocation directory {reloc_rva:#x}+{reloc_size:#x} outside every section"
            )),
            Some(s) => {
                check!(
                    s.flags & SCN_EXECUTE == 0,
                    ".reloc data in executable section {}",
                    s.name
                );
                let mut at = reloc_rva;
                let end = reloc_rva + reloc_size;
                let mut last_page: Option<u32> = None;
                while at < end {
                    let Some(o) = offset_of(s, at) else {
                        errors.push(format!("relocation block at {at:#x} has no file data"));
                        break;
                    };
                    let (Some(page), Some(block)) = (u32_at(b, o), u32_at(b, o + 4)) else {
                        errors.push("relocation block header truncated".into());
                        break;
                    };
                    if block < 8 || !block.is_multiple_of(4) || at + block > end {
                        errors.push(format!(
                            "relocation block at {at:#x} has invalid size {block}"
                        ));
                        break;
                    }
                    check!(
                        page.is_multiple_of(0x1000),
                        "relocation page {page:#x} not 4 KiB aligned"
                    );
                    check!(
                        last_page.is_none_or(|p| page > p),
                        "relocation pages not increasing"
                    );
                    last_page = Some(page);
                    for k in (8..block).step_by(2) {
                        let e = u16_at(b, o + k as usize).unwrap_or(0);
                        match e >> 12 {
                            0 => check!(e == 0, "ABSOLUTE relocation entry {e:#x} with an offset"),
                            10 => {
                                let target = page + u32::from(e & 0xfff);
                                match find(target, 8) {
                                    None => errors.push(format!(
                                        "DIR64 target {target:#x} outside every section"
                                    )),
                                    Some(t) => {
                                        let value = offset_of(t, target).and_then(|x| u64_at(b, x));
                                        check!(
                                            value.is_some_and(|v| v >= image_base
                                                && v < image_base + u64::from(image_size)),
                                            "DIR64 at {target:#x} holds {value:x?}, not an address of the image"
                                        );
                                    }
                                }
                                relocs.push(target);
                            }
                            kind => {
                                errors.push(format!("relocation type {kind} at page {page:#x}"))
                            }
                        }
                    }
                    at += block;
                }
                let mut sorted = relocs.clone();
                sorted.sort_unstable();
                check!(
                    sorted.windows(2).all(|w| w[1] >= w[0] + 8),
                    "overlapping DIR64 relocations"
                );
            }
        }
    }
    if errors.is_empty() {
        Ok(Pe {
            entry,
            sections,
            imports,
            relocs,
            dynamic_base,
        })
    } else {
        Err(errors)
    }
}

// ------------------------------------------------------------ SHA-256 ---

/// FIPS 180-4 SHA-256, lowercase hex.
pub fn sha256(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[4 * i..4 * i + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [
                t1.wrapping_add(t2),
                v[0],
                v[1],
                v[2],
                v[3].wrapping_add(t1),
                v[4],
                v[5],
                v[6],
            ];
        }
        for (x, y) in h.iter_mut().zip(v) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

// ---------------------------------------------------------- execution ---

/// Outcome of running an ELF64 image.
#[derive(Debug)]
pub struct Run {
    /// Exit status when the process exited normally.
    pub code: Option<i32>,
    /// Name of the signal that killed the process (e.g. `SIGSEGV`).
    pub signal: Option<String>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Syscall names in order (only with `strace`), `execve` included.
    pub syscalls: Vec<String>,
}

pub enum Exec {
    Ran(Run),
    NotRun(String),
}

/// Prints an explicit NOT RUN line for `what` and fails when
/// `ELE_REQUIRE_NATIVE_EXEC=1`.
pub fn not_run(what: &str, reason: &str) {
    use std::io::Write;
    let _ = writeln!(std::io::stderr(), "NOT RUN[native-exec] {what}: {reason}");
    assert!(
        std::env::var_os(REQUIRE_NATIVE_EXEC).is_none_or(|v| v != "1"),
        "{REQUIRE_NATIVE_EXEC}=1 but {what} could not be executed: {reason}"
    );
}

fn to_wsl_path(dir: &Path) -> String {
    let canonical = dir.canonicalize().unwrap();
    let windows = canonical
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .replace('\\', "/");
    let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
    format!("/mnt/{}/{rest}", drive.to_ascii_lowercase())
}

/// Runs `image` with `args` in a fresh `dir`. With `trace`, the run happens
/// under `strace -f` and the syscall names are collected; a host without
/// strace returns `NotRun`.
pub fn run_elf(image: &Path, dir: &Path, args: &[&str], trace: bool) -> Exec {
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir).unwrap();
    fs::copy(image, dir.join("prog")).unwrap();
    // The script reports the outcome through files so that no shell or WSL
    // layer can reinterpret the status; strace writes the kill signal.
    let script = "cd \"$1\" || exit 90\nshift\nchmod 700 prog\n\
        if [ \"$ELE_TRACE\" = 1 ]; then\n\
          command -v strace >/dev/null 2>&1 || { echo nostrace > outcome; exit 0; }\n\
          strace -f -o trace.txt ./prog \"$@\" > out.txt 2> err.txt\n\
        else\n\
          ./prog \"$@\" > out.txt 2> err.txt\n\
        fi\n\
        echo \"status $?\" > outcome\n";
    fs::write(dir.join("run.sh"), script).unwrap();
    let trace_flag = if trace { "1" } else { "0" };
    let status = if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Command::new("sh")
            .arg(dir.join("run.sh"))
            .arg(dir)
            .args(args)
            .env("ELE_TRACE", trace_flag)
            .status()
    } else if cfg!(windows) {
        let Ok(distro) = std::env::var(WSL_DISTRO) else {
            return Exec::NotRun(format!(
                "this host is not Linux x86-64 and {WSL_DISTRO} is not set (e.g. {WSL_DISTRO}=Ubuntu)"
            ));
        };
        let linux = to_wsl_path(dir);
        Command::new("wsl")
            .args([
                "-d",
                &distro,
                "--exec",
                "env",
                &format!("ELE_TRACE={trace_flag}"),
                "sh",
            ])
            .arg(format!("{linux}/run.sh"))
            .arg(&linux)
            .args(args)
            .status()
    } else {
        return Exec::NotRun("this host can neither run ELF64 x86-64 nor reach WSL".into());
    };
    match status {
        Ok(s) if s.success() => {}
        Ok(s) => return Exec::NotRun(format!("runner script failed with {s}")),
        Err(e) => return Exec::NotRun(format!("cannot start the runner: {e}")),
    }
    let outcome = fs::read_to_string(dir.join("outcome")).unwrap_or_default();
    if outcome.trim() == "nostrace" {
        return Exec::NotRun("strace is not installed on the execution host".into());
    }
    let Some(shell_status) = outcome
        .trim()
        .strip_prefix("status ")
        .and_then(|s| s.parse::<i32>().ok())
    else {
        return Exec::NotRun(format!("runner produced no status ({outcome:?})"));
    };
    let mut run = Run {
        code: None,
        signal: None,
        stdout: fs::read(dir.join("out.txt")).unwrap_or_default(),
        stderr: fs::read(dir.join("err.txt")).unwrap_or_default(),
        syscalls: Vec::new(),
    };
    if trace {
        let text = fs::read_to_string(dir.join("trace.txt")).unwrap_or_default();
        for line in text.lines() {
            // "<pid>  name(args) = r", "+++ exited with N +++",
            // "+++ killed by SIGSEGV +++", "--- SIGSEGV {...} ---".
            let body = line
                .split_once(' ')
                .map_or(line, |(_, rest)| rest)
                .trim_start();
            if let Some(rest) = body.strip_prefix("+++ exited with ") {
                run.code = rest.trim_end_matches(" +++").trim().parse().ok();
            } else if let Some(rest) = body.strip_prefix("+++ killed by ") {
                run.signal = Some(rest.split_whitespace().next().unwrap_or("").to_string());
            } else if let Some((name, _)) = body.split_once('(')
                && !name.is_empty()
                && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
            {
                run.syscalls.push(name.to_string());
            }
        }
        if run.code.is_none() && run.signal.is_none() {
            return Exec::NotRun(format!(
                "strace recorded no exit (shell status {shell_status})"
            ));
        }
    } else if shell_status > 128 {
        run.signal = Some(format!("signal {}", shell_status - 128));
    } else {
        run.code = Some(shell_status);
    }
    Exec::Ran(run)
}

/// Syscalls the ELE Linux runtime is allowed to make (codegen/native_rt*.l,
/// native_rt_platform.l, native_list_int.l): `execve` is strace's own record
/// of the program start. The second row is the safe publication of
/// `writeBytes` (getrandom nonce, stat + fchmod to keep the destination's
/// mode, fsync, rename, unlink of the temporary on failure) and `sameFile`
/// (lstat), present since PR #140; every other syscall is still a violation.
pub const ALLOWED_SYSCALLS: [&str; 17] = [
    "execve",
    "read",
    "write",
    "open",
    "close",
    "fstat",
    "mmap",
    "munmap",
    "mremap",
    "exit",
    "getrandom",
    "stat",
    "lstat",
    "fchmod",
    "fsync",
    "rename",
    "unlink",
];

/// Scratch directory under `target/stage1-tests/<group>`.
pub fn scratch(group: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests")
        .join(group);
    fs::create_dir_all(&dir).unwrap();
    dir
}
