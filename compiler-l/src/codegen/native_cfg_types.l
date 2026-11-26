take lir_tokens
take native_layout
take native_cfg_defs

expose flow cfgType(p: view CfgProgram, source: view Text, reader: edit NativeReader) => Int {
    hold w = nativeWord(source, edit reader)
    when nativeEquals(source, view w, "i") { give 0 }
    when nativeEquals(source, view w, "b") { give 1 }
    when nativeEquals(source, view w, "f") { give cfgFloatType() }
    when nativeEquals(source, view w, "h") { give cfgFileType() }
    when nativeEquals(source, view w, "w") { give cfgWindowType() }
    when w.start < w.end && source@byteAt(w.start) == 115 {
        hold id = nativeDecimal(source, edit reader, view w, 1)
        when id >= 0 && id < p.structs.length { give 2 + id }
    }
    when w.start < w.end && source@byteAt(w.start) == 101 {
        hold id = nativeDecimal(source, edit reader, view w, 1)
        when id >= 0 && id < p.enums.length { give 2 + p.structs.length + id }
    }
    when w.start < w.end && source@byteAt(w.start) == 108 {
        // A list is three words whatever its element, so `lK` is usable
        // before `list lK` is read; only the declared count matters.
        hold id = nativeDecimal(source, edit reader, view w, 1)
        when id >= 0 && id < p.decl_lists { give 2 + p.decl_structs + p.decl_enums + id }
    }
    reader.error = 30
    give -1
}

expose flow cfgUnitType() => Int {
    give -2
}

expose flow cfgTextType() => Int {
    give -3
}

// Call targets of the Float text routines (native_rt_float): -1 - (base + k),
// above every platform routine (native_cfg_platform: cfgPlatformBase() is
// 1048576) so the three target spaces never overlap.
expose flow cfgFloatRoutineBase() => Int { give 1052672 }

// Float: an IEEE-754 binary64 value kept as its bit pattern in one 8-byte
// word, so it is stored, copied, passed and returned exactly like an Int.
// It is a distinct type code: only float instructions (the type selects the
// operation of binary/unary) and the conversions itof/ftoi accept it.
expose flow cfgFloatType() => Int { give -6 }

// An opaque, linear File handle. Its storage is one machine word, but no
// integer constant or arithmetic expression has this type.
expose flow cfgFileType() => Int { give -4 }

// An opaque, linear Window: the address of the runtime's state block. Only
// windowopen produces one, so no Int, File or forged address has this type.
expose flow cfgWindowType() => Int { give -5 }

// Values that own an OS resource only their close operation may release.
expose flow cfgIsLinear(ty: Int) => Bool { give ty == cfgFileType() || ty == cfgWindowType() }

// Values whose assignment transfers ownership instead of copying.
expose flow cfgIsMove(ty: Int) => Bool {
    give ty >= 2 || ty == cfgTextType() || cfgIsLinear(ty)
}

// Value types plus `u` and `t`. Callers decide where each is acceptable;
// aggregates keep using cfgType, so Text cannot appear inside them.
expose flow cfgTypeOrUnit(p: view CfgProgram, source: view Text, reader: edit NativeReader) => Int {
    change probe = NativeReader(offset: reader.offset, error: 0)
    hold w = nativeWord(source, edit probe)
    when nativeEquals(source, view w, "u") {
        reader.offset = probe.offset
        give cfgUnitType()
    }
    when nativeEquals(source, view w, "t") {
        reader.offset = probe.offset
        give cfgTextType()
    }
    give cfgType(p, source, edit reader)
}

expose flow cfgTypeSize(p: view CfgProgram, ty: Int) => Int {
    when ty == 0 || ty == cfgFloatType() || cfgIsLinear(ty) { give 8 }
    // A unit variable owns one never-read slot so that slot math stays uniform.
    when ty == cfgUnitType() { give 8 }
    when ty == cfgTextType() || cfgListIndex(p, ty) >= 0 { give 24 }
    when ty == 1 { give 1 }
    when ty >= 2 && ty - 2 < p.structs.length { give p.structs[ty - 2].size }
    hold enum_id = ty - 2 - p.structs.length
    when enum_id >= 0 && enum_id < p.enums.length { give p.enums[enum_id].size }
    give -1
}

