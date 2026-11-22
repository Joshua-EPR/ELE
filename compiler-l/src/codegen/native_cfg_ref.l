take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_returnref

// Reference parameters (`view T` / `edit T`) and Text queries of the
// ELE-written CFG backend.
//
// Model, sound by construction for this subset:
// - A reference is a parameter (`var vN ref T`, N < params), one word with
//   the address of the referent, pushed by the caller; or a local defined
//   by a `loan`, whose validity the verifier follows (native_cfg_loan).
// - A reference argument may name a list element (`ref pN[vI] 0|1`); it
//   lasts for that call only, and the overlap rule below keeps the list
//   itself from being passed exclusively next to it.
// - A reference is never a value: it cannot be copied, moved, returned,
//   stored in an aggregate, dropped or assigned. Only places (`pN`,
//   `pN.k`, `pN.k.j`) and reference arguments (`ref <place> 0|1`) name it.
//   Hence no reference outlives the call that created it and the callee
//   never frees or moves the referent.
// - ELE-LIR does not record whether a parameter is `view` or `edit`. A
//   parameter is exclusive when the function stores through it, appends
//   to it or passes it on as `ref ... 1`; every caller must then pass
//   `ref ... 1`. Stage 1 checks the declared modes; this backend checks
//   that the code it emits never writes through a shared reference.
// - Inside one call, an exclusive reference may not overlap any other
//   argument, and a moved value may not overlap any reference.
//
// Rejection codes: 95 drop/move/store of Text through a reference,
// 96 reference outside parameters or as a destination, 97 malformed
// Text query, 98 exclusive parameter receives a shared reference,
// 99 overlapping arguments.

expose flow cfgIsRef(p: view CfgProgram, f: Int, variable: Int) => Bool {
    give p.var_ref[p.functions[f].first_var + variable]
}

// Reads `val <operand>` or `ref <place> <0|1>` and appends it to the call
// argument tables. Returns 0 or a rejection code.
expose flow cfgReadCallArg(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader) => Int {
    hold mode = nativeWord(source, edit reader)
    when nativeEquals(source, view mode, "ref") {
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        hold exclusive = nativeNumber(source, edit reader)
        when reader.error != 0 || place.variable < 0 || (exclusive != 0 && exclusive != 1) { give 37 }
        hold ty = cfgPlaceType(p, f, view place)
        when ty == -1 || ty == cfgUnitType() { give 37 }
        p.call_args@push(NativeOperand(is_var: true, value: place.variable, is_bool: false, is_unit: false, is_text: false))
        p.call_ref@push(exclusive)
        p.call_field@push(place.field)
        p.call_sub@push(place.subfield)
        p.call_ext@push(place.ext)
        give 0
    }
    when !nativeEquals(source, view mode, "val") { give 37 }
    hold arg = cfgOperand(edit p, source, edit reader)
    hold arg_type = cfgOperandType(p, f, view arg)
    p.call_args@push(arg)
    p.call_ref@push(-1)
    p.call_field@push(-1)
    p.call_sub@push(-1)
    p.call_ext@push(-1)
    // By value: primitives, Text, a whole shape/choice, or a linear File.
    when reader.error != 0 || (arg_type < 0 && arg_type != cfgTextType() && arg_type != cfgFileType()) { give 37 }
    give 0
}

// `i len vD <place>` (kind 14) and `i byteat vD <place> <index>` (kind 15).
expose flow cfgReadTextQuery(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst, kind: Int) {
    inst.kind = kind
    inst.dst = nativeId(source, edit reader, 118)
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    inst.place_var = place.variable
    inst.place_field = place.field
    inst.place_subfield = place.subfield
    inst.place_ext = place.ext
    when kind == 15 { inst.a = nativeOperand(source, edit reader) }
}

expose flow cfgCheckTextQuery(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold first = p.functions[f].first_var
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: inst.place_ext)
    hold ty = cfgPlaceType(p, f, view place)
    // `len` counts the bytes of a Text or the elements of a list.
    hold measurable = ty == cfgTextType() || (inst.kind == 14 && cfgListIndex(p, ty) >= 0)
    when p.types_code[first + inst.dst] != 0 || !measurable { give 97 }
    when inst.kind == 15 && cfgOperandType(p, f, view inst.a) != 0 { give 97 }
    give 0
}

