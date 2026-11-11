//! ELE v2 generics: explicit `of[T]` never shares syntax with comparisons
//! or indexing. Historic angle brackets remain bootstrap compatibility only.
use project_l::{check, lexer, parser};

#[test]
fn generic_flow_uses_of_brackets_without_legacy_angle_tokens() {
    let source = r#"
flow identity of[T](value: T) => T = value

flow main() => Int {
    hold n = identity of[Int](42)
    give n
}
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.functions[0].type_params.len(), 1);
    let parser::Stmt::Let(_, _, _, expr) = &ast.functions[1].body[0] else {
        panic!("expected explicit generic call binding");
    };
    assert!(matches!(
        &expr.kind,
        parser::ExprKind::GenericCall(name, args, _)
            if name == "identity" && args.len() == 1
    ));
    check(source).unwrap();
}

#[test]
fn shape_generic_fields_and_extended_methods_share_type_parameters() {
    let source = r#"
shape Cell of[T] {
    item: T
}
extend of[T] Cell of[T] {
    flow read() => T = this.item
    exclusive flow set(value: T) {
        this.item = value
    }
}
flow main() => Int {
    change cell = Cell(item: 1)
    cell@set(42)
    give cell@read()
}
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.structs[0].params.len(), 1);
    assert_eq!(ast.impls[0].params.len(), 1);
    assert_eq!(ast.impls[0].target_args.len(), 1);
    check(source).unwrap();
}

#[test]
fn contract_implementation_uses_extend_on_instead_of_impl_for() {
    let source = r#"
contract Readable {
    flow code() => Int
}
shape Message { code: Int }
extend Readable on Message {
    flow code() => Int = this.code
}
flow extract of[T: Readable](item: T) => Int {
    give item@code()
}
flow main() => Int {
    hold message = Message(code: 42)
    give extract(message)
}
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.impls[0].trait_name.as_deref(), Some("Readable"));
    assert_eq!(
        ast.functions[0].type_params[0].bound.as_deref(),
        Some("Readable")
    );
    check(source).unwrap();
}

#[test]
fn choice_type_application_and_nested_of_brackets_keep_types_nominal() {
    let source = r#"
choice Slot of[T] {
    Empty,
    Full(T)
}
shape Holder of[T] {
    entry: T
}
flow main() => Int {
    hold slot: Slot of[Int] = Slot@Full(42)
    hold holder: Holder of[Slot of[Int]] = Holder(entry: slot)
    choose holder.entry {
        Slot.Empty: { give 0 },
        Slot.Full(value): { give value },
    }
    give 1
}
"#;
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.enums[0].params, vec!["T"]);
    assert_eq!(ast.structs[0].params.len(), 1);
    check(source).unwrap();
}

#[test]
fn old_angle_generics_remain_available_for_bootstrap() {
    check("fn identity<T>(value: T) -> T = value\nfn main() -> Int { return identity<Int>(42) }")
        .unwrap();
}

#[test]
fn ordinary_comparisons_and_identifiers_named_of_are_not_generic_calls() {
    check(
        r#"
flow main() => Int {
    hold of = 4
    when of < 10 {
        give of
    }
    give 0
}
"#,
    )
    .unwrap();
}

#[test]
fn malformed_generic_call_does_not_silently_become_indexing() {
    let src = "flow main() => Int { hold n = identity of[Int]\n give 0 }";
    assert!(parser::parse(lexer::lex(src).unwrap()).is_err());
}
