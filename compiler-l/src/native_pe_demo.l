take codegen.x86_64
take codegen.pe64
take codegen.win64_rt

// Native Windows x86-64 proof: ELE builds machine code that writes a
// message to stdout with WriteFile and leaves with ExitProcess(42), and
// wraps it in a PE32+ image with its own KERNEL32 import table. Stage 0
// only bootstraps this ELE program; no linker, CRT or Rust code takes part
// in producing the .exe.
//
// Usage:
//   native-pe-demo <out.exe>                 write the demo image
//   native-pe-demo --bad-alignment <out.exe> must fail, writing nothing
//   native-pe-demo --self-check              print the writer's error codes
//   native-pe-demo --deep-frames <out.exe>   1000 nested 4 KiB frames, exit 43
//   native-pe-demo --relocated <out.exe>     ASLR image with a DIR64 relocation;
//                                            exit 0 when moved and correct
//   native-pe-demo --relocated-missing <out.exe>  same, relocation omitted:
//                                            exit 2 when moved (stale address)

flow demoMessage() => Text {
    give "Hola desde ELE: PE32+ nativo para Windows x64\n"
}

flow demoCode(imports: edit Pe64Imports) => X64Code {
    change code = x64New()
    hold message = demoMessage()
    hold length = message.byteLength
    // push rbp; mov rbp,rsp; one 16-byte slot pair: RSP = 0 (mod 16).
    x64FrameBegin(edit code, 2)
    // Shadow space (32) + fifth WriteFile argument (8), rounded to 16.
    x64MovImm64(edit code, 10, 48)
    x64SubReg(edit code, 4, 10)
    x64MovImm64(edit code, 1, -11)                     // STD_OUTPUT_HANDLE
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64MovReg(edit code, 1, 0)                         // hFile
    hold text_at = x64LeaRipPlaceholder(edit code, 2)  // lpBuffer
    x64MovImm64(edit code, 8, length)                  // nNumberOfBytesToWrite
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 0, 0)
    x64LeaMem(edit code, 9, 5, -8)                     // lpNumberOfBytesWritten
    x64StoreMem64(edit code, 4, 32, 0)                 // lpOverlapped = NULL
    w64CallImport(edit code, edit imports, pe64ImportWriteFile())
    x64TestEax(edit code)
    hold wrote = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 3)
    hold patch_wrote = code.bytes.length
    x64PatchRelative(edit code, wrote, patch_wrote)
    x64LoadSlot(edit code, 0, 0)
    x64MovImm64(edit code, 1, length)
    x64CmpReg(edit code, 0, 1)
    hold complete = x64ConditionalPlaceholder(edit code, true)
    w64EmitExit(edit code, edit imports, 4)
    hold patch_complete = code.bytes.length
    x64PatchRelative(edit code, complete, patch_complete)
    w64EmitExit(edit code, edit imports, 42)
    // The message lives in .text after the code (read-only data).
    hold message_at = code.bytes.length
    each i among 0..length { code.bytes@push(message@byteAt(i)) }
    x64PatchRelative(edit code, text_at, message_at)
    give code
}

flow sameBytes(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength { give false }
    each i among 0..a.byteLength {
        when a@byteAt(i) != b@byteAt(i) { give false }
    }
    give true
}

// Recursion through the largest frame x64FrameBegin allows (512 slots,
// 4 KiB) whose only stack writes are PUSH RBP and the return address, so
// consecutive writes are 4112 bytes apart: with a lazily committed stack
// they would step over the 4 KiB guard page. 1000 levels need about 4 MiB.
flow deepFramesCode(imports: edit Pe64Imports) => X64Code {
    change code = x64New()
    x64MovImm64(edit code, 3, 1000)
    hold first = x64CallPlaceholder(edit code)
    w64EmitExit(edit code, edit imports, 43)
    hold nested = code.bytes.length
    x64PatchRelative(edit code, first, nested)
    x64FrameBegin(edit code, 512)
    x64MovReg(edit code, 0, 3)
    x64TestRax(edit code)
    hold done = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 10, -1)
    x64AddReg(edit code, 3, 10)
    hold again = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, again, nested)
    hold done_at = code.bytes.length
    x64PatchRelative(edit code, done, done_at)
    x64FrameEnd(edit code)
    give code
}

