import lir_tokens
import native_layout
import native_cfg_defs

pub fn cfgType(p: &CfgProgram, source: &Text, reader: &mut NativeReader) -> Int {
    let w = nativeWord(source, &mut reader)
    if nativeEquals(source, &w, "i") { return 0 }
    if nativeEquals(source, &w, "b") { return 1 }
    if w.start < w.end && source.byteAt(w.start) == 115 {
        let id = nativeDecimal(source, &mut reader, &w, 1)
        if id >= 0 && id < p.structs.length { return 2 + id }
    }
    if w.start < w.end && source.byteAt(w.start) == 101 {
        let id = nativeDecimal(source, &mut reader, &w, 1)
        if id >= 0 && id < p.enums.length { return 2 + p.structs.length + id }
    }
    reader.error = 30
    return -1
}

pub fn cfgTypeSize(p: &CfgProgram, ty: Int) -> Int {
    if ty == 0 { return 8 }
    if ty == 1 { return 1 }
    if ty >= 2 && ty - 2 < p.structs.length { return p.structs[ty - 2].size }
    let enum_id = ty - 2 - p.structs.length
    if enum_id >= 0 && enum_id < p.enums.length { return p.enums[enum_id].size }
    return -1
}

pub fn cfgTypeAlign(p: &CfgProgram, ty: Int) -> Int {
    if ty == 0 { return 8 }
    if ty == 1 { return 1 }
    if ty >= 2 && ty - 2 < p.structs.length { return p.structs[ty - 2].align }
    let enum_id = ty - 2 - p.structs.length
    if enum_id >= 0 && enum_id < p.enums.length { return p.enums[enum_id].align }
    return -1
}

// Structs in ELE are MOVE-only, even when all their fields are primitives.
// The backend currently accepts only drop-free structs. A type may refer
// to a previously completed struct, yielding acyclic by-value layouts.
// The verifier invalidates whole-value move sources; `read` of a struct
// field (partial move) remains rejected until move paths are implemented.
// Text, Lists, loans and unknown types remain unsupported.
pub fn cfgReadStruct(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, sid: Int) {
    nativeExpect(source, &mut reader, "struct")
    let id = nativeId(source, &mut reader, 115)
    let name = nativeWord(source, &mut reader)
    nativeExpect(source, &mut reader, "fields")
    let count = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || id != sid || !cfgEncodedName(source, &name) || count < 1 || count > 4 {
        p.error = 60
        return
    }
    var layout = nativeLayoutNew()
    let first = p.fields.length
    for i in 0..count {
        nativeExpect(source, &mut reader, "field")
        let fname = nativeWord(source, &mut reader)
        let ty = cfgType(p, source, &mut reader)
        nativeEndLine(source, &mut reader)
        if reader.error != 0 || !cfgEncodedName(source, &fname) || ty < 0 {
            p.error = 61
            break
        }
        let offset = nativeLayoutAdd(&mut layout, cfgTypeSize(p, ty), cfgTypeAlign(p, ty), false)
        if offset < 0 { p.error = 62; break }
        p.fields.push(CfgField(ty: ty, offset: offset))
    }
    if p.error != 0 { return }
    let size = nativeLayoutSeal(&mut layout)
    if size <= 0 || size > 512 { p.error = 63; return }
    p.structs.push(CfgStruct(first_field: first, fields: count, size: size, align: layout.align))
}

// Read a complete enum descriptor from the official ELE-LIR 1 extension:
// enum eN <encoded-name> variants V
// variant <encoded-name> types 0|1 [i|b]
// No user-provided layouts and no heap/owned payloads are trusted here.
pub fn cfgReadEnum(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, id: Int) {
    nativeExpect(source, &mut reader, "enum")
    let actual = nativeId(source, &mut reader, 101)
    let name = nativeWord(source, &mut reader)
    nativeExpect(source, &mut reader, "variants")
    let count = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || actual != id || !cfgEncodedName(source, &name) || count < 1 || count > 8 {
        p.error = 80
        return
    }
    let first = p.variants.length
    var any_payload = false
    for v in 0..count {
        nativeExpect(source, &mut reader, "variant")
        let vname = nativeWord(source, &mut reader)
        nativeExpect(source, &mut reader, "types")
        let argc = nativeNumber(source, &mut reader)
        if argc < 0 || argc > 1 { p.error = 81; return }
        var payload = -1
        if argc == 1 { payload = cfgType(p, source, &mut reader) }
        nativeEndLine(source, &mut reader)
        if reader.error != 0 || !cfgEncodedName(source, &vname) || payload > 1 {
            p.error = 82
            return
        }
        if argc == 1 { any_payload = true }
        p.variants.push(CfgVariant(payload_type: payload))
    }
    var size = 8
    if any_payload { size = 16 }
    p.enums.push(CfgEnum(first_variant: first, variants: count, size: size, align: 8))
}

