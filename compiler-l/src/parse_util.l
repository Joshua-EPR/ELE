import lexer
import tokens
import cursor
import ast

fn selectInt(cond: Bool, ifTrue: Int, ifFalse: Int) -> Int {
    if cond { return ifTrue }
    return ifFalse
}

fn cursorSpanStart(cursor: &TokenCursor, tokens: &List<LexToken>, defaultPos: Int) -> Int {
    if cursor.pos < tokens.length {
        return tokens[cursor.pos].start
    }
    return defaultPos
}

fn cursorSpanEnd(cursor: &TokenCursor, tokens: &List<LexToken>, defaultPos: Int) -> Int {
    if cursor.pos < tokens.length {
        return tokens[cursor.pos].end
    }
    return defaultPos
}

fn cursorPrevEnd(cursor: &TokenCursor, tokens: &List<LexToken>, defaultPos: Int) -> Int {
    if cursor.pos > 0 && cursor.pos - 1 < tokens.length {
        return tokens[cursor.pos - 1].end
    }
    return defaultPos
}

fn parserMatchText(source: &Text, start: Int, end: Int, expected: Text) -> Bool {
    let len = end - start
    if len != expected.byteLength { return false }
    for i in 0..len {
        if source.byteAt(start + i) != expected.byteAt(i) {
            return false
        }
    }
    return true
}

// Canonical ELE keywords are recognized at the syntax boundary without
// rewriting the underlying source offsets used by Stage 1 diagnostics.
fn parserIsWord(source: &Text, token: &LexToken, expected: Text) -> Bool {
    match tokenKindValue(&token.kind) {
        LexKind.Word => {
            if parserMatchText(source, token.start, token.end, expected) { return true }
            if expected == "fn" { return parserMatchText(source, token.start, token.end, "flow") }
            if expected == "struct" { return parserMatchText(source, token.start, token.end, "shape") }
            if expected == "impl" { return parserMatchText(source, token.start, token.end, "extend") }
            if expected == "enum" { return parserMatchText(source, token.start, token.end, "choice") }
            if expected == "trait" { return parserMatchText(source, token.start, token.end, "contract") }
            if expected == "pub" { return parserMatchText(source, token.start, token.end, "expose") }
            if expected == "let" { return parserMatchText(source, token.start, token.end, "hold") }
            if expected == "var" { return parserMatchText(source, token.start, token.end, "change") }
            if expected == "const" { return parserMatchText(source, token.start, token.end, "fixed") }
            if expected == "return" { return parserMatchText(source, token.start, token.end, "give") }
            if expected == "match" { return parserMatchText(source, token.start, token.end, "choose") }
            if expected == "if" { return parserMatchText(source, token.start, token.end, "when") }
            if expected == "else" { return parserMatchText(source, token.start, token.end, "otherwise") }
            if expected == "for" { return parserMatchText(source, token.start, token.end, "each") }
            if expected == "in" { return parserMatchText(source, token.start, token.end, "among") }
            if expected == "while" { return parserMatchText(source, token.start, token.end, "during") }
            if expected == "loop" { return parserMatchText(source, token.start, token.end, "repeat") }
            if expected == "break" { return parserMatchText(source, token.start, token.end, "leave") }
            if expected == "continue" { return parserMatchText(source, token.start, token.end, "proceed") }
            if expected == "self" { return parserMatchText(source, token.start, token.end, "this") }
            if expected == "mut" { return parserMatchText(source, token.start, token.end, "exclusive") }
            if expected == "static" { return parserMatchText(source, token.start, token.end, "direct") }
            if expected == "async" { return parserMatchText(source, token.start, token.end, "later") }
            if expected == "await" { return parserMatchText(source, token.start, token.end, "wait") }
            if expected == "spawn" { return parserMatchText(source, token.start, token.end, "launch") }
            if expected == "import" { return parserMatchText(source, token.start, token.end, "take") }
            if expected == "module" { return parserMatchText(source, token.start, token.end, "space") }
            if expected == "region" { return parserMatchText(source, token.start, token.end, "zone") }
            return false
        }
        _ => { return false }
    }
}

