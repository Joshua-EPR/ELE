use project_l::{check, lexer, parser};
use std::{fs, path::PathBuf, process::Command};

#[test]
fn required_negative_diagnostics() {
    for (source, cause) in [
        ("fn main() { let x = 1; x = 2 }", "inmutable"),
        ("fn main() { print(noExiste) }", "no definido"),
        ("fn main() { if 10 { print(1) } }", "Bool"),
        (
            "fn f(x: Bool) -> Int { return x }\nfn main() {}",
            "incompatible",
        ),
        ("fn main() { let x = 1; let x = 2 }", "duplicado"),
        ("fn main() { let x = 1 + true }", "incompatible"),
        ("fn f(x: Int) {}\nfn main() { f() }", "argumentos"),
        (
            "fn f() -> Int { if true { return 1 } }\nfn main() {}",
            "falta retorno",
        ),
        ("fn main() { let x: Int = \"hola\" }", "incompatible"),
        ("trait X {}", "falta fn main"),
        ("fn main() { let fn = 1 }", "reservada"),
        ("fn main() { let x = 1 < 2 < 3 }", "encadenadas"),
        ("fn main() { let x = 1.0 + 2 }", "incompatible"),
        (
            "fn main() { if true { let x = 1 }; print(x) }",
            "no definido",
        ),
        ("fn f(x: Int) { x = 3 }\nfn main() {}", "inmutable"),
    ] {
        let error = check(source).expect_err(source);
        assert!(error.message.contains(cause), "{error:?}");
        assert!(error.span.line > 0 && error.span.column > 0);
    }
}

#[test]
fn comments_multiline_and_spans() {
    let source =
        "/* outer /* inner */ */\nfn main() {\n let x = (1\n + 2 *\n 3)\n print(x) // comment\n}";
    check(source).expect("multiline");
    let err = check("fn main() {\n  print(missing)\n}").expect_err("unknown");
    assert_eq!((err.span.line, err.span.column), (2, 9));
    assert!(lexer::lex("/* unterminated").is_err());
    assert!(lexer::lex("\"unterminated").is_err());
    let tokens = lexer::lex("\"hello\\nworld\"").expect("string token");
    assert!(matches!(&tokens[0].kind, lexer::Kind::Text(s) if s == "hello\nworld"));
}

#[test]
fn loop_control_and_block_diagnostics() {
    for (source, cause) in [
        ("fn main() { break }", "fuera de un bucle"),
        ("fn main() { continue }", "fuera de un bucle"),
        (
            "fn f() { break }\nfn main() { loop { f(); break } }",
            "fuera de un bucle",
        ),
        ("fn main() { loop { break 42 } }", "con valor"),
        ("fn main() { while true { continue 42 } }", "con valor"),
        ("fn main() { { let x = 1 }; print(x) }", "no definido"),
        ("fn main() { let x = 1; { x = 2 } }", "inmutable"),
        (
            "fn main() { loop { let x = 1; break }; print(x) }",
            "no definido",
        ),
        ("fn main() { if false {} else if 3 {} }", "Bool"),
        (
            "fn f() -> Int { if true { 1 } else { 2 }; }\nfn main() {}",
            "falta retorno",
        ),
        ("fn f() -> Int { { 1 }; }\nfn main() {}", "falta retorno"),
    ] {
        let error = check(source).expect_err(source);
        assert!(error.message.contains(cause), "{error:?}");
    }
    let err = check("fn main() {\n    break\n}").expect_err("illegal break");
    assert_eq!((err.span.line, err.span.column), (2, 5));
    let deep = format!("fn main() {{ {}{{}} }}", "if false {} else ".repeat(150));
    assert!(check(&deep).is_err());
}

#[test]
fn pratt_precedence() {
    let ast = parser::parse(lexer::lex("fn main() { print(1 + 2 * 3) }").unwrap()).unwrap();
    let parser::Stmt::Expr(e, _) = &ast.functions[0].body[0] else {
        panic!("expression expected")
    };
    let parser::ExprKind::Call(_, args) = &e.kind else {
        panic!("call expected")
    };
    let parser::ExprKind::Binary(op, _, rhs) = &args[0].kind else {
        panic!("addition expected")
    };
    assert_eq!(op, "+");
    assert!(matches!(&rhs.kind, parser::ExprKind::Binary(op, _, _) if op == "*"));
}

