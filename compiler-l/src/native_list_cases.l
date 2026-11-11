import codegen.x86_64
import codegen.elf64
import codegen.native_list_int

// Stage-0 bootstrap generates native ELF64 from this ELE v2 source.
// p: push 40+2 (capacity 1->2) => 42
// g: push 10+20+12 (capacity 1->2->4) => 42
// t: pop 2, retain 40 => 42
// o: read index out of bounds => 127
// e: pop empty list => 127
// d: drop list twice => 121
// b: access a dropped list => 121
flow main() => Int {
    when processArgCount() != 2 { give 2 }
    choose processArg(0) {
        Ok(mode): {
            when mode.byteLength != 1 { give 3 }
            hold kind = mode.byteAt(0)
            when kind != 112 && kind != 103 && kind != 116 && kind != 111 && kind != 101 && kind != 100 && kind != 98 { give 4 }
            hold slots = NativeIntListSlots(ptr: 0, bytes: 1, live: 2, len: 3, cap: 4, resize_scratch: 5, cap_scratch: 6)
            change code = x64New()
            x64FrameBegin(edit code, 10)
            nativeListInit(edit code, view slots, 1)
            when kind == 112 || kind == 116 {
                nativeListPush(edit code, view slots, 40)
                nativeListPush(edit code, view slots, 2)
            }
            when kind == 103 {
                nativeListPush(edit code, view slots, 10)
                nativeListPush(edit code, view slots, 20)
                nativeListPush(edit code, view slots, 12)
            }
            when kind == 111 || kind == 100 || kind == 98 {
                nativeListPush(edit code, view slots, 42)
            }
            when kind == 101 {
                nativeListPop(edit code, view slots) // empty: exit 127
            }
            when kind == 111 {
                nativeListRead(edit code, view slots, 1) // OOB: exit 127
            }
            when kind == 112 || kind == 103 {
                nativeListRead(edit code, view slots, 0)
                x64StoreSlot(edit code, 7, 0)
                nativeListRead(edit code, view slots, 1)
                x64LoadSlot(edit code, 2, 7)
                x64AddReg(edit code, 0, 2)
                x64StoreSlot(edit code, 7, 0)
                when kind == 103 {
                    nativeListRead(edit code, view slots, 2)
                    x64LoadSlot(edit code, 2, 7)
                    x64AddReg(edit code, 0, 2)
                    x64StoreSlot(edit code, 7, 0)
                }
            }
            when kind == 116 {
                nativeListPop(edit code, view slots)
                x64StoreSlot(edit code, 7, 0)
                nativeListRead(edit code, view slots, 0)
                x64LoadSlot(edit code, 2, 7)
                x64AddReg(edit code, 0, 2)
                x64StoreSlot(edit code, 7, 0)
            }
            when kind != 101 && kind != 111 {
                nativeListDrop(edit code, view slots)
            }
            when kind == 100 {
                nativeListDrop(edit code, view slots) // double drop: exit 121
            }
            when kind == 98 {
                nativeListRead(edit code, view slots, 0) // after drop: exit 121
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
