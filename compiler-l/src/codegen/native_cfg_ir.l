import lir_tokens
import native_layout

// Restricted, typed, flattened representation of ELE-LIR 1 for the
// independent ELE-written x86-64 bootstrap backend. Supports move-only,
// drop-free structs with primitive fields (including nested structs).
// Also supports tagged enums with zero or one primitive payload per variant.
// Text, loans, floats, arrays and side effects are explicitly rejected.
// Type IDs: 0 = Int, 1 = Bool, 2+s = nominal struct s,
// 2+struct_count+e = nominal enum e.
// Instruction kinds: 1 use, 2 binary, 3 call, 4 struct, 5 read,
// 6 store, 7 variant, 8 discriminant, 9 checked primitive payload.
// Binary operations: 1 add, 2 sub, 3 mul, 4 eq, 5 ne, 6 lt,
// 7 le, 8 gt, 9 ge. Terminators: 1 return, 2 jump, 3 branch.

pub struct CfgInst {
    kind: Int
    dst: Int
    op: Int
    callee: Int
    argc: Int
    a: NativeOperand
    b: NativeOperand
    c: NativeOperand
    d: NativeOperand
    place_var: Int
    place_field: Int
    place_subfield: Int
}

pub struct CfgField {
    ty: Int
    offset: Int
}

pub struct CfgStruct {
    first_field: Int
    fields: Int
    size: Int
    align: Int
}

// Monomorphized tagged enums. This bootstrap subset supports only variants
// with no payload or one primitive Int/Bool payload. Each enum is move-only
// and drop-free. A populated payload slot is always fully initialized,
// including for None/unit variants, so whole-value moves copy defined bytes.
pub struct CfgEnum {
    first_variant: Int
    variants: Int
    size: Int
    align: Int
}

pub struct CfgVariant {
    payload_type: Int
}

pub struct CfgPlace {
    variable: Int
    field: Int
    subfield: Int
}

pub struct CfgBlock {
    first: Int
    count: Int
    term: Int
    value: NativeOperand
    yes: Int
    no: Int
}

pub struct CfgFunc {
    first_var: Int
    vars: Int
    first_block: Int
    blocks: Int
    params: Int
    result_bool: Bool
}

pub struct CfgProgram {
    error: Int
    main: Int
    functions: List<CfgFunc>
    types_bool: List<Bool>
    types_code: List<Int>
    slot_start: List<Int>
    slot_count: List<Int>
    structs: List<CfgStruct>
    fields: List<CfgField>
    enums: List<CfgEnum>
    variants: List<CfgVariant>
    blocks: List<CfgBlock>
    insts: List<CfgInst>
}

fn cfgEmptyOperand() -> NativeOperand {
    return NativeOperand(is_var: false, value: 0, is_bool: false)
}

fn cfgEmpty() -> CfgProgram {
    return CfgProgram(error: 0, main: -1, functions: List[], types_bool: List[], types_code: List[], slot_start: List[], slot_count: List[], structs: List[], fields: List[], enums: List[], variants: List[], blocks: List[], insts: List[])
}