// Base relocation probe: compares the run-time address of a code label
// (LEA RIP-relative, always right) with the same address stored as a 64-bit
// absolute (MOVABS, right only if the loader applied a DIR64 relocation).
// Exits 2 if the absolute address is stale, 1 if the image was loaded at
// its preferred base (nothing was relocated, the check proved nothing), and
// 0 if the image was moved and the relocated address is exact. `abs_at`
// receives the code offset of the relocated MOVABS immediate.
flow relocProbeCode(imports: edit Pe64Imports, abs_at: edit List of[Int]) => X64Code {
    change code = x64New()
    hold lea_at = x64LeaRipPlaceholder(edit code, 0)
    x64MovImm64(edit code, 1, 0)
    hold absolute_at = code.bytes.length - 8
    abs_at@push(absolute_at)
    x64CmpReg(edit code, 0, 1)
    hold same = x64ConditionalPlaceholder(edit code, true)
    w64EmitExit(edit code, edit imports, 2)
    hold same_at = code.bytes.length
    x64PatchRelative(edit code, same, same_at)
    // The preferred-base address, built so that it is NOT an image address
    // in the code (value + 2^40, then minus 2^40): never relocated.
    x64MovImm64(edit code, 1, 0)
    hold preferred_at = code.bytes.length - 8
    x64MovImm64(edit code, 10, 1099511627776)
    x64SubReg(edit code, 1, 10)
    x64CmpReg(edit code, 0, 1)
    hold moved = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 1)
    hold moved_at = code.bytes.length
    x64PatchRelative(edit code, moved, moved_at)
    w64EmitExit(edit code, edit imports, 0)
    hold label = code.bytes.length
    code.bytes@push(195)
    x64PatchRelative(edit code, lea_at, label)
    x64PatchAbsolute64(edit code, absolute_at, pe64CodeAddress() + label)
    x64PatchAbsolute64(edit code, preferred_at, pe64CodeAddress() + label + 1099511627776)
    give code
}

// MOVABS RAX, imm64; RET with the immediate at offset 2.
flow movabsCode(value: Int) => List of[Int] {
    change out: List of[Int] = List[72, 184]
    change n = value
    each i among 0..8 {
        out@push(n % 256)
        n = n / 256
    }
    out@push(195)
    give out
}

flow selfCheckLine(name: Text, error: Int) {
    print("{name}={error}")
}

