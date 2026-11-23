take lexer
take tokens
take cursor
take ast
take parse_util
take expr
take types
take stmt

expose flow parseDecl(tree: edit AstTree, source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken]) => Int {
    when cursor.pos >= tokens.length { give -1 }
    hold is_public = parserTakeWord(source, edit cursor, tokens, "pub")

    when parserTakeWord(source, edit cursor, tokens, "import") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold pathStartTok = view tokens[cursor.pos]
        cursor.pos += 1
        change path_end = pathStartTok.end
        during parserTakeSymbol(source, edit cursor, tokens, ".") {
            when cursor.pos < tokens.length {
                path_end = tokens[cursor.pos].end
                cursor.pos += 1
            }
        }
        parserTakeSymbol(source, edit cursor, tokens, ";")
        give astAddDecl(edit tree, AstDeclKind.Import, pathStartTok.start, path_end, is_public, pathStartTok.start, path_end, 0, 0, 0, 0, 0)
    }

    when parserAtWord(source, cursor, tokens, "const") {
        hold s_id = parseStmt(edit tree, source, edit cursor, tokens, 0)
        when s_id >= 0 {
            // End the immutable AST borrow before astAddDecl mutates the tree.
            hold start = tree.statements[s_id].start
            hold end = tree.statements[s_id].end
            hold a = tree.statements[s_id].a
            hold b = tree.statements[s_id].b
            hold c = tree.statements[s_id].c
            hold d = tree.statements[s_id].d
            give astAddDecl(edit tree, AstDeclKind.Const, start, end, is_public, a, b, c, d, 0, 0, 0)
        }
        give -1
    }

    when parserTakeWord(source, edit cursor, tokens, "struct") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(edit cursor, tokens)
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "{{")

        hold first_field = tree.fields.length
        change field_count = 0
        parserSkipSeparators(source, edit cursor, tokens)

        during !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            hold f_pub = parserTakeWord(source, edit cursor, tokens, "pub")
            when cursor.pos >= tokens.length { leave }
            hold fTok = view tokens[cursor.pos]
            cursor.pos += 1
            parserNeedSymbol(edit tree, source, edit cursor, tokens, ":")
            hold f_type = parseType(edit tree, source, edit cursor, tokens, 0)
            change f_default = -1
            when parserTakeSymbol(source, edit cursor, tokens, "=") {
                parserSkipNewlines(edit cursor, tokens)
                f_default = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, 0)
            }
            change end_p = fTok.end
            when f_default >= 0 {
                end_p = tree.expressions[f_default].end
            } otherwise when f_type >= 0 {
                end_p = tree.types[f_type].end
            }
            astAddField(edit tree, fTok.start, fTok.end, f_pub, f_type, f_default, fTok.start, end_p)
            field_count += 1
            parserTakeSymbol(source, edit cursor, tokens, ",")
            parserSkipSeparators(source, edit cursor, tokens)
        }

        parserNeedSymbol(edit tree, source, edit cursor, tokens, "}}")
        hold end_pos = cursorPrevEnd(cursor, tokens, nameTok.end)
        give astAddDecl(edit tree, AstDeclKind.Struct, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, first_field, field_count, 0, 0, 0)
    }

    when parserTakeWord(source, edit cursor, tokens, "enum") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        parserSkipNewlines(edit cursor, tokens)
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "{{")

        hold first_variant = tree.variants.length
        change variant_count = 0
        parserSkipSeparators(source, edit cursor, tokens)

        during !parserAtSymbol(source, cursor, tokens, "}}") && cursor.pos < tokens.length {
            when cursor.pos >= tokens.length { leave }
            hold vTok = view tokens[cursor.pos]
            cursor.pos += 1
            hold first_payload = tree.extra.length
            change payload_count = 0
            when parserTakeSymbol(source, edit cursor, tokens, "(") {
                parserSkipNewlines(edit cursor, tokens)
                when !parserTakeSymbol(source, edit cursor, tokens, ")") {
                    during cursor.pos < tokens.length {
                        hold p_ty = parseType(edit tree, source, edit cursor, tokens, 0)
                        when p_ty >= 0 {
                            astAddExtra(edit tree, p_ty)
                            payload_count += 1
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
            }
            hold end_p = cursorPrevEnd(cursor, tokens, vTok.end)
            astAddVariant(edit tree, vTok.start, vTok.end, first_payload, payload_count, vTok.start, end_p)
            variant_count += 1
            parserTakeSymbol(source, edit cursor, tokens, ",")
            parserSkipSeparators(source, edit cursor, tokens)
        }

        parserNeedSymbol(edit tree, source, edit cursor, tokens, "}}")
        hold end_pos = cursorPrevEnd(cursor, tokens, nameTok.end)
        give astAddDecl(edit tree, AstDeclKind.Enum, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, first_variant, variant_count, 0, 0, 0)
    }

    hold is_async = parserTakeWord(source, edit cursor, tokens, "async")
    when parserTakeWord(source, edit cursor, tokens, "fn") {
        when cursor.pos >= tokens.length {
            astAddError(edit tree, ParseProblem.ExpectedIdentifier, "", source.byteLength, source.byteLength)
            give -1
        }
        hold nameTok = view tokens[cursor.pos]
        cursor.pos += 1
        parserNeedSymbol(edit tree, source, edit cursor, tokens, "(")

        hold first_param = tree.params.length
        change param_count = 0
        parserSkipNewlines(edit cursor, tokens)

        when !parserTakeSymbol(source, edit cursor, tokens, ")") {
            during cursor.pos < tokens.length {
                when cursor.pos >= tokens.length { leave }
                hold pTok = view tokens[cursor.pos]
                cursor.pos += 1
                parserNeedSymbol(edit tree, source, edit cursor, tokens, ":")
                hold p_type = parseType(edit tree, source, edit cursor, tokens, 0)
                hold end_p = astTypeEnd(view tree, p_type, pTok.end)
                astAddParam(edit tree, pTok.start, pTok.end, p_type, pTok.start, end_p)
                param_count += 1
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

        change ret_type = -1
        when parserTakeSymbol(source, edit cursor, tokens, "->") {
            ret_type = parseType(edit tree, source, edit cursor, tokens, 0)
        }

        parserSkipNewlines(edit cursor, tokens)
        change body_stmt = -1
        when parserTakeSymbol(source, edit cursor, tokens, "=") {
            parserSkipNewlines(edit cursor, tokens)
            hold retExpr = parseExpr(edit tree, source, edit cursor, tokens, 0, 0, 0)
            hold ret_end = astExprEnd(view tree, retExpr, nameTok.end)
            hold s_ret = astAddStmt(edit tree, AstStmtKind.Return, nameTok.start, ret_end, retExpr, 0, 0, 0, 0)
            hold extra_b = astAddExtra(edit tree, s_ret)
            body_stmt = astAddStmt(edit tree, AstStmtKind.Block, nameTok.start, ret_end, extra_b, 1, 0, 0, 0)
        } otherwise {
            body_stmt = parseBlock(edit tree, source, edit cursor, tokens, 0)
        }

        hold end_pos = astStmtEnd(view tree, body_stmt, nameTok.end)
        hold async_flag = selectInt(is_async, 1, 0)
        give astAddDecl(edit tree, AstDeclKind.Function, nameTok.start, end_pos, is_public, nameTok.start, nameTok.end, async_flag, first_param, param_count, ret_type, body_stmt)
    }

    hold tok_start = cursorSpanStart(cursor, tokens, source.byteLength)
    hold tok_end = cursorSpanEnd(cursor, tokens, source.byteLength)
    astAddError(edit tree, ParseProblem.ExpectedDeclaration, "", tok_start, tok_end)
    give -1
}