// Largest shape, choice payload, aggregate result or list element: the
// bound of the layout planner (native_layout). Copies of aggregates are
// unrolled word by word, so code size grows linearly up to it; a list of
// rtListLimit() such elements stays below 2^53 bytes, far from Int overflow.
expose flow cfgMaxValueBytes() => Int {
    give nativeLayoutMaxBytes()
}

expose flow cfgTypeAlign(p: view CfgProgram, ty: Int) => Int {
    when ty == 0 || ty == cfgFloatType() || cfgIsLinear(ty) { give 8 }
    when ty == 1 { give 1 }
    when ty == cfgTextType() || cfgListIndex(p, ty) >= 0 { give 8 }
    when ty >= 2 && ty - 2 < p.structs.length { give p.structs[ty - 2].align }
    hold enum_id = ty - 2 - p.structs.length
    when enum_id >= 0 && enum_id < p.enums.length { give p.enums[enum_id].align }
    give -1
}

// Structs in ELE are MOVE-only, even when all their fields are primitives.
// A field may name a previously declared struct, Text, a list, or ANY
// declared enum (`eK` with K below the header count): enums are listed
// after structs, so a struct such as `LexError { problem: LexProblem,
// offset: Int }` refers forward. Layouts are computed once every
// declaration is read (cfgLayoutDecls in native_cfg_fields); until then a
// struct or enum has size 0 and fields have offset -1.
// The verifier invalidates whole-value move sources; reads of aggregate
// fields are partial moves tracked by move paths (native_cfg_paths).
// Loans and unknown types remain unsupported.
expose flow cfgReadStruct(p: edit CfgProgram, source: view Text, reader: edit NativeReader, sid: Int) {
    nativeExpect(source, edit reader, "struct")
    hold id = nativeId(source, edit reader, 115)
    hold name = nativeWord(source, edit reader)
    nativeExpect(source, edit reader, "fields")
    hold count = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || id != sid || !cfgEncodedName(source, view name) || count < 1 || count > 64 {
        p.error = 60
        give
    }
    hold first = p.fields.length
    each i among 0..count {
        nativeExpect(source, edit reader, "field")
        hold fname = nativeWord(source, edit reader)
        // A field may own a Text (three words); see native_cfg_paths.
        hold ty = cfgDeclType(p, source, edit reader, true)
        nativeEndLine(source, edit reader)
        when reader.error != 0 || !cfgEncodedName(source, view fname) || (ty < 0 && ty != cfgTextType() && ty != cfgFloatType()) {
            p.error = 61
            leave
        }
        p.fields@push(CfgField(ty: ty, offset: -1))
    }
    when p.error != 0 { give }
    p.structs@push(CfgStruct(first_field: first, fields: count, size: 0, align: 0))
}

// Type of a declaration member: `i`, `b`, an earlier struct `sK`, any
// declared enum `eK`, a declared list `lK`, and `t` when `text` holds.
// Enum codes use the header counts (2 + decl_structs + K): they equal the
// final codes because every struct is declared before any enum.
flow cfgDeclType(p: view CfgProgram, source: view Text, reader: edit NativeReader, text: Bool) => Int {
    change probe = NativeReader(offset: reader.offset, error: 0)
    hold w = nativeWord(source, edit probe)
    when text && nativeEquals(source, view w, "t") {
        reader.offset = probe.offset
        give cfgTextType()
    }
    when w.start < w.end && source@byteAt(w.start) == 101 {
        reader.offset = probe.offset
        hold id = nativeDecimal(source, edit reader, view w, 1)
        when id >= 0 && id < p.decl_enums { give 2 + p.decl_structs + id }
        reader.error = 30
        give -1
    }
    hold ty = cfgType(p, source, edit reader)
    // A linear resource cannot be embedded in shapes, choices or lists.
    when cfgIsLinear(ty) { reader.error = 30; give -1 }
    give ty
}

