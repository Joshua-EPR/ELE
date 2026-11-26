take lexer
take tokens
take cursor
take ast
take float_parse

expose flow selectInt(cond: Bool, ifTrue: Int, ifFalse: Int) => Int {
    when cond { give ifTrue }
    give ifFalse
}

expose flow cursorSpanStart(cursor: view TokenCursor, tokens: view List of[LexToken], defaultPos: Int) => Int {
    when cursor.pos < tokens.length {
        give tokens[cursor.pos].start
    }
    give defaultPos
}

expose flow cursorSpanEnd(cursor: view TokenCursor, tokens: view List of[LexToken], defaultPos: Int) => Int {
    when cursor.pos < tokens.length {
        give tokens[cursor.pos].end
    }
    give defaultPos
}

expose flow cursorPrevEnd(cursor: view TokenCursor, tokens: view List of[LexToken], defaultPos: Int) => Int {
    when cursor.pos > 0 && cursor.pos - 1 < tokens.length {
        give tokens[cursor.pos - 1].end
    }
    give defaultPos
}

expose flow parserMatchText(source: view Text, start: Int, end: Int, expected: Text) => Bool {
    hold len = end - start
    when len != expected.byteLength { give false }
    each i among 0..len {
        when source@byteAt(start + i) != expected@byteAt(i) {
            give false
        }
    }
    give true
}

// Compare keyword spelling without relying on unsupported Text == Text.
expose flow parserExpectedIs(word: view Text, candidate: Text) => Bool {
    give parserMatchText(word, 0, word.byteLength, candidate)
}

// Canonical ELE keywords are recognized at the syntax boundary without
// rewriting the underlying source offsets used by Stage 1 diagnostics.
expose flow parserIsWord(source: view Text, token: view LexToken, expected: Text) => Bool {
    choose tokenKindValue(view token.kind) {
        LexKind.Word : {
            when parserExpectedIs(view expected, "fn") && parserMatchText(source, token.start, token.end, "flow") { give true }
            when parserExpectedIs(view expected, "struct") && parserMatchText(source, token.start, token.end, "shape") { give true }
            when parserExpectedIs(view expected, "impl") && parserMatchText(source, token.start, token.end, "extend") { give true }
            when parserExpectedIs(view expected, "enum") && parserMatchText(source, token.start, token.end, "choice") { give true }
            when parserExpectedIs(view expected, "trait") && parserMatchText(source, token.start, token.end, "contract") { give true }
            when parserExpectedIs(view expected, "pub") && parserMatchText(source, token.start, token.end, "expose") { give true }
            when parserExpectedIs(view expected, "let") && parserMatchText(source, token.start, token.end, "hold") { give true }
            when parserExpectedIs(view expected, "var") && parserMatchText(source, token.start, token.end, "change") { give true }
            when parserExpectedIs(view expected, "const") && parserMatchText(source, token.start, token.end, "fixed") { give true }
            when parserExpectedIs(view expected, "return") && parserMatchText(source, token.start, token.end, "give") { give true }
            when parserExpectedIs(view expected, "match") && parserMatchText(source, token.start, token.end, "choose") { give true }
            when parserExpectedIs(view expected, "if") && parserMatchText(source, token.start, token.end, "when") { give true }
            when parserExpectedIs(view expected, "else") && parserMatchText(source, token.start, token.end, "otherwise") { give true }
            when parserExpectedIs(view expected, "for") && parserMatchText(source, token.start, token.end, "each") { give true }
            when parserExpectedIs(view expected, "in") && parserMatchText(source, token.start, token.end, "among") { give true }
            when parserExpectedIs(view expected, "while") && parserMatchText(source, token.start, token.end, "during") { give true }
            when parserExpectedIs(view expected, "loop") && parserMatchText(source, token.start, token.end, "repeat") { give true }
            when parserExpectedIs(view expected, "break") && parserMatchText(source, token.start, token.end, "leave") { give true }
            when parserExpectedIs(view expected, "continue") && parserMatchText(source, token.start, token.end, "proceed") { give true }
            when parserExpectedIs(view expected, "self") && parserMatchText(source, token.start, token.end, "this") { give true }
            when parserExpectedIs(view expected, "mut") && parserMatchText(source, token.start, token.end, "exclusive") { give true }
            when parserExpectedIs(view expected, "static") && parserMatchText(source, token.start, token.end, "direct") { give true }
            when parserExpectedIs(view expected, "async") && parserMatchText(source, token.start, token.end, "later") { give true }
            when parserExpectedIs(view expected, "await") && parserMatchText(source, token.start, token.end, "wait") { give true }
            when parserExpectedIs(view expected, "spawn") && parserMatchText(source, token.start, token.end, "launch") { give true }
            when parserExpectedIs(view expected, "import") && parserMatchText(source, token.start, token.end, "take") { give true }
            when parserExpectedIs(view expected, "module") && parserMatchText(source, token.start, token.end, "space") { give true }
            when parserExpectedIs(view expected, "region") && parserMatchText(source, token.start, token.end, "zone") { give true }
            give parserMatchText(source, token.start, token.end, expected)
        }
        _ : { give false }
    }
}

