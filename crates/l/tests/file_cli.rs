use std::{
    ffi::OsStr,
    fs,
    path::PathBuf,
    process::{Command, Output},
};

const LEXER: &str = include_str!("../../../compiler-l/src/lexer.l");
const BACKENDS: [&str; 2] = ["cranelift", "rustc"];

struct Exe {
    dir: PathBuf,
    path: PathBuf,
    native: bool,
}

impl Exe {
    fn build(case: &str, backend: &str, source: &str) -> Self {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/file-cli")
            .join(case)
            .join(backend);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("main.l"), source).unwrap();
        let native = backend == "cranelift";
        let mut command = Command::new(env!("CARGO_BIN_EXE_l"));
        command
            .current_dir(&dir)
            .args(["build", "main.l", "--backend", backend]);
        if native {
            command.arg("--trace-alloc");
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{backend}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        let path = dir.join(
            stdout
                .lines()
                .find_map(|line| line.strip_prefix("Build: "))
                .unwrap(),
        );
        Self { dir, path, native }
    }

    fn fixture(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.dir.join(name);
        fs::write(&path, bytes).unwrap();
        path
    }

    fn run(&self, args: &[&OsStr], code: i32, stdout: &str, opens: u64) -> String {
        let mut cmd = Command::new(&self.path);
        cmd.current_dir(&self.dir).args(args);
        if self.native {
            cmd.env("PATH", "");
        }
        let Output {
            status,
            stdout: output,
            stderr,
        } = cmd.output().unwrap();
        let stderr = String::from_utf8(stderr).unwrap();
        assert_eq!(status.code(), Some(code), "{stderr}");
        assert_eq!(String::from_utf8(output).unwrap(), stdout);
        if !self.native {
            return stderr;
        }
        let (diagnostics, stats) = stderr.rsplit_once("l-alloc: ").unwrap();
        let count = |name: &str| -> u64 {
            stats
                .split_whitespace()
                .find_map(|field| field.strip_prefix(name))
                .unwrap()
                .parse()
                .unwrap()
        };
        assert_eq!(count("allocs="), count("frees="), "{stats}");
        assert_eq!(count("file_opens="), opens, "{stats}");
        assert_eq!(count("file_closes="), opens, "{stats}");
        assert_eq!(count("heap_ok="), 1, "{stats}");
        diagnostics.into()
    }

    fn driver(case: &str, backend: &str) -> Self {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/file-cli")
            .join(case)
            .join(backend);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("lexer.l"), LEXER).unwrap();
        fs::write(
            dir.join("tokens.l"),
            include_str!("../../../compiler-l/src/tokens.l"),
        )
        .unwrap();
        fs::write(
            dir.join("cursor.l"),
            include_str!("../../../compiler-l/src/cursor.l"),
        )
        .unwrap();
        fs::write(
            dir.join("main.l"),
            include_str!("../../../compiler-l/src/main.l"),
        )
        .unwrap();
        let native = backend == "cranelift";
        let mut command = Command::new(env!("CARGO_BIN_EXE_l"));
        command
            .current_dir(&dir)
            .args(["build", "main.l", "--backend", backend]);
        if native {
            command.arg("--trace-alloc");
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{backend}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8(output.stdout).unwrap();
        let path = dir.join(
            stdout
                .lines()
                .find_map(|line| line.strip_prefix("Build: "))
                .unwrap(),
        );
        Self { dir, path, native }
    }
}

#[test]
fn arguments_preserve_empty_quotes_and_unicode_and_main_returns_status() {
    let source = r#"
fn show(index: Int) {
    match processArg(index) {
        Ok(text) => {
            let len = text.byteLength
            print("{len}:{text}")
        }
        Err(code) => { print("error:{code}") }
    }
}
fn main() -> Int {
    let count = processArgCount()
    print(count)
    for i in 0..count { show(i) }
    show(-1)
    show(count)
    if count == 0 { return -1 }
    return 19
}
"#;
    for backend in BACKENDS {
        let exe = Exe::build("args", backend, source);
        let args = ["", "á 😀", "a \"b\" c", "C:\\con espacio\\"].map(OsStr::new);
        let expected = "4\n0:\n7:á 😀\n7:a \"b\" c\n15:C:\\con espacio\\\nerror:1\nerror:1\n";
        assert!(exe.run(&args, 19, expected, 0).is_empty());
        assert!(exe.run(&[], 255, "0\nerror:1\nerror:1\n", 0).is_empty());
    }
}

#[test]
fn file_api_handles_bounds_partial_tail_and_repeated_drops() {
    let source = r#"
fn read(path: Text, max: Int) {
    match readText(path, max) {
        Ok(text) => { print(text.byteLength) }
        Err(code) => { print("error:{code}") }
    }
}
fn main() -> Int {
    for i in 0..4 { read("carga 😃.l", 131073) }
    read("carga 😃.l", 131072)
    read("carga 😃.l", 0)
    read("vacío.l", 0)
    read("ausente.l", 0)
    read("malo.l", 8)
    read("carga 😃.l", -1)
    read("carga 😃.l", 67108865)
    read("con\u{0}nul.l", 100)
    return 0
}
"#;
    for backend in BACKENDS {
        let exe = Exe::build("files", backend, source);
        let mut content = vec![b'x'; 131_071];
        content.extend_from_slice("é".as_bytes());
        exe.fixture("carga 😃.l", &content);
        exe.fixture("vacío.l", b"");
        exe.fixture("malo.l", &[0xed, 0xa0, 0x80]);
        let expected = "131073\n131073\n131073\n131073\nerror:5\nerror:5\n0\nerror:2\nerror:4\nerror:1\nerror:1\nerror:1\n";
        assert!(exe.run(&[], 0, expected, 8).is_empty());
    }
}

