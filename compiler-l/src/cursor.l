take lexer
take tokens

expose shape TokenCursor {
    pos: Int
    fileId: Int
}

expose flow cursorNew(fileId: Int) => TokenCursor {
    give TokenCursor(pos: 0, fileId: fileId)
}

expose flow cursorIsAtEnd(cursor: view TokenCursor, tokens: view List of[LexToken]) => Bool {
    when cursor.pos >= tokens.length { give true }
    hold current_kind_token = view tokens[cursor.pos]
    choose tokenKindValue(view current_kind_token.kind) {
        LexKind.Eof : { give true }
        _ : { give false }
    }
}

expose flow cursorCurrent(cursor: view TokenCursor, tokens: view List of[LexToken]) => view LexToken {
    give view tokens[cursor.pos]
}

expose flow cursorCurrentKind(cursor: view TokenCursor, tokens: view List of[LexToken]) => view LexKind {
    give view tokens[cursor.pos].kind
}

expose flow cursorAdvance(cursor: edit TokenCursor, tokens: view List of[LexToken]) => view LexToken {
    hold current = view tokens[cursor.pos]
    when cursor.pos < tokens.length {
        cursor.pos += 1
    }
    give current
}

expose flow cursorExpectKind(kind: view LexKind, expected: view LexKind) => Bool {
    choose kind {
        LexKind.Word : { choose expected { LexKind.Word : { give true }, _ : { give false } } }
        LexKind.Integer : { choose expected { LexKind.Integer : { give true }, _ : { give false } } }
        LexKind.Symbol : { choose expected { LexKind.Symbol : { give true }, _ : { give false } } }
        LexKind.Newline : { choose expected { LexKind.Newline : { give true }, _ : { give false } } }
        LexKind.Eof : { choose expected { LexKind.Eof : { give true }, _ : { give false } } }
        LexKind.Text : { choose expected { LexKind.Text : { give true }, _ : { give false } } }
        LexKind.TextStart : { choose expected { LexKind.TextStart : { give true }, _ : { give false } } }
        LexKind.TextEnd : { choose expected { LexKind.TextEnd : { give true }, _ : { give false } } }
        LexKind.InterpolationStart : { choose expected { LexKind.InterpolationStart : { give true }, _ : { give false } } }
        LexKind.InterpolationEnd : { choose expected { LexKind.InterpolationEnd : { give true }, _ : { give false } } }
    }
}

expose flow cursorExpect(cursor: edit TokenCursor, tokens: view List of[LexToken], expected: view LexKind) => Bool {
    when cursor.pos >= tokens.length { give false }
    hold token = view tokens[cursor.pos]
    when cursorExpectKind(view token.kind, expected) {
        cursor.pos += 1
        give true
    }
    give false
}
