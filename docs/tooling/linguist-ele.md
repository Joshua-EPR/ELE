# GitHub Linguist Recognition Strategy for the ELE Language (`.l`)

## 1. Executive Summary

The ELE programming language uses `.l` as its canonical source file extension (e.g., `main.l`, `compiler-l/src/lexer.l`). On GitHub, file classification, language statistics, and default syntax highlighting are determined by [github/linguist](https://github.com/github/linguist).

The `.l` extension is historically shared with:
1. **Common Lisp** (primarily `.lisp`, `.lsp`, but also historically `.l`)
2. **Lex / Flex** (standard scanner specification files)

Because of this three-way collision, unconfigured repositories containing ELE code may misclassify `.l` files as Common Lisp or Lex. This document specifies:
- Collision analysis and syntactic invariants distinguishing ELE.
- Immediate disambiguation via repository `.gitattributes` overrides.
- Concrete heuristic rules and language definitions for eventual upstream contribution to `github/linguist`.
- Governance guidelines regarding external submissions.

---

## 2. Extension Collision & Lexical Analysis

### 2.1 Common Lisp (`.l`)
Common Lisp is characterized by prefix S-expressions and semicolon line comments:
- Structural tokens: Predominantly nested round parentheses `(` and `)`.
- Top-level forms: `(defun ...)`, `(defmacro ...)`, `(defvar ...)`, `(in-package ...)`.
- Comments: Single or multiple semicolons (`;; comment`).
- Absences: No curly braces `{}` or C-like semicolons as statement terminators.

### 2.2 Lex / Flex (`.l`)
Lex files specify lexical scanners using a multi-section grammar:
- Structural tokens: Divided into three sections delimited by `%%` on a line by itself.
- Section 1: Declarations enclosed in `%{` and `%}`, or `%option` directives.
- Section 2: Regular expression patterns followed by C code actions `{ action }`.
- Comments: C-style comments `/* ... */` inside action blocks or after whitespace.

### 2.3 ELE v2 (`.l`)
ELE v2 is a modern systems language with a distinctive syntax:
- Structural tokens: C-family block delimiters `{ ... }`, parentheses `( ... )` for argument lists, square brackets `[ ... ]` for arrays and generics `of[T]`.
- Comments: Line comments `//` and block comments `/* ... */`.
- Distinctive Canonical Keywords:
  - Declarations: `flow` (functions), `shape` (nominal structs), `choice` (algebraic enums), `extend` (type implementations), `contract` (traits/interfaces), `fixed` (constants), `take` (imports), `space` (modules), `zone` (regions), `expose` (public visibility).
  - Control Flow: `when` / `otherwise` (conditions), `during` (while-loops), `repeat` (infinite loops), `each ... among` (collection loops), `give` (explicit returns), `choose` (pattern matching), `leave` / `proceed` (break / continue).
  - Ownership & Borrowing: `hold` (immutable let), `change` (mutable var), `exclusive` (mutable method receiver), `direct` (associated functions), `view` (shared borrow), `edit` (exclusive borrow).
  - Concurrency: `later` (async), `wait` (await), `launch` (spawn).
- Distinctive Operators & Calling Conventions:
  - Canonical method calls: `target@method(args)` and `Type@direct_method()`.
  - Return arrow: `=> Type`.
  - Match arms: `pattern: { body }`.
  - Generics: `of[T]` (e.g., `shape Box of[T]`, `List of[Int]`).
  - String interpolation: `"{var}"` inside double-quoted text.

---

## 3. Disambiguation Heuristic Strategy

Linguist utilizes regex heuristics in `lib/linguist/heuristics.rb` to resolve conflicting file extensions. ELE files can be unambiguously differentiated using three clear invariants:

### Invariant 1: Absence of Lisp Top-Level S-Expressions
ELE files do not begin declarations with `(defun`, `(defmacro`, `(in-package`, or leading `(;;`.

### Invariant 2: Absence of Lex Section Separators
ELE files never contain section divider lines consisting solely of `%%` (`^%%$`).

### Invariant 3: Strong Presence of ELE v2 Signature Tokens
A regular expression matching top-level ELE declarations and constructs:
- Declarations: `^\s*(?:expose\s+)?(?:flow|shape|choice|extend|contract)\b`
- Imports: `^\s*take\s+[a-zA-Z_]`
- Method invocations: `@[a-zA-Z_][a-zA-Z0-9_]*\(`
- Variable declarations: `^\s*(?:hold|change)\s+[a-zA-Z_]`
- Return expressions: `=>\s*[A-Z][a-zA-Z0-9_]*\s*\{`

---

## 4. Repository Override (`.gitattributes`)

Until upstream Linguist includes ELE heuristics natively, repositories containing ELE source code can configure `.gitattributes` in the repository root.

The ELE repository currently overrides `.l` to prevent Lex/Flex misclassification:
```gitattributes
# ELE Language File Attributes
# *.l is the canonical extension of the ELE Systems Programming Language.
*.l linguist-language=Text
```

For environments or tooling that support custom Linguist language definitions, the direct mapping is:
```gitattributes
*.l linguist-language=ELE
*.l linguist-detectable=true
```

To associate the syntax grammar in GitHub or editors supporting TextMate grammars, map the scope `source.ele` to `.l`.

---

## 5. Specification for Future `github/linguist` Submission

> [!IMPORTANT]
> **Strict Upstream Submission Policy**: Do NOT submit pull requests to `github/linguist` prematurely. Linguist's submission guidelines require a significant volume of independent public repositories, stars, and adoption before a new language can be merged upstream.

When the repository metrics meet Linguist criteria, the submission comprises the following two additions:

### 5.1 Proposed Language Entry (`lib/linguist/languages.yml`)

```yaml
ELE:
  type: programming
  color: "#34789e"
  extensions:
    - ".l"
  tm_scope: source.ele
  ace_mode: text
  codemirror_mode: clike
  language_id: 89312014
```

### 5.2 Proposed Disambiguation Heuristic (`lib/linguist/heuristics.rb`)

```ruby
disambiguate ".l" do
  # Check for Lex/Flex section divider
  matches %r{^%%$} do
    return name "Lex"
  end

  # Check for Common Lisp top-level S-expressions or semicolons
  matches %r{^\s*\((?:defun|defmacro|defvar|defparameter|in-package|ql:quickload)\b} do
    return name "Common Lisp"
  end

  # Check for ELE signature constructs:
  # flow, shape, choice, extend, contract, take, hold, change, or method calls with @
  matches %r{^\s*(?:expose\s+)?(?:flow|shape|choice|extend|contract)\s+[a-zA-Z_]|^\s*take\s+[a-zA-Z_]|@[a-zA-Z_][a-zA-Z0-9_]*\(} do
    return name "ELE"
  end
end
```

---

## 6. Verification and Maintenance

1. **Local Test Script**: `tests/test_syntax_grammar.py` verifies lexical patterns and TextMate grammar compatibility.
2. **Ratchet Integrity**: `cargo test -p project-l --test ele_v2_legacy_ratchet` verifies zero regressions across all repository `.l` sources.
3. **Editor Tooling**: The VS Code extension located in `editors/vscode/` serves as the reference implementation for ELE grammar and problemMatcher integrations.
