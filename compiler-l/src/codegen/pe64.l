// Minimal Windows PE32+ (PE64, AMD64) executable writer, written in ELE.
// Produces a console image with no linker:
//   .text   RX  machine code followed by its read-only literals
//   .idata  RW  import directory, ILT, IAT and hint/name table of
//               KERNEL32.dll: the base set (GetStdHandle, WriteFile,
//               ExitProcess, VirtualAlloc, VirtualFree) always, then every
//               further known import the code calls (the platform runtime's
//               GetCommandLineW ... GetLastError), in index order
//   .reloc  R   (relocatable images only) IMAGE_REL_BASED_DIR64 base
//               relocations for every absolute address embedded in .text
//
// Two image kinds:
// - fixed (pe64Executable, pe64ExecutableWith): no relocation directory, so
//   the image declares IMAGE_FILE_RELOCS_STRIPPED and claims neither
//   DYNAMIC_BASE (ASLR) nor HIGH_ENTROPY_VA; it must load at its base.
// - relocatable (pe64ExecutableRelocatable): the caller lists the code
//   offsets of every 64-bit absolute address (patched for the preferred
//   base); the writer emits a .reloc section and claims DYNAMIC_BASE and
//   HIGH_ENTROPY_VA, so the loader may place the image anywhere.
// Both claim NX_COMPAT: no section is both writable and executable.
//
// Every size, offset and RVA is computed with checked arithmetic bounded by
// the 32-bit PE fields. Invalid inputs give a deterministic error and an
// empty image, never a partially written or malformed file.
//
// Errors: 1 empty code, 2 code larger than PE64_MAX_CODE, 3 byte outside
// [0,255], 4 invalid alignment, 5 size/offset overflow (does not fit a
// 32-bit PE field), 6 invalid entry point, 7 invalid import fixup,
// 8 invalid base relocation.

fixed PE64_IMAGE_BASE = 5368709120
fixed PE64_SECTION_ALIGN = 4096
fixed PE64_FILE_ALIGN = 512
fixed PE64_MAX_CODE = 33554432
fixed PE64_DWORD_MAX = 4294967295
fixed PE64_DOS_SIZE = 128
// DOS area + "PE\0\0" + COFF header + PE32+ optional header, before the
// 40-byte section headers.
fixed PE64_OPTIONAL_END = 392
// Known imports; the first PE64_BASE_IMPORTS are in every image.
fixed PE64_IMPORT_COUNT = 17
fixed PE64_BASE_IMPORTS = 5
fixed PE64_STACK_SIZE = 8388608
fixed PE64_PAGE = 4096

// Indexes of the known imported functions. A base import's index is also
// its IAT slot; a further import takes the next slot after the base set and
// the further imports of lower index that the image calls.
expose flow pe64ImportGetStdHandle() => Int { give 0 }
expose flow pe64ImportWriteFile() => Int { give 1 }
expose flow pe64ImportExitProcess() => Int { give 2 }
expose flow pe64ImportVirtualAlloc() => Int { give 3 }
expose flow pe64ImportVirtualFree() => Int { give 4 }
expose flow pe64ImportGetCommandLineW() => Int { give 5 }
expose flow pe64ImportWideCharToMultiByte() => Int { give 6 }
expose flow pe64ImportMultiByteToWideChar() => Int { give 7 }
expose flow pe64ImportCreateFileW() => Int { give 8 }
expose flow pe64ImportReadFile() => Int { give 9 }
expose flow pe64ImportCloseHandle() => Int { give 10 }
expose flow pe64ImportGetFileType() => Int { give 11 }
expose flow pe64ImportGetLastError() => Int { give 12 }
expose flow pe64ImportGetFileInformationByHandle() => Int { give 13 }
expose flow pe64ImportFlushFileBuffers() => Int { give 14 }
expose flow pe64ImportMoveFileExW() => Int { give 15 }
expose flow pe64ImportDeleteFileW() => Int { give 16 }

