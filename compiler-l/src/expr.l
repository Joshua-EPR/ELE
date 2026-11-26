take lexer
take tokens
take cursor
take ast
take parse_util
take float_parse

expose flow parseExpr(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], min_prec: Int, parens: Int, depth: Int) => Int {
    when depth > 128 {
        hold s = cursorSpanStart(cursor, tokens, source.byteLength)
        hold e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(edit tree, ParseProblem.NestingLimitExceeded, "", s, e)
        give -1
    }

    change lhs = parsePrimaryExpr(edit tree, source, edit cursor, tokens, parens, depth + 1)
    when lhs < 0 { give -1 }

    during parserAtSymbol(source, cursor, tokens, ".") || parserAtSymbol(source, cursor, tokens, "@") || parserAtSymbol(source, cursor, tokens, "?") || parserAtSymbol(source, cursor, tokens, "[") {
        // Keep the expression span independent of the mutable AST insertion.
        hold lhs_start = tree.expressions[lhs].start
        hold tok = view tokens[cursor.pos]
        when parserTakeSymbol(source, edit cursor, tokens, "[") {
            parserSkipNewlines(edit cursor, tokens)
            hold index = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
            parserSkipNewlines(edit cursor, tokens)
            parserNeedSymbol(edit tree, source, edit cursor, tokens, "]")
            hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
            lhs = astAddExpr(edit tree, AstExprKind.Index, lhs_start, end_pos, lhs, index, 0, 0)
            proceed
        }
        when parserTakeSymbol(source, edit cursor, tokens, "?") {
            lhs = astAddExpr(edit tree, AstExprKind.Try, lhs_start, tok.end, lhs, 0, 0, 0)
            proceed
        }

        hold method_only = parserTakeSymbol(source, edit cursor, tokens, "@")
        when !method_only { parserTakeSymbol(source, edit cursor, tokens, ".") }
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            leave
        }
        hold memberTok = view tokens[cursor.pos]
        hold m_start = memberTok.start
        hold m_end = memberTok.end
        cursor.pos += 1

        when parserTakeSymbol(source, edit cursor, tokens, "(") {
            change children: List of[Int] = List[]
            parserSkipNewlines(edit cursor, tokens)
            when !parserTakeSymbol(source, edit cursor, tokens, ")") {
                during cursor.pos < tokens.length {
                    hold arg = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                    when arg >= 0 {
                        children@push(arg)
                    }
                    parserSkipNewlines(edit cursor, tokens)
                    when parserTakeSymbol(source, edit cursor, tokens, ")") {
                        leave
                    }
                    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ",") {
                        leave
                    }
                    parserSkipNewlines(edit cursor, tokens)
                    when parserTakeSymbol(source, edit cursor, tokens, ")") {
                        leave
                    }
                }
            }
            hold first_call = astAppendExtras(edit tree, children, true)
            hold end_pos = cursorPrevEnd(cursor, tokens, m_end)
            lhs = astAddExpr(edit tree, AstExprKind.MethodCall, lhs_start, end_pos, lhs, m_start, m_end, first_call)
        } otherwise {
            when method_only {
                astAddError(edit tree, ParseProblem.ExpectedToken, "(", m_start, m_end)
                give -1
            }
            lhs = astAddExpr(edit tree, AstExprKind.Field, lhs_start, m_end, lhs, m_start, m_end, 0)
        }
    }

    during cursor.pos < tokens.length {
        when parens > 0 {
            parserSkipNewlines(edit cursor, tokens)
        }
        when cursor.pos >= tokens.length { leave }
        hold tok = view tokens[cursor.pos]
        hold shift_pair = parserShiftPair(source, tokens, cursor.pos)
        change prec = parserGetBinaryPrecedence(source, tok)
        when shift_pair { prec = 9 }
        when prec < min_prec || prec == 0 {
            leave
        }

        when prec == 5 {
            hold left_expr = view tree.expressions[lhs]
            choose left_expr.kind {
                AstExprKind.Binary : {
                    hold op_start = left_expr.c
                    hold b = source@byteAt(op_start)
                    // `<<` and `>>` are shifts, not comparisons.
                    hold shift = left_expr.d - op_start == 2 && source@byteAt(op_start + 1) == b
                    when (b == 60 || b == 62) && !shift {
                        astAddError(edit tree, ParseProblem.ChainedComparisonsProhibited, "", tok.start, tok.end)
                        give -1
                    }
                }
                _ : {}
            }
        }

        hold op_start = tok.start
        change op_end = tok.end
        hold is_null_coalesce = (prec == 1)
        cursor.pos += 1
        when shift_pair {
            op_end = tokens[cursor.pos].end
            cursor.pos += 1
        }
        parserSkipNewlines(edit cursor, tokens)

        hold next_min = selectInt(is_null_coalesce, prec, prec + 1)
        hold rhs = parseExpr(edit tree, source, edit cursor, tokens, next_min, parens, depth + 1)
        when rhs < 0 { give -1 }

        hold s_pos = tree.expressions[lhs].start
        hold e_pos = tree.expressions[rhs].end
        lhs = astAddExpr(edit tree, AstExprKind.Binary, s_pos, e_pos, lhs, rhs, op_start, op_end)
    }

    give lhs
}

