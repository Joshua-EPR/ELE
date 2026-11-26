// Strict, allocation-light token reader for a *small* ELE-LIR v1 subset.
// Keeps token spans in the original Text so it need not create substrings.
// Errors are sticky; consumers must reject any nonzero error.

expose shape NativeWord {
    start: Int
    end: Int
}

expose shape NativeReader {
    offset: Int
    error: Int
}

expose flow nativeReaderNew() => NativeReader {
    give NativeReader(offset: 0, error: 0)
}

expose flow nativeWord(source: view Text, reader: edit NativeReader) => NativeWord {
    change p = reader.offset
    // Words may be separated by one ASCII space only. Never cross a line.
    when p < source.byteLength && source@byteAt(p) == 32 { p += 1 }
    hold start = p
    during p < source.byteLength {
        hold b = source@byteAt(p)
        when b == 32 || b == 10 || b == 13 { leave }
        p += 1
    }
    reader.offset = p
    when p == start { reader.error = 1 }
    give NativeWord(start: start, end: p)
}

// Literal tokens are passed by value: a string literal is not an addressable
// place and cannot be implicitly borrowed as &Text in Stage 0.
expose flow nativeEquals(source: view Text, word: view NativeWord, literal: Text) => Bool {
    when word.end - word.start != literal.byteLength { give false }
    each i among 0..literal.byteLength {
        when source@byteAt(word.start + i) != literal@byteAt(i) { give false }
    }
    give true
}

expose flow nativeExpect(source: view Text, reader: edit NativeReader, literal: Text) {
    hold w = nativeWord(source, edit reader)
    when !nativeEquals(source, view w, literal) { reader.error = 2 }
}

expose flow nativeEndLine(source: view Text, reader: edit NativeReader) {
    change p = reader.offset
    when p < source.byteLength && source@byteAt(p) == 13 { p += 1 }
    when p < source.byteLength && source@byteAt(p) == 10 {
        p += 1
    } otherwise when p != source.byteLength {
        reader.error = 3
    }
    reader.offset = p
}

expose flow nativeDecimal(source: view Text, reader: edit NativeReader, word: view NativeWord, prefix: Int) => Int {
    change p = word.start + prefix
    change negative = false
    when p < word.end && source@byteAt(p) == 45 {
        negative = true
        p += 1
    }
    when p == word.end { reader.error = 4; give 0 }
    change n = 0
    during p < word.end {
        hold b = source@byteAt(p)
        when b < 48 || b > 57 { reader.error = 4; give 0 }
        hold digit = b - 48
        // Int32 range is intentional for this bootstrap subset.
        when n > (2147483647 - digit) / 10 { reader.error = 5; give 0 }
        n = n * 10 + digit
        p += 1
    }
    when negative { give -n }
    give n
}

// Full Int (64-bit signed) range for `ci` constants. The magnitude is
// accumulated as a negative number so the minimum Int needs no special case.
expose flow nativeDecimal64(source: view Text, reader: edit NativeReader, word: view NativeWord, prefix: Int) => Int {
    change p = word.start + prefix
    change negative = false
    when p < word.end && source@byteAt(p) == 45 {
        negative = true
        p += 1
    }
    when p == word.end { reader.error = 4; give 0 }
    hold minimum = -9223372036854775807 - 1
    change n = 0
    during p < word.end {
        hold b = source@byteAt(p)
        when b < 48 || b > 57 { reader.error = 4; give 0 }
        hold digit = b - 48
        when n < (minimum + digit) / 10 { reader.error = 5; give 0 }
        n = n * 10 - digit
        p += 1
    }
    when negative { give n }
    when n == minimum { reader.error = 5; give 0 }
    give -n
}

expose flow nativeNumber(source: view Text, reader: edit NativeReader) => Int {
    hold w = nativeWord(source, edit reader)
    give nativeDecimal(source, edit reader, view w, 0)
}

