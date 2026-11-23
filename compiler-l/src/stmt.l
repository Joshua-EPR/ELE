take lexer
take tokens
take cursor
take ast
take parse_util
take expr
take types

expose flow parseBlock(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], depth: Int) => Int {
    when depth > 128 {
        hold s = cursorSpanStart(cursor, tokens, source.byteLength)
        hold e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(edit tree, ParseProblem.NestingLimitExceeded, "", s, e)
        give -1
    }
    when cursor.pos >= tokens.length {
        astAddError(edit tree, ParseProblem.ExpectedToken, "{{", source.byteLength, source.byteLength)
        give -1
    }
    hold openTok = view tokens[cursor.pos]
    when !parserNeedSymbol(edit tree, source, edit cursor, tokens, "{{") {
        give -1
    }

    change block_stmts: List of[Int] = List[]
    parserSkipSeparators(source, edit cursor, tokens)

    during !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
        hold current_kind_token = view tokens[cursor.pos]
        choose tokenKindValue(view current_kind_token.kind) {
            LexKind.Eof : {
                astAddError(edit tree, ParseProblem.UnclosedBlock, "}}", openTok.start, openTok.end)
                give -1
            }
            _ : {}
        }
        hold before_pos = cursor.pos
        hold stmt = parseStmt(edit tree, source, edit cursor, tokens, depth + 1)
        when stmt >= 0 {
            block_stmts@push(stmt)
        } otherwise {
            when cursor.pos == before_pos && cursor.pos < tokens.length {
                cursor.pos += 1
            }
        }
        parserSkipSeparators(source, edit cursor, tokens)
    }

    parserNeedSymbol(edit tree, source, edit cursor, tokens, "}}")
    hold end_pos = cursorPrevEnd(cursor, tokens, openTok.end)
    hold first_stmt = tree.extra.length
    hold count = block_stmts.length
    each s among 0..count {
        astAddExtra(edit tree, block_stmts[s])
    }
    give astAddStmt(edit tree, AstStmtKind.Block, openTok.start, end_pos, first_stmt, count, 0, 0, 0)
}

