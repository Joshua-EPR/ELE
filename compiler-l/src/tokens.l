fn tokenName(kind: &LexKind) -> Text {
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

fn emitTokens(tokens: &List<LexToken>) {
    for i in 0..tokens.length {
        let token = &tokens[i]
        let name = tokenName(token.kind)
        let start = token.start
        let end = token.end
        print("{name}:{start}:{end}")
    }
}
