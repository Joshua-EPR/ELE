//! Regressions of the ELE-written driver (`compiler-l/src/main_driver.l`)
//! against Stage 0:
//! - `choose` over Int, Bool and Text literal patterns lowers to valid LIR
//!   (it used to end in "LIR inválida (regla 2, bloque 0)") and runs with the
//!   exact output of Stage 0, as PE32+ and as ELF64;
//! - primitive matches keep Stage 0's pattern checks (type, reachability,
//!   exhaustiveness) as diagnostics, never as an internal error;
//! - a lexer failure is reported with `file:line:col` and its own message,
//!   while genuinely invalid UTF-8 is still reported as such.
#[allow(dead_code)]
mod stage1_support;

#[path = "stage1_support/elf_exec.rs"]
mod elf_exec;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("main_driver"))
}

fn work(name: &str) -> PathBuf {
    let dir = root()
        .join("target/stage1-tests/driver-regressions")
        .join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(dir: &Path, source: &Path, target: &str, image: &str) -> (Output, PathBuf) {
    let image = dir.join(image);
    let out = Command::new(driver())
        .current_dir(dir)
        .arg("build")
        .arg(source)
        .args(["--target", target, "--output"])
        .arg(&image)
        .output()
        .expect("failed to run the ELE driver");
    (out, image)
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).replace("\r\n", "\n")
}

/// Text, Int and Bool matches: borrowed (`view Text` parameter), owned
/// temporary (call result), struct field, escapes, `{{`/`}}`, `\u{..}`,
/// the empty Text, negative and `_`-separated Int literals, a Bool match
/// covered by both literals, and prefixes that must not match.
const CHOOSE_PROGRAM: &str = r#"shape Item {
    name: Text
    count: Int
}

flow label(n: Int) => Text {
    choose n {
        0 : { give "" }
        1 : { give "uno" }
        -1 : { give "menos" }
        1_000 : { give "mil" }
        _ : { give "otro" }
    }
}

flow score(word: view Text) => Int {
    choose word {
        "" : { give 0 }
        "uno" : { give 1 }
        "unos" : { give 2 }
        "caf\u{E9}" : { give 3 }
        "{{x}}" : { give 4 }
        "a\"b" : { give 5 }
        _ : { give 9 }
    }
}

flow main() => Int {
    change total = 0
    each i among -1..3 {
        choose label(i) {
            "uno" : { total = total + 10 }
            "menos" : { total = total + 100 }
            "" : { total = total + 1000 }
            _ : { total = total + 1 }
        }
    }
    hold big = label(1000)
    hold item = Item(name: "café", count: 2)
    choose item.name {
        "café" : { total = total + 20000 }
        _ : {}
    }
    hold w0 = ""
    hold w1 = "uno"
    hold w2 = "unos"
    hold w3 = "café"
    hold w4 = "{{x}}"
    hold w5 = "a\"b"
    hold w6 = "un"
    hold s = score(w0) + score(w1) * 10 + score(w2) * 100 + score(w3) * 1000 + score(w4) * 10000 + score(w5) * 100000 + score(w6) * 1000000
    hold flag = item.count > 1
    choose flag {
        false : { total = total + 7 }
        true : { total = total + 300000 }
    }
    print("{big} {item.name} {s} {total}")
    give total % 100
}
"#;

const CHOOSE_STDOUT: &str = "mil café 9543210 321111\n";
// Not 87: wsl.exe turns that Linux status (ERROR_INVALID_PARAMETER on
// Windows) into its own failure when the image runs through WSL.
const CHOOSE_EXIT: i32 = 11;

