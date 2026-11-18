// Minimal Windows PE32+ (PE64, AMD64) executable writer, written in ELE.
// Produces a console image with two sections and no linker:
//   .text   RX  machine code followed by its read-only literals
//   .idata  RW  import directory, ILT, IAT and hint/name table of
//               KERNEL32.dll (GetStdHandle, WriteFile, ExitProcess)
// There is no relocation directory. Code that embeds absolute addresses
// (the CFG lowering does, for Text literals) needs the image at its
// preferred base, so the image declares IMAGE_FILE_RELOCS_STRIPPED and does
// NOT claim DYNAMIC_BASE (ASLR) nor HIGH_ENTROPY_VA. It does claim NX_COMPAT:
// no section is both writable and executable.
//
// Every size, offset and RVA is computed with checked arithmetic bounded by
// the 32-bit PE fields. Invalid inputs give a deterministic error and an
// empty image, never a partially written or malformed file.
//
// Errors: 1 empty code, 2 code larger than PE64_MAX_CODE, 3 byte outside
// [0,255], 4 invalid alignment, 5 size/offset overflow (does not fit a
// 32-bit PE field), 6 invalid entry point, 7 invalid import fixup.

const PE64_IMAGE_BASE = 5368709120
const PE64_SECTION_ALIGN = 4096
const PE64_FILE_ALIGN = 512
const PE64_MAX_CODE = 16777216
const PE64_DWORD_MAX = 4294967295
const PE64_DOS_SIZE = 128
// DOS area + "PE\0\0" + COFF header + PE32+ optional header + 2 sections.
const PE64_HEADERS_END = 472
const PE64_IMPORT_COUNT = 3

// Indexes of the imported functions (their IAT slots).
expose flow pe64ImportGetStdHandle() => Int { give 0 }
expose flow pe64ImportWriteFile() => Int { give 1 }
expose flow pe64ImportExitProcess() => Int { give 2 }

// Places in the code where a CALL [RIP+disp32] must reach IAT slot `index`.
expose shape Pe64Imports {
    at: List of[Int]
    index: List of[Int]
}

expose shape Pe64Image {
    bytes: List of[Int]
    error: Int
}

expose shape Pe64Layout {
    error: Int
    headers_size: Int
    text_rva: Int
    text_offset: Int
    text_raw: Int
    idata_rva: Int
    idata_offset: Int
    idata_raw: Int
    image_size: Int
    file_size: Int
}

expose flow pe64NewImports() => Pe64Imports {
    give Pe64Imports(at: List[], index: List[])
}

// Virtual address of the first .text byte with the default layout: fixups
// of absolute addresses inside the image are relative to it.
expose flow pe64CodeAddress() => Int {
    give PE64_IMAGE_BASE + PE64_SECTION_ALIGN
}

flow peImportName(index: Int) => Text {
    when index == 0 { give "GetStdHandle" }
    when index == 1 { give "WriteFile" }
    give "ExitProcess"
}

flow peDllName() => Text {
    give "KERNEL32.dll"
}

// a + b, or -1 when either is negative or the sum leaves a DWORD.
flow peAdd(a: Int, b: Int) => Int {
    when a < 0 || b < 0 { give -1 }
    when a > PE64_DWORD_MAX - b { give -1 }
    give a + b
}

// `value` rounded up to a multiple of `align` (a power of two), or -1.
flow peAlign(value: Int, align: Int) => Int {
    when value < 0 || align <= 0 { give -1 }
    hold padded = peAdd(value, align - 1)
    when padded < 0 { give -1 }
    give padded - padded % align
}

flow pePowerOfTwo(n: Int) => Bool {
    when n <= 0 { give false }
    change x = n
    during x % 2 == 0 { x = x / 2 }
    give x == 1
}

// Section/file alignment rules accepted by this writer: both powers of two,
// 512 <= file <= 64 KiB, page-sized or larger sections, section >= file,
// and both representable in their DWORD fields.
expose flow pe64AlignmentError(section_align: Int, file_align: Int) => Int {
    when !pePowerOfTwo(section_align) || !pePowerOfTwo(file_align) { give 4 }
    when file_align < 512 || file_align > 65536 { give 4 }
    when section_align < 4096 || section_align > 2147483648 { give 4 }
    when section_align < file_align { give 4 }
    give 0
}

flow peLayoutFail(code: Int) => Pe64Layout {
    give Pe64Layout(error: code, headers_size: 0, text_rva: 0, text_offset: 0, text_raw: 0, idata_rva: 0, idata_offset: 0, idata_raw: 0, image_size: 0, file_size: 0)
}

