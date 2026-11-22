//! Ratchet of the historic (Rust-like) spelling while ELE migrates to its
//! canonical v2 syntax (`docs/ELE_SYNTAX_V2.md`, issues #12 and #10).
//!
//! The audit runs Stage 0's real lexer (`project_l::lexer::lex`), so the bytes
//! of comments and `Text` literals never become tokens, and the tokens of
//! interpolated expressions (`"{...}"`) are skipped on purpose: only the code
//! a parser reads as declarations and statements is counted. Nothing here
//! rewrites sources; the audit only reads them.
//!
//! # What counts as legacy
//!
//! The mapping comes from the table of `docs/ELE_SYNTAX_V2.md` and from the
//! places where `crates/l/src/parser.rs` still accepts the historic spelling
//! as a bootstrap fallback (`canonical_ele_keyword`, `&`/`&mut`, `->`, the
//! `=>` arm separator of `match`, `<T>` generics):
//!
//! | category          | legacy token(s)                          | ELE v2            |
//! |-------------------|------------------------------------------|-------------------|
//! | `kw_<word>`       | `fn struct impl enum trait pub let var`  | `flow shape extend choice contract expose hold change` |
//! |                   | `const return match if else for in`      | `fixed give choose when otherwise each among` |
//! |                   | `while loop break continue self mut`     | `during repeat leave proceed this exclusive` |
//! |                   | `static async await spawn import module region` | `direct later wait launch take space zone` |
//! | `return_arrow`    | `->` (return annotation)                 | `=>`              |
//! | `match_arm_arrow` | `=>` directly inside a `match`/`choose` body | `:`           |
//! | `borrow_ref`      | `&T` / `&value`                          | `view`            |
//! | `borrow_mut`      | `&mut T` / `&mut value` (one construct)  | `edit`            |
//! | `angle_generic`   | `<...>` type parameters / arguments      | `of[...]`         |
//! | `dot_method_call` | `value.method(...)` / `Type.method(...)` | `@method(...)`    |
//!
//! Precise rules (token level, after dropping `Newline` tokens):
//! * a keyword word right after `.` or `@` is a member name, not a keyword;
//! * `mut` right after `&` belongs to `borrow_mut` and is not `kw_mut`;
//! * `=>` is legacy only at the top level of a `match`/`choose` body (the
//!   first `{` after the keyword); elsewhere it is the v2 return arrow;
//! * `<` is a generic only when a well-formed type-argument list closes with
//!   `>` and it follows a declaration name (`fn/flow`, `struct/shape`,
//!   `enum/choice`, `trait/contract`), `impl`/`extend`, a CamelCase type name,
//!   or a lowercase name whose `>` is followed by `(` (an explicit call);
//!   `a < b` comparisons are never counted;
//! * `.name(` counts as a method call only when `name` starts with a lowercase
//!   letter or `_`: `Estado.Si(42)` is a variant constructor, valid in v2, and
//!   `obj.field` without `(` is field access, valid in v2.
//!
//! Remaining limits: legacy code inside interpolations is not counted, and
//! spellings without a v2 equivalent yet (`as`, `move`, `unsafe`, `extern`,
//! `None`, `?`, `Option`/`Result`) are not legacy for this audit.
//!
//! # Ratchet
//!
//! `docs/ele_v2_legacy_baseline.tsv` holds the count of every legacy category
//! of every audited file. It is generated, never hand-edited:
//!
//! ```text
//! ELE_UPDATE_LEGACY_BASELINE=1 cargo test -p project-l --test ele_v2_legacy_ratchet
//! ```
//!
//! The test fails when a count grows or a file without a baseline row uses
//! legacy syntax, and asks for regeneration when a count shrinks, so the
//! baseline only goes down.

use project_l::lexer::{Kind, lex};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const BASELINE: &str = "docs/ele_v2_legacy_baseline.tsv";
const UPDATE_VAR: &str = "ELE_UPDATE_LEGACY_BASELINE";

