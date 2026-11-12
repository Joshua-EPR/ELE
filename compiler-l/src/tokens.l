import lexer

pub fn tokenName(kind: &LexKind) -> Text {
    match kind {
        LexKind.Word => { return "word" }
        LexKind.Integer => { return "int" }
        LexKind.Symbol => { return "symbol" }
        LexKind.Newline => { return "newline" }
        LexKind.Eof => { return "eof" }
        LexKind.Text => { return "text" }
        LexKind.TextStart => { return "text_start" }
        LexKind.TextEnd => { return "text_end" }
        LexKind.InterpolationStart => { return "interp_start" }
        LexKind.InterpolationEnd => { return "interp_end" }
    }
}

pub fn emitTokens(tokens: &List<LexToken>) {
    for i in 0..tokens.length {
        let token = &tokens[i]
        let name = tokenName(&token.kind)
        let start = token.start
        let end = token.end
        print("{name}:{start}:{end}")
    }
}

// Unit-only LexKind can be reconstructed from a shared borrow without
// moving the field of a borrowed LexToken (ELE structs remain move-only).
pub fn tokenKindValue(kind: &LexKind) -> LexKind {
    match kind {
        LexKind.Word => { return LexKind.Word }
        LexKind.Integer => { return LexKind.Integer }
        LexKind.Symbol => { return LexKind.Symbol }
        LexKind.Newline => { return LexKind.Newline }
        LexKind.Eof => { return LexKind.Eof }
        LexKind.Text => { return LexKind.Text }
        LexKind.TextStart => { return LexKind.TextStart }
        LexKind.TextEnd => { return LexKind.TextEnd }
        LexKind.InterpolationStart => { return LexKind.InterpolationStart }
        LexKind.InterpolationEnd => { return LexKind.InterpolationEnd }
    }
}