// Read a complete enum descriptor from the official ELE-LIR 1 extension:
// enum eN <encoded-name> variants V
// variant <encoded-name> types 0|1 [<type>]
// A payload is Int, Bool, Text or an aggregate: a struct or enum. That, and the
// layout, are checked by cfgLayoutDecls once every member is known.
expose flow cfgReadEnum(p: edit CfgProgram, source: view Text, reader: edit NativeReader, id: Int) {
    nativeExpect(source, edit reader, "enum")
    hold actual = nativeId(source, edit reader, 101)
    hold name = nativeWord(source, edit reader)
    nativeExpect(source, edit reader, "variants")
    hold count = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || actual != id || !cfgEncodedName(source, view name) || count < 1 || count > 64 {
        p.error = 80
        give
    }
    hold first = p.variants.length
    each v among 0..count {
        nativeExpect(source, edit reader, "variant")
        hold vname = nativeWord(source, edit reader)
        nativeExpect(source, edit reader, "types")
        hold argc = nativeNumber(source, edit reader)
        when argc < 0 || argc > 1 { p.error = 81; give }
        change payload = -1
        when argc == 1 { payload = cfgDeclType(p, source, edit reader, true) }
        nativeEndLine(source, edit reader)
        when reader.error != 0 || !cfgEncodedName(source, view vname) || (argc == 1 && payload < 0 && payload != cfgTextType() && payload != cfgFloatType()) {
            p.error = 82
            give
        }
        p.variants@push(CfgVariant(payload_type: payload))
    }
    p.enums@push(CfgEnum(first_variant: first, variants: count, size: 0, align: 0))
}

flow cfgBadPlace(reader: edit NativeReader) => CfgPlace {
    reader.error = 70
    give CfgPlace(variable: -1, field: -1, subfield: -1, ext: -1)
}