/// Historic keywords and the canonical spelling that replaces each one.
const LEGACY_KEYWORDS: &[(&str, &str)] = &[
    ("fn", "flow"),
    ("struct", "shape"),
    ("impl", "extend"),
    ("enum", "choice"),
    ("trait", "contract"),
    ("pub", "expose"),
    ("let", "hold"),
    ("var", "change"),
    ("const", "fixed"),
    ("return", "give"),
    ("match", "choose"),
    ("if", "when"),
    ("else", "otherwise"),
    ("for", "each"),
    ("in", "among"),
    ("while", "during"),
    ("loop", "repeat"),
    ("break", "leave"),
    ("continue", "proceed"),
    ("self", "this"),
    ("mut", "exclusive"),
    ("static", "direct"),
    ("async", "later"),
    ("await", "wait"),
    ("spawn", "launch"),
    ("import", "take"),
    ("module", "space"),
    ("region", "zone"),
];

/// Audited trees (relative to the repository root) and single files.
const AUDITED_TREES: &[&str] = &["compiler-l/src", "examples", "ejemplos"];
const AUDITED_FILES: &[&str] = &["crates/l/src/prelude.l"];
/// Trees already migrated to ELE v2 (docs/EXAMPLES_ELE_V2_MIGRATION.md):
/// they must stay at zero, whatever the baseline says.
const FULLY_V2_TREES: &[&str] = &["examples", "ejemplos"];

type Counts = BTreeMap<String, usize>;

fn word(kind: &Kind) -> Option<&str> {
    match kind {
        Kind::Word(w) => Some(w),
        _ => None,
    }
}

fn is_sym(kind: Option<&Kind>, s: &str) -> bool {
    matches!(kind, Some(Kind::Sym(x)) if x == s)
}

fn starts_lower(w: &str) -> bool {
    w.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
}

fn camel_case(w: &str) -> bool {
    w.starts_with(|c: char| c.is_ascii_uppercase()) && w.chars().any(|c| c.is_ascii_lowercase())
}

/// Index of the `>` closing a type-argument list opened by `<` at `open`, if
/// the tokens in between can only be type syntax.
fn angle_close(code: &[&Kind], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (j, kind) in code.iter().enumerate().skip(open).take(96) {
        match kind {
            Kind::Sym(s) if s == "<" => depth += 1,
            Kind::Sym(s) if s == ">" => {
                depth -= 1;
                if depth == 0 {
                    return Some(j);
                }
            }
            Kind::Sym(s)
                if [",", "&", "(", ")", "[", "]", ":", ";", "->", "=>"].contains(&s.as_str()) => {}
            Kind::Word(w)
                if w.starts_with(|c: char| c.is_ascii_uppercase())
                    || ["mut", "of", "view", "edit"].contains(&w.as_str()) => {}
            Kind::Int(_) => {}
            _ => return None,
        }
    }
    None
}