// Deterministic rejections of the layout and writer; the Rust test pins
// every printed code.
flow selfCheck() => Int {
    hold ok = pe64Layout(4096, pe64IdataLength(), 4096, 512)
    selfCheckLine("ok", ok.error)
    print("ok.text_rva={ok.text_rva}")
    print("ok.idata_rva={ok.idata_rva}")
    print("ok.image_size={ok.image_size}")
    print("ok.file_size={ok.file_size}")
    hold e_empty_code = pe64Layout(0, 100, 4096, 512)
    selfCheckLine("empty_code", e_empty_code.error)
    hold e_code_too_large = pe64Layout(33554433, 100, 4096, 512)
    selfCheckLine("code_too_large", e_code_too_large.error)
    hold e_code_huge = pe64Layout(4611686018427387904, 100, 4096, 512)
    selfCheckLine("code_huge", e_code_huge.error)
    hold e_section_not_pow2 = pe64Layout(16, 100, 3000, 512)
    selfCheckLine("section_not_pow2", e_section_not_pow2.error)
    hold e_file_not_pow2 = pe64Layout(16, 100, 4096, 768)
    selfCheckLine("file_not_pow2", e_file_not_pow2.error)
    hold e_file_too_small = pe64Layout(16, 100, 4096, 256)
    selfCheckLine("file_too_small", e_file_too_small.error)
    hold e_file_too_large = pe64Layout(16, 100, 262144, 131072)
    selfCheckLine("file_too_large", e_file_too_large.error)
    hold e_section_below_file = pe64Layout(16, 100, 4096, 8192)
    selfCheckLine("section_below_file", e_section_below_file.error)
    hold e_section_zero = pe64Layout(16, 100, 0, 512)
    selfCheckLine("section_zero", e_section_zero.error)
    hold e_section_negative = pe64Layout(16, 100, -4096, 512)
    selfCheckLine("section_negative", e_section_negative.error)
    hold e_section_huge = pe64Layout(16, 100, 4294967296, 512)
    selfCheckLine("section_huge", e_section_huge.error)
    // 2 GiB sections: .idata would start at 4 GiB, past every DWORD RVA.
    hold e_image_overflow = pe64Layout(16, 100, 2147483648, 512)
    selfCheckLine("image_overflow", e_image_overflow.error)
    hold e_idata_overflow = pe64Layout(16, 4294967295, 4096, 512)
    selfCheckLine("idata_overflow", e_idata_overflow.error)
    change none = pe64NewImports()
    hold empty: List of[Int] = List[]
    hold w_empty = pe64Executable(view empty, 0, view none)
    selfCheckLine("writer_empty", w_empty.error)
    hold bad_byte: List of[Int] = List[195, 256]
    hold w_bad_byte = pe64Executable(view bad_byte, 0, view none)
    selfCheckLine("writer_bad_byte", w_bad_byte.error)
    hold one: List of[Int] = List[195]
    hold w_bad_entry = pe64Executable(view one, 1, view none)
    selfCheckLine("writer_bad_entry", w_bad_entry.error)
    hold short: List of[Int] = List[255, 21, 0, 0]
    change late = pe64NewImports()
    late.at@push(2)
    late.index@push(0)
    hold w_out_of_code = pe64Executable(view short, 0, view late)
    selfCheckLine("writer_fixup_out_of_code", w_out_of_code.error)
    change unknown = pe64NewImports()
    unknown.at@push(0)
    unknown.index@push(pe64ImportCount())
    hold w_unknown_import = pe64Executable(view short, 0, view unknown)
    selfCheckLine("writer_unknown_import", w_unknown_import.error)
    hold not_call: List of[Int] = List[195, 0, 0, 0, 0]
    change misplaced = pe64NewImports()
    misplaced.at@push(1)
    misplaced.index@push(0)
    hold w_not_call = pe64Executable(view not_call, 0, view misplaced)
    selfCheckLine("writer_fixup_not_call", w_not_call.error)
    hold two_calls: List of[Int] = List[255, 21, 0, 0, 0, 0, 255, 21, 0, 0, 0, 0]
    change twice = pe64NewImports()
    twice.at@push(2)
    twice.index@push(0)
    twice.at@push(2)
    twice.index@push(1)
    hold w_duplicate = pe64Executable(view two_calls, 0, view twice)
    selfCheckLine("writer_fixup_duplicate", w_duplicate.error)
    change overlapping = pe64NewImports()
    overlapping.at@push(2)
    overlapping.index@push(0)
    overlapping.at@push(4)
    overlapping.index@push(1)
    hold w_overlap = pe64Executable(view two_calls, 0, view overlapping)
    selfCheckLine("writer_fixup_overlap", w_overlap.error)
    change both = pe64NewImports()
    both.at@push(2)
    both.index@push(0)
    both.at@push(8)
    both.index@push(2)
    hold w_both = pe64Executable(view two_calls, 0, view both)
    selfCheckLine("writer_fixups_ok", w_both.error)
    hold w_bad_align = pe64ExecutableWith(view one, 0, view none, 4096, 100)
    selfCheckLine("writer_bad_alignment", w_bad_align.error)
    hold fine = pe64Executable(view one, 0, view none)
    selfCheckLine("writer_ok", fine.error)
    print("writer_ok.length={fine.bytes.length}")
    // Base relocations (error 8).
    hold reloc_layout = pe64LayoutWith(4096, pe64IdataLength(), 12, 4096, 512)
    selfCheckLine("reloc_layout", reloc_layout.error)
    print("reloc_layout.reloc_rva={reloc_layout.reloc_rva}")
    print("reloc_layout.image_size={reloc_layout.image_size}")
    print("reloc_layout.file_size={reloc_layout.file_size}")
    hold r_layout_neg = pe64LayoutWith(16, 100, -1, 4096, 512)
    selfCheckLine("reloc_layout_negative", r_layout_neg.error)
    hold inside = movabsCode(pe64CodeAddress())
    change at2: List of[Int] = List[2]
    hold relocated = pe64ExecutableRelocatable(view inside, 0, view none, view at2)
    selfCheckLine("reloc_ok", relocated.error)
    print("reloc_ok.length={relocated.bytes.length}")
    hold no_relocs: List of[Int] = List[]
    hold r_none = pe64ExecutableRelocatable(view inside, 0, view none, view no_relocs)
    selfCheckLine("reloc_none_ok", r_none.error)
    change at_negative: List of[Int] = List[-1]
    hold r_neg = pe64ExecutableRelocatable(view inside, 0, view none, view at_negative)
    selfCheckLine("reloc_negative", r_neg.error)
    change at_late: List of[Int] = List[4]
    hold r_late = pe64ExecutableRelocatable(view inside, 0, view none, view at_late)
    selfCheckLine("reloc_out_of_code", r_late.error)
    change at_overlap: List of[Int] = List[2, 3]
    hold r_overlap = pe64ExecutableRelocatable(view inside, 0, view none, view at_overlap)
    selfCheckLine("reloc_overlap", r_overlap.error)
    change at_twice: List of[Int] = List[2, 2]
    hold r_twice = pe64ExecutableRelocatable(view inside, 0, view none, view at_twice)
    selfCheckLine("reloc_duplicate", r_twice.error)
    hold null_address = movabsCode(0)
    hold r_outside = pe64ExecutableRelocatable(view null_address, 0, view none, view at2)
    selfCheckLine("reloc_outside_image", r_outside.error)
    hold past_end = movabsCode(pe64CodeAddress() + 1048576)
    hold r_past = pe64ExecutableRelocatable(view past_end, 0, view none, view at2)
    selfCheckLine("reloc_past_image", r_past.error)
    change on_call = pe64NewImports()
    on_call.at@push(2)
    on_call.index@push(0)
    change at_zero: List of[Int] = List[0]
    hold r_on_import = pe64ExecutableRelocatable(view two_calls, 0, view on_call, view at_zero)
    selfCheckLine("reloc_on_import", r_on_import.error)
    give 0
}