expose flow parserIsSymbol(source: view Text, token: view LexToken, expected: Text) => Bool {
    choose tokenKindValue(view token.kind) {
        LexKind.Symbol : {
            when parserExpectedIs(view expected, "->") && parserMatchText(source, token.start, token.end, "=>") { give true }
            when parserExpectedIs(view expected, "=>") && parserMatchText(source, token.start, token.end, ":") { give true }
            give parserMatchText(source, token.start, token.end, expected)
        }
        _ : { give false }
    }
}

// A numeric token is a Float when it has a fraction or an exponent: a plain
// Int token holds only digits and `_` (the lexer scans both into one kind).
expose flow parserIsFloatLiteral(source: view Text, start: Int, end: Int) => Bool {
    each i among start..end {
        hold b = source@byteAt(i)
        when b == 46 || b == 101 || b == 69 { give true }
    }
    give false
}

expose flow parserParseDecimalInt(source: view Text, start: Int, end: Int) => Int {
    change val = 0
    each i among start..end {
        hold b = source@byteAt(i)
        when b >= 48 && b <= 57 {
            when val > 922337203685477580 || (val == 922337203685477580 && b > 55) {
                give -1
            }
            val = val * 10 + (b - 48)
        }
    }
    give val
}

// A `0x` or `0b` literal: its value is the 64-bit two's complement pattern,
// so 0xFFFF_FFFF_8000_0000 is the address -2147483648 (the higher half).
expose flow parserIsRadixLiteral(source: view Text, start: Int, end: Int) => Bool {
    when end - start < 3 || source@byteAt(start) != 48 { give false }
    hold r = source@byteAt(start + 1)
    give r == 120 || r == 98
}

expose shape RadixValue {
    ok: Bool
    value: Int
}

// Accumulates up to 64 bits; more significant bits are an error. Digits
// are added with ELE's checked arithmetic: bit 63 is added last, as
// Int.MIN, so no step overflows.
expose flow parserParseRadixInt(source: view Text, start: Int, end: Int) => RadixValue {
    hold bits_per = selectInt(source@byteAt(start + 1) == 120, 4, 1)
    change bits: List of[Int] = List[]
    each i among start + 2..end {
        hold b = source@byteAt(i)
        change d = -1
        when b >= 48 && b <= 57 { d = b - 48 }
        when b >= 65 && b <= 70 { d = b - 55 }
        when b >= 97 && b <= 102 { d = b - 87 }
        when d >= 0 {
            change mask = 1
            each k among 1..bits_per { mask = mask * 2 }
            during mask > 0 {
                bits@push((d / mask) % 2)
                mask = mask / 2
            }
        }
    }
    // Leading zero bits do not count toward the width.
    change lead = 0
    during lead < bits.length && bits[lead] == 0 { lead += 1 }
    when bits.length - lead > 64 { give RadixValue(ok: false, value: 0) }
    change value = 0
    change top = false
    each i among lead..bits.length {
        when bits.length - 1 - i == 63 {
            top = true
        } otherwise {
            value = value * 2 + bits[i]
        }
    }
    when top { value = value + (-9223372036854775807 - 1) }
    give RadixValue(ok: true, value: value)
}

// The decimal magnitude 9223372036854775808 (2^63): out of range as an Int,
// valid only as the operand of a unary minus.
expose flow parserIsIntMinMagnitude(source: view Text, start: Int, end: Int) => Bool {
    give parserMatchText(source, start, end, "9223372036854775808")
}

expose flow parserSkipNewlines(cursor: edit TokenCursor, tokens: view List of[LexToken]) {
    during cursor.pos < tokens.length {
        hold current_kind_token = view tokens[cursor.pos]
        choose tokenKindValue(view current_kind_token.kind) {
            LexKind.Newline : { cursor.pos += 1 }
            _ : { give }
        }
    }
}

