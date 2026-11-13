import lexer
import tokens
import cursor
import ast
import parse_util
import expr
import types

fn parseBlock(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, depth: Int) -> Int {
    if depth > 128 {
        let s = cursorSpanStart(cursor, tokens, source.byteLength)
        let e = cursorSpanEnd(cursor, tokens, source.byteLength)
        astAddError(&mut tree, ParseProblem.NestingLimitExceeded, "", s, e)
        return -1
    }
    if cursor.pos >= tokens.length {
        astAddError(&mut tree, ParseProblem.ExpectedToken, "{{", source.byteLength, source.byteLength)
        return -1
    }
    let openTok = &tokens[cursor.pos]
    if !parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "{{") {
        return -1
    }

    var block_stmts: List<Int> = List[]
    parserSkipSeparators(source, &mut cursor, tokens)

    while !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
        let current_kind_token = &tokens[cursor.pos]
        match tokenKindValue(&current_kind_token.kind) {
            LexKind.Eof => {
                astAddError(&mut tree, ParseProblem.UnclosedBlock, "}}", openTok.start, openTok.end)
                return -1
            }
            _ => {}
        }
        let before_pos = cursor.pos
        let stmt = parseStmt(&mut tree, source, &mut cursor, tokens, depth + 1)
        if stmt >= 0 {
            block_stmts.push(stmt)
        } else {
            if cursor.pos == before_pos && cursor.pos < tokens.length {
                cursor.pos += 1
            }
        }
        parserSkipSeparators(source, &mut cursor, tokens)
    }

    parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "}}")
    let end_pos = cursorPrevEnd(cursor, tokens, openTok.end)
    let first_stmt = tree.extra.length
    let count = block_stmts.length
    for s in 0..count {
        astAddExtra(&mut tree, block_stmts[s])
    }
    return astAddStmt(&mut tree, AstStmtKind.Block, openTok.start, end_pos, first_stmt, count, 0, 0, 0)
}

