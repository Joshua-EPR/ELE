use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
};

const LEXER: &str = include_str!("../../../compiler-l/src/lexer.l");
const TOKENS: &str = include_str!("../../../compiler-l/src/tokens.l");
const CURSOR: &str = include_str!("../../../compiler-l/src/cursor.l");

fn execute(case: &str, source: &str, backend: &str, trace: bool) -> Output {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/self-hosting")
        .join(case)
        .join(backend);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("main.l"), source).unwrap();
    let mut build = Command::new(env!("CARGO_BIN_EXE_l"));
    build
        .current_dir(&dir)
        .args(["build", "main.l", "--backend", backend]);
    if trace {
        build.arg("--trace-alloc");
    }
    let output = build.output().unwrap();
    assert!(
        output.status.success(),
        "{backend}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    let exe = stdout
        .lines()
        .find_map(|s| s.strip_prefix("Build: "))
        .unwrap();
    let mut run = Command::new(dir.join(exe));
    if backend == "cranelift" {
        run.env("PATH", "");
    }
    run.output().unwrap()
}

fn check(case: &str, source: &str, expected: &str, allocations: Option<u64>) {
    for backend in ["cranelift", "rustc"] {
        let native = backend == "cranelift";
        let out = execute(case, source, backend, native);
        assert_eq!(out.status.code(), Some(0), "{backend}: {:?}", out.stderr);
        assert_eq!(out.stdout, expected.as_bytes(), "{backend}");
        if native {
            let stderr = String::from_utf8(out.stderr).unwrap();
            let count = |key: &str| -> u64 {
                stderr
                    .split_whitespace()
                    .find_map(|word| word.strip_prefix(key))
                    .unwrap()
                    .parse()
                    .unwrap()
            };
            assert_eq!(stderr.lines().count(), 1, "{stderr}");
            assert_eq!(count("heap_ok="), 1, "{stderr}");
            assert_eq!(count("allocs="), count("frees="), "{stderr}");
            if let Some(expected) = allocations {
                assert_eq!(count("allocs="), expected, "{stderr}");
            }
        } else {
            assert!(out.stderr.is_empty(), "{:?}", out.stderr);
        }
    }
}

#[test]
fn text_bytes_are_unsigned_utf8_and_do_not_consume_the_owner() {
    check(
        "bytes",
        r#"@noalloc
fn length(text: &Text) -> Int !{} = text.byteLength
@noalloc
fn first(text: &Text) -> Int !{panic} = text.byteAt(0)
struct Buffer { text: Text }
fn make(n: Int) -> Text {
    print("receptor")
    return "é{n}"
}
fn offset() -> Int { print("índice"); return 1 }
fn main() {
    let input = "Aé😀\u{0}"
    print(length(input))
    for i in 0..input.byteLength { print(input.byteAt(i)) }
    print(first(input))
    print("".byteLength)
    print(make(7).byteAt(offset()))
    let field = Buffer(text: "z")
    print(field.text.byteAt(0))
}"#,
        "8\n65\n195\n169\n240\n159\n152\n128\n0\n65\n0\nreceptor\níndice\n169\n122\n",
        Some(1),
    );
}

