import native_cfg_defs
import native_cfg_types
import native_cfg_fields
import x86_64
import native_rt_list
import native_cfg_text
import native_rt

// x86-64 lowering of `List of[T]` (kinds 18..21) and the drop glue of the
// types that own heap storage. Rules and layout: native_cfg_list.

// RDI = address of the list header at the place of `inst`.
flow cfgListHeader(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    cfgPlaceAddressRax(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
    x64MovReg(edit code, 7, 0)
}

flow cfgListElemOf(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: inst.place_ext)
    give p.list_elem[cfgListIndex(p, cfgPlaceType(p, f, view place))]
}

expose flow cfgEmitList(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    when inst.kind == 18 {
        // An empty header, one reservation for every element, then each
        // operand moved to its position and the final length.
        hold elem = p.list_elem[inst.op]
        hold size = cfgTypeSize(p, elem)
        hold base = cfgVarBase(p, f, inst.dst)
        x64MovImm64(edit code, 0, 0)
        x64StoreMem64(edit code, 5, base, 0)
        x64StoreMem64(edit code, 5, base + 8, 0)
        x64StoreMem64(edit code, 5, base + 16, 0)
        when inst.argc > 0 {
            cfgPlaceAddressRax(edit code, p, f, inst.dst, -1, -1, -1, edit fix)
            x64MovReg(edit code, 7, 0)
            x64MovImm64(edit code, 6, inst.argc)
            x64MovImm64(edit code, 2, size)
            x64MovImm64(edit code, 1, 0)
            cfgRuntimeCall(edit code, edit fix, rtListReserve())
            each n among 0..inst.argc {
                hold arg = view p.struct_args[inst.arg_first + n]
                x64LoadMem64(edit code, 9, 5, base)
                cfgStoreValueAt(edit code, p, f, elem, arg, 9, n * size, edit fix)
            }
            x64MovImm64(edit code, 0, inst.argc)
            x64StoreMem64(edit code, 5, base + 8, 0)
        }
    } otherwise {
        hold elem = cfgListElemOf(p, f, inst)
        hold size = cfgTypeSize(p, elem)
        when inst.kind == 19 {
            // Room for one more (at least four when the buffer grows), then
            // the operand moved to buffer + length * size and length + 1.
            cfgListHeader(edit code, p, f, inst, edit fix)
            x64MovImm64(edit code, 6, 1)
            x64MovImm64(edit code, 2, size)
            x64MovImm64(edit code, 1, 4)
            cfgRuntimeCall(edit code, edit fix, rtListReserve())
            hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
            x64LoadMem64(edit code, 10, at.base, at.disp + 8)
            x64MovImm64(edit code, 8, 1)
            x64AddReg(edit code, 8, 10)
            x64StoreMem64(edit code, at.base, at.disp + 8, 8)
            x64LoadMem64(edit code, 9, at.base, at.disp)
            x64MovImm64(edit code, 8, size)
            x64MulReg(edit code, 10, 8)
            x64AddReg(edit code, 9, 10)
            cfgStoreValueAt(edit code, p, f, elem, view inst.a, 9, 0, edit fix)
        } otherwise {
            when inst.kind == 20 {
                // reserve(n): room for n more elements, no minimum.
                cfgListHeader(edit code, p, f, inst, edit fix)
                cfgLoadOperand(edit code, p, f, view inst.a, 6)
                x64MovImm64(edit code, 2, size)
                x64MovImm64(edit code, 1, 0)
                cfgRuntimeCall(edit code, edit fix, rtListReserve())
            } otherwise {
                when inst.kind == 21 {
                    // capacity: the third word of the header.
                    hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
                    x64LoadMem64(edit code, 0, at.base, at.disp + 16)
                    x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
                } otherwise {
                    // 23: listpop
                    hold dst_ty = p.types_code[p.functions[f].first_var + inst.dst]
                    hold e = dst_ty - 2 - p.decl_structs
                    hold kind = view p.enums[e]
                    hold dest = cfgVarBase(p, f, inst.dst)
                    hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
                    x64LoadMem64(edit code, 0, at.base, at.disp + 8)
                    x64TestRax(edit code)
                    hold if_empty = x64ConditionalPlaceholder(edit code, true)
                    x64MovImm64(edit code, 10, -1)
                    x64AddReg(edit code, 0, 10)
                    x64StoreMem64(edit code, at.base, at.disp + 8, 0)
                    x64MovImm64(edit code, 10, size)
                    x64MulReg(edit code, 0, 10)
                    x64LoadMem64(edit code, 9, at.base, at.disp)
                    x64AddReg(edit code, 9, 0)
                    x64MovImm64(edit code, 0, 1)
                    x64StoreMem64(edit code, 5, dest, 0)
                    when kind.size > 8 {
                        x64MovImm64(edit code, 0, 0)
                        each w among 1..(kind.size / 8) {
                            x64StoreMem64(edit code, 5, dest + 8 * w, 0)
                        }
                    }
                    cfgCopyValue(edit code, p, elem, 5, dest + 8, 9, 0)
                    hold done = x64JumpPlaceholder(edit code)
                    hold empty_target = code.bytes.length
                    x64PatchRelative(edit code, if_empty, empty_target)
                    x64MovImm64(edit code, 0, 0)
                    x64StoreMem64(edit code, 5, dest, 0)
                    when kind.size > 8 {
                        x64MovImm64(edit code, 0, 0)
                        each w among 1..(kind.size / 8) {
                            x64StoreMem64(edit code, 5, dest + 8 * w, 0)
                        }
                    }
                    hold done_target = code.bytes.length
                    x64PatchRelative(edit code, done, done_target)
                }
            }
        }
    }
}

