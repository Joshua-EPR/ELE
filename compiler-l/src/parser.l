import lexer
import tokens
import cursor
import ast
import parse_util
import expr
import types
import stmt
import decl

// Stage 0 allows a borrowed enum to be inspected through a reference
// parameter, but does not allow taking a fresh borrow as a match scrutinee.
// Encode only the three token categories needed for error recovery.
fn parserRecoveryKind(kind: &LexKind) -> Int {
    match kind {
        LexKind.Eof => { return 0 }
        LexKind.Symbol => { return 1 }
        LexKind.Word => { return 2 }
        _ => { return 3 }
    }
}

fn parserSynchronize(source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) {
    cursor.pos += 1
    while cursor.pos < tokens.length {
        let tok = &tokens[cursor.pos]
        let kind = parserRecoveryKind(&tok.kind)
        if kind == 0 { return }
        if kind == 1 {
            let len = tok.end - tok.start
            if len == 1 {
                let b = source.byteAt(tok.start)
                if b == 59 || b == 125 {
                    cursor.pos += 1
                    return
                }
            }
        }
        if kind == 2 {
            if parserIsWord(source, tok, "fn") || parserIsWord(source, tok, "let") || parserIsWord(source, tok, "var") || parserIsWord(source, tok, "struct") || parserIsWord(source, tok, "enum") || parserIsWord(source, tok, "const") || parserIsWord(source, tok, "import") {
                return
            }
        }
        cursor.pos += 1
    }
}

pub fn parseProgram(tree: &mut AstTree, source: &Text, tokens: &List<LexToken>, fileId: Int) -> Bool {
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
