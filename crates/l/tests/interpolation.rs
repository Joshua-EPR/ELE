use project_l::{
    check, lexer,
    lir::{Instruction, ValueKind},
    parser,
};
use std::{fs, path::PathBuf, process::Command};

#[test]
fn parser_uses_normal_pratt_inside_text() {
    let ast =
        parser::parse(lexer::lex(r#"fn main() { let s = "v={1 + 2 * 3}" }"#).unwrap()).unwrap();
    let parser::Stmt::Let(_, _, _, e) = &ast.functions[0].body[0] else {
        panic!("let")
    };
    let parser::ExprKind::Interpolate(parts) = &e.kind else {
        panic!("interpolation")
    };
    let parser::ExprKind::Binary(op, _, rhs) = &parts[1].kind else {
        panic!("sum")
    };
    assert_eq!(op, "+");
    assert!(matches!(&rhs.kind, parser::ExprKind::Binary(op, _, _) if op == "*"));
}

#[test]
fn constants_fold_but_effectful_calls_remain_in_lir() {
    let ir = check(
        r#"const S = "v={N * 2}, {true}, {1.5}"
const N = 21
fn main() { let s = S; print(s) }"#,
    )
    .unwrap();
    let Instruction::Bind(_, _, v) = &ir.functions[ir.main].body[0] else {
        panic!("binding")
    };
    assert!(matches!(&v.kind, ValueKind::Text(s) if s == "v=42, true, 1.5"));
    let ir = check(
        r#"fn f() -> Int { print(1); return 2 }
fn main() { let s = "{f()}"; print(s) }"#,
    )
    .unwrap();
    let Instruction::Bind(_, _, v) = &ir.functions[ir.main].body[0] else {
        panic!("binding")
    };
    assert!(
        matches!(&v.kind, ValueKind::Interpolate(parts) if parts.iter().any(|p| matches!(p.kind, ValueKind::Call(_, _))))
    );
    assert!(
        check("const A=\"{B}\"\nconst B=\"{A}\"\nfn main() {}")
            .unwrap_err()
            .message
            .contains("circular")
    );
    let mut source = String::from("const C0=\"abcd\"\n");
    for i in 1..21 {
        source.push_str(&format!("const C{i}=\"{{C{}}}{{C{}}}\"\n", i - 1, i - 1));
    }
    source.push_str("fn main() {}");
    assert!(check(&source).unwrap_err().message.contains("1 MiB"));
}

#[test]
fn invalid_interpolations_have_source_locations() {
    for (source, category, cause) in [
        (
            r#"fn main() { print("x={unknown}") }"#,
            "semántica",
            "no definido",
        ),
        (r#"fn main() { print("x={}") }"#, "sintaxis", "expresión"),
        (r#"fn main() { print("x={1 +}") }"#, "sintaxis", "expresión"),
        (
            r#"fn main() { print("x={1 2}") }"#,
            "sintaxis",
            "se esperaba '}'",
        ),
        (
            r#"fn main() { print("x={1; 2}") }"#,
            "sintaxis",
            "se esperaba '}'",
        ),
        (
            r#"fn main() { print("x={1 + true}") }"#,
            "semántica",
            "incompatible",
        ),
        (
            r#"fn main() { print("x={()}") }"#,
            "semántica",
            "no convertible",
        ),
        (
            r#"fn f() {} fn main() { print("x={f()}") }"#,
            "semántica",
            "no convertible",
        ),
        (
            r#"fn main() { print("x={print(1)}") }"#,
            "semántica",
            "no convertible",
        ),
        (r#"fn main() { print("x={1"#, "léxico", "sin cerrar"),
        (r#"fn main() { print("x=}") }"#, "léxico", "sin apertura"),
        (
            r#"fn main() { let a="a"; let b=a; print("{a}") }"#,
            "ownership",
            "después de moverlo",
        ),
        (
            r#"fn take(a:Text)->Text=a
fn main() { let a="a"; print("{take(a)} {a}") }"#,
            "ownership",
            "después de moverlo",
        ),
        (
            r#"fn main() { let a=1; print("{a.field}") }"#,
            "semántica",
            "sobre tipo no struct Int",
        ),
    ] {
        let e = check(source).expect_err(source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
        assert!(e.span.line > 0 && e.span.column > 0);
    }
    let e = check("fn main() {\n    print(\"Valor: {missing}\")\n}").unwrap_err();
    assert_eq!((e.span.line, e.span.column), (2, 20));
    let e = check("fn main() {\n    print(\"á🚀 {missing}\")\n}").unwrap_err();
    assert_eq!((e.span.line, e.span.column), (2, 16));
    let e = check("fn main() { print(\"value={\n missing}\") }").unwrap_err();
    assert_eq!((e.span.line, e.span.column), (2, 2));
}

#[test]
fn malformed_nested_text_does_not_crash() {
    let mut source = "1".to_string();
    for _ in 0..80 {
        source = format!("\"{{{source}}}\"");
    }
    assert!(
        check(&format!("fn main() {{ print({source}) }}"))
            .unwrap_err()
            .message
            .contains("anidamiento")
    );
    let alphabet = ['{', '}', '"', '\\', '(', ')', '/', '*', '\n', '0', 'a', 'é'];
    let mut seed = 21u64;
    for _ in 0..1500 {
        let mut source = String::from("fn main() { print(\"");
        for _ in 0..48 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            source.push(alphabet[(seed >> 32) as usize % alphabet.len()]);
        }
        source.push_str("\") }");
        let _ = check(&source);
    }
}

#[test]
fn native_interpolation_is_a_text_value_and_evaluates_once() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/interpolation");
    fs::create_dir_all(&dir).unwrap();
    for (name, source, expected) in [
        (
            "fibonacci",
            include_str!("../../../examples/fibonacci.l"),
            "Fibonacci: 55\n",
        ),
        (
            "plain",
            r#"fn main() { print("Hola mundo"); print("Número: {42}"); print("Operación: {10 + 20}"); print("Llaves: {{valor}}") }"#,
            "Hola mundo\nNúmero: 42\nOperación: 30\nLlaves: {valor}\n",
        ),
        (
            "values",
            include_str!("../../../examples/interpolation.l"),
            "Hola Ana, edad: 25; doble: 50\nOperación: 30; llaves: {valor}; Bool: true\n",
        ),
        (
            "once",
            r#"fn mark(n:Int)->Int { print(n); return n }
fn main() { let text="{mark(1)}-{mark(2)}"; print(text) }"#,
            "1\n2\n1-2\n",
        ),
        (
            "borrow_then_move",
            r#"fn take(s:Text)->Text=s
fn main() { let a="Ana"; let s="{a} / {take(a)}"; print(s) }"#,
            "Ana / Ana\n",
        ),
        (
            "reuse",
            r#"fn wrap(s:Text)->Text="[{s}]"
fn main() { let name="Ana"; let result="Hola {name}"; print(name); print(wrap(result)) }"#,
            "Ana\n[Hola Ana]\n",
        ),
        (
            "nested",
            r#"fn identity(s:Text)->Text=s
fn main() { let x=7; print("{identity("cita: \"sí\"; {x}")}") }"#,
            "cita: \"sí\"; 7\n",
        ),
        (
            "escapes",
            r#"fn main() { let n=7; print("{{{n}}}; \u{7b}literal\u{7d}; 🚀\n{n}") }"#,
            "{7}; {literal}; 🚀\n7\n",
        ),
        (
            "comments",
            "fn main() { print(\"{1 /* } \\\" /* nested */ */ +\n2}\") }",
            "3\n",
        ),
        (
            "line_comment",
            "fn main() { print(\"{1 + // }\n2}\") }",
            "3\n",
        ),
        (
            "runtime_primitives",
            r#"fn main() { let a=true; let b=1.5; let n=-7; print("{a} {b} {n}") }"#,
            "true 1.5 -7\n",
        ),
        (
            "owned_loop",
            r#"fn main() { var i=0; while i<3 { let s="item {i}"; let t=s; print(t); i+=1 } }"#,
            "item 0\nitem 1\nitem 2\n",
        ),
        (
            "self_reassign",
            r#"fn main() { var s="a"; s="{s}b"; print(s) }"#,
            "ab\n",
        ),
    ] {
        let file = format!("{name}.l");
        fs::write(dir.join(&file), source).unwrap();
        let out = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["run", &file])
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(0),
            "{name}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            out.stderr.is_empty(),
            "{name}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
            expected,
            "{name}"
        );
    }
    for (name, source, runtime) in [
        ("runtime_panic", r#"fn main() { print("{1/0}") }"#, true),
        ("const_panic", "const S=\"{1/0}\"\nfn main() {}", false),
        (
            "bad",
            "fn main() {\n    print(\"Valor: {missing}\")\n}",
            false,
        ),
    ] {
        let file = format!("{name}.l");
        fs::write(dir.join(&file), source).unwrap();
        let out = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["run", &file])
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(out.stdout.is_empty());
        let err = String::from_utf8_lossy(&out.stderr);
        assert_eq!(err.starts_with("ELE "), runtime, "{err}");
        if name == "bad" {
            assert!(err.contains("bad.l:2:20: L0001"), "{err}");
        }
    }
}
