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
    if w.start < w.end && source.byteAt(w.start) == 108 {
        // A list is three words whatever its element, so `lK` is usable
        // before `list lK` is read; only the declared count matters.
        let id = nativeDecimal(source, &mut reader, &w, 1)
        if id >= 0 && id < p.decl_lists { return 2 + p.decl_structs + p.decl_enums + id }
    }
    reader.error = 30
    return -1
}

pub fn cfgUnitType() -> Int {
    return -2
}

pub fn cfgTextType() -> Int {
    return -3
}

// Values whose assignment transfers ownership instead of copying.
pub fn cfgIsMove(ty: Int) -> Bool {
    return ty >= 2 || ty == cfgTextType()
}

// Value types plus `u` and `t`. Callers decide where each is acceptable;
// aggregates keep using cfgType, so Text cannot appear inside them.
pub fn cfgTypeOrUnit(p: &CfgProgram, source: &Text, reader: &mut NativeReader) -> Int {
    var probe = NativeReader(offset: reader.offset, error: 0)
    let w = nativeWord(source, &mut probe)
    if nativeEquals(source, &w, "u") {
        reader.offset = probe.offset
        return cfgUnitType()
    }
    if nativeEquals(source, &w, "t") {
        reader.offset = probe.offset
        return cfgTextType()
    }
    return cfgType(p, source, &mut reader)
}

pub fn cfgTypeSize(p: &CfgProgram, ty: Int) -> Int {
    if ty == 0 { return 8 }
    // A unit variable owns one never-read slot so that slot math stays uniform.
    if ty == cfgUnitType() { return 8 }
    if ty == cfgTextType() || cfgListIndex(p, ty) >= 0 { return 24 }
    if ty == 1 { return 1 }
    if ty >= 2 && ty - 2 < p.structs.length { return p.structs[ty - 2].size }
    let enum_id = ty - 2 - p.structs.length
    if enum_id >= 0 && enum_id < p.enums.length { return p.enums[enum_id].size }
    return -1
}

