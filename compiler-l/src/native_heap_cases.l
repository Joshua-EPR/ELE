import codegen.x86_64
import codegen.elf64
import codegen.native_heap

// Bootstrap-only fixture: emits self-contained Linux ELF64 from ELE code.
// Usage: native_heap_cases <ok|bad> <output.elf>
// ok: map one page, write/read 42, unmap, then exit 42.
// bad: try to unmap an intentionally unaligned pointer; exit 124.
// Actual execution happens on Linux; Windows only generates the ELF bytes.
fn main() -> Int {
    if heapPageRound(1) != 4096 { return 10 }
    if heapPageRound(4096) != 4096 { return 11 }
    if heapPageRound(4097) != 8192 { return 12 }
    if heapPageRound(1048576) != 1048576 { return 13 }
    if heapPageRound(0) != -1 { return 14 }
    if heapPageRound(-1) != -1 { return 15 }
    // The Stage 3.3 heap limit is 32 MiB; sizes above the former 1 MiB
    // limit must round correctly, while out-of-range sizes still fail closed.
    if heapPageRound(1048577) != 1052672 { return 16 }
    if heapPageRound(33554431) != 33554432 { return 20 }
    if heapPageRound(33554432) != 33554432 { return 21 }
    if heapPageRound(33554433) != -1 { return 22 }
    var invalid = x64New()
    if heapEmitCheckedMap(&mut invalid, 0) { return 17 }
    if heapEmitCheckedUnmap(&mut invalid, -1) { return 18 }
    if invalid.bytes.length != 0 { return 19 }

    if processArgCount() != 2 { return 2 }
    match processArg(0) {
        Ok(mode) => {
            let normal = mode.byteLength == 2 && mode.byteAt(0) == 111 && mode.byteAt(1) == 107
            let bad = mode.byteLength == 3 && mode.byteAt(0) == 98 && mode.byteAt(1) == 97 && mode.byteAt(2) == 100
            if !normal && !bad { return 3 }
            var code = x64New()
            x64FrameBegin(&mut code, 2)
            if !heapEmitCheckedMap(&mut code, 8) { return 4 }
            x64StoreSlot(&mut code, 0, 0) // keep mapped address
            x64MovImm64(&mut code, 2, 42)
            x64StoreMem64(&mut code, 0, 0, 2)
            x64LoadMem64(&mut code, 3, 0, 0)
            x64StoreSlot(&mut code, 1, 3) // keep loaded value
            x64LoadSlot(&mut code, 7, 0) // RDI = mapping
            if bad {
                x64MovImm64(&mut code, 1, 1)
                x64AddReg(&mut code, 7, 1) // unaligned munmap -> EINVAL
            }
            if !heapEmitCheckedUnmap(&mut code, 8) { return 5 }
            x64LoadSlot(&mut code, 7, 1)
            x64MovImm64(&mut code, 0, 60) // exit(saved value)
            x64Syscall(&mut code)
            if code.error != 0 { return 6 }
            let image = elf64Executable(&code.bytes)
            if image.length <= 4096 { return 7 }
            match processArg(1) {
                Ok(path) => { return writeBytes(path, image) }
                Err(code) => { return 8 }
            }
        }
        Err(code) => { return 9 }
    }
}
