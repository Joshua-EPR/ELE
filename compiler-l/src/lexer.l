expose choice LexKind {
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

expose shape LexToken {
    kind: LexKind
    start: Int
    end: Int
}

expose choice LexProblem {
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

expose shape LexError {
    problem: LexProblem
    offset: Int
}

// User-facing description of a lexer failure (shared by lexer-l and ele).
expose flow lexProblemMessage(problem: view LexProblem) => Text {
    choose problem {
        LexProblem.UnexpectedByte : { give "carácter inválido o fuera del subconjunto léxico" }
        LexProblem.UnclosedComment : { give "comentario sin cerrar" }
        LexProblem.UnsupportedNumber : { give "Float inválido" }
        LexProblem.UnclosedString : { give "cadena sin cerrar" }
        LexProblem.InvalidEscape : { give "escape no implementado o inválido" }
        LexProblem.InvalidUnicodeEscape : { give "escape Unicode inválido" }
        LexProblem.InvalidUnicodeScalar : { give "scalar Unicode inválido" }
        LexProblem.UnclosedInterpolation : { give "interpolación sin cerrar: falta '}}'" }
        LexProblem.UnopenedBrace : { give "llave '}}' sin apertura en Text; use '}}}}' para una llave literal" }
        LexProblem.ExcessiveDepth : { give "límite de anidamiento Text (64) excedido" }
    }
}

// `path:line:column: <prefix><message> (byte offset)` of a lexer failure.
// Lines and columns start at 1 after a BOM; columns count code points.
expose flow lexDiagnostic(path: view Text, source: view Text, error: view LexError, prefix: view Text) => Text {
    hold offset = error.offset
    hold message = lexProblemMessage(error.problem)
    change line = 1
    change column = 1
    each i among lexStart(source)..offset {
        hold b = source@byteAt(i)
        when b == 10 {
            line += 1
            column = 1
        } otherwise when b < 128 || b >= 192 {
            column += 1
        }
    }
    give "{path}:{line}:{column}: {prefix}{message} (byte {offset})"
}

flow lexPeek(source: view Text, offset: Int, end: Int) => Int {
    when offset >= end { give -1 }
    give source@byteAt(offset)
}

flow lexDigit(b: Int) => Bool = b >= 48 && b <= 57

flow lexWordStart(b: Int) => Bool {
    give b == 95 || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
}

flow lexIsHexDigit(b: Int) => Bool {
    give (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

flow lexHexValue(b: Int) => Int {
    when b >= 48 && b <= 57 { give b - 48 }
    when b >= 65 && b <= 70 { give b - 65 + 10 }
    when b >= 97 && b <= 102 { give b - 97 + 10 }
    give 0
}

// A digit of a `0x` (radix byte 120) or `0b` (98) literal.
flow lexRadixDigit(b: Int, radix: Int) => Bool {
    when radix == 98 { give b == 48 || b == 49 }
    give lexDigit(b) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

flow lexSymbolWidth(b: Int, next: Int, third: Int) => Int {
    // ..=, .., ->, =>, ??, &&, || and compound arithmetic/comparison.
    when b == 46 && next == 46 {
        when third == 61 { give 3 }
        give 2
    }
    when (next == 62 && (b == 45 || b == 61)) || (b == next && (b == 63 || b == 38 || b == 124)) {
        give 2
    }
    // Shifts << and >>, and the wrapping operators +%, -% and *%.
    when (b == next && (b == 60 || b == 62)) || (next == 37 && (b == 42 || b == 43 || b == 45)) {
        give 2
    }
    when next == 61 {
        when b == 33 || b == 37 || b == 42 || b == 43 || b == 45 || b == 47 || (b >= 60 && b <= 62) {
            give 2
        }
    }
    // `|`, `^` and `~` are the bitwise or, xor and not operators.
    when b == 33 || b == 37 || b == 38 || (b >= 40 && b <= 47) || (b >= 58 && b <= 64) || b == 91 || b == 93 || b == 94 || b == 123 || b == 124 || b == 125 || b == 126 {
        give 1
    }
    give 0
}

expose flow lexStart(source: view Text) => Int {
    when source.byteLength >= 3 && source@byteAt(0) == 239 && source@byteAt(1) == 187 && source@byteAt(2) == 191 {
        give 3
    }
    give 0
}

flow lexScan(source: view Text, start_offset: Int, end: Int, interpolation: Int, interp_brace: Int, depth: Int, tokens: edit List of[LexToken]) => Result of[Int, LexError] {
    change offset = start_offset
    change braces = 0
    during offset < end {
        hold start = offset
        hold b = source@byteAt(offset)
        offset += 1

        when interpolation == 1 && b == 125 {
            when braces == 0 {
                tokens@push(LexToken(kind: LexKind.InterpolationEnd, start: start, end: offset))
                give Ok(offset)
            }
            braces -= 1
            tokens@push(LexToken(kind: LexKind.Symbol, start: start, end: offset))
            proceed
        }

        when b == 10 {
            tokens@push(LexToken(kind: LexKind.Newline, start: start, end: offset))
            proceed
        }
        when b == 32 || (b >= 9 && b <= 13) {
            proceed
        }
        hold next = lexPeek(source, offset, end)
        when b == 47 && next == 47 {
            offset += 1
            during offset < end && source@byteAt(offset) != 10 {
                offset += 1
            }
            proceed
        }
        when b == 47 && next == 42 {
            offset += 1
            change nesting = 1
            during nesting > 0 && offset < end {
                hold current = source@byteAt(offset)
                hold after = lexPeek(source, offset + 1, end)
                when current == 47 && after == 42 {
                    nesting += 1
                    offset += 2
                } otherwise when current == 42 && after == 47 {
                    nesting -= 1
                    offset += 2
                } otherwise {
                    when current == 10 {
                        tokens@push(LexToken(kind: LexKind.Newline, start: offset, end: offset + 1))
                    }
                    offset += 1
                }
            }
            when nesting != 0 {
                give Err(LexError(problem: LexProblem.UnclosedComment, offset: start))
            }
            proceed
        }

        when b == 34 {
            when depth > 64 {
                give Err(LexError(problem: LexProblem.ExcessiveDepth, offset: start))
            }
            hold open = start
            change literal_start = offset
            change interpolated = false
            change closed = false
            during offset < end {
                hold c = source@byteAt(offset)
                when c == 34 {
                    hold close = offset
                    offset += 1
                    when interpolated {
                        tokens@push(LexToken(kind: LexKind.Text, start: literal_start, end: close))
                        tokens@push(LexToken(kind: LexKind.TextEnd, start: close, end: offset))
                    } otherwise {
                        tokens@push(LexToken(kind: LexKind.Text, start: open, end: offset))
                    }
                    closed = true
                    leave
                }
                when c == 10 || c == 13 {
                    give Err(LexError(problem: LexProblem.UnclosedString, offset: open))
                }
                when c == 92 {
                    hold esc_pos = offset
                    offset += 1
                    when offset >= end {
                        give Err(LexError(problem: LexProblem.UnclosedString, offset: open))
                    }
                    hold esc = source@byteAt(offset)
                    when esc == 110 || esc == 116 || esc == 114 || esc == 34 || esc == 92 {
                        offset += 1
                        proceed
                    }
                    when esc == 117 {
                        offset += 1
                        when offset >= end || source@byteAt(offset) != 123 {
                            give Err(LexError(problem: LexProblem.InvalidUnicodeEscape, offset: esc_pos))
                        }
                        offset += 1
                        hold hex_start = offset
                        during offset < end && lexIsHexDigit(source@byteAt(offset)) {
                            offset += 1
                        }
                        when offset == hex_start || offset - hex_start > 6 || offset >= end || source@byteAt(offset) != 125 {
                            give Err(LexError(problem: LexProblem.InvalidUnicodeEscape, offset: esc_pos))
                        }
                        change hex_val = 0
                        each hi among hex_start..offset {
                            hex_val = hex_val * 16 + lexHexValue(source@byteAt(hi))
                        }
                        when hex_val > 1114111 || (hex_val >= 55296 && hex_val <= 57343) {
                            give Err(LexError(problem: LexProblem.InvalidUnicodeScalar, offset: esc_pos))
                        }
                        offset += 1
                        proceed
                    }
                    give Err(LexError(problem: LexProblem.InvalidEscape, offset: esc_pos))
                }
                when c == 123 {
                    when offset + 1 < end && source@byteAt(offset + 1) == 123 {
                        offset += 2
                        proceed
                    }
                    when depth + 1 > 64 {
                        give Err(LexError(problem: LexProblem.ExcessiveDepth, offset: open))
                    }
                    when !interpolated {
                        tokens@push(LexToken(kind: LexKind.TextStart, start: open, end: open + 1))
                        interpolated = true
                    }
                    tokens@push(LexToken(kind: LexKind.Text, start: literal_start, end: offset))
                    hold brace_start = offset
                    offset += 1
                    tokens@push(LexToken(kind: LexKind.InterpolationStart, start: brace_start, end: offset))
                    choose lexScan(source, offset, end, 1, brace_start, depth + 1, edit tokens) {
                        Ok(next_offset) : {
                            offset = next_offset
                            literal_start = offset
                        }
                        Err(err) : {
                            give Err(err)
                        }
                    }
                    proceed
                }
                when c == 125 {
                    when offset + 1 < end && source@byteAt(offset + 1) == 125 {
                        offset += 2
                        proceed
                    }
                    give Err(LexError(problem: LexProblem.UnopenedBrace, offset: offset))
                }
                offset += 1
            }
            when !closed {
                give Err(LexError(problem: LexProblem.UnclosedString, offset: open))
            }
            proceed
        }

        when lexWordStart(b) {
            during offset < end {
                hold current = source@byteAt(offset)
                when !lexWordStart(current) && !lexDigit(current) { leave }
                offset += 1
            }
            tokens@push(LexToken(kind: LexKind.Word, start: start, end: offset))
            proceed
        }
        // Hexadecimal `0x` and binary `0b` Int literals, with `_` separators.
        // The parser checks the digits and the 64-bit width.
        when b == 48 && (next == 120 || next == 98) && offset + 1 < end && lexRadixDigit(source@byteAt(offset + 1), next) {
            offset += 1
            during offset < end {
                hold current = source@byteAt(offset)
                when !lexRadixDigit(current, next) && current != 95 { leave }
                offset += 1
            }
            tokens@push(LexToken(kind: LexKind.Integer, start: start, end: offset))
            proceed
        }
        when lexDigit(b) {
            during offset < end {
                hold current = source@byteAt(offset)
                when !lexDigit(current) && current != 95 { leave }
                offset += 1
            }
            // A Float literal (`.` and a digit, and/or an exponent, as in
            // Stage 0) is lexed as one numeric token; the parser tells it
            // from an Int by its spelling (parserIsFloatLiteral).
            when lexPeek(source, offset, end) == 46 && lexDigit(lexPeek(source, offset + 1, end)) {
                offset += 1
                during offset < end {
                    hold current = source@byteAt(offset)
                    when !lexDigit(current) && current != 95 { leave }
                    offset += 1
                }
            }
            hold suffix = lexPeek(source, offset, end)
            when suffix == 69 || suffix == 101 {
                offset += 1
                hold sign = lexPeek(source, offset, end)
                when sign == 43 || sign == 45 { offset += 1 }
                change exponent_digits = 0
                during offset < end && lexDigit(source@byteAt(offset)) {
                    offset += 1
                    exponent_digits += 1
                }
                when exponent_digits == 0 {
                    give Err(LexError(problem: LexProblem.UnsupportedNumber, offset: start))
                }
            }
            tokens@push(LexToken(kind: LexKind.Integer, start: start, end: offset))
            proceed
        }

        when b == 123 {
            braces += 1
        }
        hold width = lexSymbolWidth(b, next, lexPeek(source, offset + 1, end))
        when width == 0 {
            give Err(LexError(problem: LexProblem.UnexpectedByte, offset: start))
        }
        offset = start + width
        tokens@push(LexToken(kind: LexKind.Symbol, start: start, end: offset))
    }

    when interpolation == 1 {
        give Err(LexError(problem: LexProblem.UnclosedInterpolation, offset: interp_brace))
    }

    give Ok(offset)
}

expose flow lexSource(source: view Text) => Result of[List of[LexToken], LexError] {
    hold end = source.byteLength
    change tokens: List of[LexToken] = List[]
    hold start = lexStart(source)
    choose lexScan(source, start, end, 0, 0, 0, edit tokens) {
        Ok(final_offset) : {
            tokens@push(LexToken(kind: LexKind.Eof, start: end, end: end))
            give Ok(tokens)
        }
        Err(err) : {
            give Err(err)
        }
    }
}