// Supports direct places `pN.M` and two-level primitive projections
// `pN.M.K`. A field holding another struct cannot be read by value yet:
// doing so would partially move its parent and require move-path flags.
pub fn cfgReadPlace(p: &CfgProgram, f: Int, source: &Text, reader: &mut NativeReader) -> CfgPlace {
    let w = nativeWord(source, &mut reader)
    var dot1 = w.start
    while dot1 < w.end && source.byteAt(dot1) != 46 { dot1 += 1 }
    if dot1 <= w.start + 1 || dot1 >= w.end - 1 || source.byteAt(w.start) != 112 {
        reader.error = 70
        return CfgPlace(variable: -1, field: -1, subfield: -1)
    }
    var dot2 = dot1 + 1
    while dot2 < w.end && source.byteAt(dot2) != 46 { dot2 += 1 }
    if dot2 == dot1 + 1 || dot2 == w.end - 1 {
        reader.error = 70
        return CfgPlace(variable: -1, field: -1, subfield: -1)
    }
    let root_word = NativeWord(start: w.start, end: dot1)
    let field_word = NativeWord(start: dot1 + 1, end: dot2)
    let variable = nativeDecimal(source, &mut reader, &root_word, 1)
    let field = nativeDecimal(source, &mut reader, &field_word, 0)
    var subfield = -1
    if dot2 < w.end {
        let nested_word = NativeWord(start: dot2 + 1, end: w.end)
        subfield = nativeDecimal(source, &mut reader, &nested_word, 0)
    }
    if variable < 0 || variable >= p.functions[f].vars || field < 0 || reader.error != 0 {
        reader.error = 70
        return CfgPlace(variable: -1, field: -1, subfield: -1)
    }
    let ty = p.types_code[p.functions[f].first_var + variable]
    if ty < 2 || ty - 2 >= p.structs.length || field >= p.structs[ty - 2].fields {
        reader.error = 70
        return CfgPlace(variable: -1, field: -1, subfield: -1)
    }
    if subfield >= 0 {
        let st = &p.structs[ty - 2]
        let child_ty = p.fields[st.first_field + field].ty
        if child_ty < 2 || subfield >= p.structs[child_ty - 2].fields {
            reader.error = 70
            return CfgPlace(variable: -1, field: -1, subfield: -1)
        }
    }
    return CfgPlace(variable: variable, field: field, subfield: subfield)
}

pub fn cfgPlaceType(p: &CfgProgram, f: Int, place: &CfgPlace) -> Int {
    if place.variable < 0 || place.variable >= p.functions[f].vars { return -1 }
    let ty = p.types_code[p.functions[f].first_var + place.variable]
    if ty < 2 || ty - 2 >= p.structs.length { return -1 }
    let st = &p.structs[ty - 2]
    if place.field < 0 || place.field >= st.fields { return -1 }
    let first_ty = p.fields[st.first_field + place.field].ty
    if place.subfield < 0 { return first_ty }
    if first_ty < 2 || first_ty - 2 >= p.structs.length { return -1 }
    let child = &p.structs[first_ty - 2]
    if place.subfield >= child.fields { return -1 }
    return p.fields[child.first_field + place.subfield].ty
}

// Strict ASCII-only identifier decoding for this bootstrap subset.
// Reject malformed lengths and byte sequences rather than accepting a
// token whose spelling happens to occupy one whitespace-separated word.
pub fn cfgEncodedName(source: &Text, name: &NativeWord) -> Bool {
    var pos = name.start
    var declared = 0
    var digits = 0
    while pos < name.end {
        let b = source.byteAt(pos)
        if b == 58 { break }
        if b < 48 || b > 57 { return false }
        if declared > 100 { return false }
        declared = declared * 10 + b - 48
        digits += 1
        pos += 1
    }
    if digits == 0 || declared < 1 || declared > 128 || pos >= name.end { return false }
    pos += 1
    var seen = 0
    while pos < name.end {
        var number = 0
        var length = 0
        while pos < name.end {
            let b = source.byteAt(pos)
            if b == 44 { break }
            if b < 48 || b > 57 { return false }
            number = number * 10 + b - 48
            length += 1
            if length > 3 { return false }
            pos += 1
        }
        if length == 0 || number < 32 || number > 126 { return false }
        seen += 1
        if seen > declared { return false }
        if pos < name.end { pos += 1; if pos == name.end { return false } }
    }
    return seen == declared
}

pub fn cfgBinaryOp(source: &Text, w: &NativeWord) -> Int {
    if nativeEquals(source, w, "add") { return 1 }
    if nativeEquals(source, w, "sub") { return 2 }
    if nativeEquals(source, w, "mul") { return 3 }
    if nativeEquals(source, w, "eq") { return 4 }
    if nativeEquals(source, w, "ne") { return 5 }
    if nativeEquals(source, w, "lt") { return 6 }
    if nativeEquals(source, w, "le") { return 7 }
    if nativeEquals(source, w, "gt") { return 8 }
    if nativeEquals(source, w, "ge") { return 9 }
    return 0
}

pub fn cfgOperandType(p: &CfgProgram, f: Int, op: &NativeOperand) -> Int {
    if !op.is_var {
        if op.is_bool { return 1 }
        return 0
    }
    if op.value < 0 || op.value >= p.functions[f].vars { return -1 }
    let slot = p.functions[f].first_var + op.value
    return p.types_code[slot]
}