fn parseStmt(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>, depth: Int) -> Int {
    if cursor.pos >= tokens.length { return -1 }
    let tok = &tokens[cursor.pos]

    if parserAtWord(source, cursor, tokens, "const") {
        cursor.pos += 1
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        var type_id = -1
        if parserTakeSymbol(source, &mut cursor, tokens, ":") {
            type_id = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
        }
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "=")
        parserSkipNewlines(&mut cursor, tokens)
        let val = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        let end_pos = astExprEnd(&tree, val, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.Const, tok.start, end_pos, nameTok.start, nameTok.end, type_id, val, 0)
    }

    if parserAtWord(source, cursor, tokens, "let") || parserAtWord(source, cursor, tokens, "var") {
        let is_mut = parserTakeWord(source, &mut cursor, tokens, "var")
        if !is_mut {
            parserTakeWord(source, &mut cursor, tokens, "let")
        }
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        var type_id = -1
        if parserTakeSymbol(source, &mut cursor, tokens, ":") {
            type_id = parseType(&mut tree, source, &mut cursor, tokens, depth + 1)
        }
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "=")
        parserSkipNewlines(&mut cursor, tokens)
        let val = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        let end_pos = astExprEnd(&tree, val, tok.end)
        let mut_flag = selectInt(is_mut, 1, 0)
        return astAddStmt(&mut tree, AstStmtKind.Let, tok.start, end_pos, nameTok.start, nameTok.end, mut_flag, type_id, val)
    }

    if parserTakeWord(source, &mut cursor, tokens, "return") {
        if parserAtSymbol(source, cursor, tokens, ";") || parserAtSymbol(source, cursor, tokens, "}}") || cursor.pos >= tokens.length {
            return astAddStmt(&mut tree, AstStmtKind.Return, tok.start, tok.end, -1, 0, 0, 0, 0)
        }
        let current_kind_token = &tokens[cursor.pos]
        match tokenKindValue(&current_kind_token.kind) {
            LexKind.Newline => {
                return astAddStmt(&mut tree, AstStmtKind.Return, tok.start, tok.end, -1, 0, 0, 0, 0)
            }
            _ => {}
        }
        let val = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        let end_pos = astExprEnd(&tree, val, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.Return, tok.start, end_pos, val, 0, 0, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "if") {
        let cond = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(&mut cursor, tokens)
        let then_block = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
        var else_stmt = -1
        parserSkipNewlines(&mut cursor, tokens)
        if parserTakeWord(source, &mut cursor, tokens, "else") {
            parserSkipNewlines(&mut cursor, tokens)
            if parserAtWord(source, cursor, tokens, "if") {
                else_stmt = parseStmt(&mut tree, source, &mut cursor, tokens, depth + 1)
            } else {
                else_stmt = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
            }
        }
        var end_pos = tok.end
        if else_stmt >= 0 {
            end_pos = tree.statements[else_stmt].end
        } else if then_block >= 0 {
            end_pos = tree.statements[then_block].end
        }
        return astAddStmt(&mut tree, AstStmtKind.If, tok.start, end_pos, cond, then_block, else_stmt, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "while") {
        let cond = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(&mut cursor, tokens)
        let body = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
        let end_pos = astStmtEnd(&tree, body, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.While, tok.start, end_pos, cond, body, 0, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "for") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let varTok = &tokens[cursor.pos]
        cursor.pos += 1
        parserNeedWord(&mut tree, source, &mut cursor, tokens, "in")
        let startExpr = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)

        let is_inclusive = parserTakeSymbol(source, &mut cursor, tokens, "..=")
        if is_inclusive || parserTakeSymbol(source, &mut cursor, tokens, "..") {
            let endExpr = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
            parserSkipNewlines(&mut cursor, tokens)
            let body = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
            let end_pos = astStmtEnd(&tree, body, tok.end)
            let inc_flag = selectInt(is_inclusive, 1, 0)
            let extra_idx = astAddExtra(&mut tree, inc_flag)
            astAddExtra(&mut tree, body)
            return astAddStmt(&mut tree, AstStmtKind.For, tok.start, end_pos, varTok.start, varTok.end, startExpr, endExpr, extra_idx)
        }

        parserSkipNewlines(&mut cursor, tokens)
        let body = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
        let end_pos = astStmtEnd(&tree, body, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.ForEach, tok.start, end_pos, varTok.start, varTok.end, startExpr, body, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "loop") {
        parserSkipNewlines(&mut cursor, tokens)
        let body = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
        let end_pos = astStmtEnd(&tree, body, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.Loop, tok.start, end_pos, body, 0, 0, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "break") {
        return astAddStmt(&mut tree, AstStmtKind.Break, tok.start, tok.end, 0, 0, 0, 0, 0)
    }
    if parserTakeWord(source, &mut cursor, tokens, "continue") {
        return astAddStmt(&mut tree, AstStmtKind.Continue, tok.start, tok.end, 0, 0, 0, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "region") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(&mut cursor, tokens)
        let body = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
        let end_pos = astStmtEnd(&tree, body, tok.end)
        return astAddStmt(&mut tree, AstStmtKind.Region, tok.start, end_pos, nameTok.start, nameTok.end, body, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "match") {
        let scrutinee = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        parserSkipNewlines(&mut cursor, tokens)
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "{{")
        var arm_starts: List<Int> = List[]
        var arm_ends: List<Int> = List[]
        var arm_stmts: List<Int> = List[]
        while !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            parserSkipSeparators(source, &mut cursor, tokens)
            if parserAtSymbol(source, cursor, tokens, "}}") || cursor.pos >= tokens.length {
                break
            }
            let p_start = cursorSpanStart(cursor, tokens, source.byteLength)
            while !parserAtSymbol(source, cursor, tokens, "=>") && cursor.pos < tokens.length {
                cursor.pos += 1
            }
            let p_end = cursorPrevEnd(cursor, tokens, source.byteLength)
            parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "=>")
            parserSkipNewlines(&mut cursor, tokens)
            var body_stmt = -1
            if parserAtSymbol(source, cursor, tokens, "{{") {
                body_stmt = parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
            } else if parserTakeWord(source, &mut cursor, tokens, "return") {
                let ret_e = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
                let r_end = astExprEnd(&tree, ret_e, p_end)
                body_stmt = astAddStmt(&mut tree, AstStmtKind.Return, p_start, r_end, ret_e, 0, 0, 0, 0)
            } else {
                let body_e = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
                let b_end = astExprEnd(&tree, body_e, p_end)
                body_stmt = astAddStmt(&mut tree, AstStmtKind.Expr, p_start, b_end, body_e, 0, 0, 0, 0)
            }
            arm_starts.push(p_start)
            arm_ends.push(p_end)
            arm_stmts.push(body_stmt)
            parserTakeSymbol(source, &mut cursor, tokens, ",")
            parserSkipSeparators(source, &mut cursor, tokens)
        }
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "}}")
        let end_pos = cursorPrevEnd(cursor, tokens, tok.end)
        let first_arm = tree.extra.length
        let arm_count = arm_starts.length
        for a in 0..arm_count {
            astAddExtra(&mut tree, arm_starts[a])
            astAddExtra(&mut tree, arm_ends[a])
            astAddExtra(&mut tree, arm_stmts[a])
        }
        let match_expr = astAddExpr(&mut tree, AstExprKind.Match, tok.start, end_pos, scrutinee, first_arm, arm_count, 0)
        return astAddStmt(&mut tree, AstStmtKind.Expr, tok.start, end_pos, match_expr, 0, 0, 0, 0)
    }

    if parserAtSymbol(source, cursor, tokens, "{{") {
        return parseBlock(&mut tree, source, &mut cursor, tokens, depth + 1)
    }

    let e = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
    if e < 0 { return -1 }

    if parserAtSymbol(source, cursor, tokens, "=") || parserAtSymbol(source, cursor, tokens, "+=") || parserAtSymbol(source, cursor, tokens, "-=") || parserAtSymbol(source, cursor, tokens, "*=") || parserAtSymbol(source, cursor, tokens, "/=") || parserAtSymbol(source, cursor, tokens, "%=") {
        let opTok = &tokens[cursor.pos]
        let op_s = opTok.start
        let op_e = opTok.end
        cursor.pos += 1
        parserSkipNewlines(&mut cursor, tokens)
        let val = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, depth + 1)
        let end_pos = astExprEnd(&tree, val, op_e)
        // Read the target span before lending `tree` exclusively to astAddStmt.
        let target_start = tree.expressions[e].start
        return astAddStmt(&mut tree, AstStmtKind.Assign, target_start, end_pos, e, op_s, op_e, val, 0)
    }

    let explicit_semi = parserTakeSymbol(source, &mut cursor, tokens, ";")
    let semi_flag = selectInt(explicit_semi, 1, 0)
    let expr_start = tree.expressions[e].start
    let expr_end = tree.expressions[e].end
    return astAddStmt(&mut tree, AstStmtKind.Expr, expr_start, expr_end, e, semi_flag, 0, 0, 0)
}
