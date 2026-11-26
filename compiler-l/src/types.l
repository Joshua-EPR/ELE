take lexer
take tokens
take cursor
take ast
take parse_util

expose flow parseType(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], depth: Int) => Int {
    when depth > 128 {
        hold s = cursorSpanStart(cursor, tokens, source.byteLength)
        hold e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(edit tree, ParseProblem.NestingLimitExceeded, "", s, e)
        give -1
    }
    change t = parseTypeAtom(edit tree, source, edit cursor, tokens, depth + 1)
    when t < 0 { give -1 }

    during parserAtSymbol(source, cursor, tokens, "?") || parserAtSymbol(source, cursor, tokens, "??") {
        hold isDouble = parserTakeSymbol(source, edit cursor, tokens, "??")
        when !isDouble {
            parserTakeSymbol(source, edit cursor, tokens, "?")
        }
        hold layers = selectInt(isDouble, 2, 1)
        each _ among 0..layers {
            hold extra_idx = astAddExtra(edit tree, 1)
            astAddExtra(edit tree, t)
            hold type_start = tree.types[t].start
            hold type_end = tree.types[t].end + 1
            t = astAddType(edit tree, AstTypeKind.Named, type_start, type_end, 0, 0, extra_idx)
        }
    }
    give t
}

flow parseTypeAtom(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], depth: Int) => Int {
    when cursor.pos >= tokens.length {
        astAddError(edit tree, ParseProblem.ExpectedType, "", source.byteLength, source.byteLength)
        give -1
    }
    hold tok = view tokens[cursor.pos]

    hold is_view = parserTakeWord(source, edit cursor, tokens, "view")
    hold is_edit = parserTakeWord(source, edit cursor, tokens, "edit")
    when is_view || is_edit {
        hold inner = parseType(edit tree, source, edit cursor, tokens, depth + 1)
        hold end_p = astTypeEnd(view tree, inner, tok.end)
        give astAddType(edit tree, AstTypeKind.Ref, tok.start, end_p, inner, selectInt(is_edit, 1, 0), 0)
    }

    when parserTakeSymbol(source, edit cursor, tokens, "&") {
        hold mutable = parserTakeWord(source, edit cursor, tokens, "mut")
        hold inner = parseType(edit tree, source, edit cursor, tokens, depth + 1)
        hold is_mut = selectInt(mutable, 1, 0)
        hold end_p = astTypeEnd(view tree, inner, tok.end)
        give astAddType(edit tree, AstTypeKind.Ref, tok.start, end_p, inner, is_mut, 0)
    }

    when parserTakeSymbol(source, edit cursor, tokens, "[") {
        hold elem = parseType(edit tree, source, edit cursor, tokens, depth + 1)
        when parserTakeSymbol(source, edit cursor, tokens, ";") {
            when cursor.pos >= tokens.length {
                astAddError(edit tree, ParseProblem.ExpectedToken, "entero", source.byteLength, source.byteLength)
                give -1
            }
            hold lenTok = view tokens[cursor.pos]
            change arrLen = 0
            choose tokenKindValue(view lenTok.kind) {
                LexKind.Integer : {
                    when parserIsRadixLiteral(source, lenTok.start, lenTok.end) {
                        hold radix = parserParseRadixInt(source, lenTok.start, lenTok.end)
                        when !radix.ok || radix.value < 0 {
                            astAddError(edit tree, ParseProblem.ExpectedToken, "entero", lenTok.start, lenTok.end)
                            give -1
                        }
                        cursor.pos += 1
                        parserNeedSymbol(edit tree, source, edit cursor, tokens, "]")
                        hold radix_end = cursorPrevEnd(cursor, tokens, tok.end)
                        give astAddType(edit tree, AstTypeKind.Array, tok.start, radix_end, elem, radix.value, 0)
                    }
                    when parserIsFloatLiteral(source, lenTok.start, lenTok.end) {
                        astAddError(edit tree, ParseProblem.ExpectedToken, "entero", lenTok.start, lenTok.end)
                        give -1
                    }
                    arrLen = parserParseDecimalInt(source, lenTok.start, lenTok.end)
                    cursor.pos += 1
                }
                _ : {
                    astAddError(edit tree, ParseProblem.ExpectedToken, "entero", lenTok.start, lenTok.end)
                    give -1
                }
            }
            parserNeedSymbol(edit tree, source, edit cursor, tokens, "]")
            hold end_p = cursorPrevEnd(cursor, tokens, tok.end)
            give astAddType(edit tree, AstTypeKind.Array, tok.start, end_p, elem, arrLen, 0)
        }
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "]")
        hold end_p = cursorPrevEnd(cursor, tokens, tok.end)
        give astAddType(edit tree, AstTypeKind.Slice, tok.start, end_p, elem, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "Int") {
        give astAddType(edit tree, AstTypeKind.Int, tok.start, tok.end, 0, 0, 0)
    }
    when parserTakeWord(source, edit cursor, tokens, "Float") || parserTakeWord(source, edit cursor, tokens, "f64") {
        give astAddType(edit tree, AstTypeKind.Float, tok.start, tok.end, 0, 0, 0)
    }
    when parserTakeWord(source, edit cursor, tokens, "f32") {
        give astAddType(edit tree, AstTypeKind.F32, tok.start, tok.end, 0, 0, 0)
    }
    when parserTakeWord(source, edit cursor, tokens, "Bool") {
        give astAddType(edit tree, AstTypeKind.Bool, tok.start, tok.end, 0, 0, 0)
    }
    when parserTakeWord(source, edit cursor, tokens, "Text") {
        give astAddType(edit tree, AstTypeKind.Text, tok.start, tok.end, 0, 0, 0)
    }
    when parserTakeSymbol(source, edit cursor, tokens, "(") {
        parserNeedSymbol(edit tree, source, edit cursor, tokens, ")")
        hold end_p = cursorPrevEnd(cursor, tokens, tok.end)
        give astAddType(edit tree, AstTypeKind.Unit, tok.start, end_p, 0, 0, 0)
    }

    choose tokenKindValue(view tok.kind) {
        LexKind.Word : {
            hold name_start = tok.start
            hold name_end = tok.end
            cursor.pos += 1
            change extra_idx = -1
            // ELE v2: Type of[Arg, ...]. The historic Type<Arg> remains
            // accepted during bootstrap migration. Both have the same AST.
            change closes_square = false
            change has_args = parserTakeSymbol(source, edit cursor, tokens, "<")
            when !has_args && parserTakeWord(source, edit cursor, tokens, "of") {
                when !parserNeedSymbol(edit tree, source, edit cursor, tokens, "[") {
                    give -1
                }
                has_args = true
                closes_square = true
            }
            when has_args {
                change type_args: List of[Int] = List[]
                during cursor.pos < tokens.length {
                    change at_end = parserAtSymbol(source, cursor, tokens, ">")
                    when closes_square { at_end = parserAtSymbol(source, cursor, tokens, "]") }
                    when at_end { leave }
                    hold arg = parseType(edit tree, source, edit cursor, tokens, depth + 1)
                    when arg >= 0 { type_args@push(arg) }
                    when !parserTakeSymbol(source, edit cursor, tokens, ",") { leave }
                }
                when closes_square {
                    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, "]") { give -1 }
                } otherwise {
                    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ">") { give -1 }
                }
                hold first_pos = tree.extra.length
                astAddExtra(edit tree, type_args.length)
                each a among 0..type_args.length {
                    astAddExtra(edit tree, type_args[a])
                }
                extra_idx = first_pos
            }
            hold end_pos = cursorPrevEnd(cursor, tokens, name_end)
            give astAddType(edit tree, AstTypeKind.Named, name_start, end_pos, name_start, name_end, extra_idx)
        }
        _ : {
            astAddError(edit tree, ParseProblem.ExpectedType, "", tok.start, tok.end)
            give -1
        }
    }
}