fn parserIsSymbol(source: &Text, token: &LexToken, expected: Text) -> Bool {
    match tokenKindValue(&token.kind) {
        LexKind.Symbol => {
            if parserMatchText(source, token.start, token.end, expected) { return true }
            if expected == "->" { return parserMatchText(source, token.start, token.end, "=>") }
            if expected == "=>" { return parserMatchText(source, token.start, token.end, ":") }
            return false
        }
        _ => { return false }
    }
}

fn parserParseDecimalInt(source: &Text, start: Int, end: Int) -> Int {
    var val = 0
    for i in start..end {
        let b = source.byteAt(i)
        if b >= 48 && b <= 57 {
            if val > 922337203685477580 || (val == 922337203685477580 && b > 55) {
                return -1
            }
            val = val * 10 + (b - 48)
        }
    }
    return val
}

fn parserSkipNewlines(cursor: &mut TokenCursor, tokens: &List<LexToken>) {
    while cursor.pos < tokens.length {
        let current_kind_token = &tokens[cursor.pos]
        match tokenKindValue(&current_kind_token.kind) {
            LexKind.Newline => { cursor.pos += 1 }
            _ => { return }
        }
    }
}

fn parserSkipSeparators(source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) {
    while cursor.pos < tokens.length {
        let tok = &tokens[cursor.pos]
        match tokenKindValue(&tok.kind) {
            LexKind.Newline => { cursor.pos += 1 }
            LexKind.Symbol => {
                if tok.end - tok.start == 1 && source.byteAt(tok.start) == 59 {
                    cursor.pos += 1
                } else {
                    return
                }
            }
            _ => { return }
        }
    }
}

fn parserAtWord(source: &Text, cursor: &TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if cursor.pos >= tokens.length { return false }
    let tok = &tokens[cursor.pos]
    return parserIsWord(source, tok, expected)
}

fn parserAtSymbol(source: &Text, cursor: &TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if cursor.pos >= tokens.length { return false }
    let tok = &tokens[cursor.pos]
    return parserIsSymbol(source, tok, expected)
}

fn parserTakeWord(source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if parserAtWord(source, cursor, tokens, expected) {
        cursor.pos += 1
        return true
    }
    return false
}

fn parserTakeSymbol(source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if parserAtSymbol(source, cursor, tokens, expected) {
        cursor.pos += 1
        return true
    }
    return false
}

fn parserNeedWord(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if parserTakeWord(source, &mut cursor, tokens, "{expected}") {
        return true
    }
    let s = cursorSpanStart(cursor, tokens, source.byteLength)
    let e = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(&mut tree, ParseProblem.ExpectedToken, expected, s, e)
    return false
}

fn parserNeedSymbol(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: Text) -> Bool {
    if parserTakeSymbol(source, &mut cursor, tokens, "{expected}") {
        return true
    }
    let s = cursorSpanStart(cursor, tokens, source.byteLength)
    let e = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(&mut tree, ParseProblem.ExpectedToken, expected, s, e)
    return false
}

fn parserGetBinaryPrecedence(source: &Text, token: &LexToken) -> Int {
    match tokenKindValue(&token.kind) {
        LexKind.Symbol => {
            let len = token.end - token.start
            let b0 = source.byteAt(token.start)
            if len == 1 {
                if b0 == 42 || b0 == 47 || b0 == 37 { return 7 }
                if b0 == 43 || b0 == 45 { return 6 }
                if b0 == 60 || b0 == 62 { return 5 }
                return 0
            }
            if len == 2 {
                let b1 = source.byteAt(token.start + 1)
                if b0 == 63 && b1 == 63 { return 1 }
                if b0 == 124 && b1 == 124 { return 2 }
                if b0 == 38 && b1 == 38 { return 3 }
                if (b0 == 61 || b0 == 33) && b1 == 61 { return 4 }
                if (b0 == 60 || b0 == 62) && b1 == 61 { return 5 }
                return 0
            }
            return 0
        }
        _ => { return 0 }
    }
}