expose flow parseStmt(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken], depth: Int) => Int {
    when cursor.pos >= tokens.length { give -1 }
    hold tok = view tokens[cursor.pos]

    when parserAtWord(source, cursor, tokens, "const") {
        cursor.pos += 1
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        change type_id = -1
        when parserTakeSymbol(source, edit cursor, tokens, ":") {
            type_id = parseType(edit tree, source, edit cursor, tokens, depth + 1)
        }
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "=")
        parserSkipNewlines(edit cursor, tokens)
        hold val = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        hold end_pos = astExprEnd(view tree, val, tok.end)
        give astAddStmt(edit tree, AstStmtKind.Const, tok.start, end_pos, nameTok.start, nameTok.end, type_id, val, 0)
    }

    when parserAtWord(source, cursor, tokens, "let") || parserAtWord(source, cursor, tokens, "var") {
        hold is_mut = parserTakeWord(source, edit cursor, tokens, "var")
        when !is_mut {
            parserTakeWord(source, edit cursor, tokens, "let")
        }
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        change type_id = -1
        when parserTakeSymbol(source, edit cursor, tokens, ":") {
            type_id = parseType(edit tree, source, edit cursor, tokens, depth + 1)
        }
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "=")
        parserSkipNewlines(edit cursor, tokens)
        hold val = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        hold end_pos = astExprEnd(view tree, val, tok.end)
        hold mut_flag = selectInt(is_mut, 1, 0)
        give astAddStmt(edit tree, AstStmtKind.Let, tok.start, end_pos, nameTok.start, nameTok.end, mut_flag, type_id, val)
    }

    when parserTakeWord(source, edit cursor, tokens, "return") {
        when parserAtSymbol(source, cursor, tokens, ";") || parserAtSymbol(source, cursor, tokens, "}}") || cursor.pos >= tokens.length {
            give astAddStmt(edit tree, AstStmtKind.Return, tok.start, tok.end, -1, 0, 0, 0, 0)
        }
        hold current_kind_token = view tokens[cursor.pos]
        choose tokenKindValue(view current_kind_token.kind) {
            LexKind.Newline : {
                give astAddStmt(edit tree, AstStmtKind.Return, tok.start, tok.end, -1, 0, 0, 0, 0)
            }
            _ : {}
        }
        hold val = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        hold end_pos = astExprEnd(view tree, val, tok.end)
        give astAddStmt(edit tree, AstStmtKind.Return, tok.start, end_pos, val, 0, 0, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "if") {
        hold cond = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(edit cursor, tokens)
        hold then_block = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
        change else_stmt = -1
        parserSkipNewlines(edit cursor, tokens)
        when parserTakeWord(source, edit cursor, tokens, "else") {
            parserSkipNewlines(edit cursor, tokens)
            when parserAtWord(source, cursor, tokens, "if") {
                else_stmt = parseStmt(edit tree, source, edit cursor, tokens, depth + 1)
            } otherwise {
                else_stmt = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
            }
        }
        change end_pos = tok.end
        when else_stmt >= 0 {
            end_pos = tree.statements[else_stmt].end
        } otherwise when then_block >= 0 {
            end_pos = tree.statements[then_block].end
        }
        give astAddStmt(edit tree, AstStmtKind.If, tok.start, end_pos, cond, then_block, else_stmt, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "while") {
        hold cond = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(edit cursor, tokens)
        hold body = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
        hold end_pos = astStmtEnd(view tree, body, tok.end)
        give astAddStmt(edit tree, AstStmtKind.While, tok.start, end_pos, cond, body, 0, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "for") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold varTok = view tokens[cursor.pos]
        cursor.pos += 1
        parserNeedWord(edit tree, source, edit cursor, tokens, "in")
        hold startExpr = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)

        hold is_inclusive = parserTakeSymbol(source, edit cursor, tokens, "..=")
        when is_inclusive || parserTakeSymbol(source, edit cursor, tokens, "..") {
            hold endExpr = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
            parserSkipNewlines(edit cursor, tokens)
            hold body = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
            hold end_pos = astStmtEnd(view tree, body, tok.end)
            hold inc_flag = selectInt(is_inclusive, 1, 0)
            hold extra_idx = astAddExtra(edit tree, inc_flag)
            astAddExtra(edit tree, body)
            give astAddStmt(edit tree, AstStmtKind.For, tok.start, end_pos, varTok.start, varTok.end, startExpr, endExpr, extra_idx)
        }

        parserSkipNewlines(edit cursor, tokens)
        hold body = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
        hold end_pos = astStmtEnd(view tree, body, tok.end)
        give astAddStmt(edit tree, AstStmtKind.ForEach, tok.start, end_pos, varTok.start, varTok.end, startExpr, body, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "loop") {
        parserSkipNewlines(edit cursor, tokens)
        hold body = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
        hold end_pos = astStmtEnd(view tree, body, tok.end)
        give astAddStmt(edit tree, AstStmtKind.Loop, tok.start, end_pos, body, 0, 0, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "break") {
        give astAddStmt(edit tree, AstStmtKind.Break, tok.start, tok.end, 0, 0, 0, 0, 0)
    }
    when parserTakeWord(source, edit cursor, tokens, "continue") {
        give astAddStmt(edit tree, AstStmtKind.Continue, tok.start, tok.end, 0, 0, 0, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "region") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(edit cursor, tokens)
        hold body = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
        hold end_pos = astStmtEnd(view tree, body, tok.end)
        give astAddStmt(edit tree, AstStmtKind.Region, tok.start, end_pos, nameTok.start, nameTok.end, body, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "match") {
        hold scrutinee = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(edit cursor, tokens)
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "{{")
        change arm_starts: List of[Int] = List[]
        change arm_ends: List of[Int] = List[]
        change arm_stmts: List of[Int] = List[]
        during !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            parserSkipSeparators(source, edit cursor, tokens)
            when parserAtSymbol(source, cursor, tokens, "}}") || cursor.pos >= tokens.length {
                leave
            }
            hold p_start = cursorSpanStart(cursor, tokens, source.byteLength)
            during !parserAtSymbol(source, cursor, tokens, "=>") && cursor.pos < tokens.length {
                cursor.pos += 1
            }
            hold p_end = cursorPrevEnd(cursor, tokens, source.byteLength)
            parserNeedSymbol(edit tree, source, edit cursor, tokens, "=>")
            parserSkipNewlines(edit cursor, tokens)
            change body_stmt = -1
            when parserAtSymbol(source, cursor, tokens, "{{") {
                body_stmt = parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
            } otherwise when parserTakeWord(source, edit cursor, tokens, "return") {
                hold ret_e = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
                hold r_end = astExprEnd(view tree, ret_e, p_end)
                body_stmt = astAddStmt(edit tree, AstStmtKind.Return, p_start, r_end, ret_e, 0, 0, 0, 0)
            } otherwise {
                hold body_e = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
                hold b_end = astExprEnd(view tree, body_e, p_end)
                body_stmt = astAddStmt(edit tree, AstStmtKind.Expr, p_start, b_end, body_e, 0, 0, 0, 0)
            }
            arm_starts@push(p_start)
            arm_ends@push(p_end)
            arm_stmts@push(body_stmt)
            parserTakeSymbol(source, edit cursor, tokens, ",")
            parserSkipSeparators(source, edit cursor, tokens)
        }
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "}}")
        hold end_pos = cursorPrevEnd(cursor, tokens, tok.end)
        hold first_arm = tree.extra.length
        hold arm_count = arm_starts.length
        each a among 0..arm_count {
            astAddExtra(edit tree, arm_starts[a])
            astAddExtra(edit tree, arm_ends[a])
            astAddExtra(edit tree, arm_stmts[a])
        }
        hold match_expr = astAddExpr(edit tree, AstExprKind.Match, tok.start, end_pos, scrutinee, first_arm, arm_count, 0)
        give astAddStmt(edit tree, AstStmtKind.Expr, tok.start, end_pos, match_expr, 0, 0, 0, 0)
    }

    when parserAtSymbol(source, cursor, tokens, "{{") {
        give parseBlock(edit tree, source, edit cursor, tokens, depth + 1)
    }

    hold e = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
    when e < 0 { give -1 }

    when parserAtSymbol(source, cursor, tokens, "=") || parserAtSymbol(source, cursor, tokens, "+=") || parserAtSymbol(source, cursor, tokens, "-=") || parserAtSymbol(source, cursor, tokens, "*=") || parserAtSymbol(source, cursor, tokens, "/=") || parserAtSymbol(source, cursor, tokens, "%=") {
        hold opTok = view tokens[cursor.pos]
        hold op_s = opTok.start
        hold op_e = opTok.end
        cursor.pos += 1
        parserSkipNewlines(edit cursor, tokens)
        hold val = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, depth + 1)
        hold end_pos = astExprEnd(view tree, val, op_e)
        // Read the target span before lending `tree` exclusively to astAddStmt.
        hold target_start = tree.expressions[e].start
        give astAddStmt(edit tree, AstStmtKind.Assign, target_start, end_pos, e, op_s, op_e, val, 0)
    }

    hold explicit_semi = parserTakeSymbol(source, edit cursor, tokens, ";")
    hold semi_flag = selectInt(explicit_semi, 1, 0)
    hold expr_start = tree.expressions[e].start
    hold expr_end = tree.expressions[e].end
    give astAddStmt(edit tree, AstStmtKind.Expr, expr_start, expr_end, e, semi_flag, 0, 0, 0)
}