// Value-producing `choose`: keep its arm expressions distinct from the
// statement `choose` AST, whose bodies are statements and have no value.
flow parseChooseExpr(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], tok: view LexToken, parens: Int, depth: Int) => Int {
    cursor.pos += 1
    parserSkipNewlines(edit cursor, tokens)
    hold scrutinee = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
    parserSkipNewlines(edit cursor, tokens)
    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, "{{") { give -1 }

    change arm_starts: List of[Int] = List[]
    change arm_ends: List of[Int] = List[]
    change arm_values: List of[Int] = List[]
    parserSkipSeparators(source, edit cursor, tokens)
    during !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
        hold p_start = cursorSpanStart(cursor, tokens, source.byteLength)
        during cursor.pos < tokens.length && !parserAtSymbol(source, cursor, tokens, ":") && !parserAtSymbol(source, cursor, tokens, "}}") {
            cursor.pos += 1
        }
        hold p_end = cursorPrevEnd(cursor, tokens, p_start)
        when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ":") { give -1 }
        parserSkipNewlines(edit cursor, tokens)
        hold value = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
        when value < 0 { give -1 }
        arm_starts@push(p_start)
        arm_ends@push(p_end)
        arm_values@push(value)
        parserSkipNewlines(edit cursor, tokens)
        parserTakeSymbol(source, edit cursor, tokens, ",")
        parserSkipSeparators(source, edit cursor, tokens)
    }
    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, "}}") { give -1 }

    hold first_arm = tree.extra.length
    hold arm_count = arm_values.length
    each i among 0..arm_count {
        astAddExtra(edit tree, arm_starts[i])
        astAddExtra(edit tree, arm_ends[i])
        astAddExtra(edit tree, arm_values[i])
    }
    hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
    give astAddExpr(edit tree, AstExprKind.Choose, tok.start, end_pos, scrutinee, first_arm, arm_count, 0)
}

