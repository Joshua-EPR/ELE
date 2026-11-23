take codegen.x86_64
take codegen.elf64
take codegen.native_heap

// Bootstrap-only fixture: emits self-contained Linux ELF64 from ELE code.
// Usage: native_heap_cases <ok|bad> <output.elf>
// ok: map one page, write/read 42, unmap, then exit 42.
// bad: try to unmap an intentionally unaligned pointer; exit 124.
// Actual execution happens on Linux; Windows only generates the ELF bytes.
flow main() => Int {
    when heapPageRound(1) != 4096 { give 10 }
    when heapPageRound(4096) != 4096 { give 11 }
    when heapPageRound(4097) != 8192 { give 12 }
    when heapPageRound(1048576) != 1048576 { give 13 }
    when heapPageRound(0) != -1 { give 14 }
    when heapPageRound(-1) != -1 { give 15 }
    // The Stage 3.3 heap limit is 32 MiB; sizes above the former 1 MiB
    // limit must round correctly, while out-of-range sizes still fail closed.
    when heapPageRound(1048577) != 1052672 { give 16 }
    when heapPageRound(33554431) != 33554432 { give 20 }
    when heapPageRound(33554432) != 33554432 { give 21 }
    when heapPageRound(33554433) != -1 { give 22 }
    change invalid = x64New()
    when heapEmitCheckedMap(edit invalid, 0) { give 17 }
    when heapEmitCheckedUnmap(edit invalid, -1) { give 18 }
    when invalid.bytes.length != 0 { give 19 }

    when processArgCount() != 2 { give 2 }
    choose processArg(0) {
        Ok(mode) : {
            hold normal = mode.byteLength == 2 && mode@byteAt(0) == 111 && mode@byteAt(1) == 107
            hold bad = mode.byteLength == 3 && mode@byteAt(0) == 98 && mode@byteAt(1) == 97 && mode@byteAt(2) == 100
            when !normal && !bad { give 3 }
            change code = x64New()
            x64FrameBegin(edit code, 2)
            when !heapEmitCheckedMap(edit code, 8) { give 4 }
            x64StoreSlot(edit code, 0, 0) // keep mapped address
            x64MovImm64(edit code, 2, 42)
            x64StoreMem64(edit code, 0, 0, 2)
            x64LoadMem64(edit code, 3, 0, 0)
            x64StoreSlot(edit code, 1, 3) // keep loaded value
            x64LoadSlot(edit code, 7, 0) // RDI = mapping
            when bad {
                x64MovImm64(edit code, 1, 1)
                x64AddReg(edit code, 7, 1) // unaligned munmap -> EINVAL
            }
            when !heapEmitCheckedUnmap(edit code, 8) { give 5 }
            x64LoadSlot(edit code, 7, 1)
            x64MovImm64(edit code, 0, 60) // exit(saved value)
            x64Syscall(edit code)
            when code.error != 0 { give 6 }
            hold image = elf64Executable(view code.bytes)
            when image.length <= 4096 { give 7 }
            choose processArg(1) {
                Ok(path) : { give writeBytes(path, image) }
                Err(code) : { give 8 }
            }
        }
        Err(code) : { give 9 }
    }
}