// File and memory layout of headers, .text (`code_length` bytes) and
// .idata (`idata_length` bytes). Checks every intermediate value.
expose flow pe64Layout(code_length: Int, idata_length: Int, section_align: Int, file_align: Int) => Pe64Layout {
    when code_length <= 0 { give peLayoutFail(1) }
    when code_length > PE64_MAX_CODE { give peLayoutFail(2) }
    when idata_length <= 0 { give peLayoutFail(5) }
    hold bad_alignment = pe64AlignmentError(section_align, file_align)
    when bad_alignment != 0 { give peLayoutFail(bad_alignment) }
    hold headers = peAlign(PE64_HEADERS_END, file_align)
    hold text_rva = peAlign(headers, section_align)
    hold text_raw = peAlign(code_length, file_align)
    hold text_span = peAlign(code_length, section_align)
    hold idata_rva = peAdd(text_rva, text_span)
    hold idata_offset = peAdd(headers, text_raw)
    hold idata_raw = peAlign(idata_length, file_align)
    hold idata_span = peAlign(idata_length, section_align)
    hold image_size = peAdd(idata_rva, idata_span)
    hold file_size = peAdd(idata_offset, idata_raw)
    when headers < 0 || text_rva < 0 || text_raw < 0 || text_span < 0 { give peLayoutFail(5) }
    when idata_rva < 0 || idata_offset < 0 || idata_raw < 0 || idata_span < 0 { give peLayoutFail(5) }
    when image_size < 0 || file_size < 0 { give peLayoutFail(5) }
    give Pe64Layout(error: 0, headers_size: headers, text_rva: text_rva, text_offset: headers, text_raw: text_raw, idata_rva: idata_rva, idata_offset: idata_offset, idata_raw: idata_raw, image_size: image_size, file_size: file_size)
}

flow pePut(out: edit List of[Int], b: Int) {
    out@push(b)
}

flow peLittle(out: edit List of[Int], n: Int, width: Int) {
    change x = n
    each i among 0..width {
        pePut(edit out, x % 256)
        x = x / 256
    }
}

flow peAscii(out: edit List of[Int], text: view Text) {
    each i among 0..text.byteLength {
        pePut(edit out, text.byteAt(i))
    }
}

flow peZeros(out: edit List of[Int], count: Int) {
    each i among 0..count { pePut(edit out, 0) }
}

flow pePadTo(out: edit List of[Int], size: Int) {
    during out.length < size { pePut(edit out, 0) }
}

// .idata offsets: 2 import descriptors (KERNEL32 + terminator), ILT, IAT,
// DLL name and one hint/name entry per import, each 2-byte aligned.
flow peIltOffset() => Int { give 40 }
flow peIatOffset() => Int { give 40 + (PE64_IMPORT_COUNT + 1) * 8 }
flow peDllNameOffset() => Int { give 40 + 2 * (PE64_IMPORT_COUNT + 1) * 8 }

flow peEven(n: Int) => Int {
    give n + n % 2
}

flow peHintNameOffset(index: Int) => Int {
    hold dll = peDllName()
    change at = peEven(peDllNameOffset() + dll.byteLength + 1)
    each i among 0..index {
        hold name = peImportName(i)
        at = peEven(at + 2 + name.byteLength + 1)
    }
    give at
}

expose flow pe64IdataLength() => Int {
    give peHintNameOffset(PE64_IMPORT_COUNT)
}

// RVA of the IAT slot of import `index` in an image laid out as `layout`.
expose flow pe64IatSlotRva(layout: view Pe64Layout, index: Int) => Int {
    give layout.idata_rva + peIatOffset() + 8 * index
}

flow peIdata(rva: Int) => List of[Int] {
    change out: List of[Int] = List[]
    // IMAGE_IMPORT_DESCRIPTOR for KERNEL32.dll.
    peLittle(edit out, rva + peIltOffset(), 4)    // OriginalFirstThunk (ILT)
    peLittle(edit out, 0, 4)                      // TimeDateStamp
    peLittle(edit out, 0, 4)                      // ForwarderChain
    peLittle(edit out, rva + peDllNameOffset(), 4) // Name
    peLittle(edit out, rva + peIatOffset(), 4)    // FirstThunk (IAT)
    peZeros(edit out, 20)                         // terminator descriptor
    // ILT and IAT start identical: RVAs of the hint/name entries; the loader
    // overwrites the IAT with the resolved addresses.
    each table among 0..2 {
        each i among 0..PE64_IMPORT_COUNT {
            peLittle(edit out, rva + peHintNameOffset(i), 8)
        }
        peLittle(edit out, 0, 8)
    }
    hold dll = peDllName()
    peAscii(edit out, view dll)
    pePut(edit out, 0)
    pePadTo(edit out, peHintNameOffset(0))
    each i among 0..PE64_IMPORT_COUNT {
        peLittle(edit out, 0, 2)                  // hint: none, bind by name
        hold name = peImportName(i)
        peAscii(edit out, view name)
        pePut(edit out, 0)
        pePadTo(edit out, peHintNameOffset(i + 1))
    }
    give out
}

