import lexer
import tokens
import cursor
import ast
import parse_util

fn parseType(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, depth: Int) -> Int {
    if depth > 128 {
        let s = cursorSpanStart(cursor, tokens, source.byteLength)
        let e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(&mut tree, ParseProblem.NestingLimitExceeded, "", s, e)
        return -1
    }
    var t = parseTypeAtom(&mut tree, source, &mut cursor, tokens, depth + 1)
    if t < 0 { return -1 }

    while parserAtSymbol(source, cursor, tokens, "?") || parserAtSymbol(source, cursor, tokens, "??") {
        let isDouble = parserTakeSymbol(source, &mut cursor, tokens, "??")
        if !isDouble {
            parserTakeSymbol(source, &mut cursor, tokens, "?")
        }
        let layers = selectInt(isDouble, 2, 1)
        for _ in 0..layers {
            let extra_idx = astAddExtra(&mut tree, 1)
            astAddExtra(&mut tree, t)
            let type_start = tree.types[t].start
            let type_end = tree.types[t].end + 1
            t = astAddType(&mut tree, AstTypeKind.Named, type_start, type_end, 0, 0, extra_idx)
        }
    }
    return t
}

fn parseTypeAtom(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, depth: Int) -> Int {
    if cursor.pos >= tokens.length {
        astAddError(&mut tree, ParseProblem.ExpectedType, "", source.byteLength, source.byteLength)
        return -1
    }
    let tok = &tokens[cursor.pos]

    let is_view = parserTakeWord(source, &mut cursor, tokens, "view")
    let is_edit = parserTakeWord(source, &mut cursor, tokens, "edit")
    if is_view || is_edit {
        let inner = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
        let end_p = astTypeEnd(&tree, inner, tok.end)
        return astAddType(&mut tree, AstTypeKind.Ref, tok.start, end_p, inner, selectInt(is_edit, 1, 0), 0)
    }

    if parserTakeSymbol(source, &mut cursor, tokens, "&") {
        let mutable = parserTakeWord(source, &mut cursor, tokens, "mut")
        let inner = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
        let is_mut = selectInt(mutable, 1, 0)
        let end_p = astTypeEnd(&tree, inner, tok.end)
        return astAddType(&mut tree, AstTypeKind.Ref, tok.start, end_p, inner, is_mut, 0)
    }

    if parserTakeSymbol(source, &mut cursor, tokens, "[") {
        let elem = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
        if parserTakeSymbol(source, &mut cursor, tokens, ";") {
            if cursor.pos >= tokens.length {
                astAddError(&mut tree, ParseProblem.ExpectedToken, "entero", source.byteLength, source.byteLength)
                return -1
            }
            let lenTok = &tokens[cursor.pos]
            var arrLen = 0
            match tokenKindValue(&lenTok.kind) {
                LexKind.Integer => {
                    arrLen = parserParseDecimalInt(source, lenTok.start, lenTok.end)
                    cursor.pos += 1
                }
                _ => {
                    astAddError(&mut tree, ParseProblem.ExpectedToken, "entero", lenTok.start, lenTok.end)
                    return -1
                }
            }
            parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "]")
            let end_p = cursorPrevEnd(cursor, tokens, tok.end)
            return astAddType(&mut tree, AstTypeKind.Array, tok.start, end_p, elem, arrLen, 0)
        }
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "]")
        let end_p = cursorPrevEnd(cursor, tokens, tok.end)
        return astAddType(&mut tree, AstTypeKind.Slice, tok.start, end_p, elem, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "Int") {
        return astAddType(&mut tree, AstTypeKind.Int, tok.start, tok.end, 0, 0, 0)
    }
    if parserTakeWord(source, &mut cursor, tokens, "Float") || parserTakeWord(source, &mut cursor, tokens, "f64") {
        return astAddType(&mut tree, AstTypeKind.Float, tok.start, tok.end, 0, 0, 0)
    }
    if parserTakeWord(source, &mut cursor, tokens, "f32") {
        return astAddType(&mut tree, AstTypeKind.F32, tok.start, tok.end, 0, 0, 0)
    }
    if parserTakeWord(source, &mut cursor, tokens, "Bool") {
        return astAddType(&mut tree, AstTypeKind.Bool, tok.start, tok.end, 0, 0, 0)
    }
    if parserTakeWord(source, &mut cursor, tokens, "Text") {
        return astAddType(&mut tree, AstTypeKind.Text, tok.start, tok.end, 0, 0, 0)
    }
    if parserTakeSymbol(source, &mut cursor, tokens, "(") {
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ")")
        let end_p = cursorPrevEnd(cursor, tokens, tok.end)
        return astAddType(&mut tree, AstTypeKind.Unit, tok.start, end_p, 0, 0, 0)
    }

    match tokenKindValue(&tok.kind) {
        LexKind.Word => {
            let name_start = tok.start
            let name_end = tok.end
            cursor.pos += 1
            var extra_idx = -1
            // ELE v2: Type of[Arg, ...]. The historic Type<Arg> remains
            // accepted during bootstrap migration. Both have the same AST.
            var closes_square = false
            var has_args = parserTakeSymbol(source, &mut cursor, tokens, "<")
            if !has_args && parserTakeWord(source, &mut cursor, tokens, "of") {
                if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "[") {
                    return -1
                }
                has_args = true
                closes_square = true
            }
            if has_args {
                var type_args: List<Int> = List[]
                while cursor.pos < tokens.length {
                    var at_end = parserAtSymbol(source, cursor, tokens, ">")
                    if closes_square { at_end = parserAtSymbol(source, cursor, tokens, "]") }
                    if at_end { break }
                    let arg = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
                    if arg >= 0 { type_args.push(arg) }
                    if !parserTakeSymbol(source, &mut cursor, tokens, ",") { break }
                }
                if closes_square {
                    if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "]") { return -1 }
                } else {
                    if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ">") { return -1 }
                }
                let first_pos = tree.extra.length
                astAddExtra(&mut tree, type_args.length)
                for a in 0..type_args.length {
                    astAddExtra(&mut tree, type_args[a])
                }
                extra_idx = first_pos
            }
            let end_pos = cursorPrevEnd(cursor, tokens, name_end)
            return astAddType(&mut tree, AstTypeKind.Named, name_start, end_pos, name_start, name_end, extra_idx)
        }
        _ => {
            astAddError(&mut tree, ParseProblem.ExpectedType, "", tok.start, tok.end)
            return -1
        }
    }
}
