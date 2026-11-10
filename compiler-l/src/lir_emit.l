import tokens
import sema_types
import lir_build
import lir_finish

// Text serialization of ELE LIR, protocol version 1 (docs/LIR_PROTOCOL.md).
// One record per line, fields separated by single spaces. Names and text
// constants are written as `<length>:<byte>,<byte>,...` (decimal UTF-8
// bytes), so no escaping is needed and lengths can be validated.

fn lirHexValue(b: Int) -> Int {
    if b >= 48 && b <= 57 { return b - 48 }
    if b >= 97 && b <= 102 { return b - 87 }
    return b - 55
}

// Append the UTF-8 encoding of a Unicode scalar.
fn lirUtf8(bytes: &mut List<Int>, scalar: Int) {
    if scalar < 128 {
        bytes.push(scalar)
    } else if scalar < 2048 {
        bytes.push(192 + scalar / 64)
        bytes.push(128 + scalar % 64)
    } else if scalar < 65536 {
        bytes.push(224 + scalar / 4096)
        bytes.push(128 + (scalar / 64) % 64)
        bytes.push(128 + scalar % 64)
    } else {
        bytes.push(240 + scalar / 262144)
        bytes.push(128 + (scalar / 4096) % 64)
        bytes.push(128 + (scalar / 64) % 64)
        bytes.push(128 + scalar % 64)
    }
}

// Decode the escapes of a literal span already validated by the lexer.
fn lirDecode(source: &Text, start: Int, end: Int) -> List<Int> {
    var bytes: List<Int> = List[]
    var i = start
    while i < end {
        let b = source.byteAt(i)
        if b == 92 && i + 1 < end {
            let e = source.byteAt(i + 1)
            if e == 117 {
                var scalar = 0
                var j = i + 3
                while j < end && source.byteAt(j) != 125 {
                    scalar = scalar * 16 + lirHexValue(source.byteAt(j))
                    j += 1
                }
                lirUtf8(&mut bytes, scalar)
                i = j + 1
            } else {
                var c = e
                if e == 110 { c = 10 }
                if e == 116 { c = 9 }
                if e == 114 { c = 13 }
                bytes.push(c)
                i += 2
            }
        } else if (b == 123 || b == 125) && i + 1 < end && source.byteAt(i + 1) == b {
            // `{{` and `}}` stand for one brace.
            bytes.push(b)
            i += 2
        } else {
            bytes.push(b)
            i += 1
        }
    }
    return bytes
}

// Line start offsets of a source, for offset -> line:column.
fn lirLineStarts(source: &Text) -> List<Int> {
    var starts: List<Int> = List[]
    starts.push(0)
    for i in 0..source.byteLength {
        if source.byteAt(i) == 10 { starts.push(i + 1) }
    }
    return starts
}

// ` @line:col` of a byte offset (columns count code points, as the CLI).
fn lirAtText(source: &Text, starts: &List<Int>, offset: Int) -> Text {
    if offset < 0 || offset > source.byteLength { return "" }
    var low = 0
    var high = starts.length - 1
    while low < high {
        let mid = (low + high + 1) / 2
        if starts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    var col = 1
    for i in starts[low]..offset {
        let b = source.byteAt(i)
        if b < 128 || b >= 192 { col += 1 }
    }
    let line = low + 1
    return " @{line}:{col}"
}

fn lirBytesText(bytes: &List<Int>) -> Text {
    let n = bytes.length
    var out = "{n}:"
    for i in 0..n {
        let b = bytes[i]
        if i == 0 { out = "{out}{b}" } else { out = "{out},{b}" }
    }
    return out
}

fn lirSpanText(source: &Text, start: Int, end: Int) -> Text {
    var bytes: List<Int> = List[]
    for i in start..end { bytes.push(source.byteAt(i)) }
    return lirBytesText(&bytes)
}

// Type code: i Int, f Float, b Bool, t Text, u Unit, s<k> struct k.
fn lirTypeCode(types: &TypeTable, lm: &LirModule, ty: Int) -> Text {
    if ty == 1 { return "i" }
    if ty == 2 { return "f" }
    if ty == 4 { return "b" }
    if ty == 5 { return "t" }
    if ty == 6 { return "u" }
    if ty >= 0 && ty < types.types.length {
        match types.types[ty].kind {
            SemTypeKind.Struct => {
                let decl = types.types[ty].nominal_id
                for k in 0..lm.st_decl.length {
                    if lm.st_decl[k] == decl { return "s{k}" }
                }
            }
            SemTypeKind.Enum => {
                let decl = types.types[ty].nominal_id
                for k in 0..lm.en_decl.length {
                    if lm.en_decl[k] == decl { return "e{k}" }
                }
            }
            SemTypeKind.List => {
                let elem = types.types[ty].elem_type
                for k in 0..lm.list_elem.length {
                    if lm.list_elem[k] == elem { return "l{k}" }
                }
            }
            _ => {}
        }
    }
    return "?"
}

fn lirOperandText(l: &LirFn, source: &Text, operand: Int) -> Text {
    if lirIsVar(operand) { return "v{operand}" }
    let id = lirConstId(operand)
    if id < 0 || id >= l.consts.length { return "?" }
    let c = &l.consts[id]
    if c.kind == LIR_CONST_INT {
        let value = c.value
        return "ci{value}"
    }
    if c.kind == LIR_CONST_BOOL {
        let value = c.value
        return "cb{value}"
    }
    if c.kind == LIR_CONST_UNIT { return "cu" }
    let bytes = lirDecode(source, c.start, c.end)
    let text = lirBytesText(&bytes)
    return "ct{text}"
}

// Place: p<var> followed by .<field> per projection, outermost last.
fn lirPlaceText(l: &LirFn, place: Int) -> Text {
    if place < 0 || place >= l.places.length { return "?" }
    var suffix = ""
    var cursor = place
    var steps = 0
    while l.places[cursor].parent >= 0 && steps <= l.places.length {
        let f = l.places[cursor].field
        if f >= 0 {
            suffix = ".{f}{suffix}"
        } else if f <= -2 {
            let iv = 0 - 2 - f
            suffix = "[v{iv}]{suffix}"
        }
        cursor = l.places[cursor].parent
        steps += 1
    }
    let root = l.places[cursor].root
    return "p{root}{suffix}"
}

fn lirArgText(l: &LirFn, source: &Text, arg: Int) -> Text {
    if arg < 0 || arg >= l.args.length { return "?" }
    if l.args[arg].by_ref {
        let place = lirPlaceText(l, l.args[arg].value)
        var m = 0
        if l.args[arg].mutable { m = 1 }
        return "ref {place} {m}"
    }
    let operand = lirOperandText(l, source, l.args[arg].value)
    return "val {operand}"
}
