// Strict, allocation-light token reader for a *small* ELE-LIR v1 subset.
// Keeps token spans in the original Text so it need not create substrings.
// Errors are sticky; consumers must reject any nonzero error.

pub struct NativeWord {
    start: Int
    end: Int
}

pub struct NativeReader {
    offset: Int
    error: Int
}

pub fn nativeReaderNew() -> NativeReader {
    return NativeReader(offset: 0, error: 0)
}

pub fn nativeWord(source: &Text, reader: &mut NativeReader) -> NativeWord {
    var p = reader.offset
    // Words may be separated by one ASCII space only. Never cross a line.
    if p < source.byteLength && source.byteAt(p) == 32 { p += 1 }
    let start = p
    while p < source.byteLength {
        let b = source.byteAt(p)
        if b == 32 || b == 10 || b == 13 { break }
        p += 1
    }
    reader.offset = p
    if p == start { reader.error = 1 }
    return NativeWord(start: start, end: p)
}

pub fn nativeEquals(source: &Text, word: &NativeWord, literal: &Text) -> Bool {
    if word.end - word.start != literal.byteLength { return false }
    for i in 0..literal.byteLength {
        if source.byteAt(word.start + i) != literal.byteAt(i) { return false }
    }
    return true
}

pub fn nativeExpect(source: &Text, reader: &mut NativeReader, literal: &Text) {
    let w = nativeWord(source, &mut reader)
    if !nativeEquals(source, &w, literal) { reader.error = 2 }
}

pub fn nativeEndLine(source: &Text, reader: &mut NativeReader) {
    var p = reader.offset
    if p < source.byteLength && source.byteAt(p) == 13 { p += 1 }
    if p < source.byteLength && source.byteAt(p) == 10 {
        p += 1
    } else if p != source.byteLength {
        reader.error = 3
    }
    reader.offset = p
}

pub fn nativeDecimal(source: &Text, reader: &mut NativeReader, word: &NativeWord, prefix: Int) -> Int {
    var p = word.start + prefix
    var negative = false
    if p < word.end && source.byteAt(p) == 45 {
        negative = true
        p += 1
    }
    if p == word.end { reader.error = 4; return 0 }
    var n = 0
    while p < word.end {
        let b = source.byteAt(p)
        if b < 48 || b > 57 { reader.error = 4; return 0 }
        let digit = b - 48
        // Int32 range is intentional for this bootstrap subset.
        if n > (2147483647 - digit) / 10 { reader.error = 5; return 0 }
        n = n * 10 + digit
        p += 1
    }
    if negative { return -n }
    return n
}

pub fn nativeNumber(source: &Text, reader: &mut NativeReader) -> Int {
    let w = nativeWord(source, &mut reader)
    return nativeDecimal(source, &mut reader, &w, 0)
}

pub fn nativeId(source: &Text, reader: &mut NativeReader, prefix: Int) -> Int {
    let w = nativeWord(source, &mut reader)
    if w.start >= w.end || source.byteAt(w.start) != prefix {
        reader.error = 6
        return -1
    }
    return nativeDecimal(source, &mut reader, &w, 1)
}

pub struct NativeOperand {
    is_var: Bool
    value: Int
    is_bool: Bool
}

pub fn nativeOperand(source: &Text, reader: &mut NativeReader) -> NativeOperand {
    let w = nativeWord(source, &mut reader)
    if w.start >= w.end {
        reader.error = 7
        return NativeOperand(is_var: false, value: 0, is_bool: false)
    }
    if source.byteAt(w.start) == 118 {
        let index = nativeDecimal(source, &mut reader, &w, 1)
        return NativeOperand(is_var: true, value: index, is_bool: false)
    }
    if w.end - w.start >= 3 && source.byteAt(w.start) == 99 && source.byteAt(w.start + 1) == 105 {
        let value = nativeDecimal(source, &mut reader, &w, 2)
        return NativeOperand(is_var: false, value: value, is_bool: false)
    }
    if w.end - w.start == 3 && source.byteAt(w.start) == 99 && source.byteAt(w.start + 1) == 98 {
        let value = source.byteAt(w.start + 2)
        if value == 48 { return NativeOperand(is_var: false, value: 0, is_bool: true) }
        if value == 49 { return NativeOperand(is_var: false, value: 1, is_bool: true) }
    }
    reader.error = 7
    return NativeOperand(is_var: false, value: 0, is_bool: false)
}

pub fn nativeAtEnd(source: &Text, reader: &NativeReader) -> Bool {
    return reader.offset == source.byteLength
}

// Stage 1 emits an optional source location on instruction records:
// ` @<line>:<column>`. Parse it conservatively rather than dropping an
// arbitrary trailing token. The record remains single-line and bounded.
pub fn nativeEndLineSpan(source: &Text, reader: &mut NativeReader) {
    var p = reader.offset
    if p < source.byteLength && source.byteAt(p) == 32 {
        p += 1
        if p >= source.byteLength || source.byteAt(p) != 64 { reader.error = 10; return }
        p += 1
        var line = 0
        var digits = 0
        while p < source.byteLength {
            let b = source.byteAt(p)
            if b < 48 || b > 57 { break }
            if line > 1000000 { reader.error = 11; return }
            line = line * 10 + b - 48
            digits += 1
            p += 1
        }
        if digits == 0 || line == 0 || p >= source.byteLength || source.byteAt(p) != 58 { reader.error = 11; return }
        p += 1
        var col = 0
        digits = 0
        while p < source.byteLength {
            let b = source.byteAt(p)
            if b < 48 || b > 57 { break }
            if col > 1000000 { reader.error = 11; return }
            col = col * 10 + b - 48
            digits += 1
            p += 1
        }
        if digits == 0 || col == 0 { reader.error = 11; return }
        reader.offset = p
    }
    nativeEndLine(source, &mut reader)
}