flow writeImage(path: view Text, image: view Pe64Image) => Int {
    when image.error != 0 {
        printError("PE64 rechazado (código {image.error})")
        give 3
    }
    hold status = writeBytes(path, image.bytes)
    when status != 0 {
        printError("No se pudo escribir PE64 (código {status})")
        give 4
    }
    give 0
}

flow main() => Int {
    when processArgCount() == 1 {
        choose processArg(0) {
            Ok(arg) : {
                hold self_check = "--self-check"
                when sameBytes(view arg, view self_check) { give selfCheck() }
                change imports = pe64NewImports()
                hold code = demoCode(edit imports)
                when code.error != 0 { give 2 }
                hold image = pe64Executable(view code.bytes, 0, view imports)
                give writeImage(view arg, view image)
            }
            Err(e) : { give 5 }
        }
    }
    when processArgCount() == 2 {
        change mode = 0
        choose processArg(0) {
            Ok(flag) : {
                hold bad_alignment = "--bad-alignment"
                hold deep_frames = "--deep-frames"
                when sameBytes(view flag, view bad_alignment) { mode = 1 }
                when sameBytes(view flag, view deep_frames) { mode = 2 }
                hold relocated = "--relocated"
                hold relocated_missing = "--relocated-missing"
                when sameBytes(view flag, view relocated) { mode = 3 }
                when sameBytes(view flag, view relocated_missing) { mode = 4 }
            }
            Err(e) : { give 5 }
        }
        when mode == 0 { give 6 }
        choose processArg(1) {
            Ok(path) : {
                change imports = pe64NewImports()
                when mode == 2 {
                    hold deep = deepFramesCode(edit imports)
                    when deep.error != 0 { give 2 }
                    hold deep_image = pe64Executable(view deep.bytes, 0, view imports)
                    give writeImage(view path, view deep_image)
                }
                when mode == 3 || mode == 4 {
                    change abs_at: List of[Int] = List[]
                    hold probe = relocProbeCode(edit imports, edit abs_at)
                    when probe.error != 0 { give 2 }
                    // --relocated-missing: same code and DYNAMIC_BASE, but
                    // the MOVABS gets no relocation entry.
                    when mode == 4 { abs_at = List[] }
                    hold probe_image = pe64ExecutableRelocatable(view probe.bytes, 0, view imports, view abs_at)
                    give writeImage(view path, view probe_image)
                }
                hold code = demoCode(edit imports)
                when code.error != 0 { give 2 }
                // File alignment 100 is not a power of two: nothing is written.
                hold image = pe64ExecutableWith(view code.bytes, 0, view imports, 4096, 100)
                give writeImage(view path, view image)
            }
            Err(e) : { give 5 }
        }
    }
    printError("Uso: native-pe-demo <salida.exe> | --bad-alignment <salida.exe> | --deep-frames <salida.exe> | --relocated <salida.exe> | --relocated-missing <salida.exe> | --self-check")
    give 6
}
