import lexer
import tokens
import cursor
import ast
import parse_util

fn parseExpr(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, min_prec: Int, parens: Int, depth: Int) -> Int {
    if depth > 128 {
        let s = cursorSpanStart(cursor, tokens, source.byteLength)
        let e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(&mut tree, ParseProblem.NestingLimitExceeded, "", s, e)
        return -1
    }

    var lhs = parsePrimaryExpr(&mut tree, source, &mut cursor, tokens, parens, depth + 1)
    if lhs < 0 { return -1 }

    while parserAtSymbol(source, cursor, tokens, ".") || parserAtSymbol(source, cursor, tokens, "@") || parserAtSymbol(source, cursor, tokens, "?") || parserAtSymbol(source, cursor, tokens, "[") {
        let tok = &tokens[cursor.pos]
        if parserTakeSymbol(source, &mut cursor, tokens, "[") {
            parserSkipNewlines(&mut cursor, tokens)
            let index = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
            parserSkipNewlines(&mut cursor, tokens)
            parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "]")
            let end_pos = cursorPrevEnd(cursor, tokens, tok.end)
            lhs = astAddExpr(&mut tree, AstExprKind.Index, tree.expressions[lhs].start, end_pos, lhs, index, 0, 0)
            continue
        }
        if parserTakeSymbol(source, &mut cursor, tokens, "?") {
            lhs = astAddExpr(&mut tree, AstExprKind.Try, tree.expressions[lhs].start, tok.end, lhs, 0, 0, 0)
            continue
        }

        let method_only = parserTakeSymbol(source, &mut cursor, tokens, "@")
        if !method_only { parserTakeSymbol(source, &mut cursor, tokens, ".") }
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            break
        }
        let memberTok = &tokens[cursor.pos]
        let m_start = memberTok.start
        let m_end = memberTok.end
        cursor.pos += 1

        if parserTakeSymbol(source, &mut cursor, tokens, "(") {
            var children: List<Int> = List[]
            parserSkipNewlines(&mut cursor, tokens)
            if !parserTakeSymbol(source, &mut cursor, tokens, ")") {
                while cursor.pos < tokens.length {
                    let arg = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                    if arg >= 0 {
                        children.push(arg)
                    }
                    parserSkipNewlines(&mut cursor, tokens)
                    if parserTakeSymbol(source, &mut cursor, tokens, ")") {
                        break
                    }
                    if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ",") {
                        break
                    }
                    parserSkipNewlines(&mut cursor, tokens)
                    if parserTakeSymbol(source, &mut cursor, tokens, ")") {
                        break
                    }
                }
            }
            let first_call = astAppendExtras(&mut tree, children, true)
            let end_pos = cursorPrevEnd(cursor, tokens, m_end)
            lhs = astAddExpr(&mut tree, AstExprKind.MethodCall, tree.expressions[lhs].start, end_pos, lhs, m_start, m_end, first_call)
        } else {
            if method_only {
                astAddError(&mut tree, ParseProblem.ExpectedToken, "(", m_start, m_end)
                return -1
            }
            lhs = astAddExpr(&mut tree, AstExprKind.Field, tree.expressions[lhs].start, m_end, lhs, m_start, m_end, 0)
        }
    }

    while cursor.pos < tokens.length {
        if parens > 0 {
            parserSkipNewlines(&mut cursor, tokens)
        }
        if cursor.pos >= tokens.length { break }
        let tok = &tokens[cursor.pos]
        let prec = parserGetBinaryPrecedence(source, tok)
        if prec < min_prec || prec == 0 {
            break
        }

        if prec == 5 {
            let left_expr = &tree.expressions[lhs]
            match left_expr.kind {
                AstExprKind.Binary => {
                    let op_start = left_expr.c
                    let b = source.byteAt(op_start)
                    if b == 60 || b == 62 {
                        astAddError(&mut tree, ParseProblem.ChainedComparisonsProhibited, "", tok.start, tok.end)
                        return -1
                    }
                }
                _ => {}
            }
        }

        let op_start = tok.start
        let op_end = tok.end
        let is_null_coalesce = (prec == 1)
        cursor.pos += 1
        parserSkipNewlines(&mut cursor, tokens)

        let next_min = selectInt(is_null_coalesce, prec, prec + 1)
        let rhs = parseExpr(&mut tree, source, &mut cursor, tokens, next_min, parens, depth + 1)
        if rhs < 0 { return -1 }

        let s_pos = tree.expressions[lhs].start
        let e_pos = tree.expressions[rhs].end
        lhs = astAddExpr(&mut tree, AstExprKind.Binary, s_pos, e_pos, lhs, rhs, op_start, op_end)
    }

    return lhs
}

