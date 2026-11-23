take lexer

expose flow tokenName(kind: view LexKind) => Text {
    choose kind {
        LexKind.Word : { give "word" }
        LexKind.Integer : { give "int" }
        LexKind.Symbol : { give "symbol" }
        LexKind.Newline : { give "newline" }
        LexKind.Eof : { give "eof" }
        LexKind.Text : { give "text" }
        LexKind.TextStart : { give "text_start" }
        LexKind.TextEnd : { give "text_end" }
        LexKind.InterpolationStart : { give "interp_start" }
        LexKind.InterpolationEnd : { give "interp_end" }
    }
}

expose flow emitTokens(tokens: view List of[LexToken]) {
    each i among 0..tokens.length {
        hold token = view tokens[i]
        hold name = tokenName(view token.kind)
        hold start = token.start
        hold end = token.end
        print("{name}:{start}:{end}")
    }
}

// Unit-only LexKind can be reconstructed from a shared borrow without
// moving the field of a borrowed LexToken (ELE structs remain move-only).
expose flow tokenKindValue(kind: view LexKind) => LexKind {
    choose kind {
        LexKind.Word : { give LexKind.Word }
        LexKind.Integer : { give LexKind.Integer }
        LexKind.Symbol : { give LexKind.Symbol }
        LexKind.Newline : { give LexKind.Newline }
        LexKind.Eof : { give LexKind.Eof }
        LexKind.Text : { give LexKind.Text }
        LexKind.TextStart : { give LexKind.TextStart }
        LexKind.TextEnd : { give LexKind.TextEnd }
        LexKind.InterpolationStart : { give LexKind.InterpolationStart }
        LexKind.InterpolationEnd : { give LexKind.InterpolationEnd }
    }
}