#[test]
fn choose_over_text_int_and_bool_runs_like_stage0() {
    let dir = work("choose_text");
    let source = dir.join("choose_text.l");
    fs::write(&source, CHOOSE_PROGRAM).unwrap();

    // The expectation is Stage 0's own behaviour for the same program.
    if cfg!(windows) {
        let reference = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .arg("run")
            .arg(&source)
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8_lossy(&reference.stdout).replace("\r\n", "\n"),
            CHOOSE_STDOUT,
            "Stage 0 stderr: {}",
            stderr(&reference)
        );
        assert_eq!(reference.status.code(), Some(CHOOSE_EXIT));
    }

    let (pe, pe_image) = build(&dir, &source, "pe", "choose_text.exe");
    assert!(pe.status.success(), "PE build failed: {}", stderr(&pe));
    if cfg!(windows) {
        let run = Command::new(&pe_image).output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n"),
            CHOOSE_STDOUT
        );
        assert_eq!(run.status.code(), Some(CHOOSE_EXIT));
    }

    let (elf, elf_image) = build(&dir, &source, "elf", "choose_text.elf");
    assert!(elf.status.success(), "ELF build failed: {}", stderr(&elf));
    assert_eq!(&fs::read(&elf_image).unwrap()[..4], b"\x7fELF");
    let run_dir = dir.join("elf_run");
    fs::create_dir_all(&run_dir).unwrap();
    match elf_exec::execute(&elf_image, &run_dir, &[]) {
        Some(run) => {
            assert_eq!(
                run.stdout.replace("\r\n", "\n"),
                CHOOSE_STDOUT,
                "{}",
                run.stderr
            );
            assert_eq!(run.code, Some(CHOOSE_EXIT));
            if let Some(heap) = &run.heap {
                heap.assert_balanced("choose over Text");
            }
        }
        None => eprintln!(
            "NOT RUN[native-exec]: {} was built but this host cannot execute ELF64",
            elf_image.display()
        ),
    }
}

#[test]
fn primitive_match_patterns_are_diagnosed_not_ice() {
    let dir = work("choose_diagnostics");
    let cases: [(&str, &str, &str); 6] = [
        (
            "missing_wildcard.l",
            "flow main() => Int {\n    hold w = \"a\"\n    change r = 0\n    choose w {\n        \"a\" : { r = 1 }\n    }\n    give r\n}\n",
            "missing_wildcard.l:4:5: error[L0004]: match no exhaustivo sobre Text: falta el caso _",
        ),
        (
            "missing_false.l",
            "flow main() => Int {\n    hold b = true\n    change r = 0\n    choose b {\n        true : { r = 1 }\n    }\n    give r\n}\n",
            "missing_false.l:4:5: error[L0004]: match no exhaustivo sobre Bool: falta el caso false",
        ),
        (
            "mismatch.l",
            "flow main() => Int {\n    hold w = \"a\"\n    change r = 0\n    choose w {\n        1 : { r = 1 }\n        _ : { r = 2 }\n    }\n    give r\n}\n",
            "mismatch.l:5:9: error[L0003]: patrón 1 incompatible con tipo Text",
        ),
        (
            "text_on_int.l",
            "flow main() => Int {\n    hold n = 3\n    change r = 0\n    choose n {\n        \"3\" : { r = 1 }\n        _ : { r = 2 }\n    }\n    give r\n}\n",
            "text_on_int.l:5:9: error[L0003]: patrón Text incompatible con tipo Int",
        ),
        (
            "repeated.l",
            "flow main() => Int {\n    hold w = \"a\"\n    change r = 0\n    choose w {\n        \"a\" : { r = 1 }\n        \"\\u{61}\" : { r = 2 }\n        _ : { r = 3 }\n    }\n    give r\n}\n",
            "repeated.l:6:9: error[L0004]: patrón inalcanzable: los brazos anteriores ya cubren estos valores",
        ),
        (
            "binder.l",
            "flow main() => Int {\n    hold n = 3\n    change r = 0\n    choose n {\n        1 : { r = 1 }\n        other : { r = 2 }\n    }\n    give r\n}\n",
            "binder.l:6:9: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE",
        ),
    ];
    for (name, program, expected) in cases {
        let source = dir.join(name);
        fs::write(&source, program).unwrap();
        let (out, image) = build(&dir, &source, "pe", "never.exe");
        let err = stderr(&out);
        assert_eq!(out.status.code(), Some(1), "{name}: {err}");
        assert!(
            err.contains(expected),
            "{name}: expected `{expected}`, got:\n{err}"
        );
        assert!(!err.contains("error[ICE]"), "{name}: {err}");
        assert!(!image.exists(), "{name} produced an image");
    }
}