fn parsePrimaryExpr(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, parens: Int, depth: Int) -> Int {
    if cursor.pos >= tokens.length {
        astAddError(&mut tree, ParseProblem.ExpectedExpression, "", source.byteLength, source.byteLength)
        return -1
    }
    let tok = &tokens[cursor.pos]

    match tokenKindValue(&tok.kind) {
        LexKind.Integer => {
            let val = parserParseDecimalInt(source, tok.start, tok.end)
            cursor.pos += 1
            if val < 0 {
                astAddError(&mut tree, ParseProblem.UnexpectedToken, "entero fuera de rango", tok.start, tok.end)
                return -1
            }
            return astAddExpr(&mut tree, AstExprKind.IntLit, tok.start, tok.end, val, 0, 0, 0)
        }
        LexKind.Text => {
            cursor.pos += 1
            return astAddExpr(&mut tree, AstExprKind.TextLit, tok.start, tok.end, tok.start, tok.end, 0, 0)
        }
        LexKind.TextStart => {
            cursor.pos += 1
            var children: List<Int> = List[]
            while cursor.pos < tokens.length {
                let partTok = &tokens[cursor.pos]
                match tokenKindValue(&partTok.kind) {
                    LexKind.TextEnd => {
                        cursor.pos += 1
                        break
                    }
                    LexKind.Text => {
                        cursor.pos += 1
                        let partExpr = astAddExpr(&mut tree, AstExprKind.TextLit, partTok.start, partTok.end, partTok.start, partTok.end, 0, 0)
                        children.push(partExpr)
                    }
                    LexKind.InterpolationStart => {
                        cursor.pos += 1
                        parserSkipNewlines(&mut cursor, tokens)
                        let innerExpr = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                        if innerExpr >= 0 {
                            children.push(innerExpr)
                        }
                        parserSkipNewlines(&mut cursor, tokens)
                        if cursor.pos < tokens.length {
                            let current_kind_token = &tokens[cursor.pos]
                            match tokenKindValue(&current_kind_token.kind) {
                                LexKind.InterpolationEnd => { cursor.pos += 1 }
                                _ => {
                                    astAddError(&mut tree, ParseProblem.UnclosedInterpolation, "}}", tokens[cursor.pos].start, tokens[cursor.pos].end)
                                    return -1
                                }
                            }
                        }
                    }
                    _ => {
                        astAddError(&mut tree, ParseProblem.ExpectedToken, "segmento de texto", partTok.start, partTok.end)
                        return -1
                    }
                }
            }
            let end_pos = cursorPrevEnd(cursor, tokens, tok.end)
            let first_part = astAppendExtras(&mut tree, children, false)
            return astAddExpr(&mut tree, AstExprKind.Interpolate, tok.start, end_pos, first_part, children.length, 0, 0)
        }
        LexKind.Word => {
            if parserTakeWord(source, &mut cursor, tokens, "true") {
                return astAddExpr(&mut tree, AstExprKind.BoolLit, tok.start, tok.end, 1, 0, 0, 0)
            }
            if parserTakeWord(source, &mut cursor, tokens, "false") {
                return astAddExpr(&mut tree, AstExprKind.BoolLit, tok.start, tok.end, 0, 0, 0, 0)
            }
            if parserTakeWord(source, &mut cursor, tokens, "None") {
                return astAddExpr(&mut tree, AstExprKind.Name, tok.start, tok.end, tok.start, tok.end, 0, 0)
            }
            let is_view = parserTakeWord(source, &mut cursor, tokens, "view")
            let is_edit = parserTakeWord(source, &mut cursor, tokens, "edit")
            if is_view || is_edit {
                parserSkipNewlines(&mut cursor, tokens)
                let operand = parseExpr(&mut tree, source, &mut cursor, tokens, 8, parens, depth + 1)
                let end_pos = astExprEnd(&tree, operand, tok.end)
                return astAddExpr(&mut tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, tok.end, 0)
            }
            if parserTakeWord(source, &mut cursor, tokens, "await") {
                parserSkipNewlines(&mut cursor, tokens)
                let operand = parseExpr(&mut tree, source, &mut cursor, tokens, 8, parens, depth + 1)
                let end_pos = astExprEnd(&tree, operand, tok.end)
                return astAddExpr(&mut tree, AstExprKind.Await, tok.start, end_pos, operand, 0, 0, 0)
            }
            if parserTakeWord(source, &mut cursor, tokens, "spawn") {
                parserSkipNewlines(&mut cursor, tokens)
                let operand = parseExpr(&mut tree, source, &mut cursor, tokens, 8, parens, depth + 1)
                let end_pos = astExprEnd(&tree, operand, tok.end)
                return astAddExpr(&mut tree, AstExprKind.Spawn, tok.start, end_pos, operand, 0, 0, 0)
            }
            if parserTakeWord(source, &mut cursor, tokens, "List") {
                if parserTakeSymbol(source, &mut cursor, tokens, "[") {
                    var children: List<Int> = List[]
                    parserSkipNewlines(&mut cursor, tokens)
                    if !parserTakeSymbol(source, &mut cursor, tokens, "]") {
                        while cursor.pos < tokens.length {
                            let elem = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                            if elem >= 0 {
                                children.push(elem)
                            }
                            parserSkipNewlines(&mut cursor, tokens)
                            if parserTakeSymbol(source, &mut cursor, tokens, "]") {
                                break
                            }
                            if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ",") {
                                break
                            }
                            parserSkipNewlines(&mut cursor, tokens)
                            if parserTakeSymbol(source, &mut cursor, tokens, "]") {
                                break
                            }
                        }
                    }
                    let end_pos = cursorPrevEnd(cursor, tokens, tok.end)
                    let first_elem = astAppendExtras(&mut tree, children, false)
                    return astAddExpr(&mut tree, AstExprKind.ListLit, tok.start, end_pos, first_elem, children.length, 0, 0)
                }
                return astAddExpr(&mut tree, AstExprKind.Name, tok.start, tok.end, tok.start, tok.end, 0, 0)
            }

            let name_start = tok.start
            let name_end = tok.end
            cursor.pos += 1

            if parserTakeSymbol(source, &mut cursor, tokens, "(") {
                var children: List<Int> = List[]
                parserSkipNewlines(&mut cursor, tokens)
                if !parserTakeSymbol(source, &mut cursor, tokens, ")") {
                    while cursor.pos < tokens.length {
                        var is_named = false
                        if cursor.pos + 1 < tokens.length {
                            let t0 = &tokens[cursor.pos]
                            let t1 = &tokens[cursor.pos + 1]
                            if parserIsSymbol(source, t1, ":") {
                                match tokenKindValue(&t0.kind) {
                                    LexKind.Word => { is_named = true }
                                    _ => {}
                                }
                            }
                        }
                        var arg = -1
                        if is_named {
                            let nTok = &tokens[cursor.pos]
                            cursor.pos += 2
                            parserSkipNewlines(&mut cursor, tokens)
                            let val = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                            let end_p = astExprEnd(&tree, val, nTok.end)
                            arg = astAddExpr(&mut tree, AstExprKind.Named, nTok.start, end_p, nTok.start, nTok.end, val, 0)
                        } else {
                            arg = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                        }
                        if arg >= 0 {
                            children.push(arg)
                        }
                        parserSkipNewlines(&mut cursor, tokens)
                        if parserTakeSymbol(source, &mut cursor, tokens, ")") {
                            break
                        }
                        if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ",") {
                            break
                        }
                        parserSkipNewlines(&mut cursor, tokens)
                        if parserTakeSymbol(source, &mut cursor, tokens, ")") {
                            break
                        }
                    }
                }
                let end_pos = cursorPrevEnd(cursor, tokens, name_end)
                let first_arg = astAppendExtras(&mut tree, children, false)
                return astAddExpr(&mut tree, AstExprKind.Call, name_start, end_pos, name_start, name_end, first_arg, children.length)
            }

            return astAddExpr(&mut tree, AstExprKind.Name, name_start, name_end, name_start, name_end, 0, 0)
        }
        LexKind.Symbol => {
            if parserTakeSymbol(source, &mut cursor, tokens, "(") {
                parserSkipNewlines(&mut cursor, tokens)
                if parserTakeSymbol(source, &mut cursor, tokens, ")") {
                    let end_p = cursorPrevEnd(cursor, tokens, tok.end)
                    return astAddExpr(&mut tree, AstExprKind.UnitLit, tok.start, end_p, 0, 0, 0, 0)
                }
                let inner = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                parserSkipNewlines(&mut cursor, tokens)
                parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ")")
                return inner
            }
            if parserTakeSymbol(source, &mut cursor, tokens, "[") {
                var children: List<Int> = List[]
                parserSkipNewlines(&mut cursor, tokens)
                if !parserTakeSymbol(source, &mut cursor, tokens, "]") {
                    while cursor.pos < tokens.length {
                        let elem = parseExpr(&mut tree, source, &mut cursor, tokens, 0, parens + 1, depth + 1)
                        if elem >= 0 {
                            children.push(elem)
                        }
                        parserSkipNewlines(&mut cursor, tokens)
                        if parserTakeSymbol(source, &mut cursor, tokens, "]") {
                            break
                        }
                        if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ",") {
                            break
                        }
                        parserSkipNewlines(&mut cursor, tokens)
                        if parserTakeSymbol(source, &mut cursor, tokens, "]") {
                            break
                        }
                    }
                }
                let end_pos = cursorPrevEnd(cursor, tokens, tok.end)
                let first_elem = astAppendExtras(&mut tree, children, false)
                return astAddExpr(&mut tree, AstExprKind.ArrayLit, tok.start, end_pos, first_elem, children.length, 0, 0)
            }
            if parserTakeSymbol(source, &mut cursor, tokens, "-") || parserTakeSymbol(source, &mut cursor, tokens, "!") {
                parserSkipNewlines(&mut cursor, tokens)
                let operand = parseExpr(&mut tree, source, &mut cursor, tokens, 8, parens, depth + 1)
                let end_pos = astExprEnd(&tree, operand, tok.end)
                return astAddExpr(&mut tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, tok.end, 0)
            }
            if parserTakeSymbol(source, &mut cursor, tokens, "&") {
                parserSkipNewlines(&mut cursor, tokens)
                let is_mut = parserTakeWord(source, &mut cursor, tokens, "mut")
                let operand = parseExpr(&mut tree, source, &mut cursor, tokens, 8, parens, depth + 1)
                let end_pos = astExprEnd(&tree, operand, tok.end)
                let op_end = selectInt(is_mut, tok.start + 4, tok.end)
                return astAddExpr(&mut tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, op_end, 0)
            }

            astAddError(&mut tree, ParseProblem.ExpectedExpression, "", tok.start, tok.end)
            return -1
        }
        _ => {
            astAddError(&mut tree, ParseProblem.ExpectedExpression, "", tok.start, tok.end)
            return -1
        }
    }
}