fn offset(source: &str, span: project_l::Span) -> usize {
    let line_start = source
        .split_inclusive('\n')
        .take(span.line - 1)
        .map(str::len)
        .sum::<usize>();
    line_start
        + source[line_start..]
            .char_indices()
            .nth(span.column - 1)
            .map_or(source.len() - line_start, |(i, _)| i)
}

#[test]
fn autonomous_lexer_agrees_with_stage_zero_on_a_real_file() {
    use project_l::lexer::{Kind, lex};

    let source = "fn suma(x: Int) -> Int {\r\n/* café\n/* 👋 */ */ return x + 10\r\n}\r\n";
    let mut expected = String::new();
    for token in lex(source).unwrap() {
        let start = offset(source, token.span);
        let (kind, len) = match token.kind {
            Kind::Word(word) => ("word", word.len()),
            Kind::Int(int) => ("int", int.to_string().len()),
            Kind::Sym(sym) => ("symbol", sym.len()),
            Kind::Newline => ("newline", 1),
            Kind::Eof => ("eof", 0),
            kind => panic!("{kind:?}"),
        };
        expected.push_str(&format!("{kind}:{start}:{}\n", start + len));
    }
    for backend in BACKENDS {
        let exe = Exe::driver("parity", backend);
        let source_file = exe.fixture("entrada con café 👋.l", source.as_bytes());
        assert!(
            exe.run(&[source_file.as_os_str()], 0, &expected, 1)
                .is_empty()
        );
        let empty = exe.fixture("empty.l", b"");
        assert!(exe.run(&[empty.as_os_str()], 0, "eof:0:0\n", 1).is_empty());
        let bom = exe.fixture("bom.l", b"\xef\xbb\xbfx\r\n");
        assert!(
            exe.run(&[bom.as_os_str()], 0, "word:3:4\nnewline:5:6\neof:6:6\n", 1)
                .is_empty()
        );
    }
}

#[test]
fn autonomous_lexer_reports_distinct_failures_and_closes_files() {
    for backend in BACKENDS {
        let exe = Exe::driver("diagnostics", backend);
        for args in [
            vec![],
            vec![OsStr::new("")],
            vec![OsStr::new("a"), OsStr::new("b")],
        ] {
            assert_eq!(exe.run(&args, 2, "", 0), "Uso: lexer-l <archivo.l>\n");
        }
        assert_eq!(
            exe.run(&[OsStr::new("ausente.l")], 3, "", 0),
            "ausente.l: archivo inexistente\n"
        );
        assert!(
            exe.run(&[OsStr::new(".")], 4, "", 0)
                .contains("abrir o leer")
        );
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            let locked = exe.fixture("bloqueado.l", b"x");
            let handle = fs::OpenOptions::new()
                .read(true)
                .share_mode(0)
                .open(&locked)
                .unwrap();
            assert!(
                exe.run(&[locked.as_os_str()], 4, "", 0)
                    .contains("abrir o leer")
            );
            drop(handle);
        }
        exe.fixture("bytes.l", &[b'a', 0xf0, 0x9f]);
        assert_eq!(
            exe.run(&[OsStr::new("bytes.l")], 5, "", 1),
            "bytes.l: UTF-8 inválido\n"
        );
        let invalid = "x\r\n/* é👋 */ $";
        exe.fixture("léxico.l", invalid.as_bytes());
        let diagnostic = project_l::lexer::lex(invalid).unwrap_err();
        let expected = format!(
            "léxico.l:{}:{}: carácter inválido o fuera del subconjunto léxico (byte {})\n",
            diagnostic.span.line,
            diagnostic.span.column,
            offset(invalid, diagnostic.span),
        );
        assert_eq!(exe.run(&[OsStr::new("léxico.l")], 6, "", 1), expected);
        exe.fixture("string.l", b"\"texto sin cerrar");
        assert!(
            exe.run(&[OsStr::new("string.l")], 6, "", 1)
                .contains("string.l:1:1: cadena sin cerrar (byte 0)")
        );
        let str_valid = "\"Hola {nombre}!\"\n";
        let str_file = exe.fixture("valido.l", str_valid.as_bytes());
        let expected_str = "text_start:0:1\ntext:1:6\ninterp_start:6:7\nword:7:13\ninterp_end:13:14\ntext:14:15\ntext_end:15:16\nnewline:16:17\neof:17:17\n";
        assert_eq!(exe.run(&[str_file.as_os_str()], 0, expected_str, 1), "");
        let too_large = exe.fixture("enorme.l", b"");
        fs::OpenOptions::new()
            .write(true)
            .open(too_large)
            .unwrap()
            .set_len(16 * 1024 * 1024 + 1)
            .unwrap();
        assert!(
            exe.run(&[OsStr::new("enorme.l")], 7, "", 1)
                .contains("16 MiB")
        );
    }
}

#[test]
fn platform_operations_preserve_types_effects_and_loans() {
    for (source, code) in [
        ("fn main() { processArg(true); }", "L0001"),
        ("fn main() { processArgCount(1); }", "L0001"),
        ("fn main() { readText(\"p\", false); }", "L0001"),
        ("fn main() { printError(1); }", "L0001"),
        ("fn main() -> Bool = true", "L0001"),
        ("async fn main() -> Int = 1", "L0001"),
        (
            "fn f() -> Int !{} = processArgCount()\nfn main() {}",
            "L0010",
        ),
        ("@noalloc\nfn main() { readText(\"p\", 10); }", "L0010"),
        (
            r#"fn consume(t: Text) -> Int = t.byteLength
fn main() { let t = "x"; readText(t, consume(t)); }"#,
            "L0012",
        ),
    ] {
        let error = project_l::check(source).expect_err(source);
        assert_eq!(error.code, code, "{source}: {error:?}");
    }
}
