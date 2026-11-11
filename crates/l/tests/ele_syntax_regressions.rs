//! Guardrails: the canonical surface must not change legacy parser/type semantics.
use project_l::{check, lexer, parser};

#[test]
fn bootstrap_byte_length_in_a_range_has_integer_type() {
    let source = r#"
struct LineCol { line: Int, column: Int }
fn computeLineCol(source: &Text, start: Int, offset: Int) -> LineCol {
    var line = 1
    var column = 1
    for i in start..offset {
        if i < source.byteLength {
            let b = source.byteAt(i)
            if b == 10 {
                line += 1
                column = 1
            } else if b < 128 || b >= 192 {
                column += 1
            }
        }
    }
    return LineCol(line: line, column: column)
}
fn main() -> Int { return 0 }
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.structs.len(), 1);
    assert_eq!(ast.functions.len(), 2);
    check(source).unwrap();
}

#[test]
fn canonical_keyword_aliases_do_not_turn_old_fields_into_keywords() {
    check(r#"
struct State { flow: Int, change: Int, next: Int }
fn main() -> Int {
    let s = State(flow: 1, change: 2, next: 3)
    return s.flow + s.change + s.next
}
"#).unwrap();
}
