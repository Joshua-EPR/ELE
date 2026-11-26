// ELF64 image for `--target kernel`: an ET_EXEC executable in the higher
// half (Limine loads it as is), with no system calls, interpreter or
// relocations.
//
//   offset 0          ELF header + program headers (not loaded)
//   offset 0x1000     .text   R+X  at KERNEL_BASE + 0x1000 (entry stub first)
//   next page         .rodata R    (Text literals and `cadena` records)
//   next page         .data   R+W  (`datos64`), then on the next page
//                     .bss    R+W  (`reservar`, zero-filled, not in the file)
//   then              .symtab, .strtab, .shstrtab and the section headers,
//                     not loaded: one FUNC symbol per flow, so GDB,
//                     objdump and QEMU logs show flow names.
//
// Every segment keeps p_vaddr = KERNEL_BASE + p_offset, so a file offset
// and its address differ by the same constant everywhere. A segment with
// nothing in it is left out.

// 0xFFFFFFFF80000000 (top 2 GiB) as a two's complement Int.
fixed ELF64K_BASE = -2147483648
fixed ELF64K_TEXT_OFFSET = 4096
fixed ELF64K_MAX_CODE = 33554432
fixed ELF64K_MAX_BSS = 1073741824

expose flow elf64KernelTextAddress() => Int {
    give ELF64K_BASE + ELF64K_TEXT_OFFSET
}

flow elfkPageUp(n: Int) => Int {
    give (n + 4095) / 4096 * 4096
}

flow elfkRodataOffset(text_length: Int) => Int {
    give elfkPageUp(ELF64K_TEXT_OFFSET + text_length)
}

flow elfkDataOffset(text_length: Int, rodata_length: Int) => Int {
    give elfkPageUp(elfkRodataOffset(text_length) + rodata_length)
}

flow elfkBssOffset(text_length: Int, rodata_length: Int, data_length: Int) => Int {
    give elfkPageUp(elfkDataOffset(text_length, rodata_length) + data_length)
}

// Address of the first .rodata byte for a .text of `text_length` bytes.
expose flow elf64KernelRodataAddress(text_length: Int) => Int {
    give ELF64K_BASE + elfkRodataOffset(text_length)
}

expose flow elf64KernelDataAddress(text_length: Int, rodata_length: Int) => Int {
    give ELF64K_BASE + elfkDataOffset(text_length, rodata_length)
}

expose flow elf64KernelBssAddress(text_length: Int, rodata_length: Int, data_length: Int) => Int {
    give ELF64K_BASE + elfkBssOffset(text_length, rodata_length, data_length)
}

// Little-endian, any Int (negative values as two's complement).
flow elfkLittle(out: edit List of[Int], n: Int, width: Int) {
    change x = n
    each i among 0..width {
        change b = x % 256
        when b < 0 { b += 256 }
        out@push(b)
        x = (x - b) / 256
    }
}

flow elfkPad(out: edit List of[Int], size: Int) {
    during out.length < size { out@push(0) }
}

flow elfkText(out: edit List of[Int], value: view Text) {
    each i among 0..value.byteLength { out@push(value@byteAt(i)) }
    out@push(0)
}

flow elfkSection(out: edit List of[Int], name: Int, kind: Int, flags: Int, address: Int, offset: Int, size: Int, link: Int, info: Int, align: Int, entsize: Int) {
    elfkLittle(edit out, name, 4)
    elfkLittle(edit out, kind, 4)
    elfkLittle(edit out, flags, 8)
    elfkLittle(edit out, address, 8)
    elfkLittle(edit out, offset, 8)
    elfkLittle(edit out, size, 8)
    elfkLittle(edit out, link, 4)
    elfkLittle(edit out, info, 4)
    elfkLittle(edit out, align, 8)
    elfkLittle(edit out, entsize, 8)
}

