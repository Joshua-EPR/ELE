// Minimal Linux ELF64/x86-64 executable emitter written in ELE.
// One RX PT_LOAD segment, no libc, linker, dynamic loader, section table or
// relocations. The code must implement a syscall-based entry point itself.
// This is a bootstrap proof of direct binary-format emission, not a full ELF
// object writer or a substitute for the Windows PE backend.

const ELF64_CODE_OFFSET = 4096
const ELF64_LOAD_ADDRESS = 4194304
const ELF64_MAX_CODE = 1048576

fn elfPut(out: &mut List<Int>, b: Int) {
    out.push(b)
}

fn elfLittle(out: &mut List<Int>, n: Int, width: Int) {
    var x = n
    for i in 0..width {
        elfPut(&mut out, x % 256)
        x = x / 256
    }
}

// Virtual address of the first code byte: fixups of absolute addresses
// inside the image are relative to it.
pub fn elf64CodeAddress() -> Int {
    return ELF64_LOAD_ADDRESS + ELF64_CODE_OFFSET
}

// Return an empty buffer for unsupported / unrepresentable inputs.
pub fn elf64Executable(code: &List<Int>) -> List<Int> {
    return elf64ExecutableData(code, 0)
}

fn elfPageUp(n: Int) -> Int {
    return (n + 4095) / 4096 * 4096
}

// Virtual address of the read-write data area that follows a code segment
// of `code_length` bytes: the first page boundary after it.
pub fn elf64DataAddress(code_length: Int) -> Int {
    return ELF64_LOAD_ADDRESS + elfPageUp(ELF64_CODE_OFFSET + code_length)
}

// `data_pages` > 0 adds a second PT_LOAD segment, read-write and never
// executable, of that many zero-filled pages at elf64DataAddress. The pages
// are stored in the file (no bss), so every kernel maps them the same way.
// With 0 the image is byte-identical to the historical single-segment one.
pub fn elf64ExecutableData(code: &List<Int>, data_pages: Int) -> List<Int> {
    var out: List<Int> = List[]
    if code.length == 0 || code.length > ELF64_MAX_CODE { return out }
    if data_pages < 0 || data_pages > 16 { return out }
    // The owned output buffer must not escape from inside the loop: the
    // ownership checker conservatively prohibits moving an outer local there.
    var valid_bytes = true
    for i in 0..code.length {
        if code[i] < 0 || code[i] > 255 { valid_bytes = false }
    }
    if !valid_bytes { return out }
    let total = ELF64_CODE_OFFSET + code.length

    // ELF identification (16 bytes): magic, 64-bit, little-endian, v1, SYSV.
    elfPut(&mut out, 127)
    elfPut(&mut out, 69)
    elfPut(&mut out, 76)
    elfPut(&mut out, 70)
    elfPut(&mut out, 2)
    elfPut(&mut out, 1)
    elfPut(&mut out, 1)
    for i in 0..9 { elfPut(&mut out, 0) }

    // ELF header, 64 bytes total.
    elfLittle(&mut out, 2, 2)                    // ET_EXEC
    elfLittle(&mut out, 62, 2)                   // EM_X86_64
    elfLittle(&mut out, 1, 4)                    // EV_CURRENT
    elfLittle(&mut out, ELF64_LOAD_ADDRESS + ELF64_CODE_OFFSET, 8)
    elfLittle(&mut out, 64, 8)                   // e_phoff
    elfLittle(&mut out, 0, 8)                    // e_shoff
    elfLittle(&mut out, 0, 4)                    // flags
    elfLittle(&mut out, 64, 2)                   // e_ehsize
    elfLittle(&mut out, 56, 2)                   // e_phentsize
    var phnum = 1
    if data_pages > 0 { phnum = 2 }
    elfLittle(&mut out, phnum, 2)                // e_phnum
    elfLittle(&mut out, 0, 2)                    // e_shentsize
    elfLittle(&mut out, 0, 2)                    // e_shnum
    elfLittle(&mut out, 0, 2)                    // e_shstrndx

    // Single program header: PT_LOAD, RX, page-aligned.
    elfLittle(&mut out, 1, 4)                    // p_type
    elfLittle(&mut out, 5, 4)                    // p_flags: R + X
    elfLittle(&mut out, 0, 8)                    // p_offset
    elfLittle(&mut out, ELF64_LOAD_ADDRESS, 8)   // p_vaddr
    elfLittle(&mut out, ELF64_LOAD_ADDRESS, 8)   // p_paddr
    elfLittle(&mut out, total, 8)                // p_filesz
    elfLittle(&mut out, total, 8)                // p_memsz
    elfLittle(&mut out, ELF64_CODE_OFFSET, 8)    // p_align

    // Data segment: PT_LOAD, R + W (never X), its file offset congruent to
    // its address modulo the page size.
    let data_offset = elfPageUp(total)
    let data_size = data_pages * 4096
    if data_pages > 0 {
        elfLittle(&mut out, 1, 4)                // p_type
        elfLittle(&mut out, 6, 4)                // p_flags: R + W
        elfLittle(&mut out, data_offset, 8)      // p_offset
        elfLittle(&mut out, ELF64_LOAD_ADDRESS + data_offset, 8)
        elfLittle(&mut out, ELF64_LOAD_ADDRESS + data_offset, 8)
        elfLittle(&mut out, data_size, 8)        // p_filesz
        elfLittle(&mut out, data_size, 8)        // p_memsz
        elfLittle(&mut out, ELF64_CODE_OFFSET, 8)
    }

    while out.length < ELF64_CODE_OFFSET { elfPut(&mut out, 0) }
    for i in 0..code.length { elfPut(&mut out, code[i]) }
    if data_pages > 0 {
        while out.length < data_offset + data_size { elfPut(&mut out, 0) }
    }
    return out
}

fn elfNibble(n: Int) -> Text {
    if n == 0 { return "0" } if n == 1 { return "1" }
    if n == 2 { return "2" } if n == 3 { return "3" }
    if n == 4 { return "4" } if n == 5 { return "5" }
    if n == 6 { return "6" } if n == 7 { return "7" }
    if n == 8 { return "8" } if n == 9 { return "9" }
    if n == 10 { return "a" } if n == 11 { return "b" }
    if n == 12 { return "c" } if n == 13 { return "d" }
    if n == 14 { return "e" }
    return "f"
}

// Temporary transport for environments without writeBytes(path, bytes).
// Avoid a permanent hex conversion by implementing binary I/O in ELE later.
pub fn elf64Hex(bytes: &List<Int>) -> Text {
    var result = ""
    for i in 0..bytes.length {
        let b = bytes[i]
        if b < 0 || b > 255 { return "" }
        let high = elfNibble(b / 16)
        let low = elfNibble(b % 16)
        result = "{result}{high}{low}"
    }
    return result
}
