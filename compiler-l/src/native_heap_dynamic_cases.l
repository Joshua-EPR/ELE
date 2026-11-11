import codegen.x86_64
import codegen.elf64
import codegen.native_heap_dynamic

// Stage-0-compiled ELE generator of standalone Linux ELF64 tests.
// Modes: t=two-page success(42), z=zero length(122), n=negative(122),
// h=over 1 MiB(122), u=unaligned munmap(124).
// Unlike the previous fixed-size fixture, length enters machine code as a
// register at runtime and is rounded to pages by the emitted instructions.
flow main() => Int {
    when processArgCount() != 2 { give 2 }
    choose processArg(0) {
        Ok(mode): {
            when mode.byteLength != 1 { give 3 }
            hold kind = mode.byteAt(0)
            when kind != 116 && kind != 122 && kind != 110 && kind != 104 && kind != 117 { give 4 }
            change code = x64New()
            x64FrameBegin(edit code, 2)
            when kind == 116 || kind == 117 {
                when kind == 116 {
                    x64MovImm64(edit code, 7, 4097)
                } otherwise {
                    x64MovImm64(edit code, 7, 8)
                }
                when !heapEmitDynamicMap(edit code) { give 5 }
                x64StoreSlot(edit code, 0, 0)
                when kind == 116 {
                    x64MovImm64(edit code, 2, 40)
                    x64StoreMem64(edit code, 0, 0, 2)
                    x64MovImm64(edit code, 2, 2)
                    x64StoreMem64(edit code, 0, 4096, 2)
                    x64LoadMem64(edit code, 2, 0, 0)
                    x64LoadMem64(edit code, 3, 0, 4096)
                    x64AddReg(edit code, 2, 3)
                    x64StoreSlot(edit code, 1, 2)
                }
                x64LoadSlot(edit code, 7, 0)
                when kind == 117 {
                    x64MovImm64(edit code, 1, 1)
                    x64AddReg(edit code, 7, 1)
                    x64MovImm64(edit code, 6, 8)
                } otherwise {
                    x64MovImm64(edit code, 6, 4097)
                }
                when !heapEmitDynamicUnmap(edit code) { give 6 }
                x64LoadSlot(edit code, 7, 1)
                x64MovImm64(edit code, 0, 60)
                x64Syscall(edit code)
            } otherwise {
                when kind == 122 { x64MovImm64(edit code, 7, 0) }
                when kind == 110 { x64MovImm64(edit code, 7, -1) }
                when kind == 104 { x64MovImm64(edit code, 7, 1048577) }
                when !heapEmitDynamicMap(edit code) { give 7 }
                x64MovImm64(edit code, 7, 90)
                x64MovImm64(edit code, 0, 60)
                x64Syscall(edit code)
            }
            when code.error != 0 { give 8 }
            hold image = elf64Executable(&code.bytes)
            when image.length <= 4096 { give 9 }
            choose processArg(1) {
                Ok(path): { give writeBytes(path, image) },
                Err(error): { give 10 },
            }
        },
        Err(error): { give 11 },
    }
}
