take tokens
take sema_types
take lir_build
take lir_finish
take lir_builtin_union

// Text serialization of ELE LIR, protocol version 1 (docs/LIR_PROTOCOL.md).
// One record per line, fields separated by single spaces. Names and text
// constants are written as `<length>:<byte>,<byte>,...` (decimal UTF-8
// bytes), so no escaping is needed and lengths can be validated.

flow lirHexValue(b: Int) => Int {
    when b >= 48 && b <= 57 { give b - 48 }
    when b >= 97 && b <= 102 { give b - 87 }
    give b - 55
}

// Append the UTF-8 encoding of a Unicode scalar.
flow lirUtf8(bytes: edit List of[Int], scalar: Int) {
    when scalar < 128 {
        bytes@push(scalar)
    } otherwise when scalar < 2048 {
        bytes@push(192 + scalar / 64)
        bytes@push(128 + scalar % 64)
    } otherwise when scalar < 65536 {
        bytes@push(224 + scalar / 4096)
        bytes@push(128 + (scalar / 64) % 64)
        bytes@push(128 + scalar % 64)
    } otherwise {
        bytes@push(240 + scalar / 262144)
        bytes@push(128 + (scalar / 4096) % 64)
        bytes@push(128 + (scalar / 64) % 64)
        bytes@push(128 + scalar % 64)
    }
}

// Decode the escapes of a literal span already validated by the lexer.
flow lirDecode(source: view Text, start: Int, end: Int) => List of[Int] {
    change bytes: List of[Int] = List[]
    change i = start
    during i < end {
        hold b = source@byteAt(i)
        when b == 92 && i + 1 < end {
            hold e = source@byteAt(i + 1)
            when e == 117 {
                change scalar = 0
                change j = i + 3
                during j < end && source@byteAt(j) != 125 {
                    scalar = scalar * 16 + lirHexValue(source@byteAt(j))
                    j += 1
                }
                lirUtf8(edit bytes, scalar)
                i = j + 1
            } otherwise {
                change c = e
                when e == 110 { c = 10 }
                when e == 116 { c = 9 }
                when e == 114 { c = 13 }
                bytes@push(c)
                i += 2
            }
        } otherwise when (b == 123 || b == 125) && i + 1 < end && source@byteAt(i + 1) == b {
            // `{{` and `}}` stand for one brace.
            bytes@push(b)
            i += 2
        } otherwise {
            bytes@push(b)
            i += 1
        }
    }
    give bytes
}

// Line start offsets of a source, for offset -> line:column.
expose flow lirLineStarts(source: view Text) => List of[Int] {
    change starts: List of[Int] = List[]
    starts@push(0)
    each i among 0..source.byteLength {
        when source@byteAt(i) == 10 { starts@push(i + 1) }
    }
    give starts
}

// ` @line:col` of a byte offset (columns count code points, as the CLI).
expose flow lirAtText(source: view Text, starts: view List of[Int], offset: Int) => Text {
    when offset < 0 || offset > source.byteLength { give "" }
    change low = 0
    change high = starts.length - 1
    during low < high {
        hold mid = (low + high + 1) / 2
        when starts[mid] <= offset { low = mid } otherwise { high = mid - 1 }
    }
    change col = 1
    each i among starts[low]..offset {
        hold b = source@byteAt(i)
        when b < 128 || b >= 192 { col += 1 }
    }
    hold line = low + 1
    give " @{line}:{col}"
}

flow lirBytesText(bytes: view List of[Int]) => Text {
    hold n = bytes.length
    change out = "{n}:"
    each i among 0..n {
        hold b = bytes[i]
        when i == 0 { out = "{out}{b}" } otherwise { out = "{out},{b}" }
    }
    give out
}

expose flow lirSpanText(source: view Text, start: Int, end: Int) => Text {
    change bytes: List of[Int] = List[]
    each i among start..end { bytes@push(source@byteAt(i)) }
    give lirBytesText(view bytes)
}

// Type code: i Int, f Float, b Bool, t Text, u Unit, s<k> struct k.
expose flow lirTypeCode(types: view TypeTable, lm: view LirModule, ty: Int) => Text {
    when ty == 1 { give "i" }
    when ty == 2 { give "f" }
    when ty == 4 { give "b" }
    when ty == 5 { give "t" }
    when ty == 6 { give "u" }
    // The runtime stores one word, but the LIR must retain linear identity.
    when semTypeIsFile(types, ty) { give "h" }
    when semTypeIsWindow(types, ty) { give "w" }
    when ty >= 0 && ty < types.types.length {
        choose types.types[ty].kind {
            SemTypeKind.Struct : {
                hold decl = types.types[ty].nominal_id
                each k among 0..lm.st_decl.length {
                    when lm.st_decl[k] == decl { give "s{k}" }
                }
            }
            SemTypeKind.Enum : {
                hold decl = types.types[ty].nominal_id
                each k among 0..lm.en_decl.length {
                    when lm.en_decl[k] == decl { give "e{k}" }
                }
            }
            SemTypeKind.Option : {
                hold k = lirBuiltinEnumIndex(lm, ty)
                when k >= 0 { give "e{k}" }
            }
            SemTypeKind.Result : {
                hold k = lirBuiltinEnumIndex(lm, ty)
                when k >= 0 { give "e{k}" }
            }
            SemTypeKind.List : {
                hold elem = types.types[ty].elem_type
                each k among 0..lm.list_elem.length {
                    when lm.list_elem[k] == elem { give "l{k}" }
                }
            }
            _ : {}
        }
    }
    give "?"
}

expose flow lirOperandText(l: view LirFn, source: view Text, operand: Int) => Text {
    when lirIsVar(operand) { give "v{operand}" }
    hold id = lirConstId(operand)
    when id < 0 || id >= l.consts.length { give "?" }
    hold c = view l.consts[id]
    when c.kind == LIR_CONST_INT {
        hold value = c.value
        give "ci{value}"
    }
    when c.kind == LIR_CONST_BOOL {
        hold value = c.value
        give "cb{value}"
    }
    when c.kind == LIR_CONST_UNIT { give "cu" }
    hold bytes = lirDecode(source, c.start, c.end)
    hold text = lirBytesText(view bytes)
    give "ct{text}"
}

// Place: p<var> followed by .<field> per projection, outermost last.
expose flow lirPlaceText(l: view LirFn, place: Int) => Text {
    when place < 0 || place >= l.places.length { give "?" }
    change suffix = ""
    change cursor = place
    change steps = 0
    during l.places[cursor].parent >= 0 && steps <= l.places.length {
        hold f = l.places[cursor].field
        when f >= 0 {
            suffix = ".{f}{suffix}"
        } otherwise when f <= -2 {
            hold iv = 0 - 2 - f
            suffix = "[v{iv}]{suffix}"
        }
        cursor = l.places[cursor].parent
        steps += 1
    }
    hold root = l.places[cursor].root
    give "p{root}{suffix}"
}

expose flow lirArgText(l: view LirFn, source: view Text, arg: Int) => Text {
    when arg < 0 || arg >= l.args.length { give "?" }
    when l.args[arg].by_ref {
        hold place = lirPlaceText(l, l.args[arg].value)
        change m = 0
        when l.args[arg].mutable { m = 1 }
        give "ref {place} {m}"
    }
    hold operand = lirOperandText(l, source, l.args[arg].value)
    give "val {operand}"
}
