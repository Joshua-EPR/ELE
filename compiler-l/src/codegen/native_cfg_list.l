take lir_tokens
take native_cfg_defs
take native_cfg_types

// `List of[T]` in the ELE-written CFG backend: declarations, instructions
// and their static rules. Lowering lives in native_cfg_list_emit and the
// runtime routine in native_rt_list.
//
// A list is three words: buffer address, length and capacity, both counted
// in elements. An empty list that never grew has capacity 0 and no buffer.
// The buffer is mmap'ed, grows with mremap and is released with munmap; its
// byte size is always the element count times the element size, rounded up
// to whole pages, so it can be recomputed from the capacity.
//
// Instruction kinds: 18 listlit (operands in `struct_args`), 19 listpush,
// 20 listreserve, 21 cap. `len` (kind 14) also accepts a list place.
//
// Ownership, sound by construction for this subset:
// - a list is a move-only owner, like Text: it must be moved or dropped
//   exactly once, and `drop`/`dropfield` release its elements first;
// - `listlit` and `listpush` move their operands into the buffer;
// - an element is reached only through a place extension (`[vN]`), which
//   is bounds-checked at run time (exit 127) and never moves ownership: a
//   heap-free element is copied out or overwritten. An element that owns
//   heap storage can be borrowed or replaced (the old value is dropped);
//   moving it out still waits for `listpop`;
// - no reference to an element outlives the instruction or the call that
//   created it, so growing a list never invalidates a live reference.
//
// Rejection codes: 100 malformed list declaration, 102 malformed list
// instruction or operand type, 103 move of an owning value out of an
// element, 104 a list pushed or stored into itself.

expose flow cfgListType(p: view CfgProgram, k: Int) => Int {
    give 2 + p.decl_structs + p.decl_enums + k
}

// `list l<K> <element type>`, in order, after the shapes and choices.
expose flow cfgReadList(p: edit CfgProgram, source: view Text, reader: edit NativeReader, k: Int) {
    nativeExpect(source, edit reader, "list")
    hold id = nativeId(source, edit reader, 108)
    hold elem = cfgTypeOrUnit(p, source, edit reader)
    nativeEndLine(source, edit reader)
    change valid = reader.error == 0 && id == k && elem != cfgUnitType() && (elem >= 0 || elem == cfgTextType() || elem == cfgFloatType())
    when valid {
        hold size = cfgTypeSize(p, elem)
        valid = size >= 1 && size <= cfgMaxValueBytes()
    }
    when valid {
        p.list_elem@push(elem)
    } otherwise {
        p.error = 100
    }
}

flow cfgSetPlace(inst: edit CfgInst, place: view CfgPlace) {
    inst.place_var = place.variable
    inst.place_field = place.field
    inst.place_subfield = place.subfield
    inst.place_ext = place.ext
}

// Reads the list instructions. Returns false when `kind` is not one.
expose flow cfgReadListInst(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst, kind: view NativeWord) => Bool {
    when nativeEquals(source, kind, "listlit") {
        // i listlit vD lK <n> <operand>...
        inst.kind = 18
        inst.dst = nativeId(source, edit reader, 118)
        inst.op = nativeId(source, edit reader, 108)
        inst.argc = nativeNumber(source, edit reader)
        when inst.argc < 0 || inst.argc > 4096 {
            p.error = 102
            give true
        }
        inst.arg_first = p.struct_args.length
        each n among 0..inst.argc {
            p.struct_args@push(cfgOperand(edit p, source, edit reader))
        }
        give true
    }
    when nativeEquals(source, kind, "listpush") {
        // i listpush <place> <operand>
        inst.kind = 19
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        cfgSetPlace(edit inst, view place)
        inst.a = cfgOperand(edit p, source, edit reader)
        give true
    }
    when nativeEquals(source, kind, "listreserve") {
        // i listreserve <place> <Int operand>
        inst.kind = 20
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        cfgSetPlace(edit inst, view place)
        inst.a = nativeOperand(source, edit reader)
        give true
    }
    when nativeEquals(source, kind, "cap") {
        // i cap vD <place>
        inst.kind = 21
        inst.dst = nativeId(source, edit reader, 118)
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        cfgSetPlace(edit inst, view place)
        give true
    }
    when nativeEquals(source, kind, "listpop") {
        // i listpop vD <place>
        inst.kind = 23
        inst.dst = nativeId(source, edit reader, 118)
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        cfgSetPlace(edit inst, view place)
        give true
    }
    give false
}

// Element type of the list at the place of `inst`, or -1.
flow cfgInstListElem(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: inst.place_ext)
    hold list = cfgListIndex(p, cfgPlaceType(p, f, view place))
    when list < 0 { give -1 }
    give p.list_elem[list]
}

// Static rules of kinds 18..21. Returns 0 or a rejection code.
expose flow cfgCheckListInst(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold first = p.functions[f].first_var
    when inst.kind == 18 {
        when inst.op < 0 || inst.op >= p.decl_lists { give 102 }
        when p.types_code[first + inst.dst] != cfgListType(p, inst.op) { give 102 }
        hold elem = p.list_elem[inst.op]
        each n among 0..inst.argc {
            hold arg = view p.struct_args[inst.arg_first + n]
            when cfgOperandType(p, f, arg) != elem { give 102 }
        }
        give 0
    }
    hold item = cfgInstListElem(p, f, inst)
    when item == -1 { give 102 }
    when inst.kind == 19 {
        when cfgOperandType(p, f, view inst.a) != item { give 102 }
        // The operand is moved while the place is written.
        when inst.a.is_var && inst.a.value == inst.place_var { give 104 }
    }
    when inst.kind == 20 && cfgOperandType(p, f, view inst.a) != 0 { give 102 }
    when inst.kind == 21 && p.types_code[first + inst.dst] != 0 { give 102 }
    when inst.kind == 23 {
        hold dst_ty = p.types_code[first + inst.dst]
        hold e = dst_ty - 2 - p.decl_structs
        when e < 0 || e >= p.decl_enums || p.enums[e].variants != 2 { give 102 }
        hold v0 = view p.variants[p.enums[e].first_variant]
        hold v1 = view p.variants[p.enums[e].first_variant + 1]
        when v0.payload_type != -1 || v1.payload_type != item { give 102 }
    }
    give 0
}

// Every index variable of extension `ext` is initialized in `live`.
expose flow cfgExtLive(p: view CfgProgram, ext: Int, live: view List of[Bool]) => Bool {
    when ext < 0 { give true }
    hold first = p.ext_first[ext]
    each n among first..(first + p.ext_count[ext]) {
        when p.proj_kind[n] == 1 && !live[p.proj_value[n]] { give false }
    }
    give true
}
