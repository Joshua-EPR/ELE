// Minimal Linux ELF64/x86-64 executable emitter written in ELE.
// One RX PT_LOAD segment, no libc, linker, dynamic loader, section table or
// relocations. The code must implement a syscall-based entry point itself.
// This is a bootstrap proof of direct binary-format emission, not a full ELF
// object writer or a substitute for the Windows PE backend.

fixed ELF64_CODE_OFFSET = 4096
fixed ELF64_LOAD_ADDRESS = 4194304
fixed ELF64_MAX_CODE = 33554432

flow elfPut(out: edit List of[Int], b: Int) {
    out@push(b)
}

flow elfLittle(out: edit List of[Int], n: Int, width: Int) {
    change x = n
    each i among 0..width {
        elfPut(edit out, x % 256)
        x = x / 256
    }
}

// Virtual address of the first code byte: fixups of absolute addresses
// inside the image are relative to it.
expose flow elf64CodeAddress() => Int {
    give ELF64_LOAD_ADDRESS + ELF64_CODE_OFFSET
}

// Return an empty buffer for unsupported / unrepresentable inputs.
expose flow elf64Executable(code: view List of[Int]) => List of[Int] {
    give elf64ExecutableData(code, 0)
}

flow elfPageUp(n: Int) => Int {
    give (n + 4095) / 4096 * 4096
}

// Virtual address of the read-write data area that follows a code segment
// of `code_length` bytes: the first page boundary after it.
expose flow elf64DataAddress(code_length: Int) => Int {
    give ELF64_LOAD_ADDRESS + elfPageUp(ELF64_CODE_OFFSET + code_length)
}

// `data_pages` > 0 adds a second PT_LOAD segment, read-write and never
// executable, of that many zero-filled pages at elf64DataAddress. The pages
// are stored in the file (no bss), so every kernel maps them the same way.
// With 0 the image is byte-identical to the historical single-segment one.
expose flow elf64ExecutableData(code: view List of[Int], data_pages: Int) => List of[Int] {
    change out: List of[Int] = List[]
    when code.length == 0 || code.length > ELF64_MAX_CODE { give out }
    when data_pages < 0 || data_pages > 16 { give out }
    // The owned output buffer must not escape from inside the loop: the
    // ownership checker conservatively prohibits moving an outer local there.
    change valid_bytes = true
    each i among 0..code.length {
        when code[i] < 0 || code[i] > 255 { valid_bytes = false }
    }
    when !valid_bytes { give out }
    hold total = ELF64_CODE_OFFSET + code.length

    // ELF identification (16 bytes): magic, 64-bit, little-endian, v1, SYSV.
    elfPut(edit out, 127)
    elfPut(edit out, 69)
    elfPut(edit out, 76)
    elfPut(edit out, 70)
    elfPut(edit out, 2)
    elfPut(edit out, 1)
    elfPut(edit out, 1)
    each i among 0..9 { elfPut(edit out, 0) }

    // ELF header, 64 bytes total.
    elfLittle(edit out, 2, 2)                    // ET_EXEC
    elfLittle(edit out, 62, 2)                   // EM_X86_64
    elfLittle(edit out, 1, 4)                    // EV_CURRENT
    elfLittle(edit out, ELF64_LOAD_ADDRESS + ELF64_CODE_OFFSET, 8)
    elfLittle(edit out, 64, 8)                   // e_phoff
    elfLittle(edit out, 0, 8)                    // e_shoff
    elfLittle(edit out, 0, 4)                    // flags
    elfLittle(edit out, 64, 2)                   // e_ehsize
    elfLittle(edit out, 56, 2)                   // e_phentsize
    change phnum = 1
    when data_pages > 0 { phnum = 2 }
    elfLittle(edit out, phnum, 2)                // e_phnum
    elfLittle(edit out, 0, 2)                    // e_shentsize
    elfLittle(edit out, 0, 2)                    // e_shnum
    elfLittle(edit out, 0, 2)                    // e_shstrndx

    // Single program header: PT_LOAD, RX, page-aligned.
    elfLittle(edit out, 1, 4)                    // p_type
    elfLittle(edit out, 5, 4)                    // p_flags: R + X
    elfLittle(edit out, 0, 8)                    // p_offset
    elfLittle(edit out, ELF64_LOAD_ADDRESS, 8)   // p_vaddr
    elfLittle(edit out, ELF64_LOAD_ADDRESS, 8)   // p_paddr
    elfLittle(edit out, total, 8)                // p_filesz
    elfLittle(edit out, total, 8)                // p_memsz
    elfLittle(edit out, ELF64_CODE_OFFSET, 8)    // p_align

    // Data segment: PT_LOAD, R + W (never X), its file offset congruent to
    // its address modulo the page size.
    hold data_offset = elfPageUp(total)
    hold data_size = data_pages * 4096
    when data_pages > 0 {
        elfLittle(edit out, 1, 4)                // p_type
        elfLittle(edit out, 6, 4)                // p_flags: R + W
        elfLittle(edit out, data_offset, 8)      // p_offset
        elfLittle(edit out, ELF64_LOAD_ADDRESS + data_offset, 8)
        elfLittle(edit out, ELF64_LOAD_ADDRESS + data_offset, 8)
        elfLittle(edit out, data_size, 8)        // p_filesz
        elfLittle(edit out, data_size, 8)        // p_memsz
        elfLittle(edit out, ELF64_CODE_OFFSET, 8)
    }

    during out.length < ELF64_CODE_OFFSET { elfPut(edit out, 0) }
    each i among 0..code.length { elfPut(edit out, code[i]) }
    when data_pages > 0 {
        during out.length < data_offset + data_size { elfPut(edit out, 0) }
    }
    give out
}

flow elfNibble(n: Int) => Text {
    when n == 0 { give "0" } when n == 1 { give "1" }
    when n == 2 { give "2" } when n == 3 { give "3" }
    when n == 4 { give "4" } when n == 5 { give "5" }
    when n == 6 { give "6" } when n == 7 { give "7" }
    when n == 8 { give "8" } when n == 9 { give "9" }
    when n == 10 { give "a" } when n == 11 { give "b" }
    when n == 12 { give "c" } when n == 13 { give "d" }
    when n == 14 { give "e" }
    give "f"
}

// Temporary transport for environments without writeBytes(path, bytes).
// Avoid a permanent hex conversion by implementing binary I/O in ELE later.
expose flow elf64Hex(bytes: view List of[Int]) => Text {
    change result = ""
    each i among 0..bytes.length {
        hold b = bytes[i]
        when b < 0 || b > 255 { give "" }
        hold high = elfNibble(b / 16)
        hold low = elfNibble(b % 16)
        result = "{result}{high}{low}"
    }
    give result
}