// The classic 16-bit stub: prints a notice and exits when run under DOS.
flow peDosStub(out: edit List of[Int]) {
    peLittle(edit out, 23117, 2)   // e_magic "MZ"
    peLittle(edit out, 144, 2)     // e_cblp
    peLittle(edit out, 3, 2)       // e_cp
    peLittle(edit out, 0, 2)       // e_crlc
    peLittle(edit out, 4, 2)       // e_cparhdr
    peLittle(edit out, 0, 2)       // e_minalloc
    peLittle(edit out, 65535, 2)   // e_maxalloc
    peLittle(edit out, 0, 2)       // e_ss
    peLittle(edit out, 184, 2)     // e_sp
    peLittle(edit out, 0, 2)       // e_csum
    peLittle(edit out, 0, 2)       // e_ip
    peLittle(edit out, 0, 2)       // e_cs
    peLittle(edit out, 64, 2)      // e_lfarlc
    peLittle(edit out, 0, 2)       // e_ovno
    peZeros(edit out, 32)          // e_res, e_oemid, e_oeminfo, e_res2
    peLittle(edit out, PE64_DOS_SIZE, 4) // e_lfanew
    // push cs; pop ds; mov dx,0Eh; mov ah,9; int 21h; mov ax,4C01h; int 21h
    hold stub: List of[Int] = List[14, 31, 186, 14, 0, 180, 9, 205, 33, 184, 1, 76, 205, 33]
    each i among 0..stub.length { pePut(edit out, stub[i]) }
    hold notice = "This program cannot be run in DOS mode."
    peAscii(edit out, view notice)
    pePut(edit out, 13)
    pePut(edit out, 13)
    pePut(edit out, 10)
    pePut(edit out, 36)
    pePadTo(edit out, PE64_DOS_SIZE)
}

flow peSectionHeader(out: edit List of[Int], name: view Text, virtual_size: Int, rva: Int, raw_size: Int, raw_offset: Int, flags: Int) {
    peAscii(edit out, name)
    peZeros(edit out, 8 - name.byteLength)
    peLittle(edit out, virtual_size, 4)
    peLittle(edit out, rva, 4)
    peLittle(edit out, raw_size, 4)
    peLittle(edit out, raw_offset, 4)
    peLittle(edit out, 0, 4)                // PointerToRelocations
    peLittle(edit out, 0, 4)                // PointerToLinenumbers
    peLittle(edit out, 0, 2)                // NumberOfRelocations
    peLittle(edit out, 0, 2)                // NumberOfLinenumbers
    peLittle(edit out, flags, 4)
}

flow peHeaders(out: edit List of[Int], layout: view Pe64Layout, code_length: Int, idata_length: Int, entry: Int, section_align: Int, file_align: Int) {
    peDosStub(edit out)
    hold signature = "PE"
    peAscii(edit out, view signature)
    peZeros(edit out, 2)
    // COFF file header.
    peLittle(edit out, 34404, 2)            // Machine: AMD64 (0x8664)
    peLittle(edit out, 2, 2)                // NumberOfSections
    peLittle(edit out, 0, 4)                // TimeDateStamp: reproducible
    peLittle(edit out, 0, 4)                // PointerToSymbolTable
    peLittle(edit out, 0, 4)                // NumberOfSymbols
    peLittle(edit out, 240, 2)              // SizeOfOptionalHeader
    // RELOCS_STRIPPED | EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE.
    peLittle(edit out, 35, 2)
    // PE32+ optional header.
    peLittle(edit out, 523, 2)              // Magic 0x20B
    peLittle(edit out, 0, 2)                // linker version
    peLittle(edit out, layout.text_raw, 4)  // SizeOfCode
    peLittle(edit out, layout.idata_raw, 4) // SizeOfInitializedData
    peLittle(edit out, 0, 4)                // SizeOfUninitializedData
    peLittle(edit out, layout.text_rva + entry, 4) // AddressOfEntryPoint
    peLittle(edit out, layout.text_rva, 4)  // BaseOfCode
    peLittle(edit out, PE64_IMAGE_BASE, 8)  // ImageBase
    peLittle(edit out, section_align, 4)
    peLittle(edit out, file_align, 4)
    peLittle(edit out, 6, 2)                // MajorOperatingSystemVersion
    peLittle(edit out, 0, 2)
    peLittle(edit out, 0, 2)                // image version
    peLittle(edit out, 0, 2)
    peLittle(edit out, 6, 2)                // MajorSubsystemVersion
    peLittle(edit out, 0, 2)
    peLittle(edit out, 0, 4)                // Win32VersionValue
    peLittle(edit out, layout.image_size, 4)
    peLittle(edit out, layout.headers_size, 4)
    peLittle(edit out, 0, 4)                // CheckSum (not required for EXEs)
    peLittle(edit out, 3, 2)                // Subsystem: WINDOWS_CUI
    peLittle(edit out, 256, 2)              // DllCharacteristics: NX_COMPAT only
    peLittle(edit out, 1048576, 8)          // SizeOfStackReserve
    peLittle(edit out, 4096, 8)             // SizeOfStackCommit
    peLittle(edit out, 1048576, 8)          // SizeOfHeapReserve
    peLittle(edit out, 4096, 8)             // SizeOfHeapCommit
    peLittle(edit out, 0, 4)                // LoaderFlags
    peLittle(edit out, 16, 4)               // NumberOfRvaAndSizes
    each d among 0..16 {
        when d == 1 {
            peLittle(edit out, layout.idata_rva, 4)    // import directory
            peLittle(edit out, 40, 4)
        } otherwise when d == 12 {
            peLittle(edit out, layout.idata_rva + peIatOffset(), 4) // IAT
            peLittle(edit out, (PE64_IMPORT_COUNT + 1) * 8, 4)
        } otherwise {
            peLittle(edit out, 0, 8)
        }
    }
    // CODE | EXECUTE | READ, then INITIALIZED_DATA | READ | WRITE.
    hold text_name = ".text"
    hold idata_name = ".idata"
    peSectionHeader(edit out, view text_name, code_length, layout.text_rva, layout.text_raw, layout.text_offset, 1610612768)
    peSectionHeader(edit out, view idata_name, idata_length, layout.idata_rva, layout.idata_raw, layout.idata_offset, 3221225536)
}

