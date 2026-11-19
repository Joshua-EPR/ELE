take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_layout

// Text fields of shapes in the ELE-written CFG backend: projected sources
// of `print`/`append` (`ref pN.k[.j] 0`) and `i dropfield <place> v<flag>|-`
// (kind 17), which releases the Text stored in a field.
//
// Ownership of Text fields is checked with move paths (native_cfg_paths):
// reading a Text field of an owned shape moves it, dropfield releases it,
// and a store may only fill a field whose Text was moved or released.

// `ref <place> 0` as the source of print/append. Returns 0 or a code.
expose flow cfgReadSourceRef(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) => Int {
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    hold exclusive = nativeNumber(source, edit reader)
    when reader.error != 0 || place.variable < 0 || exclusive != 0 { give 13 }
    inst.op = place.variable
    inst.src_field = place.field
    inst.src_sub = place.subfield
    inst.src_ext = place.ext
    give 0
}

// Type of the source of print/append, seen through its place.
expose flow cfgSourcePlaceType(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    when inst.op < 0 { give cfgOperandType(p, f, view inst.a) }
    hold place = CfgPlace(variable: inst.op, field: inst.src_field, subfield: inst.src_sub, ext: inst.src_ext)
    give cfgPlaceType(p, f, view place)
}

expose flow cfgReadDropField(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 17
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    inst.place_var = place.variable
    inst.place_field = place.field
    inst.place_subfield = place.subfield
    inst.place_ext = place.ext
    change probe = NativeReader(offset: reader.offset, error: 0)
    hold flag = nativeWord(source, edit probe)
    when nativeEquals(source, view flag, "-") {
        reader.offset = probe.offset
        inst.op = -1
    } otherwise {
        inst.op = nativeId(source, edit reader, 118)
    }
}

// A dropfield names a Text or list field (not a whole variable, and not a
// place inside a list) and an optional Bool flag.
expose flow cfgCheckDropField(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
    when inst.place_field < 0 || inst.place_ext >= 0 || !cfgHeapDirect(p, cfgPlaceType(p, f, view place)) { give 92 }
    when inst.op >= 0 {
        when inst.op >= p.functions[f].vars { give 94 }
        hold first = p.functions[f].first_var
        when p.types_code[first + inst.op] != 1 || p.var_ref[first + inst.op] { give 94 }
    }
    give 0
}

// Whether a value of type `ty` owns heap storage: a Text or a list, directly
// or in a nested field, or an enum variant with an owned payload. Only such
// values need drops; the others may be copied bitwise. A list answers without
// looking at its element, so a shape that holds a list of itself terminates.
expose flow cfgOwnsHeap(p: view CfgProgram, ty: Int) => Bool {
    when cfgHeapDirect(p, ty) { give true }
    when ty < 2 { give false }
    when ty - 2 < p.structs.length {
        hold first = p.structs[ty - 2].first_field
        each k among 0..p.structs[ty - 2].fields {
            when cfgOwnsHeap(p, p.fields[first + k].ty) { give true }
        }
        give false
    }
    hold enum_id = ty - 2 - p.structs.length
    when enum_id >= 0 && enum_id < p.enums.length {
        hold first = p.enums[enum_id].first_variant
        each v among first..(first + p.enums[enum_id].variants) {
            hold payload = p.variants[v].payload_type
            when payload != -1 && cfgOwnsHeap(p, payload) { give true }
        }
    }
    give false
}

// Whether `ty` is a union (enum) with at least one variant whose payload owns
// heap storage: the only unions that a whole `i drop` may release.
expose flow cfgOwningUnion(p: view CfgProgram, ty: Int) => Bool {
    hold enum_id = ty - 2 - p.structs.length
    when ty < 2 || enum_id < 0 || enum_id >= p.enums.length { give false }
    give cfgOwnsHeap(p, ty)
}

// Declaration layouts (after cfgReadStruct/cfgReadEnum in native_cfg_types).
// Lays out struct `s` once all its field types are sized. Returns 1 when it
// was laid out now, 0 when it must wait, or an error code.
flow cfgLayoutStruct(p: edit CfgProgram, s: Int) => Int {
    hold first = p.structs[s].first_field
    hold count = p.structs[s].fields
    each k among first..(first + count) {
        when cfgTypeSize(p, p.fields[k].ty) <= 0 { give 0 }
    }
    change layout = nativeLayoutNew()
    each k among first..(first + count) {
        hold ty = p.fields[k].ty
        hold offset = nativeLayoutAdd(edit layout, cfgTypeSize(p, ty), cfgTypeAlign(p, ty), false)
        when offset < 0 { give 62 }
        p.fields[k].offset = offset
    }
    hold size = nativeLayoutSeal(edit layout)
    when size <= 0 || size > cfgMaxValueBytes() { give 63 }
    p.structs[s].size = size
    p.structs[s].align = layout.align
    give 1
}

// Enum layout: an 8-byte tag at offset 0 and, when some variant carries a
// payload, a payload area at offset 8 sized by the largest payload rounded
// up to whole words. Every alignment in this backend is at most 8, so
// offset 8 suits any payload. Payloads may own heap storage (Text, list,
// nested aggregates) and are sized accordingly; alignment > 8 is rejected (82).
flow cfgLayoutEnum(p: edit CfgProgram, e: Int) => Int {
    hold first = p.enums[e].first_variant
    hold count = p.enums[e].variants
    change largest = 0
    each v among first..(first + count) {
        hold payload = p.variants[v].payload_type
        when payload != -1 {
            when cfgTypeSize(p, payload) <= 0 { give 0 }
            when cfgTypeAlign(p, payload) > 8 { give 82 }
            hold size = cfgTypeSize(p, payload)
            when size > largest { largest = size }
        }
    }
    change size = 8
    when largest > 0 { size = 8 + 8 * ((largest + 7) / 8) }
    when size > 8 + cfgMaxValueBytes() { give 63 }
    p.enums[e].size = size
    p.enums[e].align = 8
    give 1
}

// Fixed point over the declarations: each round lays out every struct and
// enum whose members are already sized. A round without progress while a
// declaration is pending means a by-value cycle (63).
expose flow cfgLayoutDecls(p: edit CfgProgram) {
    hold total = p.structs.length + p.enums.length
    change done = 0
    during done < total {
        change progress = 0
        each s among 0..p.structs.length {
            when p.error == 0 && p.structs[s].size == 0 {
                hold r = cfgLayoutStruct(edit p, s)
                when r > 1 { p.error = r }
                when r == 1 { progress += 1 }
            }
        }
        each e among 0..p.enums.length {
            when p.error == 0 && p.enums[e].size == 0 {
                hold r = cfgLayoutEnum(edit p, e)
                when r > 1 { p.error = r }
                when r == 1 { progress += 1 }
            }
        }
        when p.error != 0 { give }
        when progress == 0 { p.error = 63; give }
        done += progress
    }
}