/// Counts the legacy constructs of one source, by category. Fails only when
/// Stage 0's lexer rejects the source.
fn audit(source: &str) -> Result<Counts, String> {
    let tokens = lex(source).map_err(|d| format!("{}: {}", d.span.line, d.message))?;
    // Code tokens: no newlines, no string pieces, nothing inside interpolations.
    let mut code: Vec<&Kind> = Vec::with_capacity(tokens.len());
    let mut interpolation = 0usize;
    for token in &tokens {
        match &token.kind {
            Kind::InterpolationStart => interpolation += 1,
            Kind::InterpolationEnd => interpolation -= 1,
            Kind::Newline | Kind::Eof | Kind::Text(_) | Kind::TextStart | Kind::TextEnd => {}
            kind if interpolation == 0 => code.push(kind),
            _ => {}
        }
    }

    let mut counts = Counts::new();
    let mut bump = |category: String| *counts.entry(category).or_insert(0) += 1;
    let mut braces = 0usize;
    let mut groups = 0usize; // parentheses and brackets
    // Match bodies: (brace depth inside the body, group depth at its `{`).
    let mut match_bodies: Vec<(usize, usize)> = Vec::new();
    let mut pending_match = false;
    for i in 0..code.len() {
        let kind = code[i];
        let prev = i.checked_sub(1).map(|p| code[p]);
        let next = code.get(i + 1).copied();
        match kind {
            Kind::Word(w) => {
                if is_sym(prev, ".") || is_sym(prev, "@") {
                    continue;
                }
                if w == "match" || w == "choose" {
                    pending_match = true;
                }
                if w == "mut" && is_sym(prev, "&") {
                    continue;
                }
                if LEGACY_KEYWORDS.iter().any(|(legacy, _)| legacy == w) {
                    bump(format!("kw_{w}"));
                }
            }
            Kind::Sym(s) => match s.as_str() {
                "{" => {
                    braces += 1;
                    if pending_match {
                        pending_match = false;
                        match_bodies.push((braces, groups));
                    }
                }
                "}" => {
                    if match_bodies.last().is_some_and(|(b, _)| *b == braces) {
                        match_bodies.pop();
                    }
                    braces = braces.saturating_sub(1);
                }
                "(" | "[" => groups += 1,
                ")" | "]" => groups = groups.saturating_sub(1),
                "->" => bump("return_arrow".into()),
                "=>" => {
                    if match_bodies.last() == Some(&(braces, groups)) {
                        bump("match_arm_arrow".into());
                    }
                }
                "&" => {
                    if next.and_then(word) == Some("mut") {
                        bump("borrow_mut".into());
                    } else {
                        bump("borrow_ref".into());
                    }
                }
                "." => {
                    if next.and_then(word).is_some_and(starts_lower)
                        && is_sym(code.get(i + 2).copied(), "(")
                    {
                        bump("dot_method_call".into());
                    }
                }
                "<" => {
                    let Some(name) = prev.and_then(word) else {
                        continue;
                    };
                    let before = i.checked_sub(2).map(|p| code[p]);
                    let Some(close) = angle_close(&code, i) else {
                        continue;
                    };
                    let declared = before.and_then(word).is_some_and(|b| {
                        [
                            "fn", "flow", "struct", "shape", "enum", "choice", "trait", "contract",
                        ]
                        .contains(&b)
                    });
                    let member = is_sym(before, ".") || is_sym(before, "@");
                    let generic = declared
                        || name == "impl"
                        || name == "extend"
                        || (camel_case(name) && !member)
                        || (starts_lower(name) && is_sym(code.get(close + 1).copied(), "("));
                    if generic {
                        bump("angle_generic".into());
                    }
                }
                _ => {}
            },
            _ => {}
        }
    }
    Ok(counts)
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn relative(path: &Path) -> String {
    path.strip_prefix(root())
        .unwrap()
        .to_string_lossy()
        .replace('\\', "/")
}

fn audited_files() -> Vec<PathBuf> {
    let mut result: Vec<PathBuf> = AUDITED_FILES
        .iter()
        .map(|f| root().join(f))
        .filter(|p| p.is_file())
        .collect();
    let mut stack: Vec<PathBuf> = AUDITED_TREES.iter().map(|t| root().join(t)).collect();
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "l") {
                result.push(path);
            }
        }
    }
    result.sort();
    result
}

/// (file, category) -> count for every audited file, zero rows omitted.
fn current_counts() -> BTreeMap<(String, String), usize> {
    let mut all = BTreeMap::new();
    let mut lex_failures = Vec::new();
    for path in audited_files() {
        let source = fs::read_to_string(&path).unwrap();
        match audit(&source) {
            Ok(counts) => {
                for (category, n) in counts {
                    all.insert((relative(&path), category), n);
                }
            }
            Err(e) => lex_failures.push(format!("{}:{e}", relative(&path))),
        }
    }
    assert!(
        lex_failures.is_empty(),
        "Stage 0's lexer rejected audited sources:\n{}",
        lex_failures.join("\n")
    );
    all
}

