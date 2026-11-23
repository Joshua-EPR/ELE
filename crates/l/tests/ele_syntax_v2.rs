//! Canonical ELE syntax is distinct from Rust while preserving the existing
//! semantic AST, ownership verification and LIR during the bootstrap migration.
use project_l::{check, lexer, parser};

#[test]
fn original_keywords_are_semantically_checked() {
    let source = include_str!("../../../examples/ele_original_syntax.l");
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.enums.len(), 1);
    assert_eq!(ast.functions.len(), 2);
    check(source).unwrap();
}

#[test]
fn shape_extend_and_receiver_at_method_respect_existing_ownership() {
    let source = r#"
shape Counter {
    value: Int
}
extend Counter {
    exclusive flow add(amount: Int) => Int {
        this.value += amount
        give this.value
    }
    direct flow start() => Self {
        give Counter(value: 0)
    }
}
flow main() => Int {
    change counter = Counter@start()
    hold result = counter@add(42)
    give result
}
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.structs.len(), 1);
    assert_eq!(ast.impls.len(), 1);
    assert_eq!(ast.impls[0].methods.len(), 2);
    let parser::Stmt::Let(_, _, _, call) = &ast.functions[0].body[1] else {
        panic!("method result must remain a typed binding")
    };
    assert!(matches!(
        &call.kind,
        parser::ExprKind::MethodCall(_, name, _) if name == "add"
    ));
    check(source).unwrap();
}

#[test]
fn view_and_edit_are_explicit_borrow_syntax() {
    check(
        r#"
flow value_of(value: view Int) => Int {
    give 42
}
flow main() => Int {
    hold n = 1
    give value_of(view n)
}
"#,
    )
    .unwrap();
}

#[test]
fn at_field_without_call_is_not_an_implicit_field_access() {
    let source = "shape Box { x: Int }\nflow main() { hold x = Box(x: 1)\n x@x }";
    let error = parser::parse(lexer::lex(source).unwrap()).unwrap_err();
    assert!(error.message.contains("@método"), "{error:?}");
}

#[test]
fn view_edit_source_has_distinct_borrow_modes() {
    let source = include_str!("../../../examples/ele_borrow_syntax.l");
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.functions.len(), 3);
    check(source).unwrap();
}

#[test]
fn legacy_spelling_is_temporarily_parseable() {
    check("fn main() -> Int { let n = 42\n return n }").unwrap();
}

#[test]
fn migrated_text_build_benchmark_uses_canonical_v2_syntax() {
    check(include_str!("../../../bench/programs/text_build.l")).unwrap();
}