flow peFail(code: Int) => Pe64Image {
    give Pe64Image(bytes: List[], error: code)
}

// Writes an image whose entry point is code offset `entry`, patching each
// import fixup with the displacement to its IAT slot.
expose flow pe64ExecutableWith(code: view List of[Int], entry: Int, imports: view Pe64Imports, section_align: Int, file_align: Int) => Pe64Image {
    when code.length == 0 { give peFail(1) }
    when code.length > PE64_MAX_CODE { give peFail(2) }
    change valid_bytes = true
    each i among 0..code.length {
        when code[i] < 0 || code[i] > 255 { valid_bytes = false }
    }
    when !valid_bytes { give peFail(3) }
    when entry < 0 || entry >= code.length { give peFail(6) }
    when imports.at.length != imports.index.length { give peFail(7) }
    change valid_fixups = true
    each i among 0..imports.at.length {
        when imports.at[i] < 0 || imports.at[i] > code.length - 4 { valid_fixups = false }
        when imports.index[i] < 0 || imports.index[i] >= PE64_IMPORT_COUNT { valid_fixups = false }
    }
    when !valid_fixups { give peFail(7) }
    hold idata_length = pe64IdataLength()
    hold layout = pe64Layout(code.length, idata_length, section_align, file_align)
    when layout.error != 0 { give peFail(layout.error) }

    change text: List of[Int] = List[]
    each i among 0..code.length { pePut(edit text, code[i]) }
    change valid_displacements = true
    each i among 0..imports.at.length {
        hold at = imports.at[i]
        hold delta = pe64IatSlotRva(view layout, imports.index[i]) - (layout.text_rva + at + 4)
        when delta < -2147483648 || delta > 2147483647 {
            valid_displacements = false
        } otherwise {
            change n = delta
            each k among 0..4 {
                change b = n % 256
                when b < 0 { b += 256 }
                text[at + k] = b
                n = (n - b) / 256
            }
        }
    }
    when !valid_displacements { give peFail(5) }

    change out: List of[Int] = List[]
    peHeaders(edit out, view layout, code.length, idata_length, entry, section_align, file_align)
    pePadTo(edit out, layout.text_offset)
    each i among 0..text.length { pePut(edit out, text[i]) }
    pePadTo(edit out, layout.idata_offset)
    hold idata = peIdata(layout.idata_rva)
    each i among 0..idata.length { pePut(edit out, idata[i]) }
    pePadTo(edit out, layout.file_size)
    give Pe64Image(bytes: out, error: 0)
}

// Default layout: 4 KiB sections, 512-byte file alignment, so .text starts
// at pe64CodeAddress().
expose flow pe64Executable(code: view List of[Int], entry: Int, imports: view Pe64Imports) => Pe64Image {
    give pe64ExecutableWith(code, entry, imports, PE64_SECTION_ALIGN, PE64_FILE_ALIGN)
}