#[test]
fn byte_operations_preserve_type_ownership_and_effect_checks() {
    for (source, code) in [
        (r#"fn main() { print("abc".byteAt(true)) }"#, "L0001"),
        (r#"fn main() { print("abc".byteAt()) }"#, "L0001"),
        (r#"fn main() { print("abc".byteAt<Int>(0)) }"#, "L0001"),
        (r#"fn main() { print(42.byteLength) }"#, "L0001"),
        (
            r#"fn main() { var text = "abc"; text.byteLength = 1 }"#,
            "L0001",
        ),
        (
            r#"fn main() { let text = "abc"; let moved = text; print(text.byteAt(0)) }"#,
            "L0005",
        ),
        (
            r#"fn f(t: &Text) -> Int !{} = t.byteAt(0)
fn main() {}"#,
            "L0010",
        ),
        (
            r#"fn consume(t: Text) -> Int = t.byteLength
fn main() { let text = "abc"; print(text.byteAt(consume(text))) }"#,
            "L0012",
        ),
    ] {
        let err = project_l::check(source).expect_err(source);
        assert_eq!(err.code, code, "{source}: {err:?}");
        assert!(err.span.line > 0 && err.span.column > 0, "{err:?}");
    }
}

#[test]
fn negative_or_out_of_range_byte_index_reports_source_position() {
    for backend in ["cranelift", "rustc"] {
        for (case, expr) in [
            ("negative", r#""a".byteAt(-1)"#),
            ("past_end", r#""é".byteAt(2)"#),
            ("empty", r#""".byteAt(0)"#),
        ] {
            let out = execute(
                case,
                &format!("fn main() {{\n    print({expr})\n}}\n"),
                backend,
                false,
            );
            assert!(!out.status.success(), "{backend}: {case}");
            assert!(out.stdout.is_empty());
            let err = String::from_utf8(out.stderr).unwrap();
            assert!(
                err.starts_with("ELE 2:") && err.contains("índice fuera de rango"),
                "{backend}: {err}"
            );
        }
    }
}

const DUMP: &str = r#"
fn kindName(kind: &LexKind) -> Text {
    match kind {
        LexKind.Word => { return "word" }
        LexKind.Integer => { return "int" }
        LexKind.Symbol => { return "symbol" }
        LexKind.Newline => { return "newline" }
        LexKind.Eof => { return "eof" }
        LexKind.Text => { return "text" }
        LexKind.TextStart => { return "text_start" }
        LexKind.TextEnd => { return "text_end" }
        LexKind.InterpolationStart => { return "interp_start" }
        LexKind.InterpolationEnd => { return "interp_end" }
    }
}
fn problemName(kind: &LexProblem) -> Text {
    match kind {
        LexProblem.UnexpectedByte => { return "byte" }
        LexProblem.UnclosedComment => { return "comment" }
        LexProblem.UnsupportedNumber => { return "number" }
        LexProblem.UnclosedString => { return "string" }
        LexProblem.InvalidEscape => { return "escape" }
        LexProblem.InvalidUnicodeEscape => { return "escape_u" }
        LexProblem.InvalidUnicodeScalar => { return "scalar" }
        LexProblem.UnclosedInterpolation => { return "interp" }
        LexProblem.UnopenedBrace => { return "brace" }
        LexProblem.ExcessiveDepth => { return "depth" }
    }
}
fn dump(source: Text) {
    match lexSource(source) {
        Ok(tokens) => {
            for i in 0..tokens.length {
                let token = &tokens[i]
                let name = kindName(token.kind)
                let start = token.start
                let end = token.end
                print("{name}:{start}:{end}")
            }
        }
        Err(error) => {
            let name = problemName(error.problem)
            let at = error.offset
            print("{name}:{at}")
        }
    }
}
"#;

#[test]
fn lexer_in_l_reports_byte_ranges_and_errors() {
    let driver = r#"
fn main() {
    dump("")
    dump("fn a_2() {{ return 1_000 }} // café\r\n")
    dump("/* é\n/* 👋 */ */a..=b && c!=1")
    dump("abc $")
    dump("/* sin cerrar")
    dump("1.5")
    dump("é")
}
"#;
    check(
        "lexer",
        &format!("{LEXER}\n{DUMP}\n{driver}"),
        concat!(
            "eof:0:0\n",
            "word:0:2\nword:3:6\nsymbol:6:7\nsymbol:7:8\nsymbol:9:10\n",
            "word:11:17\nint:18:23\nsymbol:24:25\nnewline:35:36\neof:36:36\n",
            "newline:5:6\nword:19:20\nsymbol:20:23\nword:23:24\n",
            "symbol:25:27\nword:28:29\nsymbol:29:31\nint:31:32\neof:32:32\n",
            "byte:4\ncomment:0\nnumber:0\nbyte:0\n",
        ),
        None,
    );
}

#[test]
fn lexer_in_l_agrees_with_stage_zero_on_the_shared_subset() {
    use project_l::lexer::{Kind, lex};

    let source = "fn id(x: Int) -> Int { x += 20; x } // nota\n\
                  (){}[]:;,=+-*/%!<>.?&@ == != <= >= && || -= *= /= %= .. ..= => ??\n";
    let lines: Vec<_> = source.split_inclusive('\n').collect();
    let mut expected = String::new();
    for token in lex(source).unwrap() {
        let start = lines[..token.span.line - 1]
            .iter()
            .map(|s| s.len())
            .sum::<usize>()
            + token.span.column
            - 1;
        let (name, len) = match token.kind {
            Kind::Word(word) => ("word", word.len()),
            Kind::Int(value) => ("int", value.to_string().len()),
            Kind::Sym(symbol) => ("symbol", symbol.len()),
            Kind::Newline => ("newline", 1),
            Kind::Eof => ("eof", 0),
            kind => panic!("fuera del subconjunto: {kind:?}"),
        };
        expected.push_str(&format!("{name}:{start}:{}\n", start + len));
    }
    let literal = source
        .replace('{', "{{")
        .replace('}', "}}")
        .replace('\n', "\\n");
    let driver = format!("fn main() {{ dump(\"{literal}\") }}");
    check(
        "stage-zero",
        &format!("{LEXER}\n{DUMP}\n{driver}"),
        &expected,
        None,
    );
}

#[test]
fn lexer_in_l_grows_the_token_buffer_and_releases_it() {
    let input = "x += 1_2 // café\\n".repeat(2_500);
    let driver = format!(
        r#"
fn main() {{
    let source = "{input}"
    match lexSource(source) {{
        Ok(tokens) => {{
            print(tokens.length)
            print(tokens[tokens.length - 1].end)
        }}
        Err(error) => {{ print(error.offset) }}
    }}
}}
"#
    );
    check(
        "large",
        &format!("{LEXER}\n{driver}"),
        "10001\n45000\n",
        None,
    );
}

#[test]
fn strings_and_interpolation_in_l_lexer() {
    let driver = r#"
fn main() {
    dump("\"\"")
    dump("\"Hola mundo\"")
    dump("\"\\n\\t\\r\\\"\\\\\"")
    dump("\"\\u{{41}} \\u{{1F600}}\"")
    dump("\"{{{{x}}}}\"")
    dump("\"Hola {{nombre}}!\"")
    dump("\"Resultado: {{a + b * 2}}\"")
    dump("\"sin cerrar")
    dump("\"escape \\x malo\"")
    dump("\"escape u \\u{{xyz}} malo\"")
    dump("\"scalar \\u{{110000}} malo\"")
    dump("\"interp {{sin cerrar")
    dump("\"llave }} sin abrir\"")
}
"#;
    check(
        "strings",
        &format!("{LEXER}\n{DUMP}\n{driver}"),
        concat!(
            "text:0:2\neof:2:2\n",
            "text:0:12\neof:12:12\n",
            "text:0:12\neof:12:12\n",
            "text:0:18\neof:18:18\n",
            "text:0:7\neof:7:7\n",
            "text_start:0:1\ntext:1:6\ninterp_start:6:7\nword:7:13\ninterp_end:13:14\ntext:14:15\ntext_end:15:16\neof:16:16\n",
            "text_start:0:1\ntext:1:12\ninterp_start:12:13\nword:13:14\nsymbol:15:16\nword:17:18\nsymbol:19:20\nint:21:22\ninterp_end:22:23\ntext:23:23\ntext_end:23:24\neof:24:24\n",
            "string:0\n",
            "escape:8\n",
            "escape_u:10\n",
            "scalar:8\n",
            "interp:8\n",
            "brace:7\n",
        ),
        None,
    );
}

#[test]
fn token_cursor_navigation_and_expectations() {
    let driver = r#"
fn main() {
    let source = "let x: Int = 42\n"
    match lexSource(source) {
        Ok(tokens) => {
            var cursor = cursorNew(1)
            print(cursorIsAtEnd(&cursor, &tokens))
            let c0 = cursorCurrent(&cursor, &tokens)
            print(c0.start)
            let w = cursorAdvance(&mut cursor, &tokens)
            print(w.start)
            let c1 = cursorCurrent(&cursor, &tokens)
            print(c1.start)
            let exp_word = LexKind.Word
            let exp_int = LexKind.Integer
            print(cursorExpect(&mut cursor, &tokens, &exp_word))
            let c2 = cursorCurrent(&cursor, &tokens)
            print(c2.start)
            print(cursorExpect(&mut cursor, &tokens, &exp_int))
        }
        Err(e) => { print("error") }
    }
}
"#;
    // This unit test intentionally combines the three source modules as a
    // single program; import semantics are tested separately in modules_l.rs.
    // Remove only their known import headers, so the bundled fixture never
    // depends on virtual files that this test does not create.
    // include_str! reflects checkout newline conventions (CRLF on MSVC).
    // Normalize just the embedded fixture to keep both platforms equivalent.
    let tokens_normalized = TOKENS.replace("\r\n", "\n");
    let cursor_normalized = CURSOR.replace("\r\n", "\n");
    let tokens_inline = tokens_normalized
        .strip_prefix("import lexer\n\n")
        .expect("tokens.l must import lexer explicitly");
    let cursor_inline = cursor_normalized
        .strip_prefix("import lexer\nimport tokens\n\n")
        .expect("cursor.l must import lexer and tokens explicitly");
    check(
        "cursor",
        &format!("{LEXER}\n{tokens_inline}\n{cursor_inline}\n{driver}"),
        "false\n0\n0\n4\ntrue\n5\nfalse\n",
        None,
    );
}