// Number of known imported functions: valid import indexes are 0..count-1.
expose flow pe64ImportCount() => Int { give PE64_IMPORT_COUNT }

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
    reloc_rva: Int
    reloc_offset: Int
    reloc_raw: Int
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

// The known imports by index. The ILT, the IAT, the hint/name table and
// every bound below derive from the list of imports an image carries
// (peActiveImports), never from a fixed count.
flow peImportName(index: Int) => Text {
    when index == 0 { give "GetStdHandle" }
    when index == 1 { give "WriteFile" }
    when index == 2 { give "ExitProcess" }
    when index == 3 { give "VirtualAlloc" }
    when index == 4 { give "VirtualFree" }
    when index == 5 { give "GetCommandLineW" }
    when index == 6 { give "WideCharToMultiByte" }
    when index == 7 { give "MultiByteToWideChar" }
    when index == 8 { give "CreateFileW" }
    when index == 9 { give "ReadFile" }
    when index == 10 { give "CloseHandle" }
    when index == 11 { give "GetFileType" }
    when index == 12 { give "GetLastError" }
    when index == 13 { give "GetFileInformationByHandle" }
    when index == 14 { give "FlushFileBuffers" }
    when index == 15 { give "MoveFileExW" }
    give "DeleteFileW"
}

// The imports of an image, in IAT slot order: the base set, then each
// further known import some fixup calls, by increasing index. Images that
// call only base imports keep the historical five-entry table.
flow peActiveImports(imports: view Pe64Imports) => List of[Int] {
    change active: List of[Int] = List[]
    each i among 0..PE64_IMPORT_COUNT {
        change used = i < PE64_BASE_IMPORTS
        each j among 0..imports.index.length {
            when imports.index[j] == i { used = true }
        }
        when used { active@push(i) }
    }
    give active
}

flow peBaseImports() => List of[Int] {
    change active: List of[Int] = List[]
    each i among 0..PE64_BASE_IMPORTS { active@push(i) }
    give active
}

// IAT slot of import `index` in `active`, or -1 when the image lacks it.
flow peSlotOf(active: view List of[Int], index: Int) => Int {
    each k among 0..active.length {
        when active[k] == index { give k }
    }
    give -1
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
    give Pe64Layout(error: code, headers_size: 0, text_rva: 0, text_offset: 0, text_raw: 0, idata_rva: 0, idata_offset: 0, idata_raw: 0, reloc_rva: 0, reloc_offset: 0, reloc_raw: 0, image_size: 0, file_size: 0)
}

// File and memory layout of headers, .text (`code_length` bytes) and
// .idata (`idata_length` bytes). Checks every intermediate value.
expose flow pe64Layout(code_length: Int, idata_length: Int, section_align: Int, file_align: Int) => Pe64Layout {
    give pe64LayoutWith(code_length, idata_length, 0, section_align, file_align)
}

