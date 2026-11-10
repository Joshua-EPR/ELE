use project_l::{
    check, lexer,
    lir::{Instruction, ValueKind},
    parser,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
};

fn cli(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(args)
        .output()
        .expect("CLI")
}
fn test_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/phase2")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn const_parser_and_folded_lir() {
    let source = "const ANSWER: Int = BASE * 2\nconst BASE = 21\nfn main() { const next = ANSWER+1; print(next) }";
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.constants.len(), 2);
    assert!(matches!(ast.functions[0].body[0], parser::Stmt::Const(_)));
    let ir = check(source).unwrap();
    assert_eq!(
        ir.functions[ir.main].body.len(),
        1,
        "const emits no runtime binding"
    );
    let Instruction::Return(v) = &ir.functions[ir.main].body[0] else {
        panic!("tail return")
    };
    let ValueKind::Print(arg) = &v.kind else {
        panic!("print")
    };
    assert!(
        matches!(arg.kind, ValueKind::Int(43)),
        "operator already evaluated before backend"
    );
}

#[test]
fn constant_errors_are_compile_time_diagnostics() {
    for (source, cause) in [
        ("const X = 1/0\nfn main() {}", "panic en const"),
        ("const X = 1%0\nfn main() {}", "panic en const"),
        (
            "const X = 9223372036854775807+1\nfn main() {}",
            "panic en const",
        ),
        (
            "const X = -9223372036854775808 / -1\nfn main() {}",
            "panic en const",
        ),
        (
            "const X = -(-9223372036854775808)\nfn main() {}",
            "panic en const",
        ),
        ("const X = Y\nconst Y = X\nfn main() {}", "circular"),
        ("const X = MISSING\nfn main() {}", "no definido"),
        ("const X: Bool = 42\nfn main() {}", "incompatible"),
        ("const X = 1\nconst X = 2\nfn main() {}", "duplicado"),
        ("const f = 1\nfn f() {}\nfn main() {}", "duplicado"),
        ("fn main() { let x=21; const y=x*2 }", "expresión constante"),
        (
            "fn f(x:Int) { const X=x }\nfn main() {}",
            "expresión constante",
        ),
        ("fn f() -> Int = 1\nconst X=f()\nfn main() {}", "llamadas"),
        ("fn main() { const X=print(1) }", "llamadas"),
        ("fn main() { const X=1; X=2 }", "inmutable"),
        ("const X=1\nfn main() { X=2 }", "inmutable"),
        ("fn main() { const X=1; const X=2 }", "duplicado"),
        (
            "fn main() { let x=2; const X=false && x==1 }",
            "expresión constante",
        ),
    ] {
        let e = check(source).expect_err(source);
        assert!(e.message.contains(cause), "{source}: {e:?}");
        assert!(e.span.line > 0 && e.span.column > 0);
    }
}

#[test]
fn text_move_and_type_errors() {
    for (source, cause) in [
        (
            "fn main() { let a=\"a\"; let b=a; print(a) }",
            "después de moverlo",
        ),
        (
            "fn take(x:Text) {}\nfn main() { let a=\"a\"; take(a); take(a) }",
            "después de moverlo",
        ),
        (
            "fn pair(a:Text,b:Text) {}\nfn main() { let a=\"a\"; pair(a,a) }",
            "después de moverlo",
        ),
        (
            "fn main() { let a=\"a\"; if true { let b=a }; print(a) }",
            "alguna rama",
        ),
        (
            "fn main() { let a=\"a\"; loop { let b=a; break } }",
            "dentro de bucle",
        ),
        (
            "fn take(x:Text) -> Bool = true\nfn main() { let a=\"a\"; while take(a) {} }",
            "dentro de bucle",
        ),
        ("fn main() { let a=\"a\"; a=\"b\" }", "inmutable"),
        ("fn main() { let a: Int=\"a\" }", "incompatible"),
        ("fn f(x:Bool) {}\nfn main() { f(\"a\") }", "incompatible"),
        ("fn f() -> Text = 1\nfn main() {}", "incompatible"),
        ("fn main() { print(\"a\"+\"b\") }", "operadores sobre Text"),
        ("fn main() { print(\"hola {nombre}\") }", "no definido"),
        ("fn f() {}\nfn main() { let f=1; f() }", "no invocable"),
        ("fn main() { let print=1; print(2) }", "no invocable"),
        ("fn f(x:Int,x:Int) {}\nfn main() {}", "duplicado"),
        ("fn main() { print(9223372036854775808) }", "fuera de rango"),
    ] {
        let e = check(source).expect_err(source);
        assert!(e.message.contains(cause), "{source}: {e:?}");
    }
}

