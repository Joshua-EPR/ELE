import lexer
import tokens
import cursor
import ast
import parse_util
import expr
import types
import stmt
import decl

fn parserSynchronize(source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) {
    cursor.pos += 1
    while cursor.pos < tokens.length {
        let tok = &tokens[cursor.pos]
        match tok.kind {
            LexKind.Eof => { return }
            LexKind.Symbol => {
                let len = tok.end - tok.start
                if len == 1 {
                    let b = source.byteAt(tok.start)
                    if b == 59 || b == 125 {
                        cursor.pos += 1
                        return
                    }
                }
            }
            LexKind.Word => {
                if parserIsWord(source, tok, "fn") || parserIsWord(source, tok, "let") || parserIsWord(source, tok, "var") || parserIsWord(source, tok, "struct") || parserIsWord(source, tok, "enum") || parserIsWord(source, tok, "const") || parserIsWord(source, tok, "import") {
                    return
                }
            }
            _ => {}
        }
        cursor.pos += 1
    }
}

fn parseProgram(tree: &mut AstTree, source: &Text, tokens: &List<LexToken>, fileId: Int) -> Bool {
    var cursor = cursorNew(fileId)
    parserSkipSeparators(source, &mut cursor, tokens)

    while !cursorIsAtEnd(&cursor, tokens) {
        let before_pos = cursor.pos
        let d = parseDecl(&mut tree, source, &mut cursor, tokens)
        if d < 0 {
            parserSynchronize(source, &mut cursor, tokens)
            if cursor.pos == before_pos && cursor.pos < tokens.length {
                cursor.pos += 1
            }
        }
        parserSkipSeparators(source, &mut cursor, tokens)
    }

    return tree.errors.length == 0
}
