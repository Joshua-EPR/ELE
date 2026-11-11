struct TokenCursor {
    pos: Int
    fileId: Int
}

fn cursorNew(fileId: Int) -> TokenCursor {
    return TokenCursor(pos: 0, fileId: fileId)
}

fn cursorIsAtEnd(cursor: &TokenCursor, tokens: &List<LexToken>) -> Bool {
    if cursor.pos >= tokens.length { return true }
    match tokenKindValue(&tokens[cursor.pos].kind) {
        LexKind.Eof => { return true }
        _ => { return false }
    }
}

fn cursorCurrent(cursor: &TokenCursor, tokens: &List<LexToken>) -> &LexToken {
    return &tokens[cursor.pos]
}

fn cursorCurrentKind(cursor: &TokenCursor, tokens: &List<LexToken>) -> &LexKind {
    return &tokens[cursor.pos].kind
}

fn cursorAdvance(cursor: &mut TokenCursor, tokens: &List<LexToken>) -> &LexToken {
    let current = &tokens[cursor.pos]
    if cursor.pos < tokens.length {
        cursor.pos += 1
    }
    return current
}

fn cursorExpectKind(kind: &LexKind, expected: &LexKind) -> Bool {
    match kind {
        LexKind.Word => { match expected { LexKind.Word => { return true }, _ => { return false } } }
        LexKind.Integer => { match expected { LexKind.Integer => { return true }, _ => { return false } } }
        LexKind.Symbol => { match expected { LexKind.Symbol => { return true }, _ => { return false } } }
        LexKind.Newline => { match expected { LexKind.Newline => { return true }, _ => { return false } } }
        LexKind.Eof => { match expected { LexKind.Eof => { return true }, _ => { return false } } }
        LexKind.Text => { match expected { LexKind.Text => { return true }, _ => { return false } } }
        LexKind.TextStart => { match expected { LexKind.TextStart => { return true }, _ => { return false } } }
        LexKind.TextEnd => { match expected { LexKind.TextEnd => { return true }, _ => { return false } } }
        LexKind.InterpolationStart => { match expected { LexKind.InterpolationStart => { return true }, _ => { return false } } }
        LexKind.InterpolationEnd => { match expected { LexKind.InterpolationEnd => { return true }, _ => { return false } } }
    }
}

fn cursorExpect(cursor: &mut TokenCursor, tokens: &List<LexToken>, expected: &LexKind) -> Bool {
    if cursor.pos >= tokens.length { return false }
    let token = &tokens[cursor.pos]
    if cursorExpectKind(&token.kind, expected) {
        cursor.pos += 1
        return true
    }
    return false
}