expose flow nativeId(source: view Text, reader: edit NativeReader, prefix: Int) => Int {
    hold w = nativeWord(source, edit reader)
    when w.start >= w.end || source@byteAt(w.start) != prefix {
        reader.error = 6
        give -1
    }
    give nativeDecimal(source, edit reader, view w, 1)
}

expose shape NativeOperand {
    is_var: Bool
    value: Int
    is_bool: Bool
    is_unit: Bool
    // Text literal: `value` indexes the literal table of the program.
    is_text: Bool
    // Float constant `cf<bits>`: `value` is the IEEE-754 binary64 bit
    // pattern (as a signed Int), never a decimal text.
    is_float: Bool
}

expose flow nativeOperand(source: view Text, reader: edit NativeReader) => NativeOperand {
    hold w = nativeWord(source, edit reader)
    when w.start >= w.end {
        reader.error = 7
        give NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: false, is_text: false, is_float: false)
    }
    when source@byteAt(w.start) == 118 {
        hold index = nativeDecimal(source, edit reader, view w, 1)
        give NativeOperand(is_var: true, value: index, is_bool: false, is_unit: false, is_text: false, is_float: false)
    }
    when w.end - w.start >= 3 && source@byteAt(w.start) == 99 && source@byteAt(w.start + 1) == 105 {
        hold value = nativeDecimal64(source, edit reader, view w, 2)
        give NativeOperand(is_var: false, value: value, is_bool: false, is_unit: false, is_text: false, is_float: false)
    }
    // `cf<bits>`: the binary64 bit pattern as a signed decimal Int.
    when w.end - w.start >= 3 && source@byteAt(w.start) == 99 && source@byteAt(w.start + 1) == 102 {
        hold bits = nativeDecimal64(source, edit reader, view w, 2)
        give NativeOperand(is_var: false, value: bits, is_bool: false, is_unit: false, is_text: false, is_float: true)
    }
    when w.end - w.start == 3 && source@byteAt(w.start) == 99 && source@byteAt(w.start + 1) == 98 {
        hold value = source@byteAt(w.start + 2)
        when value == 48 { give NativeOperand(is_var: false, value: 0, is_bool: true, is_unit: false, is_text: false, is_float: false) }
        when value == 49 { give NativeOperand(is_var: false, value: 1, is_bool: true, is_unit: false, is_text: false, is_float: false) }
    }
    // `cu` is the only unit constant. It carries no runtime value.
    when w.end - w.start == 2 && source@byteAt(w.start) == 99 && source@byteAt(w.start + 1) == 117 {
        give NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: true, is_text: false, is_float: false)
    }
    reader.error = 7
    give NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: false, is_text: false, is_float: false)
}

expose flow nativeAtEnd(source: view Text, reader: view NativeReader) => Bool {
    give reader.offset == source.byteLength
}

// Stage 1 emits an optional source location on instruction records:
// ` @<line>:<column>`. Parse it conservatively rather than dropping an
// arbitrary trailing token. The record remains single-line and bounded.
expose flow nativeEndLineSpan(source: view Text, reader: edit NativeReader) {
    change p = reader.offset
    when p < source.byteLength && source@byteAt(p) == 32 {
        p += 1
        when p >= source.byteLength || source@byteAt(p) != 64 { reader.error = 10; give }
        p += 1
        change line = 0
        change digits = 0
        during p < source.byteLength {
            hold b = source@byteAt(p)
            when b < 48 || b > 57 { leave }
            when line > 1000000 { reader.error = 11; give }
            line = line * 10 + b - 48
            digits += 1
            p += 1
        }
        when digits == 0 || line == 0 || p >= source.byteLength || source@byteAt(p) != 58 { reader.error = 11; give }
        p += 1
        change col = 0
        digits = 0
        during p < source.byteLength {
            hold b = source@byteAt(p)
            when b < 48 || b > 57 { leave }
            when col > 1000000 { reader.error = 11; give }
            col = col * 10 + b - 48
            digits += 1
            p += 1
        }
        when digits == 0 || col == 0 { reader.error = 11; give }
        reader.offset = p
    }
    nativeEndLine(source, edit reader)
}
