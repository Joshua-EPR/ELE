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
    selfCheckLine("empty_code", pe64Layout(0, 100, 4096, 512).error)
    selfCheckLine("code_too_large", pe64Layout(16777217, 100, 4096, 512).error)
    selfCheckLine("code_huge", pe64Layout(4611686018427387904, 100, 4096, 512).error)
    selfCheckLine("section_not_pow2", pe64Layout(16, 100, 3000, 512).error)
    selfCheckLine("file_not_pow2", pe64Layout(16, 100, 4096, 768).error)
    selfCheckLine("file_too_small", pe64Layout(16, 100, 4096, 256).error)
    selfCheckLine("file_too_large", pe64Layout(16, 100, 262144, 131072).error)
    selfCheckLine("section_below_file", pe64Layout(16, 100, 4096, 8192).error)
    selfCheckLine("section_zero", pe64Layout(16, 100, 0, 512).error)
    selfCheckLine("section_negative", pe64Layout(16, 100, -4096, 512).error)
    selfCheckLine("section_huge", pe64Layout(16, 100, 4294967296, 512).error)
    // 2 GiB sections: .idata would start at 4 GiB, past every DWORD RVA.
    selfCheckLine("image_overflow", pe64Layout(16, 100, 2147483648, 512).error)
    selfCheckLine("idata_overflow", pe64Layout(16, 4294967295, 4096, 512).error)
    change none = pe64NewImports()
    hold empty: List of[Int] = List[]
    selfCheckLine("writer_empty", pe64Executable(view empty, 0, view none).error)
    hold bad_byte: List of[Int] = List[195, 256]
    selfCheckLine("writer_bad_byte", pe64Executable(view bad_byte, 0, view none).error)
    hold one: List of[Int] = List[195]
    selfCheckLine("writer_bad_entry", pe64Executable(view one, 1, view none).error)
    hold short: List of[Int] = List[255, 21, 0, 0]
    change late = pe64NewImports()
    late.at@push(2)
    late.index@push(0)
    selfCheckLine("writer_fixup_out_of_code", pe64Executable(view short, 0, view late).error)
    change unknown = pe64NewImports()
    unknown.at@push(0)
    unknown.index@push(pe64ImportCount())
    selfCheckLine("writer_unknown_import", pe64Executable(view short, 0, view unknown).error)
    hold not_call: List of[Int] = List[195, 0, 0, 0, 0]
    change misplaced = pe64NewImports()
    misplaced.at@push(1)
    misplaced.index@push(0)
    selfCheckLine("writer_fixup_not_call", pe64Executable(view not_call, 0, view misplaced).error)
    hold two_calls: List of[Int] = List[255, 21, 0, 0, 0, 0, 255, 21, 0, 0, 0, 0]
    change twice = pe64NewImports()
    twice.at@push(2)
    twice.index@push(0)
    twice.at@push(2)
    twice.index@push(1)
    selfCheckLine("writer_fixup_duplicate", pe64Executable(view two_calls, 0, view twice).error)
    change overlapping = pe64NewImports()
    overlapping.at@push(2)
    overlapping.index@push(0)
    overlapping.at@push(4)
    overlapping.index@push(1)
    selfCheckLine("writer_fixup_overlap", pe64Executable(view two_calls, 0, view overlapping).error)
    change both = pe64NewImports()
    both.at@push(2)
    both.index@push(0)
    both.at@push(8)
    both.index@push(2)
    selfCheckLine("writer_fixups_ok", pe64Executable(view two_calls, 0, view both).error)
    selfCheckLine("writer_bad_alignment", pe64ExecutableWith(view one, 0, view none, 4096, 100).error)
    hold fine = pe64Executable(view one, 0, view none)
    selfCheckLine("writer_ok", fine.error)
    print("writer_ok.length={fine.bytes.length}")
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
                hold code = demoCode(edit imports)
                when code.error != 0 { give 2 }
                // File alignment 100 is not a power of two: nothing is written.
                hold image = pe64ExecutableWith(view code.bytes, 0, view imports, 4096, 100)
                give writeImage(view path, view image)
            }
            Err(e) : { give 5 }
        }
    }
    printError("Uso: native-pe-demo <salida.exe> | --bad-alignment <salida.exe> | --deep-frames <salida.exe> | --self-check")
    give 6
}
