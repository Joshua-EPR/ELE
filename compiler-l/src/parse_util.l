take lexer
take tokens
take cursor
take ast

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

expose flow parserGetBinaryPrecedence(source: view Text, token: view LexToken) => Int {
    choose tokenKindValue(view token.kind) {
        LexKind.Symbol : {
            hold len = token.end - token.start
            hold b0 = source@byteAt(token.start)
            when len == 1 {
                when b0 == 42 || b0 == 47 || b0 == 37 { give 7 }
                when b0 == 43 || b0 == 45 { give 6 }
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
                give 0
            }
            give 0
        }
        _ : { give 0 }
    }
}