#[test]
fn utf8_escapes_and_diagnostic_classes() {
    let tokens = lexer::lex(r#""José 🚀 \u{1F680} {{x}}\n\t\r\"\\""#).unwrap();
    assert!(matches!(&tokens[0].kind, lexer::Kind::Text(s) if s == "José 🚀 🚀 {x}\n\t\r\"\\"));
    for bad in [
        r#""\u{D800}""#,
        r#""\u{110000}""#,
        r#""\u{}""#,
        r#""\q""#,
        r#""}""#,
    ] {
        assert_eq!(lexer::lex(bad).unwrap_err().code, "L0002");
    }
    assert_eq!(check("fn main( {}").unwrap_err().code, "L0003");
    assert_eq!(
        check("fn main() { let x:Bool=1 }").unwrap_err().code,
        "L0001"
    );
    assert_eq!(
        check("const X=1/0\nfn main() {}").unwrap_err().code,
        "L0004"
    );
    assert_eq!(
        check("fn main() { let a=\"a\"; let b=a; print(a) }")
            .unwrap_err()
            .code,
        "L0005"
    );
}

#[test]
fn phase2_native_programs_stdout_stderr_and_exit() {
    let dir = test_dir("native");
    for (name, source, expected) in [
        (
            "constants",
            include_str!("../../../examples/constants.l"),
            "42\n43\ntrue\n",
        ),
        (
            "text",
            include_str!("../../../examples/text.l"),
            "Hola, José 👋\nHola, José 👋\nHola, José 👋\nUnicode: 🚀; llaves: {L}\n",
        ),
        (
            "hola_original",
            include_str!("../../../ejemplos/hola.l"),
            "Hola desde L\n",
        ),
        (
            "const_short",
            "const X=false && (1/0==0)\nconst Y=true || (1/0==0)\nfn main() { print(X); print(Y) }",
            "false\ntrue\n",
        ),
        (
            "const_shadow",
            "const X=1\nfn main() { const X=2; { const X=3; print(X) }; print(X) }",
            "3\n2\n",
        ),
        (
            "const_float",
            "const X:Float=1.0/0.0\nconst Y=0.0/0.0\nfn main() { print(X); print(Y) }",
            "inf\nNaN\n",
        ),
        (
            "text_reinit",
            "fn main() { var a=\"uno\"; let b=a; a=\"dos\"; print(a); print(b) }",
            "dos\nuno\n",
        ),
        (
            "text_loop",
            "fn main() { let a=\"a\"; var i=0; while i<2 { let b=\"b\"; let c=b; print(a); print(c); i+=1 } }",
            "a\nb\na\nb\n",
        ),
        (
            "text_branches",
            "fn f(x:Bool) -> Text { if x { \"sí\" } else { \"no\" } }\nfn main() { print(f(true)); print(f(false)) }",
            "sí\nno\n",
        ),
        (
            "limits",
            "const MIN:Int=-9223372036854775808\nfn main() { print(MIN); print(9223372036854775807) }",
            "-9223372036854775808\n9223372036854775807\n",
        ),
    ] {
        let file = format!("{name}.l");
        fs::write(dir.join(&file), source).unwrap();
        let out = cli(&dir, &["run", &file]);
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
}

#[test]
fn invalid_cli_is_rejected_without_backend() {
    let dir = test_dir("invalid");
    for (source, category) in [
        ("const X=1/0\nfn main() {}", "[const]"),
        (
            "fn main() { let a=\"a\"; let b=a; print(a) }",
            "[ownership]",
        ),
        ("fn main() { let x: Bool=1 }", "[semántica]"),
        ("fn main() { print(\"\\q\") }", "[léxico]"),
        ("fn main() { let = 1 }", "[sintaxis]"),
    ] {
        fs::write(dir.join("bad.l"), source).unwrap();
        for command in ["check", "build", "run"] {
            let out = Command::new(env!("CARGO_BIN_EXE_l"))
                .current_dir(&dir)
                .env("PATH", "")
                .args([command, "bad.l"])
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(1));
            assert!(out.stdout.is_empty());
            let stderr = String::from_utf8_lossy(&out.stderr);
            assert!(
                stderr.contains("bad.l:1:") && stderr.contains(category),
                "{stderr}"
            );
            assert!(!stderr.contains("panicked"));
        }
    }
    assert!(!dir.join("target").exists());
}

#[test]
fn built_executable_runs_without_rustc_or_sources() {
    let dir = test_dir("standalone");
    let source = dir.join("standalone.l");
    fs::write(&source, "fn main() { print(\"nativo\") }").unwrap();
    let out = cli(&dir, &["build", "standalone.l"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stderr.is_empty());
    let stdout = String::from_utf8(out.stdout).unwrap();
    let exe = dir.join(stdout.trim().strip_prefix("Build: ").unwrap());
    if cfg!(windows) {
        let binary = fs::read(&exe).unwrap();
        assert_eq!(&binary[..2], b"MZ");
        let offset = u32::from_le_bytes(binary[0x3c..0x40].try_into().unwrap()) as usize;
        assert_eq!(&binary[offset..offset + 4], b"PE\0\0");
    }
    fs::remove_file(source).unwrap();
    fs::remove_file(exe.with_extension("l.rs")).unwrap();
    let run = Command::new(exe).env("PATH", "").output().unwrap();
    assert_eq!(run.status.code(), Some(0));
    assert!(run.stderr.is_empty());
    assert_eq!(
        String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n"),
        "nativo\n"
    );
}

#[test]
fn checked_integer_runtime_failures() {
    let dir = test_dir("runtime_errors");
    for (name, expression) in [
        ("add", "9223372036854775807 + 1"),
        ("subtract", "-9223372036854775808 - 1"),
        ("multiply", "9223372036854775807 * 2"),
        ("divide", "1 / 0"),
        ("remainder", "1 % 0"),
        ("min_divide", "-9223372036854775808 / -1"),
        ("negation", "-(-9223372036854775808)"),
    ] {
        let file = format!("{name}.l");
        fs::write(
            dir.join(&file),
            format!("fn main() {{ print({expression}) }}"),
        )
        .unwrap();
        let out = cli(&dir, &["run", &file]);
        assert!(!out.status.success(), "{name}");
        assert!(out.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.starts_with("ELE 1:") && stderr.contains("overflow entero"),
            "{name}: {stderr}"
        );
        assert!(!stderr.contains("falló compilación"), "{name}: {stderr}");
    }
}