pub fn cfgTypeAlign(p: &CfgProgram, ty: Int) -> Int {
    if ty == 0 { return 8 }
    if ty == 1 { return 1 }
    if ty == cfgTextType() || cfgListIndex(p, ty) >= 0 { return 8 }
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
    if reader.error != 0 || id != sid || !cfgEncodedName(source, &name) || count < 1 || count > 64 {
        p.error = 60
        return
    }
    var layout = nativeLayoutNew()
    let first = p.fields.length
    for i in 0..count {
        nativeExpect(source, &mut reader, "field")
        let fname = nativeWord(source, &mut reader)
        // A field may own a Text (three words); see native_cfg_paths.
        let ty = cfgTypeOrUnit(p, source, &mut reader)
        nativeEndLine(source, &mut reader)
        if reader.error != 0 || !cfgEncodedName(source, &fname) || (ty < 0 && ty != cfgTextType()) {
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

fn cfgBadPlace(reader: &mut NativeReader) -> CfgPlace {
    reader.error = 70
    return CfgPlace(variable: -1, field: -1, subfield: -1, ext: -1)
}

// Decimal digits of `source` from `at` (at most seven). Returns the position
// after them; `out.start` receives the value and `out.end` the digit count.
fn cfgPlaceDigits(source: &Text, at: Int, end: Int, out: &mut NativeWord) -> Int {
    var pos = at
    var value = 0
    while pos < end && pos - at < 7 {
        let b = source.byteAt(pos)
        if b < 48 || b > 57 { break }
        value = value * 10 + b - 48
        pos += 1
    }
    out.start = value
    out.end = pos - at
    return pos
}

// A place is `p<N>` followed by projections: `.k` (field k of a shape) and
// `[v<I>]` (element of a list at the Int variable I). When `pN` is a
// reference parameter the place denotes its referent.
//
// The first two fields before any index are the static prefix
// (`field`/`subfield`), whose ownership the verifier follows with move
// paths. Everything after it is the extension (`ext`): storage reached
// through a list buffer or deeper than the tracked paths. An extension
// never moves ownership: reads through it are copies of heap-free values
// (see native_cfg_list).
pub fn cfgReadPlace(p: &mut CfgProgram, f: Int, source: &Text, reader: &mut NativeReader) -> CfgPlace {
    let w = nativeWord(source, &mut reader)
    if reader.error != 0 || w.end - w.start < 2 || source.byteAt(w.start) != 112 { return cfgBadPlace(&mut reader) }
    var number = NativeWord(start: 0, end: 0)
    var pos = cfgPlaceDigits(source, w.start + 1, w.end, &mut number)
    let variable = number.start
    if number.end == 0 || variable >= p.functions[f].vars { return cfgBadPlace(&mut reader) }
    var ty = p.types_code[p.functions[f].first_var + variable]
    var field = -1
    var subfield = -1
    var ext = -1
    var steps = 0
    while pos < w.end {
        steps += 1
        if steps > 8 { return cfgBadPlace(&mut reader) }
        let b = source.byteAt(pos)
        if b == 46 {
            pos = cfgPlaceDigits(source, pos + 1, w.end, &mut number)
            let k = number.start
            if number.end == 0 || ty < 2 || ty - 2 >= p.structs.length || k >= p.structs[ty - 2].fields { return cfgBadPlace(&mut reader) }
            ty = p.fields[p.structs[ty - 2].first_field + k].ty
            if ext < 0 && field < 0 {
                field = k
            } else if ext < 0 && subfield < 0 {
                subfield = k
            } else {
                if ext < 0 {
                    ext = p.ext_first.length
                    p.ext_first.push(p.proj_kind.length)
                    p.ext_count.push(0)
                }
                p.proj_kind.push(0)
                p.proj_value.push(k)
            }
        } else if b == 91 {
            if pos + 1 >= w.end || source.byteAt(pos + 1) != 118 { return cfgBadPlace(&mut reader) }
            pos = cfgPlaceDigits(source, pos + 2, w.end, &mut number)
            let iv = number.start
            let list = cfgListIndex(p, ty)
            if number.end == 0 || pos >= w.end || source.byteAt(pos) != 93 || list < 0 || iv >= p.functions[f].vars { return cfgBadPlace(&mut reader) }
            pos += 1
            let slot = p.functions[f].first_var + iv
            if p.types_code[slot] != 0 || p.var_ref[slot] { return cfgBadPlace(&mut reader) }
            ty = p.list_elem[list]
            if ext < 0 {
                ext = p.ext_first.length
                p.ext_first.push(p.proj_kind.length)
                p.ext_count.push(0)
            }
            p.proj_kind.push(1)
            p.proj_value.push(iv)
        } else {
            return cfgBadPlace(&mut reader)
        }
    }
    if ext >= 0 { p.ext_count[ext] = p.proj_kind.length - p.ext_first[ext] }
    return CfgPlace(variable: variable, field: field, subfield: subfield, ext: ext)
}

// Type of the static prefix of a place (without its extension).
fn cfgPrefixType(p: &CfgProgram, f: Int, place: &CfgPlace) -> Int {
    if place.variable < 0 || place.variable >= p.functions[f].vars { return -1 }
    let ty = p.types_code[p.functions[f].first_var + place.variable]
    if place.field < 0 { return ty }
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

pub fn cfgPlaceType(p: &CfgProgram, f: Int, place: &CfgPlace) -> Int {
    var ty = cfgPrefixType(p, f, place)
    if place.ext < 0 || ty == -1 { return ty }
    if place.ext >= p.ext_first.length { return -1 }
    let first = p.ext_first[place.ext]
    for n in first..(first + p.ext_count[place.ext]) {
        if p.proj_kind[n] == 1 {
            let list = cfgListIndex(p, ty)
            if list < 0 { return -1 }
            ty = p.list_elem[list]
        } else {
            if ty < 2 || ty - 2 >= p.structs.length || p.proj_value[n] >= p.structs[ty - 2].fields { return -1 }
            ty = p.fields[p.structs[ty - 2].first_field + p.proj_value[n]].ty
        }
    }
    return ty
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
    if nativeEquals(source, w, "div") { return 10 }
    if nativeEquals(source, w, "rem") { return 11 }
    return 0
}

pub fn cfgOperandType(p: &CfgProgram, f: Int, op: &NativeOperand) -> Int {
    if !op.is_var {
        if op.is_unit { return cfgUnitType() }
        if op.is_text { return cfgTextType() }
        if op.is_bool { return 1 }
        return 0
    }
    if op.value < 0 || op.value >= p.functions[f].vars { return -1 }
    let slot = p.functions[f].first_var + op.value
    // A reference is never a value operand: it cannot be copied, moved,
    // returned or stored. Only places and reference arguments may name it.
    if p.var_ref[slot] { return -1 }
    return p.types_code[slot]
}


// Reads `ct<n>:<b>,<b>,...` (n bytes, each 0..255) into the literal table.
// Returns the literal index, or -1 after setting a reader error.
fn cfgReadTextLiteral(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, w: &NativeWord) -> Int {
    var pos = w.start + 2
    var declared = 0
    var digits = 0
    while pos < w.end {
        let b = source.byteAt(pos)
        if b == 58 { break }
        if b < 48 || b > 57 || declared > 65536 { reader.error = 12; return -1 }
        declared = declared * 10 + b - 48
        digits += 1
        pos += 1
    }
    if digits == 0 || declared > 65536 || pos >= w.end { reader.error = 12; return -1 }
    pos += 1
    let first = p.text_bytes.length
    var seen = 0
    while pos < w.end {
        var number = 0
        var length = 0
        while pos < w.end {
            let b = source.byteAt(pos)
            if b == 44 { break }
            if b < 48 || b > 57 || length == 3 { reader.error = 12; return -1 }
            number = number * 10 + b - 48
            length += 1
            pos += 1
        }
        if length == 0 || number > 255 || seen == declared { reader.error = 12; return -1 }
        p.text_bytes.push(number)
        seen += 1
        if pos < w.end {
            pos += 1
            if pos == w.end { reader.error = 12; return -1 }
        }
    }
    if seen != declared { reader.error = 12; return -1 }
    p.text_start.push(first)
    p.text_length.push(declared)
    return p.text_start.length - 1
}

// Any operand, including Text literals, which need the program to store
// their bytes. Positions that cannot hold Text keep using nativeOperand.
pub fn cfgOperand(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader) -> NativeOperand {
    var probe = NativeReader(offset: reader.offset, error: 0)
    let w = nativeWord(source, &mut probe)
    if w.end - w.start >= 4 && source.byteAt(w.start) == 99 && source.byteAt(w.start + 1) == 116 {
        reader.offset = probe.offset
        let index = cfgReadTextLiteral(&mut p, source, &mut reader, &w)
        return NativeOperand(is_var: false, value: index, is_bool: false, is_unit: false, is_text: index >= 0)
    }
    return nativeOperand(source, &mut reader)
}

// `ref p<N> 0`: a shared reference to a whole variable. Projections and
// exclusive references are not lowered yet and are rejected.
pub fn cfgSharedVar(p: &CfgProgram, f: Int, source: &Text, reader: &mut NativeReader) -> Int {
    let variable = nativeId(source, &mut reader, 112)
    let exclusive = nativeNumber(source, &mut reader)
    if reader.error != 0 || exclusive != 0 || variable < 0 || variable >= p.functions[f].vars {
        reader.error = 13
        return -1
    }
    return variable
}