/// 1-based line and code-point column of a byte offset, as the driver
/// reports them.
#[test]
fn float_literals_build_and_run_natively() {
    // Float used to be a lexer error of the ELE-written driver; it is now a
    // native f64 lowered through SSE2 and printed like Stage 0's runtime.
    let dir = work("float_builds");
    fs::write(
        dir.join("float.l"),
        "flow main() {\n    hold x = 2.5\n    print(x * 2.0)\n    print(1.0 / 0.0)\n    print(0.1 + 0.2)\n}\n",
    )
    .unwrap();
    let (out, image) = build(&dir, Path::new("float.l"), "pe", "float.exe");
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert!(image.exists());
    if cfg!(windows) {
        let run = Command::new(&image).output().unwrap();
        assert_eq!(run.status.code(), Some(0));
        assert_eq!(String::from_utf8_lossy(&run.stdout), "5\ninf\n0.3\n");
    }
}

#[test]
fn lexer_errors_name_their_module_and_position() {
    let dir = work("lexer_positions");
    let cases: [(&str, &[u8], &str); 4] = [
        (
            "exponent.l",
            "flow main() => Int {\n    hold x = 1e\n    give 0\n}\n".as_bytes(),
            "exponent.l:2:14: error[LEXER]: Float inválido (byte 34)\n",
        ),
        (
            "unicode.l",
            // Columns count code points, and a BOM is not a column.
            "\u{feff}flow main() => Int {\n    // café ☕\n    hold t = \"é\" $\n    give 0\n}\n"
                .as_bytes(),
            "unicode.l:3:18: error[LEXER]: carácter inválido o fuera del subconjunto léxico (byte 59)\n",
        ),
        (
            "unclosed.l",
            "flow main() => Int {\n    print(\"abierta)\n    give 0\n}\n".as_bytes(),
            "unclosed.l:2:11: error[LEXER]: cadena sin cerrar (byte 31)\n",
        ),
        (
            "comment.l",
            "flow main() => Int {\n    give 0\n}\n/* sin cerrar\n".as_bytes(),
            "comment.l:4:1: error[LEXER]: comentario sin cerrar (byte 34)\n",
        ),
    ];
    for (name, bytes, expected) in cases {
        fs::write(dir.join(name), bytes).unwrap();
        let (out, image) = build(&dir, Path::new(name), "pe", "never.exe");
        assert_eq!(out.status.code(), Some(1), "{name}: {}", stderr(&out));
        assert_eq!(stderr(&out), expected, "{name}");
        assert!(!image.exists(), "{name} produced an image");
    }

    // A lexer error in an imported module names that module, not the entry.
    fs::write(
        dir.join("entry.l"),
        "take dep\n\nflow main() => Int {\n    give 0\n}\n",
    )
    .unwrap();
    fs::write(
        dir.join("dep.l"),
        "expose flow f() => Int {\n    give 2e\n}\n",
    )
    .unwrap();
    let (out, _) = build(&dir, Path::new("entry.l"), "pe", "never.exe");
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert!(
        err.ends_with("dep.l:2:10: error[LEXER]: Float inválido (byte 34)\n"),
        "{err}"
    );
    assert!(!err.contains("entry.l"), "{err}");
    assert!(!err.contains("UTF-8"), "{err}");
}

#[test]
fn invalid_utf8_is_still_reported_as_invalid_utf8() {
    let dir = work("lexer_invalid_utf8");
    for (name, bytes) in [
        (
            "truncated.l",
            &b"flow main() => Int {\n    give 0\n}\n\xf0\x9f"[..],
        ),
        (
            "lone_continuation.l",
            &b"flow main() => Int { give 0 }\n// \x80\n"[..],
        ),
        (
            "overlong.l",
            &b"flow main() => Int { give 0 }\n// \xc0\xaf\n"[..],
        ),
    ] {
        fs::write(dir.join(name), bytes).unwrap();
        let (out, image) = build(&dir, Path::new(name), "pe", "never.exe");
        assert_eq!(out.status.code(), Some(5), "{name}: {}", stderr(&out));
        assert_eq!(stderr(&out), format!("{name}: UTF-8 inválido\n"));
        assert!(!image.exists(), "{name} produced an image");
    }
}