// Decimal digits of `source` from `at` (at most seven). Returns the position
// after them; `out.start` receives the value and `out.end` the digit count.
flow cfgPlaceDigits(source: view Text, at: Int, end: Int, out: edit NativeWord) => Int {
    change pos = at
    change value = 0
    during pos < end && pos - at < 7 {
        hold b = source@byteAt(pos)
        when b < 48 || b > 57 { leave }
        value = value * 10 + b - 48
        pos += 1
    }
    out.start = value
    out.end = pos - at
    give pos
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
expose flow cfgReadPlace(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader) => CfgPlace {
    hold w = nativeWord(source, edit reader)
    when reader.error != 0 || w.end - w.start < 2 || source@byteAt(w.start) != 112 { give cfgBadPlace(edit reader) }
    change number = NativeWord(start: 0, end: 0)
    change pos = cfgPlaceDigits(source, w.start + 1, w.end, edit number)
    hold variable = number.start
    when number.end == 0 || variable >= p.functions[f].vars { give cfgBadPlace(edit reader) }
    change ty = p.types_code[p.functions[f].first_var + variable]
    change field = -1
    change subfield = -1
    change ext = -1
    change steps = 0
    during pos < w.end {
        steps += 1
        when steps > 8 { give cfgBadPlace(edit reader) }
        hold b = source@byteAt(pos)
        when b == 46 {
            pos = cfgPlaceDigits(source, pos + 1, w.end, edit number)
            hold k = number.start
            when number.end == 0 || ty < 2 || ty - 2 >= p.structs.length || k >= p.structs[ty - 2].fields { give cfgBadPlace(edit reader) }
            ty = p.fields[p.structs[ty - 2].first_field + k].ty
            when ext < 0 && field < 0 {
                field = k
            } otherwise when ext < 0 && subfield < 0 {
                subfield = k
            } otherwise {
                when ext < 0 {
                    ext = p.ext_first.length
                    p.ext_first@push(p.proj_kind.length)
                    p.ext_count@push(0)
                }
                p.proj_kind@push(0)
                p.proj_value@push(k)
            }
        } otherwise when b == 91 {
            when pos + 1 >= w.end || source@byteAt(pos + 1) != 118 { give cfgBadPlace(edit reader) }
            pos = cfgPlaceDigits(source, pos + 2, w.end, edit number)
            hold iv = number.start
            hold list = cfgListIndex(p, ty)
            when number.end == 0 || pos >= w.end || source@byteAt(pos) != 93 || list < 0 || iv >= p.functions[f].vars { give cfgBadPlace(edit reader) }
            pos += 1
            hold slot = p.functions[f].first_var + iv
            when p.types_code[slot] != 0 || p.var_ref[slot] { give cfgBadPlace(edit reader) }
            ty = p.list_elem[list]
            when ext < 0 {
                ext = p.ext_first.length
                p.ext_first@push(p.proj_kind.length)
                p.ext_count@push(0)
            }
            p.proj_kind@push(1)
            p.proj_value@push(iv)
        } otherwise {
            give cfgBadPlace(edit reader)
        }
    }
    when ext >= 0 { p.ext_count[ext] = p.proj_kind.length - p.ext_first[ext] }
    give CfgPlace(variable: variable, field: field, subfield: subfield, ext: ext)
}

// Type of the static prefix of a place (without its extension).
flow cfgPrefixType(p: view CfgProgram, f: Int, place: view CfgPlace) => Int {
    when place.variable < 0 || place.variable >= p.functions[f].vars { give -1 }
    hold ty = p.types_code[p.functions[f].first_var + place.variable]
    when place.field < 0 { give ty }
    when ty < 2 || ty - 2 >= p.structs.length { give -1 }
    hold st = view p.structs[ty - 2]
    when place.field < 0 || place.field >= st.fields { give -1 }
    hold first_ty = p.fields[st.first_field + place.field].ty
    when place.subfield < 0 { give first_ty }
    when first_ty < 2 || first_ty - 2 >= p.structs.length { give -1 }
    hold child = view p.structs[first_ty - 2]
    when place.subfield >= child.fields { give -1 }
    give p.fields[child.first_field + place.subfield].ty
}

expose flow cfgPlaceType(p: view CfgProgram, f: Int, place: view CfgPlace) => Int {
    change ty = cfgPrefixType(p, f, place)
    when place.ext < 0 || ty == -1 { give ty }
    when place.ext >= p.ext_first.length { give -1 }
    hold first = p.ext_first[place.ext]
    each n among first..(first + p.ext_count[place.ext]) {
        when p.proj_kind[n] == 1 {
            hold list = cfgListIndex(p, ty)
            when list < 0 { give -1 }
            ty = p.list_elem[list]
        } otherwise {
            when ty < 2 || ty - 2 >= p.structs.length || p.proj_value[n] >= p.structs[ty - 2].fields { give -1 }
            ty = p.fields[p.structs[ty - 2].first_field + p.proj_value[n]].ty
        }
    }
    give ty
}

// Strict ASCII-only identifier decoding for this bootstrap subset.
// Reject malformed lengths and byte sequences rather than accepting a
// token whose spelling happens to occupy one whitespace-separated word.
expose flow cfgEncodedName(source: view Text, name: view NativeWord) => Bool {
    change pos = name.start
    change declared = 0
    change digits = 0
    during pos < name.end {
        hold b = source@byteAt(pos)
        when b == 58 { leave }
        when b < 48 || b > 57 { give false }
        when declared > 100 { give false }
        declared = declared * 10 + b - 48
        digits += 1
        pos += 1
    }
    when digits == 0 || declared < 1 || declared > 128 || pos >= name.end { give false }
    pos += 1
    change seen = 0
    during pos < name.end {
        change number = 0
        change length = 0
        during pos < name.end {
            hold b = source@byteAt(pos)
            when b == 44 { leave }
            when b < 48 || b > 57 { give false }
            number = number * 10 + b - 48
            length += 1
            when length > 3 { give false }
            pos += 1
        }
        when length == 0 || number < 32 || number > 126 { give false }
        seen += 1
        when seen > declared { give false }
        when pos < name.end { pos += 1; when pos == name.end { give false } }
    }
    give seen == declared
}

expose flow cfgBinaryOp(source: view Text, w: view NativeWord) => Int {
    when nativeEquals(source, w, "add") { give 1 }
    when nativeEquals(source, w, "sub") { give 2 }
    when nativeEquals(source, w, "mul") { give 3 }
    when nativeEquals(source, w, "eq") { give 4 }
    when nativeEquals(source, w, "ne") { give 5 }
    when nativeEquals(source, w, "lt") { give 6 }
    when nativeEquals(source, w, "le") { give 7 }
    when nativeEquals(source, w, "gt") { give 8 }
    when nativeEquals(source, w, "ge") { give 9 }
    when nativeEquals(source, w, "div") { give 10 }
    when nativeEquals(source, w, "rem") { give 11 }
    give 0
}

expose flow cfgOperandType(p: view CfgProgram, f: Int, op: view NativeOperand) => Int {
    when !op.is_var {
        when op.is_unit { give cfgUnitType() }
        when op.is_text { give cfgTextType() }
        when op.is_bool { give 1 }
        when op.is_float { give cfgFloatType() }
        give 0
    }
    when op.value < 0 || op.value >= p.functions[f].vars { give -1 }
    hold slot = p.functions[f].first_var + op.value
    // A reference is never a value operand: it cannot be copied, moved,
    // returned or stored. Only places and reference arguments may name it.
    when p.var_ref[slot] { give -1 }
    give p.types_code[slot]
}


// Reads `ct<n>:<b>,<b>,...` (n bytes, each 0..255) into the literal table.
// Returns the literal index, or -1 after setting a reader error.
flow cfgReadTextLiteral(p: edit CfgProgram, source: view Text, reader: edit NativeReader, w: view NativeWord) => Int {
    change pos = w.start + 2
    change declared = 0
    change digits = 0
    during pos < w.end {
        hold b = source@byteAt(pos)
        when b == 58 { leave }
        when b < 48 || b > 57 || declared > 65536 { reader.error = 12; give -1 }
        declared = declared * 10 + b - 48
        digits += 1
        pos += 1
    }
    when digits == 0 || declared > 65536 || pos >= w.end { reader.error = 12; give -1 }
    pos += 1
    hold first = p.text_bytes.length
    change seen = 0
    during pos < w.end {
        change number = 0
        change length = 0
        during pos < w.end {
            hold b = source@byteAt(pos)
            when b == 44 { leave }
            when b < 48 || b > 57 || length == 3 { reader.error = 12; give -1 }
            number = number * 10 + b - 48
            length += 1
            pos += 1
        }
        when length == 0 || number > 255 || seen == declared { reader.error = 12; give -1 }
        p.text_bytes@push(number)
        seen += 1
        when pos < w.end {
            pos += 1
            when pos == w.end { reader.error = 12; give -1 }
        }
    }
    when seen != declared { reader.error = 12; give -1 }
    p.text_start@push(first)
    p.text_length@push(declared)
    give p.text_start.length - 1
}

// Any operand, including Text literals, which need the program to store
// their bytes. Positions that cannot hold Text keep using nativeOperand.
expose flow cfgOperand(p: edit CfgProgram, source: view Text, reader: edit NativeReader) => NativeOperand {
    change probe = NativeReader(offset: reader.offset, error: 0)
    hold w = nativeWord(source, edit probe)
    when w.end - w.start >= 4 && source@byteAt(w.start) == 99 && source@byteAt(w.start + 1) == 116 {
        reader.offset = probe.offset
        hold index = cfgReadTextLiteral(edit p, source, edit reader, view w)
        give NativeOperand(is_var: false, value: index, is_bool: false, is_unit: false, is_text: index >= 0, is_float: false)
    }
    give nativeOperand(source, edit reader)
}

// `ref p<N> 0`: a shared reference to a whole variable. Projections and
// exclusive references are not lowered yet and are rejected.
expose flow cfgSharedVar(p: view CfgProgram, f: Int, source: view Text, reader: edit NativeReader) => Int {
    hold variable = nativeId(source, edit reader, 112)
    hold exclusive = nativeNumber(source, edit reader)
    when reader.error != 0 || exclusive != 0 || variable < 0 || variable >= p.functions[f].vars {
        reader.error = 13
        give -1
    }
    give variable
}
