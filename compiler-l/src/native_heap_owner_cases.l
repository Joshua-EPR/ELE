take codegen.x86_64
take codegen.elf64
take codegen.native_heap_owner

// Generated ELF runtime checks for explicit owner slots (not Stage 1 drops).
// o = move owner, access mapped 42, free once -> 42
// d = free twice -> 121; m = access moved-from -> 121
// r = move into an already-live owner -> 120
// b = access pointer after free -> 121
flow main() => Int {
    when processArgCount() != 2 { give 2 }
    choose processArg(0) {
        Ok(mode): {
            when mode.byteLength != 1 { give 3 }
            hold kind = mode@byteAt(0)
            when kind != 111 && kind != 100 && kind != 109 && kind != 114 && kind != 98 { give 4 }
            change code = x64New()
            x64FrameBegin(edit code, 8)
            heapOwnerInit(edit code, 0, 1, 2)
            heapOwnerInit(edit code, 3, 4, 5)
            x64MovImm64(edit code, 7, 4097)
            heapOwnerNew(edit code, 0, 1, 2)
            heapOwnerPtr(edit code, 0, 2)
            x64MovImm64(edit code, 2, 42)
            x64StoreMem64(edit code, 0, 4096, 2)
            when kind == 114 {
                x64MovImm64(edit code, 7, 8)
                heapOwnerNew(edit code, 3, 4, 5)
            }
            heapOwnerMove(edit code, 0, 1, 2, 3, 4, 5)
            when kind == 109 {
                heapOwnerPtr(edit code, 0, 2) // must exit 121
            }
            heapOwnerPtr(edit code, 3, 5)
            x64LoadMem64(edit code, 2, 0, 4096)
            x64StoreSlot(edit code, 6, 2)
            heapOwnerDrop(edit code, 3, 4, 5)
            when kind == 100 {
                heapOwnerDrop(edit code, 3, 4, 5) // must exit 121
            }
            when kind == 98 {
                heapOwnerPtr(edit code, 3, 5) // must exit 121
            }
            x64LoadSlot(edit code, 7, 6)
            x64MovImm64(edit code, 0, 60)
            x64Syscall(edit code)
            when code.error != 0 { give 5 }
            hold image = elf64Executable(view code.bytes)
            when image.length <= 4096 { give 6 }
            choose processArg(1) {
                Ok(path): { give writeBytes(path, image) },
                Err(error): { give 7 },
            }
        },
        Err(error): { give 8 },
    }
}