// Drop glue of list `k`: glue(RDI = address of the header). Releases every
// element that owns heap storage, last first, and then the buffer.
// Slots: 0 header, 1 elements left. `target` 1 (PE32+) releases through the
// runtime instead of the Linux munmap system call.
flow cfgEmitListGlue(code: edit X64Code, p: view CfgProgram, k: Int, fix: edit CfgFix, target: Int) {
    hold elem = p.list_elem[k]
    hold size = cfgTypeSize(p, elem)
    x64FrameBegin(edit code, 2)
    x64StoreSlot(edit code, 0, 7)
    when cfgOwnsHeap(p, elem) {
        x64LoadMem64(edit code, 0, 7, 8)
        x64StoreSlot(edit code, 1, 0)
        hold top = code.bytes.length
        x64LoadSlot(edit code, 0, 1)
        x64TestRax(edit code)
        hold done = x64ConditionalPlaceholder(edit code, true)
        x64MovImm64(edit code, 10, -1)
        x64AddReg(edit code, 0, 10)
        x64StoreSlot(edit code, 1, 0)
        x64MovImm64(edit code, 1, size)
        x64MulReg(edit code, 0, 1)
        x64LoadSlot(edit code, 7, 0)
        x64LoadMem64(edit code, 7, 7, 0)
        x64AddReg(edit code, 7, 0)
        cfgDropAt(edit code, edit fix, elem)
        hold again = x64JumpPlaceholder(edit code)
        x64PatchRelative(edit code, again, top)
        hold after_items = code.bytes.length
        x64PatchRelative(edit code, done, after_items)
    }
    // munmap(buffer, pages(capacity * size)), unless it never had a buffer.
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64TestRax(edit code)
    hold empty = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 1, size)
    rtListBytes(edit code)
    x64MovReg(edit code, 6, 0)
    x64LoadMem64(edit code, 7, 7, 0)
    when target == 1 {
        // Windows: the runtime's text_drop(RDI = buffer, RSI = bytes)
        // releases it, or exits 124 (win64_heap).
        cfgRuntimeCall(edit code, edit fix, rtTextDrop())
        hold after_win_release = code.bytes.length
        x64PatchRelative(edit code, empty, after_win_release)
        x64FrameEnd(edit code)
        give
    }
    x64MovImm64(edit code, 0, 11)
    x64Syscall(edit code)
    x64TestRax(edit code)
    hold released = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 7, 124)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
    // Both branches target the same post-release instruction offset.
    hold after_release = code.bytes.length
    x64PatchRelative(edit code, released, after_release)
    x64PatchRelative(edit code, empty, after_release)
    x64FrameEnd(edit code)
}

// Drop glue of shape `s`: glue(RDI = address of the value). Releases each
// field that owns heap storage, in declaration order. Slot 0: the address.
flow cfgEmitShapeGlue(code: edit X64Code, p: view CfgProgram, s: Int, fix: edit CfgFix) {
    x64FrameBegin(edit code, 2)
    x64StoreSlot(edit code, 0, 7)
    hold first = p.structs[s].first_field
    each k among 0..p.structs[s].fields {
        hold ty = p.fields[first + k].ty
        when cfgOwnsHeap(p, ty) {
            x64LoadSlot(edit code, 7, 0)
            x64MovImm64(edit code, 10, p.fields[first + k].offset)
            x64AddReg(edit code, 7, 10)
            cfgDropAt(edit code, edit fix, ty)
        }
    }
    x64FrameEnd(edit code)
}

// Emits the list runtime and the drop glue, appending their addresses to
// `at` (after the routines of native_rt): first list_reserve, then one entry
// per type code from 2 on, -1 for the types that need no glue.
expose flow cfgEmitListRuntime(code: edit X64Code, p: view CfgProgram, fix: edit CfgFix, at: edit List of[Int]) {
    at@push(code.bytes.length)
    rtEmitListReserve(edit code)
    cfgEmitDropGlue(edit code, p, edit fix, edit at, 0)
}

// The drop glue alone, for a target whose runtime already provides
// list_reserve at rtListReserve() (win64_heap on PE32+, `target` 1).
expose flow cfgEmitDropGlue(code: edit X64Code, p: view CfgProgram, fix: edit CfgFix, at: edit List of[Int], target: Int) {
    each s among 0..p.decl_structs {
        when cfgOwnsHeap(p, 2 + s) {
            at@push(code.bytes.length)
            cfgEmitShapeGlue(edit code, p, s, edit fix)
        } otherwise {
            at@push(-1)
        }
    }
    each e among 0..p.decl_enums {
        at@push(-1)
    }
    each k among 0..p.decl_lists {
        at@push(code.bytes.length)
        cfgEmitListGlue(edit code, p, k, edit fix, target)
    }
}