fn render(counts: &BTreeMap<(String, String), usize>) -> String {
    let mut totals: BTreeMap<&str, usize> = BTreeMap::new();
    let mut files: BTreeMap<&str, usize> = BTreeMap::new();
    for ((file, category), n) in counts {
        *totals.entry(category).or_insert(0) += n;
        *files.entry(file).or_insert(0) += n;
    }
    let mut out = String::new();
    out.push_str("# ELE v2 legacy-syntax ratchet baseline (issue #12). GENERATED: do not edit.\n");
    out.push_str(&format!(
        "# Regenerate: {UPDATE_VAR}=1 cargo test -p project-l --test ele_v2_legacy_ratchet\n"
    ));
    out.push_str("# Counts may only go down; see crates/l/tests/ele_v2_legacy_ratchet.rs.\n");
    out.push_str(&format!(
        "# files with legacy syntax: {}; total legacy constructs: {}\n",
        files.len(),
        totals.values().sum::<usize>()
    ));
    for (category, n) in &totals {
        out.push_str(&format!("# total\t{category}\t{n}\n"));
    }
    out.push_str("# file\tcategory\tcount\n");
    for ((file, category), n) in counts {
        out.push_str(&format!("{file}\t{category}\t{n}\n"));
    }
    out
}

fn parse_baseline(text: &str) -> BTreeMap<(String, String), usize> {
    let mut map = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        assert_eq!(fields.len(), 3, "malformed baseline row: {line:?}");
        let n = fields[2]
            .parse()
            .unwrap_or_else(|_| panic!("malformed baseline count: {line:?}"));
        map.insert((fields[0].to_string(), fields[1].to_string()), n);
    }
    map
}

#[test]
fn legacy_syntax_never_regresses_against_the_baseline() {
    let current = current_counts();
    let rendered = render(&current);
    let baseline_path = root().join(BASELINE);
    if std::env::var_os(UPDATE_VAR).is_some_and(|v| v == "1") {
        fs::write(&baseline_path, &rendered).unwrap();
        return;
    }
    let text = fs::read_to_string(&baseline_path).unwrap_or_else(|_| {
        panic!("missing {BASELINE}; generate it with {UPDATE_VAR}=1 cargo test -p project-l --test ele_v2_legacy_ratchet")
    });
    let baseline = parse_baseline(&text);

    let mut regressions = Vec::new();
    for ((file, category), &n) in &current {
        let allowed = baseline
            .get(&(file.clone(), category.clone()))
            .copied()
            .unwrap_or(0);
        if n > allowed {
            regressions.push(format!(
                "{file}: {category} {allowed} -> {n} (use the ELE v2 spelling)"
            ));
        }
    }
    assert!(
        regressions.is_empty(),
        "legacy (pre-v2) syntax grew; see docs/ELE_SYNTAX_V2.md:\n{}",
        regressions.join("\n")
    );

    let mut improvements = Vec::new();
    for ((file, category), &allowed) in &baseline {
        let n = current
            .get(&(file.clone(), category.clone()))
            .copied()
            .unwrap_or(0);
        if n < allowed {
            improvements.push(format!("{file}: {category} {allowed} -> {n}"));
        }
    }
    assert!(
        improvements.is_empty(),
        "legacy syntax decreased; lower the ratchet with\n  {UPDATE_VAR}=1 cargo test -p project-l --test ele_v2_legacy_ratchet\n{}",
        improvements.join("\n")
    );
    assert_eq!(
        text.replace("\r\n", "\n"),
        rendered,
        "{BASELINE} is generated and must not be edited by hand; regenerate it with {UPDATE_VAR}=1"
    );
}

#[test]
fn migrated_trees_stay_fully_v2() {
    let offenders: Vec<String> = current_counts()
        .into_iter()
        .filter(|((file, _), _)| {
            FULLY_V2_TREES
                .iter()
                .any(|tree| file.starts_with(&format!("{tree}/")))
        })
        .map(|((file, category), n)| format!("{file}: {category} = {n}"))
        .collect();
    assert!(
        offenders.is_empty(),
        "migrated sources reintroduced legacy syntax:\n{}",
        offenders.join("\n")
    );
}

fn count(source: &str, category: &str) -> usize {
    audit(source).unwrap().get(category).copied().unwrap_or(0)
}

