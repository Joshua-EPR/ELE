pub enum LexKind {
    Word
    Integer
    Symbol
    Newline
    Eof
    Text
    TextStart
    TextEnd
    InterpolationStart
    InterpolationEnd
}

pub struct LexToken {
    kind: LexKind
    start: Int
    end: Int
}

pub enum LexProblem {
    UnexpectedByte
    UnclosedComment
    UnsupportedNumber
    UnclosedString
    InvalidEscape
    InvalidUnicodeEscape
    InvalidUnicodeScalar
    UnclosedInterpolation
    UnopenedBrace
    ExcessiveDepth
}

pub struct LexError {
    problem: LexProblem
    offset: Int
}

fn lexPeek(source: &Text, offset: Int, end: Int) -> Int {
    if offset >= end { return -1 }
    return source.byteAt(offset)
}

fn lexDigit(b: Int) -> Bool = b >= 48 && b <= 57

fn lexWordStart(b: Int) -> Bool {
    return b == 95 || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
}

fn lexIsHexDigit(b: Int) -> Bool {
    return (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

fn lexHexValue(b: Int) -> Int {
    if b >= 48 && b <= 57 { return b - 48 }
    if b >= 65 && b <= 70 { return b - 65 + 10 }
    if b >= 97 && b <= 102 { return b - 97 + 10 }
    return 0
}

fn lexSymbolWidth(b: Int, next: Int, third: Int) -> Int {
    // ..=, .., ->, =>, ??, &&, || and compound arithmetic/comparison.
    if b == 46 && next == 46 {
        if third == 61 { return 3 }
        return 2
    }
    if (next == 62 && (b == 45 || b == 61)) || (b == next && (b == 63 || b == 38 || b == 124)) {
        return 2
    }
    if next == 61 {
        if b == 33 || b == 37 || b == 42 || b == 43 || b == 45 || b == 47 || (b >= 60 && b <= 62) {
            return 2
        }
    }
    if b == 33 || b == 37 || b == 38 || (b >= 40 && b <= 47) || (b >= 58 && b <= 64) || b == 91 || b == 93 || b == 123 || b == 125 {
        return 1
    }
    return 0
}

pub fn lexStart(source: &Text) -> Int {
    if source.byteLength >= 3 && source.byteAt(0) == 239 && source.byteAt(1) == 187 && source.byteAt(2) == 191 {
        return 3
    }
    return 0
}

fn lexScan(source: &Text, start_offset: Int, end: Int, interpolation: Int, interp_brace: Int, depth: Int, tokens: &mut List<LexToken>) -> Result<Int, LexError> {
    var offset = start_offset
    var braces = 0
    while offset < end {
        let start = offset
        let b = source.byteAt(offset)
        offset += 1

        if interpolation == 1 && b == 125 {
            if braces == 0 {
                tokens.push(LexToken(kind: LexKind.InterpolationEnd, start: start, end: offset))
                return Ok(offset)
            }
            braces -= 1
            tokens.push(LexToken(kind: LexKind.Symbol, start: start, end: offset))
            continue
        }

        if b == 10 {
            tokens.push(LexToken(kind: LexKind.Newline, start: start, end: offset))
            continue
        }
        if b == 32 || (b >= 9 && b <= 13) {
            continue
        }
        let next = lexPeek(source, offset, end)
        if b == 47 && next == 47 {
            offset += 1
            while offset < end && source.byteAt(offset) != 10 {
                offset += 1
            }
            continue
        }
        if b == 47 && next == 42 {
            offset += 1
            var nesting = 1
            while nesting > 0 && offset < end {
                let current = source.byteAt(offset)
                let after = lexPeek(source, offset + 1, end)
                if current == 47 && after == 42 {
                    nesting += 1
                    offset += 2
                } else if current == 42 && after == 47 {
                    nesting -= 1
                    offset += 2
                } else {
                    if current == 10 {
                        tokens.push(LexToken(kind: LexKind.Newline, start: offset, end: offset + 1))
                    }
                    offset += 1
                }
            }
            if nesting != 0 {
                return Err(LexError(problem: LexProblem.UnclosedComment, offset: start))
            }
            continue
        }

        if b == 34 {
            if depth > 64 {
                return Err(LexError(problem: LexProblem.ExcessiveDepth, offset: start))
            }
            let open = start
            var literal_start = offset
            var interpolated = false
            var closed = false
            while offset < end {
                let c = source.byteAt(offset)
                if c == 34 {
                    let close = offset
                    offset += 1
                    if interpolated {
                        tokens.push(LexToken(kind: LexKind.Text, start: literal_start, end: close))
                        tokens.push(LexToken(kind: LexKind.TextEnd, start: close, end: offset))
                    } else {
                        tokens.push(LexToken(kind: LexKind.Text, start: open, end: offset))
                    }
                    closed = true
                    break
                }
                if c == 10 || c == 13 {
                    return Err(LexError(problem: LexProblem.UnclosedString, offset: open))
                }
                if c == 92 {
                    let esc_pos = offset
                    offset += 1
                    if offset >= end {
                        return Err(LexError(problem: LexProblem.UnclosedString, offset: open))
                    }
                    let esc = source.byteAt(offset)
                    if esc == 110 || esc == 116 || esc == 114 || esc == 34 || esc == 92 {
                        offset += 1
                        continue
                    }
                    if esc == 117 {
                        offset += 1
                        if offset >= end || source.byteAt(offset) != 123 {
                            return Err(LexError(problem: LexProblem.InvalidUnicodeEscape, offset: esc_pos))
                        }
                        offset += 1
                        let hex_start = offset
                        while offset < end && lexIsHexDigit(source.byteAt(offset)) {
                            offset += 1
                        }
                        if offset == hex_start || offset - hex_start > 6 || offset >= end || source.byteAt(offset) != 125 {
                            return Err(LexError(problem: LexProblem.InvalidUnicodeEscape, offset: esc_pos))
                        }
                        var hex_val = 0
                        for hi in hex_start..offset {
                            hex_val = hex_val * 16 + lexHexValue(source.byteAt(hi))
                        }
                        if hex_val > 1114111 || (hex_val >= 55296 && hex_val <= 57343) {
                            return Err(LexError(problem: LexProblem.InvalidUnicodeScalar, offset: esc_pos))
                        }
                        offset += 1
                        continue
                    }
                    return Err(LexError(problem: LexProblem.InvalidEscape, offset: esc_pos))
                }
                if c == 123 {
                    if offset + 1 < end && source.byteAt(offset + 1) == 123 {
                        offset += 2
                        continue
                    }
                    if depth + 1 > 64 {
                        return Err(LexError(problem: LexProblem.ExcessiveDepth, offset: open))
                    }
                    if !interpolated {
                        tokens.push(LexToken(kind: LexKind.TextStart, start: open, end: open + 1))
                        interpolated = true
                    }
                    tokens.push(LexToken(kind: LexKind.Text, start: literal_start, end: offset))
                    let brace_start = offset
                    offset += 1
                    tokens.push(LexToken(kind: LexKind.InterpolationStart, start: brace_start, end: offset))
                    match lexScan(source, offset, end, 1, brace_start, depth + 1, &mut tokens) {
                        Ok(next_offset) => {
                            offset = next_offset
                            literal_start = offset
                        }
                        Err(err) => {
                            return Err(err)
                        }
                    }
                    continue
                }
                if c == 125 {
                    if offset + 1 < end && source.byteAt(offset + 1) == 125 {
                        offset += 2
                        continue
                    }
                    return Err(LexError(problem: LexProblem.UnopenedBrace, offset: offset))
                }
                offset += 1
            }
            if !closed {
                return Err(LexError(problem: LexProblem.UnclosedString, offset: open))
            }
            continue
        }

        if lexWordStart(b) {
            while offset < end {
                let current = source.byteAt(offset)
                if !lexWordStart(current) && !lexDigit(current) { break }
                offset += 1
            }
            tokens.push(LexToken(kind: LexKind.Word, start: start, end: offset))
            continue
        }
        if lexDigit(b) {
            while offset < end {
                let current = source.byteAt(offset)
                if !lexDigit(current) && current != 95 { break }
                offset += 1
            }
            let suffix = lexPeek(source, offset, end)
            let fraction = suffix == 46 && lexDigit(lexPeek(source, offset + 1, end))
            if suffix == 69 || suffix == 101 || fraction {
                return Err(LexError(problem: LexProblem.UnsupportedNumber, offset: start))
            }
            tokens.push(LexToken(kind: LexKind.Integer, start: start, end: offset))
            continue
        }

        if b == 123 {
            braces += 1
        }
        let width = lexSymbolWidth(b, next, lexPeek(source, offset + 1, end))
        if width == 0 {
            return Err(LexError(problem: LexProblem.UnexpectedByte, offset: start))
        }
        offset = start + width
        tokens.push(LexToken(kind: LexKind.Symbol, start: start, end: offset))
    }

    if interpolation == 1 {
        return Err(LexError(problem: LexProblem.UnclosedInterpolation, offset: interp_brace))
    }

    return Ok(offset)
}

pub fn lexSource(source: &Text) -> Result<List<LexToken>, LexError> {
    let end = source.byteLength
    var tokens: List<LexToken> = List[]
    let start = lexStart(source)
    match lexScan(source, start, end, 0, 0, 0, &mut tokens) {
        Ok(final_offset) => {
            tokens.push(LexToken(kind: LexKind.Eof, start: end, end: end))
            return Ok(tokens)
        }
        Err(err) => {
            return Err(err)
        }
    }
}
