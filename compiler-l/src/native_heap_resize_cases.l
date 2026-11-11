import codegen.x86_64
import codegen.elf64
import codegen.native_heap_owner

// Linux ELF64 owner resize integration tests, emitted by code written in ELE.
// g: 8 -> 4097 bytes, preserved 40 + second page 2 => 42
// s: 4097 -> 8 bytes, preserved first 42 => 42
// t: move owner, then grow and free => 42
// z/h: resize to zero or >1 MiB => exit 122 (original owner intact)
// m: resize a moved-from owner => exit 121
flow main() => Int {
    change invalid = x64New()
    heapOwnerResize(edit invalid, 0, 1, 2, 0)
    when invalid.error != 31 || invalid.bytes.length != 0 { give 12 }
    when processArgCount() != 2 { give 2 }
    choose processArg(0) {
        Ok(mode): {
            when mode.byteLength != 1 { give 3 }
            hold kind = mode.byteAt(0)
            when kind != 103 && kind != 115 && kind != 116 && kind != 122 && kind != 104 && kind != 109 { give 4 }
            change code = x64New()
            x64FrameBegin(edit code, 9)
            heapOwnerInit(edit code, 0, 1, 2)
            heapOwnerInit(edit code, 3, 4, 5)
            when kind == 115 {
                x64MovImm64(edit code, 7, 4097)
            } otherwise {
                x64MovImm64(edit code, 7, 8)
            }
            heapOwnerNew(edit code, 0, 1, 2)
            heapOwnerPtr(edit code, 0, 2)
            when kind == 115 {
                x64MovImm64(edit code, 2, 42)
            } otherwise {
                x64MovImm64(edit code, 2, 40)
            }
            x64StoreMem64(edit code, 0, 0, 2)
            when kind == 116 || kind == 109 {
                heapOwnerMove(edit code, 0, 1, 2, 3, 4, 5)
            }
            when kind == 122 { x64MovImm64(edit code, 7, 0) }
            when kind == 104 { x64MovImm64(edit code, 7, 1048577) }
            when kind == 115 { x64MovImm64(edit code, 7, 8) }
            when kind == 103 || kind == 116 || kind == 109 {
                x64MovImm64(edit code, 7, 4097)
            }
            when kind == 116 {
                heapOwnerResize(edit code, 3, 4, 5, 6)
            } otherwise {
                heapOwnerResize(edit code, 0, 1, 2, 6)
            }
            when kind == 116 {
                heapOwnerPtr(edit code, 3, 5)
            } otherwise {
                heapOwnerPtr(edit code, 0, 2)
            }
            when kind == 103 || kind == 116 {
                x64MovImm64(edit code, 2, 2)
                x64StoreMem64(edit code, 0, 4096, 2)
                x64LoadMem64(edit code, 2, 0, 0)
                x64LoadMem64(edit code, 3, 0, 4096)
                x64AddReg(edit code, 2, 3)
            } otherwise {
                x64LoadMem64(edit code, 2, 0, 0)
            }
            x64StoreSlot(edit code, 7, 2)
            when kind == 116 {
                heapOwnerDrop(edit code, 3, 4, 5)
            } otherwise {
                heapOwnerDrop(edit code, 0, 1, 2)
            }
            x64LoadSlot(edit code, 7, 7)
            x64MovImm64(edit code, 0, 60)
            x64Syscall(edit code)
            when code.error != 0 { give 5 }
            hold image = elf64Executable(&code.bytes)
            when image.length <= 4096 { give 6 }
            choose processArg(1) {
                Ok(path): { give writeBytes(path, image) },
                Err(error): { give 7 },
            }
        },
        Err(error): { give 8 },
    }
}