// As pe64Layout, plus a .reloc section of `reloc_length` bytes after .idata
// when `reloc_length` > 0 (0: no .reloc section, two section headers).
expose flow pe64LayoutWith(code_length: Int, idata_length: Int, reloc_length: Int, section_align: Int, file_align: Int) => Pe64Layout {
    when code_length <= 0 { give peLayoutFail(1) }
    when code_length > PE64_MAX_CODE { give peLayoutFail(2) }
    when idata_length <= 0 || reloc_length < 0 { give peLayoutFail(5) }
    hold bad_alignment = pe64AlignmentError(section_align, file_align)
    when bad_alignment != 0 { give peLayoutFail(bad_alignment) }
    change sections = 2
    when reloc_length > 0 { sections = 3 }
    hold headers = peAlign(PE64_OPTIONAL_END + 40 * sections, file_align)
    hold text_rva = peAlign(headers, section_align)
    hold text_raw = peAlign(code_length, file_align)
    hold text_span = peAlign(code_length, section_align)
    hold idata_rva = peAdd(text_rva, text_span)
    hold idata_offset = peAdd(headers, text_raw)
    hold idata_raw = peAlign(idata_length, file_align)
    hold idata_span = peAlign(idata_length, section_align)
    hold reloc_rva = peAdd(idata_rva, idata_span)
    hold reloc_offset = peAdd(idata_offset, idata_raw)
    hold reloc_raw = peAlign(reloc_length, file_align)
    hold reloc_span = peAlign(reloc_length, section_align)
    hold image_size = peAdd(reloc_rva, reloc_span)
    hold file_size = peAdd(reloc_offset, reloc_raw)
    when headers < 0 || text_rva < 0 || text_raw < 0 || text_span < 0 { give peLayoutFail(5) }
    when idata_rva < 0 || idata_offset < 0 || idata_raw < 0 || idata_span < 0 { give peLayoutFail(5) }
    when reloc_rva < 0 || reloc_offset < 0 || reloc_raw < 0 || reloc_span < 0 { give peLayoutFail(5) }
    when image_size < 0 || file_size < 0 { give peLayoutFail(5) }
    change r_rva = reloc_rva
    change r_offset = reloc_offset
    when reloc_length == 0 {
        r_rva = 0
        r_offset = 0
    }
    give Pe64Layout(error: 0, headers_size: headers, text_rva: text_rva, text_offset: headers, text_raw: text_raw, idata_rva: idata_rva, idata_offset: idata_offset, idata_raw: idata_raw, reloc_rva: r_rva, reloc_offset: r_offset, reloc_raw: reloc_raw, image_size: image_size, file_size: file_size)
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
        pePut(edit out, text@byteAt(i))
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
// `count` is the number of imports the image carries.
flow peIltOffset() => Int { give 40 }
flow peIatOffset(count: Int) => Int { give 40 + (count + 1) * 8 }
flow peDllNameOffset(count: Int) => Int { give 40 + 2 * (count + 1) * 8 }

flow peEven(n: Int) => Int {
    give n + n % 2
}

// Offset of the hint/name entry of the `k`-th import of `active` (k ==
// active.length: the end of the table).
flow peHintNameOffset(active: view List of[Int], k: Int) => Int {
    hold dll = peDllName()
    change at = peEven(peDllNameOffset(active.length) + dll.byteLength + 1)
    each i among 0..k {
        hold name = peImportName(active[i])
        at = peEven(at + 2 + name.byteLength + 1)
    }
    give at
}

flow peIdataLengthFor(active: view List of[Int]) => Int {
    give peHintNameOffset(active, active.length)
}

// Length of .idata for an image calling only base imports.
expose flow pe64IdataLength() => Int {
    hold base = peBaseImports()
    give peIdataLengthFor(view base)
}

// RVA of the IAT slot of base import `index` in an image laid out as
// `layout` that calls only base imports.
expose flow pe64IatSlotRva(layout: view Pe64Layout, index: Int) => Int {
    give layout.idata_rva + peIatOffset(PE64_BASE_IMPORTS) + 8 * index
}

// RVA of the IAT slot of import `index` in an image carrying `active`.
flow peIatSlotRvaFor(layout: view Pe64Layout, active: view List of[Int], index: Int) => Int {
    give layout.idata_rva + peIatOffset(active.length) + 8 * peSlotOf(active, index)
}

flow peIdata(rva: Int, active: view List of[Int]) => List of[Int] {
    hold count = active.length
    change out: List of[Int] = List[]
    // IMAGE_IMPORT_DESCRIPTOR for KERNEL32.dll.
    peLittle(edit out, rva + peIltOffset(), 4)    // OriginalFirstThunk (ILT)
    peLittle(edit out, 0, 4)                      // TimeDateStamp
    peLittle(edit out, 0, 4)                      // ForwarderChain
    peLittle(edit out, rva + peDllNameOffset(count), 4) // Name
    peLittle(edit out, rva + peIatOffset(count), 4) // FirstThunk (IAT)
    peZeros(edit out, 20)                         // terminator descriptor
    // ILT and IAT start identical: RVAs of the hint/name entries; the loader
    // overwrites the IAT with the resolved addresses.
    each table among 0..2 {
        each k among 0..count {
            peLittle(edit out, rva + peHintNameOffset(active, k), 8)
        }
        peLittle(edit out, 0, 8)
    }
    hold dll = peDllName()
    peAscii(edit out, view dll)
    pePut(edit out, 0)
    pePadTo(edit out, peHintNameOffset(active, 0))
    each k among 0..count {
        peLittle(edit out, 0, 2)                  // hint: none, bind by name
        hold name = peImportName(active[k])
        peAscii(edit out, view name)
        pePut(edit out, 0)
        pePadTo(edit out, peHintNameOffset(active, k + 1))
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

// `reloc_length` 0: fixed image; otherwise the size of the .reloc data.
flow peHeaders(out: edit List of[Int], layout: view Pe64Layout, code_length: Int, idata_length: Int, import_count: Int, reloc_length: Int, entry: Int, section_align: Int, file_align: Int) {
    hold relocatable = reloc_length > 0
    peDosStub(edit out)
    hold signature = "PE"
    peAscii(edit out, view signature)
    peZeros(edit out, 2)
    // COFF file header.
    peLittle(edit out, 34404, 2)            // Machine: AMD64 (0x8664)
    when relocatable {
        peLittle(edit out, 3, 2)            // NumberOfSections
    } otherwise {
        peLittle(edit out, 2, 2)
    }
    peLittle(edit out, 0, 4)                // TimeDateStamp: reproducible
    peLittle(edit out, 0, 4)                // PointerToSymbolTable
    peLittle(edit out, 0, 4)                // NumberOfSymbols
    peLittle(edit out, 240, 2)              // SizeOfOptionalHeader
    when relocatable {
        // EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE.
        peLittle(edit out, 34, 2)
    } otherwise {
        // RELOCS_STRIPPED | EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE.
        peLittle(edit out, 35, 2)
    }
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
    when relocatable {
        // HIGH_ENTROPY_VA | DYNAMIC_BASE | NX_COMPAT: every absolute address
        // has a DIR64 relocation, so any 64-bit base works.
        peLittle(edit out, 352, 2)
    } otherwise {
        peLittle(edit out, 256, 2)          // DllCharacteristics: NX_COMPAT only
    }
    // The whole stack is committed up front: the lowering emits no stack
    // probes and a frame may reach 4 KiB (x64FrameBegin), which could step
    // over a single guard page. 8 MiB matches the usual Linux main stack.
    peLittle(edit out, PE64_STACK_SIZE, 8)  // SizeOfStackReserve
    peLittle(edit out, PE64_STACK_SIZE, 8)  // SizeOfStackCommit
    peLittle(edit out, 67108864, 8)         // SizeOfHeapReserve (64 MiB)
    peLittle(edit out, 4096, 8)             // SizeOfHeapCommit
    peLittle(edit out, 0, 4)                // LoaderFlags
    peLittle(edit out, 16, 4)               // NumberOfRvaAndSizes
    each d among 0..16 {
        when d == 1 {
            peLittle(edit out, layout.idata_rva, 4)    // import directory
            peLittle(edit out, 40, 4)
        } otherwise when d == 5 && relocatable {
            peLittle(edit out, layout.reloc_rva, 4)    // base relocation table
            peLittle(edit out, reloc_length, 4)
        } otherwise when d == 12 {
            peLittle(edit out, layout.idata_rva + peIatOffset(import_count), 4) // IAT
            peLittle(edit out, (import_count + 1) * 8, 4)
        } otherwise {
            peLittle(edit out, 0, 8)
        }
    }
    // CODE | EXECUTE | READ, then INITIALIZED_DATA | READ | WRITE.
    hold text_name = ".text"
    hold idata_name = ".idata"
    peSectionHeader(edit out, view text_name, code_length, layout.text_rva, layout.text_raw, layout.text_offset, 1610612768)
    peSectionHeader(edit out, view idata_name, idata_length, layout.idata_rva, layout.idata_raw, layout.idata_offset, 3221225536)
    when relocatable {
        // INITIALIZED_DATA | DISCARDABLE | READ.
        hold reloc_name = ".reloc"
        peSectionHeader(edit out, view reloc_name, reloc_length, layout.reloc_rva, layout.reloc_raw, layout.reloc_offset, 1107296320)
    }
}

// 64-bit little-endian value stored at code[at..at+8], or -1 when it cannot
// be an address of this image (any of the top three bytes set).
flow peAbsoluteAt(code: view List of[Int], at: Int) => Int {
    when code[at + 5] != 0 || code[at + 6] != 0 || code[at + 7] != 0 { give -1 }
    change value = 0
    change k = 4
    during k >= 0 {
        value = value * 256 + code[at + k]
        k = k - 1
    }
    give value
}

// .reloc contents: one IMAGE_BASE_RELOCATION block per 4 KiB page of .text
// holding at least one absolute address, each entry IMAGE_REL_BASED_DIR64
// (type 10) and every block padded to 4 bytes with an ABSOLUTE (type 0)
// entry. Pages are visited in increasing order and entries keep the order of
// `abs64`, so the output is deterministic. An image without absolute
// addresses still gets one block of two ABSOLUTE entries: a relocatable
// image always carries a (possibly no-op) relocation directory.
flow peRelocs(text_rva: Int, code_length: Int, abs64: view List of[Int]) => List of[Int] {
    change out: List of[Int] = List[]
    change page = text_rva - text_rva % PE64_PAGE
    hold end = text_rva + code_length
    during page < end {
        change count = 0
        each i among 0..abs64.length {
            hold rva = text_rva + abs64[i]
            when rva >= page && rva < page + PE64_PAGE { count += 1 }
        }
        when count > 0 {
            peLittle(edit out, page, 4)                    // VirtualAddress
            peLittle(edit out, 8 + 2 * (count + count % 2), 4) // SizeOfBlock
            each i among 0..abs64.length {
                hold rva = text_rva + abs64[i]
                when rva >= page && rva < page + PE64_PAGE {
                    peLittle(edit out, 40960 + (rva - page), 2) // DIR64 << 12
                }
            }
            when count % 2 == 1 { peLittle(edit out, 0, 2) }
        }
        page += PE64_PAGE
    }
    when out.length == 0 {
        peLittle(edit out, text_rva - text_rva % PE64_PAGE, 4)
        peLittle(edit out, 12, 4)
        peLittle(edit out, 0, 4)
    }
    give out
}

flow peFail(code: Int) => Pe64Image {
    give Pe64Image(bytes: List[], error: code)
}

// Writes an image whose entry point is code offset `entry`, patching each
// import fixup with the displacement to its IAT slot. With `relocatable`,
// `abs64` lists the code offsets of the 64-bit absolute addresses (already
// patched for the preferred base) and the image gets a .reloc section;
// otherwise `abs64` must be empty and the image is fixed at its base.
flow peWrite(code: view List of[Int], entry: Int, imports: view Pe64Imports, abs64: view List of[Int], relocatable: Bool, section_align: Int, file_align: Int) => Pe64Image {
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
    // Each fixup must be the displacement of a CALL [RIP+disp32] (FF 15),
    // and no two fixups may share bytes.
    each i among 0..imports.at.length {
        hold at = imports.at[i]
        when at < 2 {
            valid_fixups = false
        } otherwise when code[at - 2] != 255 || code[at - 1] != 21 {
            valid_fixups = false
        }
        each j among 0..imports.at.length {
            when i != j && imports.at[j] > at - 6 && imports.at[j] < at + 6 { valid_fixups = false }
        }
    }
    when !valid_fixups { give peFail(7) }
    // Base relocations: each covers 8 bytes inside the code and shares no
    // byte with another relocation nor with an import CALL (opcode included).
    when !relocatable && abs64.length > 0 { give peFail(8) }
    change valid_relocs = true
    each i among 0..abs64.length {
        hold at = abs64[i]
        when at < 0 || at > code.length - 8 { valid_relocs = false }
        each j among 0..abs64.length {
            when i != j && abs64[j] > at - 8 && abs64[j] < at + 8 { valid_relocs = false }
        }
        each j among 0..imports.at.length {
            when imports.at[j] - 2 < at + 8 && at < imports.at[j] + 4 { valid_relocs = false }
        }
    }
    when !valid_relocs { give peFail(8) }
    hold active = peActiveImports(imports)
    hold idata_length = peIdataLengthFor(view active)
    change reloc_length = 0
    change relocs: List of[Int] = List[]
    when relocatable {
        // .text placement does not depend on the size of .reloc.
        hold probe = pe64LayoutWith(code.length, idata_length, 1, section_align, file_align)
        when probe.error != 0 { give peFail(probe.error) }
        relocs = peRelocs(probe.text_rva, code.length, abs64)
        reloc_length = relocs.length
    }
    hold layout = pe64LayoutWith(code.length, idata_length, reloc_length, section_align, file_align)
    when layout.error != 0 { give peFail(layout.error) }
    // Every relocated value must be an address inside this image at its
    // preferred base: anything else would be relocated into garbage.
    each i among 0..abs64.length {
        hold value = peAbsoluteAt(code, abs64[i])
        when value < PE64_IMAGE_BASE || value >= PE64_IMAGE_BASE + layout.image_size { valid_relocs = false }
    }
    when !valid_relocs { give peFail(8) }

    change text: List of[Int] = List[]
    each i among 0..code.length { pePut(edit text, code[i]) }
    change valid_displacements = true
    each i among 0..imports.at.length {
        hold at = imports.at[i]
        hold delta = peIatSlotRvaFor(view layout, view active, imports.index[i]) - (layout.text_rva + at + 4)
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
    peHeaders(edit out, view layout, code.length, idata_length, active.length, reloc_length, entry, section_align, file_align)
    pePadTo(edit out, layout.text_offset)
    each i among 0..text.length { pePut(edit out, text[i]) }
    pePadTo(edit out, layout.idata_offset)
    hold idata = peIdata(layout.idata_rva, view active)
    each i among 0..idata.length { pePut(edit out, idata[i]) }
    when relocatable {
        pePadTo(edit out, layout.reloc_offset)
        each i among 0..relocs.length { pePut(edit out, relocs[i]) }
    }
    pePadTo(edit out, layout.file_size)
    give Pe64Image(bytes: out, error: 0)
}

// Fixed-base image (no .reloc, RELOCS_STRIPPED, no ASLR).
expose flow pe64ExecutableWith(code: view List of[Int], entry: Int, imports: view Pe64Imports, section_align: Int, file_align: Int) => Pe64Image {
    hold none: List of[Int] = List[]
    give peWrite(code, entry, imports, view none, false, section_align, file_align)
}

// Default layout: 4 KiB sections, 512-byte file alignment, so .text starts
// at pe64CodeAddress().
expose flow pe64Executable(code: view List of[Int], entry: Int, imports: view Pe64Imports) => Pe64Image {
    give pe64ExecutableWith(code, entry, imports, PE64_SECTION_ALIGN, PE64_FILE_ALIGN)
}

// Relocatable image with the default layout: `abs64` holds the code offset
// of every 64-bit absolute address, each patched for .text at
// pe64CodeAddress(). The loader may then place the image at any base (ASLR).
expose flow pe64ExecutableRelocatable(code: view List of[Int], entry: Int, imports: view Pe64Imports, abs64: view List of[Int]) => Pe64Image {
    give peWrite(code, entry, imports, abs64, true, PE64_SECTION_ALIGN, PE64_FILE_ALIGN)
}