#[test]
fn malformed_inputs_do_not_panic() {
    let alphabet = b"fn main() {}\n;let var=+-*/!0123\"abc";
    let mut seed = 731u64;
    for _ in 0..1000 {
        let mut source = String::from("fn main() { ");
        for _ in 0..48 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            source.push(alphabet[(seed >> 32) as usize % alphabet.len()] as char);
        }
        source.push('}');
        let _ = check(&source);
    }
    let deep = format!(
        "fn main() {{ print({}1{}) }}",
        "(".repeat(200),
        ")".repeat(200)
    );
    assert!(check(&deep).is_err());
    let long = format!("fn main() {{ print(1{}) }}", "+1".repeat(5000));
    assert!(check(&long).is_err());
}

fn cli(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(args)
        .output()
        .expect("CLI executable")
}

#[test]
fn native_acceptance_and_failure_paths() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/conformance");
    fs::create_dir_all(&dir).unwrap();
    for (name, source, expected) in [
        (
            "arithmetic",
            include_str!("../../../examples/arithmetic.l"),
            "42\n",
        ),
        (
            "control",
            include_str!("../../../examples/control_flow.l"),
            "15\n",
        ),
        ("precedence", "fn main() { print(1 + 2 * 3) }", "7\n"),
        (
            "bool",
            "fn main() { print(false && (1 / 0 == 0)); print(true || (1 / 0 == 0)) }",
            "false\ntrue\n",
        ),
        (
            "float",
            "fn main() { print(1.5 * 2.0); print(1.0 / 0.0) }",
            "3\ninf\n",
        ),
        (
            "scope",
            "fn main() { let x = 1; if true { let x = 2; print(x) }; print(x) }",
            "2\n1\n",
        ),
        (
            "recursive",
            "fn fact(x: Int) -> Int { if x <= 1 { return 1 } else { return x * fact(x - 1) } }\nfn main() { print(fact(5)) }",
            "120\n",
        ),
        (
            "order",
            "fn f(x: Int) -> Int { print(x); return x }\nfn add(a: Int, b: Int) -> Int = a+b\nfn main() { print(add(f(1), f(2))) }",
            "1\n2\n3\n",
        ),
        ("loops", include_str!("../../../examples/loops.l"), "12\n"),
        (
            "nested_loops",
            "fn main() { var n=0; var i=0; while i < 3 { i += 1; loop { n += 1; break }; if i == 2 { continue }; n += 10 }; print(n) }",
            "23\n",
        ),
        (
            "else_if",
            "fn choose(x: Int) -> Int { if x == 1 { 10 } else if x == 2 { 20 } else { 30 } }\nfn main() { print(choose(1)); print(choose(2)); print(choose(3)) }",
            "10\n20\n30\n",
        ),
        (
            "block_scope",
            "fn f() -> Int { { 42 } }\nfn main() { var x=1; { let x=2; print(x) }; { x += 2 }; print(x); print(f()) }",
            "2\n3\n42\n",
        ),
        (
            "discarded_if",
            "fn main() { if true { 1 } else { 2 }; }",
            "",
        ),
        (
            "return_from_loop",
            "fn f() -> Int { loop { return 42 }; return 0 }\nfn main() { print(f()) }",
            "42\n",
        ),
    ] {
        let file = format!("{name}.l");
        fs::write(dir.join(&file), source).unwrap();
        let output = cli(&dir, &["run", &file]);
        assert!(
            output.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            output.stderr.is_empty(),
            "{name}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).replace("\r\n", "\n"),
            expected,
            "{name}"
        );
    }
    for (name, source) in [
        (
            "overflow",
            "fn main() { var x = 9223372036854775807; x += 1; print(x) }",
        ),
        ("divide", "fn main() { var x = 0; print(1 / x) }"),
    ] {
        let file = format!("{name}.l");
        fs::write(dir.join(&file), source).unwrap();
        let output = cli(&dir, &["run", &file]);
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("overflow entero o división"));
    }
    fs::write(dir.join("bad.l"), "fn main() { let x=1; x=2 }").unwrap();
    for command in ["check", "build", "run"] {
        let output = cli(&dir, &[command, "bad.l"]);
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("bad.l:1:"));
    }
    // Checking remains available without any backend executable on PATH.
    let output = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .env("PATH", "")
        .args(["check", "arithmetic.l"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let output = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .env("PATH", "")
        .args(["build", "arithmetic.l"])
        .output()
        .unwrap();
    assert!(!output.status.success());
}
