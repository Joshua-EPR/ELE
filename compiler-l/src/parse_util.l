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
            if expected == "fn" && parserMatchText(source, token.start, token.end, "flow") { return true }
            if expected == "struct" && parserMatchText(source, token.start, token.end, "shape") { return true }
            if expected == "impl" && parserMatchText(source, token.start, token.end, "extend") { return true }
            if expected == "enum" && parserMatchText(source, token.start, token.end, "choice") { return true }
            if expected == "trait" && parserMatchText(source, token.start, token.end, "contract") { return true }
            if expected == "pub" && parserMatchText(source, token.start, token.end, "expose") { return true }
            if expected == "let" && parserMatchText(source, token.start, token.end, "hold") { return true }
            if expected == "var" && parserMatchText(source, token.start, token.end, "change") { return true }
            if expected == "const" && parserMatchText(source, token.start, token.end, "fixed") { return true }
            if expected == "return" && parserMatchText(source, token.start, token.end, "give") { return true }
            if expected == "match" && parserMatchText(source, token.start, token.end, "choose") { return true }
            if expected == "if" && parserMatchText(source, token.start, token.end, "when") { return true }
            if expected == "else" && parserMatchText(source, token.start, token.end, "otherwise") { return true }
            if expected == "for" && parserMatchText(source, token.start, token.end, "each") { return true }
            if expected == "in" && parserMatchText(source, token.start, token.end, "among") { return true }
            if expected == "while" && parserMatchText(source, token.start, token.end, "during") { return true }
            if expected == "loop" && parserMatchText(source, token.start, token.end, "repeat") { return true }
            if expected == "break" && parserMatchText(source, token.start, token.end, "leave") { return true }
            if expected == "continue" && parserMatchText(source, token.start, token.end, "proceed") { return true }
            if expected == "self" && parserMatchText(source, token.start, token.end, "this") { return true }
            if expected == "mut" && parserMatchText(source, token.start, token.end, "exclusive") { return true }
            if expected == "static" && parserMatchText(source, token.start, token.end, "direct") { return true }
            if expected == "async" && parserMatchText(source, token.start, token.end, "later") { return true }
            if expected == "await" && parserMatchText(source, token.start, token.end, "wait") { return true }
            if expected == "spawn" && parserMatchText(source, token.start, token.end, "launch") { return true }
            if expected == "import" && parserMatchText(source, token.start, token.end, "take") { return true }
            if expected == "module" && parserMatchText(source, token.start, token.end, "space") { return true }
            if expected == "region" && parserMatchText(source, token.start, token.end, "zone") { return true }
            return parserMatchText(source, token.start, token.end, expected)
        }
        _ => { return false }
    }
}

fn parserIsSymbol(source: &Text, token: &LexToken, expected: Text) -> Bool {
    match tokenKindValue(&token.kind) {
        LexKind.Symbol => {
            if expected == "->" && parserMatchText(source, token.start, token.end, "=>") { return true }
            if expected == "=>" && parserMatchText(source, token.start, token.end, ":") { return true }
            return parserMatchText(source, token.start, token.end, expected)
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