fn cfgType(p: &CfgProgram, source: &Text, reader: &mut NativeReader) -> Int {
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

fn cfgTypeSize(p: &CfgProgram, ty: Int) -> Int {
    if ty == 0 { return 8 }
    if ty == 1 { return 1 }
    if ty >= 2 && ty - 2 < p.structs.length { return p.structs[ty - 2].size }
    let enum_id = ty - 2 - p.structs.length
    if enum_id >= 0 && enum_id < p.enums.length { return p.enums[enum_id].size }
    return -1
}

fn cfgTypeAlign(p: &CfgProgram, ty: Int) -> Int {
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
fn cfgReadStruct(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, sid: Int) {
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
fn cfgReadEnum(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, id: Int) {
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
fn cfgReadPlace(p: &CfgProgram, f: Int, source: &Text, reader: &mut NativeReader) -> CfgPlace {
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

fn cfgPlaceType(p: &CfgProgram, f: Int, place: &CfgPlace) -> Int {
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
fn cfgEncodedName(source: &Text, name: &NativeWord) -> Bool {
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

fn cfgBinaryOp(source: &Text, w: &NativeWord) -> Int {
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

fn cfgReadInst(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int) {
    nativeExpect(source, &mut reader, "i")
    let kind = nativeWord(source, &mut reader)
    var inst = CfgInst(kind: 0, dst: -1, op: 0, callee: -1, argc: 0,
        a: cfgEmptyOperand(), b: cfgEmptyOperand(), c: cfgEmptyOperand(), d: cfgEmptyOperand(),
        place_var: -1, place_field: -1, place_subfield: -1)
    if nativeEquals(source, &kind, "use") {
        inst.kind = 1
        inst.dst = nativeId(source, &mut reader, 118)
        inst.a = nativeOperand(source, &mut reader)
    } else if nativeEquals(source, &kind, "binary") {
        inst.kind = 2
        inst.dst = nativeId(source, &mut reader, 118)
        let op = nativeWord(source, &mut reader)
        inst.op = cfgBinaryOp(source, &op)
        inst.a = nativeOperand(source, &mut reader)
        inst.b = nativeOperand(source, &mut reader)
    } else if nativeEquals(source, &kind, "call") {
        inst.kind = 3
        inst.dst = nativeId(source, &mut reader, 118)
        inst.callee = nativeId(source, &mut reader, 102)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 0 || inst.argc > 2 { p.error = 32 }
        if inst.argc >= 1 && inst.argc <= 2 {
            nativeExpect(source, &mut reader, "val")
            inst.a = nativeOperand(source, &mut reader)
        }
        if inst.argc == 2 {
            nativeExpect(source, &mut reader, "val")
            inst.b = nativeOperand(source, &mut reader)
        }
    } else if nativeEquals(source, &kind, "struct") {
        inst.kind = 4
        inst.dst = nativeId(source, &mut reader, 118)
        inst.op = nativeId(source, &mut reader, 115)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 1 || inst.argc > 4 { p.error = 64 }
        if inst.argc >= 1 && inst.argc <= 4 { inst.a = nativeOperand(source, &mut reader) }
        if inst.argc >= 2 && inst.argc <= 4 { inst.b = nativeOperand(source, &mut reader) }
        if inst.argc >= 3 && inst.argc <= 4 { inst.c = nativeOperand(source, &mut reader) }
        if inst.argc == 4 { inst.d = nativeOperand(source, &mut reader) }
    } else if nativeEquals(source, &kind, "read") {
        inst.kind = 5
        inst.dst = nativeId(source, &mut reader, 118)
        let place = cfgReadPlace(p, f, source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
    } else if nativeEquals(source, &kind, "store") {
        inst.kind = 6
        let place = cfgReadPlace(p, f, source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
        inst.a = nativeOperand(source, &mut reader)
    } else if nativeEquals(source, &kind, "variant") {
        inst.kind = 7
        inst.dst = nativeId(source, &mut reader, 118)
        inst.op = nativeId(source, &mut reader, 101)
        inst.place_field = nativeNumber(source, &mut reader)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 0 || inst.argc > 1 { p.error = 83 }
        if inst.argc == 1 { inst.a = nativeOperand(source, &mut reader) }
    } else if nativeEquals(source, &kind, "disc") {
        inst.kind = 8
        inst.dst = nativeId(source, &mut reader, 118)
        // pN, without any projections, is the only accepted place here.
        // The discriminant access does not consume the enum owner.
        inst.place_var = nativeId(source, &mut reader, 112)
    } else if nativeEquals(source, &kind, "payload") {
        // Experimental checked read: i payload vD pN eK V.
        // The source enum remains live because the payload must be Copy.
        // The emitter checks the active discriminant at runtime BEFORE
        // accessing memory. This does not permit owning payload extraction.
        inst.kind = 9
        inst.dst = nativeId(source, &mut reader, 118)
        inst.place_var = nativeId(source, &mut reader, 112)
        inst.op = nativeId(source, &mut reader, 101)
        inst.place_field = nativeNumber(source, &mut reader)
    } else {
        p.error = 31
    }
    nativeEndLineSpan(source, &mut reader)
    if reader.error != 0 || (inst.kind != 6 && (inst.dst < 0 || inst.dst >= p.functions[f].vars)) {
        p.error = 33
    }
    if p.error != 0 { return }
    var dest_type = -1
    if inst.kind != 6 { dest_type = p.types_code[p.functions[f].first_var + inst.dst] }
    let first_type = cfgOperandType(p, f, &inst.a)
    if inst.kind == 1 && first_type != dest_type { p.error = 34 }
    if inst.kind == 2 {
        let second_type = cfgOperandType(p, f, &inst.b)
        if inst.op == 0 || first_type < 0 || second_type < 0 { p.error = 35 }
        if inst.op <= 3 && (dest_type != 0 || first_type != 0 || second_type != 0) { p.error = 36 }
        if inst.op >= 4 && (dest_type != 1 || first_type != second_type || first_type > 1) { p.error = 36 }
        if inst.op >= 6 && first_type != 0 { p.error = 36 }
    }
    if inst.kind == 3 && inst.argc >= 1 && (first_type < 0 || first_type >= 2) { p.error = 37 }
    if inst.kind == 3 && inst.argc == 2 && (cfgOperandType(p, f, &inst.b) < 0 || cfgOperandType(p, f, &inst.b) >= 2) { p.error = 37 }
    if inst.kind == 4 {
        if inst.op < 0 || inst.op >= p.structs.length || dest_type != inst.op + 2 { p.error = 65 }
        if p.error == 0 {
            let st = &p.structs[inst.op]
            if inst.argc != st.fields { p.error = 65 }
            if inst.argc >= 1 && first_type != p.fields[st.first_field].ty { p.error = 66 }
            if inst.argc >= 2 && cfgOperandType(p, f, &inst.b) != p.fields[st.first_field + 1].ty { p.error = 66 }
            if inst.argc >= 3 && cfgOperandType(p, f, &inst.c) != p.fields[st.first_field + 2].ty { p.error = 66 }
            if inst.argc == 4 && cfgOperandType(p, f, &inst.d) != p.fields[st.first_field + 3].ty { p.error = 66 }
        }
    }
    if inst.kind == 7 {
        if inst.op < 0 || inst.op >= p.enums.length { p.error = 84 }
        if p.error == 0 {
            let item = &p.enums[inst.op]
            if dest_type != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= item.variants {
                p.error = 85
            } else {
                let variant = &p.variants[item.first_variant + inst.place_field]
                var required = 0
                if variant.payload_type >= 0 { required = 1 }
                if inst.argc != required || (required == 1 && first_type != variant.payload_type) { p.error = 86 }
            }
        }
    }
    if inst.kind == 8 {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || dest_type != 0 {
            p.error = 87
        } else {
            let owner_type = p.types_code[p.functions[f].first_var + inst.place_var]
            let enum_index = owner_type - 2 - p.structs.length
            if enum_index < 0 || enum_index >= p.enums.length { p.error = 87 }
        }
    }
    if inst.kind == 9 {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || inst.op < 0 || inst.op >= p.enums.length {
            p.error = 88
        } else {
            let ty = p.types_code[p.functions[f].first_var + inst.place_var]
            let e = &p.enums[inst.op]
            if ty != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= e.variants {
                p.error = 88
            } else {
                let payload = p.variants[e.first_variant + inst.place_field].payload_type
                // A unit variant cannot be projected; only Int/Bool Copy
                // payloads are safe while the heap/drop runtime is absent.
                if payload < 0 || payload > 1 || dest_type != payload { p.error = 89 }
            }
        }
    }
    if inst.kind == 5 || inst.kind == 6 {
        let place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield)
        let ty = cfgPlaceType(p, f, &place)
        if ty < 0 { p.error = 67 }
        if inst.kind == 5 && dest_type != ty { p.error = 67 }
        if inst.kind == 6 && first_type != ty { p.error = 67 }
        // Reading a struct field by value would partially move its parent;
        // this subset has only whole-variable move flags, so reject it.
        if inst.kind == 5 && ty >= 2 { p.error = 73 }
    }
    if p.error == 0 { p.insts.push(inst) }
}

fn cfgReadBlock(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int, b: Int) {
    nativeExpect(source, &mut reader, "block")
    let id = nativeNumber(source, &mut reader)
    let count = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || id != b || count < 0 || count > 10000 {
        p.error = 38
        return
    }
    let first = p.insts.length
    for i in 0..count {
        if p.error != 0 { break }
        cfgReadInst(&mut p, source, &mut reader, f)
    }
    if p.error != 0 { return }
    nativeExpect(source, &mut reader, "t")
    let keyword = nativeWord(source, &mut reader)
    var kind = 0
    var value = cfgEmptyOperand()
    var yes = -1
    var no = -1
    if nativeEquals(source, &keyword, "return") {
        kind = 1
        value = nativeOperand(source, &mut reader)
    } else if nativeEquals(source, &keyword, "jump") {
        kind = 2
        yes = nativeNumber(source, &mut reader)
    } else if nativeEquals(source, &keyword, "branch") {
        kind = 3
        value = nativeOperand(source, &mut reader)
        yes = nativeNumber(source, &mut reader)
        no = nativeNumber(source, &mut reader)
    } else {
        p.error = 39
    }
    nativeEndLineSpan(source, &mut reader)
    if reader.error != 0 { p.error = 40 }
    if kind == 1 {
        var expected = 0
        if p.functions[f].result_bool { expected = 1 }
        if cfgOperandType(p, f, &value) != expected { p.error = 41 }
    }
    if kind == 3 && cfgOperandType(p, f, &value) != 1 { p.error = 42 }
    if (kind == 2 || kind == 3) && (yes < 0 || yes >= p.functions[f].blocks) { p.error = 43 }
    if kind == 3 && (no < 0 || no >= p.functions[f].blocks) { p.error = 43 }
    if p.error == 0 {
        p.blocks.push(CfgBlock(first: first, count: count, term: kind, value: value, yes: yes, no: no))
    }
}

fn cfgReadFunction(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int) {
    nativeExpect(source, &mut reader, "func")
    let id = nativeId(source, &mut reader, 102)
    let name = nativeWord(source, &mut reader)
    nativeExpect(source, &mut reader, "params")
    let params = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "result")
    let result_type = cfgType(p, source, &mut reader)
    let returned_ref = nativeNumber(source, &mut reader)
    let returned_mut = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "vars")
    let vars = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "blocks")
    let blocks = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || id != f || !cfgEncodedName(source, &name) || params < 0 || params > 2 || vars < params || vars > 64 || blocks < 1 || blocks > 32 || returned_ref != 0 || returned_mut != 0 || result_type < 0 {
        p.error = 44
        return
    }
    // Calls and returns of aggregates require ABI-specific lowering. Keep
    // those unsupported until the by-value calling convention is verified.
    if result_type >= 2 { p.error = 68; return }
    p.functions.push(CfgFunc(first_var: p.types_bool.length, vars: vars, first_block: p.blocks.length, blocks: blocks, params: params, result_bool: result_type == 1))
    var next_slot = 0
    for i in 0..vars {
        nativeExpect(source, &mut reader, "var")
        let vid = nativeId(source, &mut reader, 118)
        nativeExpect(source, &mut reader, "val")
        let ty = cfgType(p, source, &mut reader)
        nativeEndLine(source, &mut reader)
        if reader.error != 0 || vid != i || ty < 0 || (i < params && ty >= 2) { p.error = 45; break }
        let size = cfgTypeSize(p, ty)
        let count_slots = (size + 7) / 8
        if size < 1 || count_slots < 1 || next_slot + count_slots > 64 { p.error = 69; break }
        p.types_bool.push(ty == 1)
        p.types_code.push(ty)
        p.slot_start.push(next_slot)
        p.slot_count.push(count_slots)
        next_slot += count_slots
    }
    if p.error != 0 { return }
    for i in 0..blocks {
        if p.error != 0 { break }
        cfgReadBlock(&mut p, source, &mut reader, f, i)
    }
    if p.error != 0 { return }
    nativeExpect(source, &mut reader, "endfunc")
    nativeEndLine(source, &mut reader)
    if reader.error != 0 { p.error = 46 }
}

pub fn cfgParse(source: &Text) -> CfgProgram {
    var p = cfgEmpty()
    if source.byteLength == 0 || source.byteLength > 1048576 {
        p.error = 47
        return p
    }
    var r = nativeReaderNew()
    nativeExpect(source, &mut r, "ELE-LIR")
    nativeExpect(source, &mut r, "1")
    nativeEndLine(source, &mut r)
    nativeExpect(source, &mut r, "module")
    nativeExpect(source, &mut r, "structs")
    let structs = nativeNumber(source, &mut r)
    var probe = NativeReader(offset: r.offset, error: 0)
    let next_word = nativeWord(source, &mut probe)
    var enums = 0
    if nativeEquals(source, &next_word, "enums") {
        nativeExpect(source, &mut r, "enums")
        enums = nativeNumber(source, &mut r)
    }
    nativeExpect(source, &mut r, "funcs")
    let functions = nativeNumber(source, &mut r)
    nativeExpect(source, &mut r, "main")
    let main = nativeId(source, &mut r, 102)
    nativeEndLine(source, &mut r)
    if r.error != 0 || structs < 0 || structs > 16 || enums < 0 || enums > 16 || functions < 1 || functions > 16 || main < 0 || main >= functions {
        p.error = 48
        return p
    }
    p.main = main
    for i in 0..structs {
        if p.error != 0 { break }
        cfgReadStruct(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    for i in 0..enums {
        if p.error != 0 { break }
        cfgReadEnum(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    for i in 0..functions {
        if p.error != 0 { break }
        cfgReadFunction(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    nativeExpect(source, &mut r, "end")
    nativeEndLine(source, &mut r)
    if r.error != 0 || !nativeAtEnd(source, &r) {
        p.error = 49
        return p
    }
    if p.functions[main].params != 0 || p.functions[main].result_bool { p.error = 50 }
    return p
}