flow elfkSegment(out: edit List of[Int], flags: Int, offset: Int, file_size: Int, memory_size: Int) {
    elfkLittle(edit out, 1, 4)                   // PT_LOAD
    elfkLittle(edit out, flags, 4)
    elfkLittle(edit out, offset, 8)
    elfkLittle(edit out, ELF64K_BASE + offset, 8)
    elfkLittle(edit out, ELF64K_BASE + offset, 8)
    elfkLittle(edit out, file_size, 8)
    elfkLittle(edit out, memory_size, 8)
    elfkLittle(edit out, 4096, 8)
}

flow elfkBytesOk(bytes: view List of[Int]) => Bool {
    each i among 0..bytes.length {
        when bytes[i] < 0 || bytes[i] > 255 { give false }
    }
    give true
}

// `names` holds the NUL-free name bytes of every symbol back to back;
// symbol k is names[name_start[k] .. name_start[k] + name_length[k]),
// at .text offset sym_start[k] with sym_size[k] bytes. An empty list is
// returned for unrepresentable input (the caller reports it).
expose flow elf64KernelImage(text: view List of[Int], rodata: view List of[Int], data: view List of[Int], bss_size: Int, names: view List of[Int], name_start: view List of[Int], name_length: view List of[Int], sym_start: view List of[Int], sym_size: view List of[Int]) => List of[Int] {
    change out: List of[Int] = List[]
    when text.length == 0 || text.length > ELF64K_MAX_CODE || rodata.length > ELF64K_MAX_CODE || data.length > ELF64K_MAX_CODE { give out }
    when bss_size < 0 || bss_size > ELF64K_MAX_BSS { give out }
    hold symbols = name_start.length
    when name_length.length != symbols || sym_start.length != symbols || sym_size.length != symbols { give out }
    change valid = elfkBytesOk(text) && elfkBytesOk(rodata) && elfkBytesOk(data)
    each k among 0..symbols {
        when name_start[k] < 0 || name_length[k] < 1 || name_start[k] + name_length[k] > names.length { valid = false }
        when sym_start[k] < 0 || sym_size[k] < 0 || sym_start[k] + sym_size[k] > text.length { valid = false }
    }
    when !valid { give out }

    hold rodata_offset = elfkRodataOffset(text.length)
    hold data_offset = elfkDataOffset(text.length, rodata.length)
    hold bss_offset = elfkBssOffset(text.length, rodata.length, data.length)
    hold has_rw = data.length > 0 || bss_size > 0
    change phnum = 1
    change loaded_end = ELF64K_TEXT_OFFSET + text.length
    when rodata.length > 0 {
        phnum += 1
        loaded_end = rodata_offset + rodata.length
    }
    change rw_memory = data.length
    when bss_size > 0 { rw_memory = bss_offset - data_offset + bss_size }
    when has_rw {
        phnum += 1
        when data.length > 0 { loaded_end = data_offset + data.length }
    }
    hold symtab_offset = (loaded_end + 7) / 8 * 8
    hold symtab_size = 24 * (symbols + 1)
    hold strtab_offset = symtab_offset + symtab_size
    change strtab_size = 1
    each k among 0..symbols { strtab_size += name_length[k] + 1 }
    hold shstrtab_offset = strtab_offset + strtab_size
    hold shstrtab_size = 52
    hold sections_offset = (shstrtab_offset + shstrtab_size + 7) / 8 * 8

    // ELF identification: magic, 64-bit, little-endian, v1, SYSV.
    out@push(127)
    out@push(69)
    out@push(76)
    out@push(70)
    out@push(2)
    out@push(1)
    out@push(1)
    elfkPad(edit out, 16)
    elfkLittle(edit out, 2, 2)                   // ET_EXEC
    elfkLittle(edit out, 62, 2)                  // EM_X86_64
    elfkLittle(edit out, 1, 4)                   // EV_CURRENT
    elfkLittle(edit out, ELF64K_BASE + ELF64K_TEXT_OFFSET, 8)
    elfkLittle(edit out, 64, 8)                  // e_phoff
    elfkLittle(edit out, sections_offset, 8)     // e_shoff
    elfkLittle(edit out, 0, 4)                   // flags
    elfkLittle(edit out, 64, 2)                  // e_ehsize
    elfkLittle(edit out, 56, 2)                  // e_phentsize
    elfkLittle(edit out, phnum, 2)
    elfkLittle(edit out, 64, 2)                  // e_shentsize
    elfkLittle(edit out, 8, 2)                   // e_shnum
    elfkLittle(edit out, 7, 2)                   // e_shstrndx

    elfkSegment(edit out, 5, ELF64K_TEXT_OFFSET, text.length, text.length)      // R + X
    when rodata.length > 0 {
        elfkSegment(edit out, 4, rodata_offset, rodata.length, rodata.length)   // R
    }
    when has_rw {
        elfkSegment(edit out, 6, data_offset, data.length, rw_memory)           // R + W
    }

    elfkPad(edit out, ELF64K_TEXT_OFFSET)
    each i among 0..text.length { out@push(text[i]) }
    when rodata.length > 0 {
        elfkPad(edit out, rodata_offset)
        each i among 0..rodata.length { out@push(rodata[i]) }
    }
    when data.length > 0 {
        elfkPad(edit out, data_offset)
        each i among 0..data.length { out@push(data[i]) }
    }

    // .symtab: the null symbol, then one global FUNC per flow in .text (1).
    elfkPad(edit out, symtab_offset + 24)
    change name_at = 1
    each k among 0..symbols {
        elfkLittle(edit out, name_at, 4)
        out@push(18)                             // STB_GLOBAL, STT_FUNC
        out@push(0)
        elfkLittle(edit out, 1, 2)
        elfkLittle(edit out, ELF64K_BASE + ELF64K_TEXT_OFFSET + sym_start[k], 8)
        elfkLittle(edit out, sym_size[k], 8)
        name_at += name_length[k] + 1
    }
    // .strtab
    out@push(0)
    each k among 0..symbols {
        each i among 0..name_length[k] { out@push(names[name_start[k] + i]) }
        out@push(0)
    }
    // .shstrtab: "", .text 1, .rodata 7, .symtab 15, .strtab 23,
    // .shstrtab 31, .data 41, .bss 47.
    out@push(0)
    hold n_text = ".text"
    hold n_rodata = ".rodata"
    hold n_symtab = ".symtab"
    hold n_strtab = ".strtab"
    hold n_shstrtab = ".shstrtab"
    hold n_data = ".data"
    hold n_bss = ".bss"
    elfkText(edit out, view n_text)
    elfkText(edit out, view n_rodata)
    elfkText(edit out, view n_symtab)
    elfkText(edit out, view n_strtab)
    elfkText(edit out, view n_shstrtab)
    elfkText(edit out, view n_data)
    elfkText(edit out, view n_bss)
    elfkPad(edit out, sections_offset)

    // 0 null, 1 .text, 2 .rodata, 3 .data, 4 .bss, 5 .symtab, 6 .strtab,
    // 7 .shstrtab.
    elfkSection(edit out, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    elfkSection(edit out, 1, 1, 6, ELF64K_BASE + ELF64K_TEXT_OFFSET, ELF64K_TEXT_OFFSET, text.length, 0, 0, 16, 0)
    elfkSection(edit out, 7, 1, 2, ELF64K_BASE + rodata_offset, rodata_offset, rodata.length, 0, 0, 8, 0)
    elfkSection(edit out, 41, 1, 3, ELF64K_BASE + data_offset, data_offset, data.length, 0, 0, 8, 0)
    elfkSection(edit out, 47, 8, 3, ELF64K_BASE + bss_offset, bss_offset, bss_size, 0, 0, 4096, 0)
    elfkSection(edit out, 15, 2, 0, 0, symtab_offset, symtab_size, 6, 1, 8, 24)
    elfkSection(edit out, 23, 3, 0, 0, strtab_offset, strtab_size, 0, 0, 1, 0)
    elfkSection(edit out, 31, 3, 0, 0, shstrtab_offset, shstrtab_size, 0, 0, 1, 0)
    give out
}
