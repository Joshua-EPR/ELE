take lexer
take tokens
take cursor
take ast
take parse_util
take expr
take types
take stmt
take decl

// Stage 0 allows a borrowed enum to be inspected through a reference
// parameter, but does not allow taking a fresh borrow as a match scrutinee.
// Encode only the three token categories needed for error recovery.
flow parserRecoveryKind(kind: view LexKind) => Int {
    choose kind {
        LexKind.Eof : { give 0 }
        LexKind.Symbol : { give 1 }
        LexKind.Word : { give 2 }
        _ : { give 3 }
    }
}

flow parserSynchronize(source: view Text, cursor: edit TokenCursor, tokens: view List of[LexToken]) {
    cursor.pos += 1
    during cursor.pos < tokens.length {
        hold tok = view tokens[cursor.pos]
        hold kind = parserRecoveryKind(view tok.kind)
        when kind == 0 { give }
        when kind == 1 {
            hold len = tok.end - tok.start
            when len == 1 {
                hold b = source@byteAt(tok.start)
                when b == 59 || b == 125 {
                    cursor.pos += 1
                    give
                }
            }
        }
        when kind == 2 {
            when parserIsWord(source, tok, "fn") || parserIsWord(source, tok, "let") || parserIsWord(source, tok, "var") || parserIsWord(source, tok, "struct") || parserIsWord(source, tok, "enum") || parserIsWord(source, tok, "const") || parserIsWord(source, tok, "import") {
                give
            }
        }
        cursor.pos += 1
    }
}

expose flow parseProgram(tree: edit AstTree, source: view Text, tokens: view List of[LexToken], fileId: Int) => Bool {
    change cursor = cursorNew(fileId)
    parserSkipSeparators(source, edit cursor, tokens)

    during !cursorIsAtEnd(view cursor, tokens) {
        hold before_pos = cursor.pos
        hold d = parseDecl(edit tree, source, edit cursor, tokens)
        when d < 0 {
            parserSynchronize(source, edit cursor, tokens)
            when cursor.pos == before_pos && cursor.pos < tokens.length {
                cursor.pos += 1
            }
        }
        parserSkipSeparators(source, edit cursor, tokens)
    }

    give tree.errors.length == 0
}