flow parsePrimaryExpr(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], parens: Int, depth: Int) => Int {
    when cursor.pos >= tokens.length {
        astAddError(edit tree, ParseProblem.ExpectedExpression, "", source.byteLength, source.byteLength)
        give -1
    }
    hold tok = view tokens[cursor.pos]

    choose tokenKindValue(view tok.kind) {
        LexKind.Integer : {
            when parserIsRadixLiteral(source, tok.start, tok.end) {
                hold radix = parserParseRadixInt(source, tok.start, tok.end)
                cursor.pos += 1
                when !radix.ok {
                    astAddError(edit tree, ParseProblem.UnexpectedToken, "literal entero de más de 64 bits", tok.start, tok.end)
                    give -1
                }
                give astAddExpr(edit tree, AstExprKind.IntLit, tok.start, tok.end, radix.value, 0, 0, 0)
            }
            when parserIsFloatLiteral(source, tok.start, tok.end) {
                hold bits = floatLiteralBits(source, tok.start, tok.end)
                cursor.pos += 1
                when bits < 0 {
                    astAddError(edit tree, ParseProblem.UnexpectedToken, "literal Float fuera de rango", tok.start, tok.end)
                    give -1
                }
                give astAddExpr(edit tree, AstExprKind.FloatLit, tok.start, tok.end, bits, 0, 0, 0)
            }
            hold val = parserParseDecimalInt(source, tok.start, tok.end)
            cursor.pos += 1
            when val < 0 {
                when parserIsIntMinMagnitude(source, tok.start, tok.end) {
                    astAddError(edit tree, ParseProblem.UnexpectedToken, "entero fuera de rango: 9223372036854775808 solo es válido directamente tras '-'", tok.start, tok.end)
                    give -1
                }
                astAddError(edit tree, ParseProblem.UnexpectedToken, "entero fuera de rango", tok.start, tok.end)
                give -1
            }
            give astAddExpr(edit tree, AstExprKind.IntLit, tok.start, tok.end, val, 0, 0, 0)
        }
        LexKind.Text : {
            cursor.pos += 1
            give astAddExpr(edit tree, AstExprKind.TextLit, tok.start, tok.end, tok.start, tok.end, 0, 0)
        }
        LexKind.TextStart : {
            cursor.pos += 1
            change children: List of[Int] = List[]
            during cursor.pos < tokens.length {
                hold partTok = view tokens[cursor.pos]
                choose tokenKindValue(view partTok.kind) {
                    LexKind.TextEnd : {
                        cursor.pos += 1
                        leave
                    }
                    LexKind.Text : {
                        cursor.pos += 1
                        hold partExpr = astAddExpr(edit tree, AstExprKind.TextLit, partTok.start, partTok.end, partTok.start, partTok.end, 0, 0)
                        children@push(partExpr)
                    }
                    LexKind.InterpolationStart : {
                        cursor.pos += 1
                        parserSkipNewlines(edit cursor, tokens)
                        hold innerExpr = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                        when innerExpr >= 0 {
                            children@push(innerExpr)
                        }
                        parserSkipNewlines(edit cursor, tokens)
                        when cursor.pos < tokens.length {
                            hold current_kind_token = view tokens[cursor.pos]
                            choose tokenKindValue(view current_kind_token.kind) {
                                LexKind.InterpolationEnd : { cursor.pos += 1 }
                                _ : {
                                    astAddError(edit tree, ParseProblem.UnclosedInterpolation, "}}", tokens[cursor.pos].start, tokens[cursor.pos].end)
                                    give -1
                                }
                            }
                        }
                    }
                    _ : {
                        astAddError(edit tree, ParseProblem.ExpectedToken, "segmento de texto", partTok.start, partTok.end)
                        give -1
                    }
                }
            }
            hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
            hold first_part = astAppendExtras(edit tree, children, false)
            give astAddExpr(edit tree, AstExprKind.Interpolate, tok.start, end_pos, first_part, children.length, 0, 0)
        }
        LexKind.Word : {
            when parserAtWord(source, cursor, tokens, "match") {
                give parseChooseExpr(edit tree, source, edit cursor, tokens, tok, parens, depth)
            }
            when parserTakeWord(source, edit cursor, tokens, "true") {
                give astAddExpr(edit tree, AstExprKind.BoolLit, tok.start, tok.end, 1, 0, 0, 0)
            }
            when parserTakeWord(source, edit cursor, tokens, "false") {
                give astAddExpr(edit tree, AstExprKind.BoolLit, tok.start, tok.end, 0, 0, 0, 0)
            }
            when parserTakeWord(source, edit cursor, tokens, "None") {
                give astAddExpr(edit tree, AstExprKind.Name, tok.start, tok.end, tok.start, tok.end, 0, 0)
            }
            hold is_view = parserTakeWord(source, edit cursor, tokens, "view")
            hold is_edit = parserTakeWord(source, edit cursor, tokens, "edit")
            when is_view || is_edit {
                parserSkipNewlines(edit cursor, tokens)
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                give astAddExpr(edit tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, tok.end, 0)
            }
            when parserTakeWord(source, edit cursor, tokens, "await") {
                parserSkipNewlines(edit cursor, tokens)
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                give astAddExpr(edit tree, AstExprKind.Await, tok.start, end_pos, operand, 0, 0, 0)
            }
            when parserTakeWord(source, edit cursor, tokens, "spawn") {
                parserSkipNewlines(edit cursor, tokens)
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                give astAddExpr(edit tree, AstExprKind.Spawn, tok.start, end_pos, operand, 0, 0, 0)
            }
            when parserTakeWord(source, edit cursor, tokens, "List") {
                when parserTakeSymbol(source, edit cursor, tokens, "[") {
                    change children: List of[Int] = List[]
                    parserSkipNewlines(edit cursor, tokens)
                    when !parserTakeSymbol(source, edit cursor, tokens, "]") {
                        during cursor.pos < tokens.length {
                            hold elem = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                            when elem >= 0 {
                                children@push(elem)
                            }
                            parserSkipNewlines(edit cursor, tokens)
                            when parserTakeSymbol(source, edit cursor, tokens, "]") {
                                leave
                            }
                            when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ",") {
                                leave
                            }
                            parserSkipNewlines(edit cursor, tokens)
                            when parserTakeSymbol(source, edit cursor, tokens, "]") {
                                leave
                            }
                        }
                    }
                    hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
                    hold first_elem = astAppendExtras(edit tree, children, false)
                    give astAddExpr(edit tree, AstExprKind.ListLit, tok.start, end_pos, first_elem, children.length, 0, 0)
                }
                give astAddExpr(edit tree, AstExprKind.Name, tok.start, tok.end, tok.start, tok.end, 0, 0)
            }

            hold name_start = tok.start
            hold name_end = tok.end
            cursor.pos += 1

            when parserTakeSymbol(source, edit cursor, tokens, "(") {
                change children: List of[Int] = List[]
                parserSkipNewlines(edit cursor, tokens)
                when !parserTakeSymbol(source, edit cursor, tokens, ")") {
                    during cursor.pos < tokens.length {
                        change is_named = false
                        when cursor.pos + 1 < tokens.length {
                            hold t0 = view tokens[cursor.pos]
                            hold t1 = view tokens[cursor.pos + 1]
                            when parserIsSymbol(source, t1, ":") {
                                choose tokenKindValue(view t0.kind) {
                                    LexKind.Word : { is_named = true }
                                    _ : {}
                                }
                            }
                        }
                        change arg = -1
                        when is_named {
                            hold nTok = view tokens[cursor.pos]
                            cursor.pos += 2
                            parserSkipNewlines(edit cursor, tokens)
                            hold val = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                            hold end_p = astExprEnd(view tree, val, nTok.end)
                            arg = astAddExpr(edit tree, AstExprKind.Named, nTok.start, end_p, nTok.start, nTok.end, val, 0)
                        } otherwise {
                            arg = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                        }
                        when arg >= 0 {
                            children@push(arg)
                        }
                        parserSkipNewlines(edit cursor, tokens)
                        when parserTakeSymbol(source, edit cursor, tokens, ")") {
                            leave
                        }
                        when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ",") {
                            leave
                        }
                        parserSkipNewlines(edit cursor, tokens)
                        when parserTakeSymbol(source, edit cursor, tokens, ")") {
                            leave
                        }
                    }
                }
                hold end_pos = cursorPrevEnd(cursor, tokens, name_end)
                hold first_arg = astAppendExtras(edit tree, children, false)
                give astAddExpr(edit tree, AstExprKind.Call, name_start, end_pos, name_start, name_end, first_arg, children.length)
            }

            give astAddExpr(edit tree, AstExprKind.Name, name_start, name_end, name_start, name_end, 0, 0)
        }
        LexKind.Symbol : {
            when parserTakeSymbol(source, edit cursor, tokens, "(") {
                parserSkipNewlines(edit cursor, tokens)
                when parserTakeSymbol(source, edit cursor, tokens, ")") {
                    hold end_p = cursorPrevEnd(cursor, tokens, tok.end)
                    give astAddExpr(edit tree, AstExprKind.UnitLit, tok.start, end_p, 0, 0, 0, 0)
                }
                hold inner = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                parserSkipNewlines(edit cursor, tokens)
                parserNeedSymbol(edit tree, source, edit cursor, tokens, ")")
                give inner
            }
            when parserTakeSymbol(source, edit cursor, tokens, "[") {
                change children: List of[Int] = List[]
                parserSkipNewlines(edit cursor, tokens)
                when !parserTakeSymbol(source, edit cursor, tokens, "]") {
                    during cursor.pos < tokens.length {
                        hold elem = parseExpr(edit tree, source, edit cursor, tokens, 0, parens + 1, depth + 1)
                        when elem >= 0 {
                            children@push(elem)
                        }
                        parserSkipNewlines(edit cursor, tokens)
                        when parserTakeSymbol(source, edit cursor, tokens, "]") {
                            leave
                        }
                        when !parserNeedSymbol(edit tree, source, edit cursor, tokens, ",") {
                            leave
                        }
                        parserSkipNewlines(edit cursor, tokens)
                        when parserTakeSymbol(source, edit cursor, tokens, "]") {
                            leave
                        }
                    }
                }
                hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
                hold first_elem = astAppendExtras(edit tree, children, false)
                give astAddExpr(edit tree, AstExprKind.ArrayLit, tok.start, end_pos, first_elem, children.length, 0, 0)
            }
            when parserTakeSymbol(source, edit cursor, tokens, "~") {
                // Bitwise not of an Int.
                parserSkipNewlines(edit cursor, tokens)
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                give astAddExpr(edit tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, tok.end, 0)
            }
            when parserTakeSymbol(source, edit cursor, tokens, "-") || parserTakeSymbol(source, edit cursor, tokens, "!") {
                // The magnitude of Int.MIN does not fit an Int. It is only
                // valid directly under `-`, where the pair is the literal
                // Int.MIN itself (Stage 0: "magnitud solo válida tras '-'").
                when tok.end == tok.start + 1 && source@byteAt(tok.start) == 45 && cursor.pos < tokens.length {
                    hold next_tok = view tokens[cursor.pos]
                    choose tokenKindValue(view next_tok.kind) {
                        LexKind.Integer : {
                            when parserIsIntMinMagnitude(source, next_tok.start, next_tok.end) {
                                cursor.pos += 1
                                hold int_min = -9223372036854775807 - 1
                                give astAddExpr(edit tree, AstExprKind.IntLit, tok.start, next_tok.end, int_min, 0, 0, 0)
                            }
                        }
                        _ : {}
                    }
                }
                parserSkipNewlines(edit cursor, tokens)
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                give astAddExpr(edit tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, tok.end, 0)
            }
            when parserTakeSymbol(source, edit cursor, tokens, "&") {
                parserSkipNewlines(edit cursor, tokens)
                hold is_mut = parserTakeWord(source, edit cursor, tokens, "mut")
                hold operand = parseExpr(edit tree, source, edit cursor, tokens, PARSER_PREC_UNARY, parens, depth + 1)
                hold end_pos = astExprEnd(view tree, operand, tok.end)
                hold op_end = selectInt(is_mut, tok.start + 4, tok.end)
                give astAddExpr(edit tree, AstExprKind.Unary, tok.start, end_pos, operand, tok.start, op_end, 0)
            }

            astAddError(edit tree, ParseProblem.ExpectedExpression, "", tok.start, tok.end)
            give -1
        }
        _ : {
            astAddError(edit tree, ParseProblem.ExpectedExpression, "", tok.start, tok.end)
            give -1
        }
    }
}
