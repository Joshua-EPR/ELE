import lexer
import tokens
import cursor
import ast
import parse_util
import expr
import types
import stmt

expose flow parseDecl(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) => Int {
    if cursor.pos >= tokens.length { return -1 }
    let is_public = parserTakeWord(source, &mut cursor, tokens, "pub")

    if parserTakeWord(source, &mut cursor, tokens, "import") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let pathStartTok = &tokens[cursor.pos]
        cursor.pos += 1
        var path_end = pathStartTok.end
        while parserTakeSymbol(source, &mut cursor, tokens, ".") {
            if cursor.pos < tokens.length {
                path_end = tokens[cursor.pos].end
                cursor.pos += 1
            }
        }
        parserTakeSymbol(source, &mut cursor, tokens, ";")
        return astAddDecl(&mut tree, AstDeclKind.Import, pathStartTok.start, path_end, is_public, pathStartTok.start, path_end, 0, 0, 0, 0, 0)
    }

    if parserAtWord(source, cursor, tokens, "const") {
        let s_id = parseStmt(&mut tree, source, &mut cursor, tokens, 0)
        if s_id >= 0 {
            let s = &tree.statements[s_id]
            return astAddDecl(&mut tree, AstDeclKind.Const, s.start, s.end, is_public, s.a, s.b, s.c, s.d, 0, 0, 0)
        }
        return -1
    }

    if parserTakeWord(source, &mut cursor, tokens, "struct") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(&mut cursor, tokens)
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "{{")

        let first_field = tree.fields.length
        var field_count = 0
        parserSkipSeparators(source, &mut cursor, tokens)

        while !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            let f_pub = parserTakeWord(source, &mut cursor, tokens, "pub")
            if cursor.pos >= tokens.length { break }
            let fTok = &tokens[cursor.pos]
            cursor.pos += 1
            parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ":")
            let f_type = parseType(&mut tree, source, &mut cursor, tokens, 0)
            var f_default = -1
            if parserTakeSymbol(source, &mut cursor, tokens, "=") {
                parserSkipNewlines(&mut cursor, tokens)
                f_default = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, 0)
            }
            var end_p = fTok.end
            if f_default >= 0 {
                end_p = tree.expressions[f_default].end
            } else if f_type >= 0 {
                end_p = tree.types[f_type].end
            }
            astAddField(&mut tree, fTok.start, fTok.end, f_pub, f_type, f_default, fTok.start, end_p)
            field_count += 1
            parserTakeSymbol(source, &mut cursor, tokens, ",")
            parserSkipSeparators(source, &mut cursor, tokens)
        }

        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "}}")
        let end_pos = cursorPrevEnd(cursor, tokens, nameTok.end)
        return astAddDecl(&mut tree, AstDeclKind.Struct, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, first_field, field_count, 0, 0, 0)
    }

    if parserTakeWord(source, &mut cursor, tokens, "enum") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(&mut cursor, tokens)
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "{{")

        let first_variant = tree.variants.length
        var variant_count = 0
        parserSkipSeparators(source, &mut cursor, tokens)

        while !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            if cursor.pos >= tokens.length { break }
            let vTok = &tokens[cursor.pos]
            cursor.pos += 1
            let first_payload = tree.extra.length
            var payload_count = 0
            if parserTakeSymbol(source, &mut cursor, tokens, "(") {
                parserSkipNewlines(&mut cursor, tokens)
                if !parserTakeSymbol(source, &mut cursor, tokens, ")") {
                    while cursor.pos < tokens.length {
                        let p_ty = parseType(&mut tree, source, &mut cursor, tokens, 0)
                        if p_ty >= 0 {
                            astAddExtra(&mut tree, p_ty)
                            payload_count += 1
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
            }
            let end_p = cursorPrevEnd(cursor, tokens, vTok.end)
            astAddVariant(&mut tree, vTok.start, vTok.end, first_payload, payload_count, vTok.start, end_p)
            variant_count += 1
            parserTakeSymbol(source, &mut cursor, tokens, ",")
            parserSkipSeparators(source, &mut cursor, tokens)
        }

        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "}}")
        let end_pos = cursorPrevEnd(cursor, tokens, nameTok.end)
        return astAddDecl(&mut tree, AstDeclKind.Enum, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, first_variant, variant_count, 0, 0, 0)
    }

    let is_async = parserTakeWord(source, &mut cursor, tokens, "async")
    if parserTakeWord(source, &mut cursor, tokens, "fn") {
        if cursor.pos >= tokens.length {
            astAddError(&mut tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            return -1
        }
        let nameTok = &tokens[cursor.pos]
        cursor.pos += 1
        parserNeedSymbol(&mut tree, source, &mut cursor, tokens, "(")

        let first_param = tree.params.length
        var param_count = 0
        parserSkipNewlines(&mut cursor, tokens)

        if !parserTakeSymbol(source, &mut cursor, tokens, ")") {
            while cursor.pos < tokens.length {
                if cursor.pos >= tokens.length { break }
                let pTok = &tokens[cursor.pos]
                cursor.pos += 1
                parserNeedSymbol(&mut tree, source, &mut cursor, tokens, ":")
                let p_type = parseType(&mut tree, source, &mut cursor, tokens, 0)
                let end_p = astTypeEnd(&tree, p_type, pTok.end)
                astAddParam(&mut tree, pTok.start, pTok.end, p_type, pTok.start, end_p)
                param_count += 1
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

        var ret_type = -1
        if parserTakeSymbol(source, &mut cursor, tokens, "->") {
            ret_type = parseType(&mut tree, source, &mut cursor, tokens, 0)
        }

        parserSkipNewlines(&mut cursor, tokens)
        var body_stmt = -1
        if parserTakeSymbol(source, &mut cursor, tokens, "=") {
            parserSkipNewlines(&mut cursor, tokens)
            let retExpr = parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, 0)
            let ret_end = astExprEnd(&tree, retExpr, nameTok.end)
            let s_ret = astAddStmt(&mut tree, AstStmtKind.Return, nameTok.start, ret_end, retExpr, 0, 0, 0, 0)
            let extra_b = astAddExtra(&mut tree, s_ret)
            body_stmt = astAddStmt(&mut tree, AstStmtKind.Block, nameTok.start, ret_end, extra_b, 1, 0, 0, 0)
        } else {
            body_stmt = parseBlock(&mut tree, source, &mut cursor, tokens, 0)
        }

        let end_pos = astStmtEnd(&tree, body_stmt, nameTok.end)
        let async_flag = selectInt(is_async, 1, 0)
        return astAddDecl(&mut tree, AstDeclKind.Function, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, async_flag, first_param, param_count, ret_type, body_stmt)
    }

    let tok_start = cursorSpanStart(cursor, tokens, source.byteLength)
    let tok_end = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(&mut tree, ParseProblem.ExpectedDeclaration, "", tok_start, tok_end)
    return -1
}