// Whether function `f` writes through its reference parameter `v`.
expose flow cfgParamNeedsMut(p: view CfgProgram, f: Int, v: Int) => Bool {
    when cfgReturnsParamMut(p, f, v) { give true }
    hold first_block = p.functions[f].first_block
    each b among first_block..(first_block + p.functions[f].blocks) {
        hold first = p.blocks[b].first
        each i among first..(first + p.blocks[b].count) {
            hold kind = p.insts[i].kind
            when (kind == 6 || kind == 12 || kind == 17 || kind == 19 || kind == 20) && p.insts[i].place_var == v { give true }
            // An exclusive loan of the referent, direct or through a reborrow.
            when kind == 22 && p.insts[i].op == 1 && p.ref_root[p.functions[f].first_var + p.insts[i].dst] == v { give true }
            when kind == 3 {
                each n among 0..p.insts[i].argc {
                    hold k = p.insts[i].arg_first + n
                    when p.call_ref[k] == 1 && p.call_args[k].value == v { give true }
                }
            }
        }
    }
    give false
}

// Two call arguments name overlapping storage. A by-value argument covers
// its whole variable; constants overlap nothing.
// A local reference is an alias of its borrowed storage, not its own slot.
// Dynamic indices are conservatively treated as potentially overlapping.
flow cfgArgsOverlap(p: view CfgProgram, f: Int, a: Int, b: Int) => Bool {
    when !p.call_args[a].is_var || !p.call_args[b].is_var { give false }
    hold first = p.functions[f].first_var
    hold params = p.functions[f].params
    change va = p.call_args[a].value
    change vb = p.call_args[b].value
    change fa = p.call_field[a]
    change fb = p.call_field[b]
    change sa = p.call_sub[a]
    change sb = p.call_sub[b]
    when p.call_ref[a] >= 0 && va >= params && p.var_ref[first + va] {
        hold origin = first + va
        hold field = p.ref_field[origin]
        when field >= 0 {
            when p.ref_sub[origin] >= 0 { sa = p.ref_sub[origin] }
            otherwise { sa = fa }
            fa = field
        } otherwise {
            fa = -1
            sa = -1
        }
        va = p.ref_root[origin]
    }
    when p.call_ref[b] >= 0 && vb >= params && p.var_ref[first + vb] {
        hold origin = first + vb
        hold field = p.ref_field[origin]
        when field >= 0 {
            when p.ref_sub[origin] >= 0 { sb = p.ref_sub[origin] }
            otherwise { sb = fb }
            fb = field
        } otherwise {
            fb = -1
            sb = -1
        }
        vb = p.ref_root[origin]
    }
    // Unknown origins must never count as a proof of disjointness.
    when va < 0 || vb < 0 { give true }
    when va != vb { give false }
    when fa >= 0 && fb >= 0 && fa != fb { give false }
    when fa >= 0 && fb >= 0 && sa >= 0 && sb >= 0 && sa != sb { give false }
    give true
}

// Value type of by-value call argument `k`.
flow cfgArgType(p: view CfgProgram, f: Int, k: Int) => Int {
    hold arg = view p.call_args[k]
    give cfgOperandType(p, f, arg)
}

// Argument types, modes and aliasing of one call of `f`.
expose flow cfgCheckCallArgs(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold target_first = p.functions[inst.callee].first_var
    each n among 0..inst.argc {
        hold k = inst.arg_first + n
        hold mode = p.call_ref[k]
        hold param_ref = p.var_ref[target_first + n]
        hold param_type = p.types_code[target_first + n]
        when mode < 0 {
            when param_ref || cfgArgType(p, f, k) != param_type { give 54 }
        } otherwise {
            hold place = CfgPlace(variable: p.call_args[k].value, field: p.call_field[k], subfield: p.call_sub[k], ext: p.call_ext[k])
            when !param_ref || cfgPlaceType(p, f, view place) != param_type { give 54 }
            when mode == 0 && cfgParamNeedsMut(p, inst.callee, n) { give 98 }
        }
        each m among 0..n {
            hold other = inst.arg_first + m
            hold other_mode = p.call_ref[other]
            when cfgArgsOverlap(p, f, other, k) {
                when mode == 1 || other_mode == 1 { give 99 }
                when mode < 0 && other_mode >= 0 && cfgIsMove(cfgArgType(p, f, k)) { give 99 }
                when other_mode < 0 && mode >= 0 && cfgIsMove(cfgArgType(p, f, other)) { give 99 }
            }
        }
    }
    give 0
}
