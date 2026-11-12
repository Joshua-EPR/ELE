//! B1 module visibility contract for the real type parser used by stmt.l.
//! Stage 1 must resolve the public entrypoint while keeping its atom parser private.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn prepare_modules() -> PathBuf {
    let dir = root().join("target/stage1-tests/b1-parse-type-exports");
    fs::create_dir_all(&dir).unwrap();
    // Import real ELE source; never replace dependencies with fake declarations.
    for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    dir
}

fn check(dir: &Path, name: &str, source: &str, expected: bool) -> String {
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let out = Command::new(sema())
        .arg(file)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(out.status.success(), expected, "{name}: {stderr}");
    stderr
}

#[test]
fn b1_public_parse_type_does_not_expose_parse_type_atom() {
    let dir = prepare_modules();
    let actual_stmt = fs::read_to_string(dir.join("stmt.l")).unwrap();
    assert!(actual_stmt.contains("import types"));
    assert!(actual_stmt.contains("parseType("));

    let public = check(
        &dir,
        "public_parse_type",
        "import types\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parseType(&mut tree, source, &mut cursor, tokens, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    let private = check(
        &dir,
        "private_parse_type_atom",
        "import types\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parseTypeAtom(&mut tree, source, &mut cursor, tokens, 0) }\n",
        false,
    );
    assert!(private.contains("error[L0001]"), "{private}");
    assert!(private.contains("private_parse_type_atom.l:"), "{private}");
}