#[test]
fn audit_counts_legacy_code_tokens() {
    assert_eq!(count("fn main() {}", "kw_fn"), 1);
    assert_eq!(count("fn f() -> Int { return 1 }", "return_arrow"), 1);
    assert_eq!(count("fn f() -> Int { return 1 }", "kw_return"), 1);
    let src = "flow f(a: &Text, b: &mut Int) => Int {\n    hold x = &a\n    give 0\n}";
    assert_eq!(count(src, "borrow_ref"), 2);
    assert_eq!(count(src, "borrow_mut"), 1);
    assert_eq!(count(src, "kw_mut"), 0);
    assert_eq!(count("impl Cuenta {\n    mut fn f() {}\n}", "kw_mut"), 1);
    assert_eq!(count("let x = y.largo(1)", "dot_method_call"), 1);
    assert_eq!(count("let x = Tipo.nuevo()", "dot_method_call"), 1);
    assert_eq!(count("hold x = Estado.Si(1)", "dot_method_call"), 0);
    assert_eq!(count("hold x = y.campo", "dot_method_call"), 0);
    assert_eq!(count("hold x = y@largo(1)", "dot_method_call"), 0);
    let generics = "fn id<T>(x: T) -> T = x\nstruct Caja<T> { d: T }\nimpl<T> Caja<T> {}\nfn g(l: List<Option<Int>>) {}\nlet v = id<Int>(1)";
    assert_eq!(count(generics, "angle_generic"), 7);
    assert_eq!(count("when a < b { give 1 }", "angle_generic"), 0);
    assert_eq!(
        count("when a < MAX && b > c(1) { give 1 }", "angle_generic"),
        0
    );
    let arms =
        "flow f() => Int {\n    match x {\n        A => 1,\n        B(v) => { give v }\n    }\n}";
    assert_eq!(count(arms, "match_arm_arrow"), 2);
    assert_eq!(count(arms, "kw_match"), 1);
    let v2 = "flow f() => Int {\n    choose x {\n        A: 1,\n        B(v): { give v }\n    }\n}";
    assert_eq!(audit(v2).unwrap(), Counts::new());
}

#[test]
fn audit_ignores_comments_strings_and_interpolation() {
    let source = concat!(
        "// fn let match -> &mut x.y()\n",
        "/* struct impl /* nested fn */ enum */\n",
        "flow main() => Int {\n",
        "    hold a = \"fn let -> &mut impl x.f()\"\n",
        "    hold b = \"valor {fn} y {{fn}}\"\n",
        "    hold c = \"{\"let {return}\"}\"\n",
        "    give 0\n",
        "}\n",
    );
    assert_eq!(audit(source).unwrap(), Counts::new());
    // Members named like keywords are not keywords.
    assert_eq!(audit("hold t = Tarea.spawn").unwrap(), Counts::new());
    // The same word in code is counted.
    assert_eq!(count("fn main() { print(\"fn\") } // fn", "kw_fn"), 1);
}

#[test]
fn every_legacy_keyword_is_still_a_stage_zero_alias() {
    // Guards the mapping above against drift: each historic keyword must be
    // reserved by Stage 0 and its v2 spelling must exist in the syntax doc.
    let doc = fs::read_to_string(root().join("docs/ELE_SYNTAX_V2.md")).unwrap();
    let rows: Vec<Vec<&str>> = doc
        .lines()
        .filter(|line| line.starts_with('|'))
        .map(|line| {
            line.split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .collect()
        })
        .collect();
    for (legacy, canonical) in LEGACY_KEYWORDS {
        assert!(
            rows.iter()
                .any(|row| row.contains(legacy) && row.contains(canonical)),
            "docs/ELE_SYNTAX_V2.md no longer maps `{legacy}` to `{canonical}`"
        );
        assert!(
            project_l::check(&format!(
                "flow main() => Int {{\n hold {legacy} = 1\n give 0\n}}"
            ))
            .is_err(),
            "`{legacy}` is no longer reserved by Stage 0"
        );
    }
}