expose flow parserSkipSeparators(source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken]) {
    during cursor.pos < tokens.length {
        hold tok = view tokens[cursor.pos]
        choose tokenKindValue(view tok.kind) {
            LexKind.Newline : { cursor.pos += 1 }
            LexKind.Symbol : {
                when tok.end - tok.start == 1 && source@byteAt(tok.start) == 59 {
                    cursor.pos += 1
                } otherwise {
                    give
                }
            }
            _ : { give }
        }
    }
}

expose flow parserAtWord(source: view Text, cursor: view TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when cursor.pos >= tokens.length { give false }
    hold tok = view tokens[cursor.pos]
    give parserIsWord(source, tok, expected)
}

expose flow parserAtSymbol(source: view Text, cursor: view TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when cursor.pos >= tokens.length { give false }
    hold tok = view tokens[cursor.pos]
    give parserIsSymbol(source, tok, expected)
}

expose flow parserTakeWord(source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when parserAtWord(source, cursor, tokens, expected) {
        cursor.pos += 1
        give true
    }
    give false
}

expose flow parserTakeSymbol(source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when parserAtSymbol(source, cursor, tokens, expected) {
        cursor.pos += 1
        give true
    }
    give false
}

expose flow parserNeedWord(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when parserTakeWord(source, edit cursor, tokens, "{expected}") {
        give true
    }
    hold s = cursorSpanStart(cursor, tokens, source.byteLength)
    hold e = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(edit tree, ParseProblem.ExpectedToken, expected, s, e)
    give false
}

expose flow parserNeedSymbol(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], expected: Text) => Bool {
    when parserTakeSymbol(source, edit cursor, tokens, "{expected}") {
        give true
    }
    hold s = cursorSpanStart(cursor, tokens, source.byteLength)
    hold e = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(edit tree, ParseProblem.ExpectedToken, expected, s, e)
    give false
}

// Binary precedence, lowest first (as in Rust): ?? 1, || 2, && 3,
// == != 4, < > <= >= 5, | 6, ^ 7, & 8, << >> 9, + - +% -% 10,
// * / % *% 11. Prefix operators bind tighter: PARSER_PREC_UNARY.
expose fixed PARSER_PREC_UNARY = 12

// `<<` / `>>`: two one-byte `<` or `>` tokens with nothing between them.
expose flow parserShiftPair(source: view Text, tokens: view List of[LexToken], pos: Int) => Bool {
    when pos + 1 >= tokens.length { give false }
    hold a = view tokens[pos]
    hold b = view tokens[pos + 1]
    when a.end - a.start != 1 || b.end - b.start != 1 || b.start != a.end { give false }
    choose tokenKindValue(view a.kind) {
        LexKind.Symbol : {}
        _ : { give false }
    }
    choose tokenKindValue(view b.kind) {
        LexKind.Symbol : {}
        _ : { give false }
    }
    hold c = source@byteAt(a.start)
    give (c == 60 || c == 62) && source@byteAt(b.start) == c
}

expose flow parserGetBinaryPrecedence(source: view Text, token: view LexToken) => Int {
    choose tokenKindValue(view token.kind) {
        LexKind.Symbol : {
            hold len = token.end - token.start
            hold b0 = source@byteAt(token.start)
            when len == 1 {
                when b0 == 42 || b0 == 47 || b0 == 37 { give 11 }
                when b0 == 43 || b0 == 45 { give 10 }
                when b0 == 38 { give 8 }
                when b0 == 94 { give 7 }
                when b0 == 124 { give 6 }
                when b0 == 60 || b0 == 62 { give 5 }
                give 0
            }
            when len == 2 {
                hold b1 = source@byteAt(token.start + 1)
                when b0 == 63 && b1 == 63 { give 1 }
                when b0 == 124 && b1 == 124 { give 2 }
                when b0 == 38 && b1 == 38 { give 3 }
                when (b0 == 61 || b0 == 33) && b1 == 61 { give 4 }
                when (b0 == 60 || b0 == 62) && b1 == 61 { give 5 }
                when b1 == 37 && b0 == 42 { give 11 }
                when b1 == 37 && (b0 == 43 || b0 == 45) { give 10 }
                give 0
            }
            give 0
        }
        _ : { give 0 }
    }
}
