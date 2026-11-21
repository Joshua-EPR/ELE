#!/usr/bin/env python3
"""
Test Suite for ELE v2 TextMate Grammar, VS Code Extension Manifest, and Lexical Patterns.
Validates:
1. JSON well-formedness and schema integrity.
2. Complete ELE v2 keyword coverage (flow, shape, choice, extend, contract, etc.).
3. Canonical method call regex (@method) highlighting as method invocation.
4. Generics (of[T]) pattern recognition.
5. String interpolation ("{var}") recursive delimiters.
6. ProblemMatcher regular expression for compiler diagnostics and error[PARSER].
7. Full presence of required code snippets.
"""

import json
import re
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EDITORS_DIR = REPO_ROOT / "editors" / "vscode"
SYNTAX_JSON = EDITORS_DIR / "syntaxes" / "ele.tmLanguage.json"
PACKAGE_JSON = EDITORS_DIR / "package.json"
SNIPPETS_JSON = EDITORS_DIR / "snippets" / "ele.json"
LANG_CONFIG_JSON = EDITORS_DIR / "language-configuration.json"
ROOT_SYNTAX_JSON = REPO_ROOT / "syntaxes" / "ele.tmLanguage.json"


class TestVSCodeManifest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(PACKAGE_JSON.exists(), f"Missing {PACKAGE_JSON}")
        with open(PACKAGE_JSON, "r", encoding="utf-8") as f:
            self.pkg = json.load(f)

    def test_package_json_structure(self):
        self.assertEqual(self.pkg.get("name"), "ele-vscode")
        self.assertIn("contributes", self.pkg)
        contrib = self.pkg["contributes"]
        self.assertIn("languages", contrib)
        self.assertIn("grammars", contrib)
        self.assertIn("snippets", contrib)
        self.assertIn("problemMatchers", contrib)

    def test_language_contribution(self):
        langs = self.pkg["contributes"]["languages"]
        self.assertTrue(any(lang.get("id") == "ele" for lang in langs))
        ele_lang = next(lang for lang in langs if lang.get("id") == "ele")
        self.assertIn(".l", ele_lang.get("extensions", []))
        self.assertIn("ELE", ele_lang.get("aliases", []))
        self.assertIn("ele", ele_lang.get("aliases", []))

    def test_problem_matcher(self):
        matchers = self.pkg["contributes"]["problemMatchers"]
        ele_matcher = next((m for m in matchers if m.get("name") == "ele"), None)
        self.assertIsNotNone(ele_matcher, "Missing 'ele' problemMatcher contribution")
        
        pattern = ele_matcher.get("pattern", {})
        regexp = pattern.get("regexp")
        self.assertIsNotNone(regexp, "Missing regexp in problemMatcher pattern")

        compiled_re = re.compile(regexp)

        # Test standard compiler diagnostic format
        line1 = "src/main.l:14:5: error[L0005]: uso de valor movido"
        m1 = compiled_re.match(line1)
        self.assertIsNotNone(m1, f"Failed to match diagnostic: {line1}")
        self.assertEqual(m1.group(1), "src/main.l")
        self.assertEqual(m1.group(2), "14")
        self.assertEqual(m1.group(3), "5")
        # Check severity / code / message mapping
        if pattern.get("severity"):
            self.assertEqual(m1.group(pattern["severity"]), "error")
            self.assertEqual(m1.group(pattern["code"]), "L0005")
            self.assertEqual(m1.group(pattern["message"]), "uso de valor movido")
        else:
            self.assertEqual(m1.group(pattern["code"]), "L0005")
            self.assertEqual(m1.group(pattern["message"]), "uso de valor movido")

        # Test parser diagnostic format
        line2 = "compiler-l/src/lexer.l:22:1: error[PARSER]: se esperaba expresión"
        m2 = compiled_re.match(line2)
        self.assertIsNotNone(m2, f"Failed to match parser error: {line2}")
        self.assertEqual(m2.group(1), "compiler-l/src/lexer.l")
        self.assertEqual(m2.group(2), "22")
        self.assertEqual(m2.group(3), "1")
        code_idx = pattern.get("code")
        self.assertEqual(m2.group(code_idx), "PARSER")
        msg_idx = pattern.get("message")
        self.assertEqual(m2.group(msg_idx), "se esperaba expresión")

        # Test Windows path diagnostic
        line3 = r"C:\project\sub\module.l:101:12: error[L0001]: symbol not found"
        m3 = compiled_re.match(line3)
        self.assertIsNotNone(m3, f"Failed to match Windows path: {line3}")
        self.assertEqual(m3.group(1), r"C:\project\sub\module.l")
        self.assertEqual(m3.group(2), "101")
        self.assertEqual(m3.group(3), "12")
        self.assertEqual(m3.group(code_idx), "L0001")


class TestLanguageConfiguration(unittest.TestCase):
    def setUp(self):
        self.assertTrue(LANG_CONFIG_JSON.exists(), f"Missing {LANG_CONFIG_JSON}")
        with open(LANG_CONFIG_JSON, "r", encoding="utf-8") as f:
            self.cfg = json.load(f)

    def test_comments(self):
        comments = self.cfg.get("comments", {})
        self.assertEqual(comments.get("lineComment"), "//")
        self.assertEqual(comments.get("blockComment"), ["/*", "*/"])

    def test_brackets(self):
        brackets = self.cfg.get("brackets", [])
        self.assertIn(["{", "}"], brackets)
        self.assertIn(["(", ")"], brackets)
        self.assertIn(["[", "]"], brackets)

    def test_indentation_rules(self):
        indent = self.cfg.get("indentationRules", {})
        self.assertIn("increaseIndentPattern", indent)
        self.assertIn("decreaseIndentPattern", indent)
        inc_re = re.compile(indent["increaseIndentPattern"])
        dec_re = re.compile(indent["decreaseIndentPattern"])
        self.assertTrue(inc_re.match("flow test() => Int {"))
        self.assertTrue(dec_re.match("}"))


class TestTextMateGrammar(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SYNTAX_JSON.exists(), f"Missing {SYNTAX_JSON}")
        with open(SYNTAX_JSON, "r", encoding="utf-8") as f:
            self.grammar = json.load(f)
        self.repo = self.grammar.get("repository", {})

    def test_scope_and_name(self):
        self.assertEqual(self.grammar.get("scopeName"), "source.ele")
        self.assertEqual(self.grammar.get("name"), "ELE")
        self.assertIn("l", self.grammar.get("fileTypes", []))

    def test_ele_v2_keywords_present(self):
        # All required canonical ELE v2 keywords:
        v2_keywords = [
            "flow", "shape", "choice", "extend", "contract",
            "hold", "change", "fixed", "give", "when", "otherwise",
            "during", "repeat", "leave", "proceed", "this",
            "exclusive", "direct", "later", "wait", "launch",
            "take", "space", "zone", "expose", "view", "edit"
        ]

        keywords_repo = self.repo.get("keywords", {}).get("patterns", [])
        keyword_regexes = [re.compile(p["match"]) for p in keywords_repo if "match" in p]

        for kw in v2_keywords:
            matched = any(r.search(kw) for r in keyword_regexes)
            self.assertTrue(matched, f"Keyword '{kw}' not matched by any keywords pattern")

    def test_canonical_method_calls(self):
        method_patterns = self.repo.get("method_calls", {}).get("patterns", [])
        self.assertTrue(len(method_patterns) > 0, "Missing method_calls patterns")

        matched_rule = None
        for p in method_patterns:
            if "match" in p:
                r = re.compile(p["match"])
                # Test target@method()
                m = r.search("target@calculate(42)")
                if m:
                    matched_rule = (p, m)
                    break
                # Or standalone @method
                m2 = r.search("@ingresar(100)")
                if m2:
                    matched_rule = (p, m2)
                    break

        self.assertIsNotNone(matched_rule, "No method call regex matched canonical @method invocation")
        p, m = matched_rule
        captures = p.get("captures", {})
        # Group 1 should be method operator @
        self.assertIn("1", captures)
        self.assertIn("keyword.operator.method", captures["1"]["name"])
        # Group 2 should be method name
        self.assertIn("2", captures)
        self.assertIn("entity.name.function.method", captures["2"]["name"])

        # Test various receiver expressions
        test_calls = [
            "account@deposit(100)",
            "Point@origin()",
            "this@internal_step()",
            "c@leer()",
            "item@transform of[Int]()"
        ]
        r = re.compile(p["match"])
        for call in test_calls:
            self.assertTrue(r.search(call), f"Failed to match method call in: {call}")

    def test_generics_of_brackets(self):
        generics_patterns = self.repo.get("generics", {}).get("patterns", [])
        self.assertTrue(len(generics_patterns) > 0, "Missing generics pattern in repository")

        matched = False
        for p in generics_patterns:
            if "match" in p:
                r = re.compile(p["match"])
                if r.search("of[T]") and r.search("of [Int]"):
                    matched = True
                    break
        self.assertTrue(matched, "Generics pattern failed to match 'of[T]' construct")

    def test_string_interpolation(self):
        strings_patterns = self.repo.get("strings", {}).get("patterns", [])
        self.assertTrue(len(strings_patterns) > 0, "Missing strings patterns")
        double_quote_rule = strings_patterns[0]
        self.assertEqual(double_quote_rule.get("begin"), "\"")
        self.assertEqual(double_quote_rule.get("end"), "\"")

        inner_patterns = double_quote_rule.get("patterns", [])
        has_interpolation = any(
            p.get("name") == "meta.interpolation.ele" and
            p.get("begin") == "\\{" and
            p.get("end") == "\\}"
            for p in inner_patterns
        )
        self.assertTrue(has_interpolation, "Missing meta.interpolation.ele in string rule")

    def test_operators(self):
        operators = self.repo.get("operators", {}).get("patterns", [])
        op_regexes = [re.compile(p["match"]) for p in operators if "match" in p]

        test_ops = ["=>", "@", "==", "!=", "<=", ">=", "+", "-", "*", "/", "%", "&&", "||", "!", "=", "+=", "??"]
        for op in test_ops:
            matched = any(r.search(op) for r in op_regexes)
            self.assertTrue(matched, f"Operator '{op}' not covered by operators patterns")


class TestELEBindingHighlighting(unittest.TestCase):
    def setUp(self):
        self.syntax = json.loads(SYNTAX_JSON.read_text(encoding="utf-8"))
        self.repo = self.syntax["repository"]

    def test_binding_declarations_and_references(self):
        bindings = [re.compile(p["match"]) for p in self.repo["bindings"]["patterns"]]
        self.assertEqual(bindings[0].search("fixed MAX_WEIGHTS: Int = 4").group(2), "MAX_WEIGHTS")
        self.assertEqual(bindings[0].search("fixed timeout = 5").group(2), "timeout")
        self.assertEqual(bindings[1].search("hold input: [Float; 2]").group(2), "input")
        self.assertEqual(bindings[1].search("change weights = List[]").group(2), "weights")
        self.assertEqual(bindings[2].search("(post: Float").group(1), "post")
        named_constant = next(
            p["match"] for p in self.repo["constants"]["patterns"]
            if p["name"] == "constant.other.identifier.ele"
        )
        self.assertIsNotNone(re.search(named_constant, "MAX_WEIGHTS"))
        self.assertIsNone(re.search(named_constant, "Float"))
        member_rule = re.compile(self.repo["variables"]["patterns"][0]["match"])
        self.assertEqual(member_rule.search("column.activeCount").group(2), "activeCount")
        variable_rule = re.compile(self.repo["variables"]["patterns"][1]["match"])
        self.assertIsNotNone(variable_rule.search("weights"))
        self.assertIsNone(variable_rule.search("Float"))

    def test_priorities_and_mirrored_grammar(self):
        includes = [p["include"] for p in self.syntax["patterns"]]
        self.assertLess(includes.index("#bindings"), includes.index("#keywords"))
        self.assertLess(includes.index("#constants"), includes.index("#types"))
        self.assertGreater(includes.index("#variables"), includes.index("#functions"))
        root = json.loads(ROOT_SYNTAX_JSON.read_text(encoding="utf-8"))
        self.assertEqual(root, self.syntax)

    def test_graphite_binding_palette_is_distinct(self):
        pkg = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        theme = next(t for t in pkg["contributes"]["themes"] if t["label"] == "ELE Graphite Dark")
        colors = json.loads((EDITORS_DIR / theme["path"]).read_text(encoding="utf-8"))
        scopes = {
            scope: rule["settings"]["foreground"]
            for rule in colors["tokenColors"]
            for scope in (rule["scope"] if isinstance(rule["scope"], list) else [rule["scope"]])
        }
        roles = (
            "variable.other.declaration.ele",
            "variable.parameter.ele",
            "variable.other.member.ele",
            "variable.other.constant.declaration.ele",
        )
        actual = [scopes.get(scope) for scope in roles]
        self.assertNotIn(None, actual)
        self.assertEqual(len(set(actual)), len(actual))


class TestSnippets(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SNIPPETS_JSON.exists(), f"Missing {SNIPPETS_JSON}")
        with open(SNIPPETS_JSON, "r", encoding="utf-8") as f:
            self.snippets = json.load(f)

    def test_required_snippets_presence(self):
        # Snippets explicitly requested in P2 objective:
        required_prefixes = [
            "flow", "shape", "choice", "extend", "contract",
            "hold", "change", "fixed", "give", "when", "otherwise",
            "during", "each", "take", "expose"
        ]

        available_prefixes = {s.get("prefix") for s in self.snippets.values()}

        for prefix in required_prefixes:
            self.assertIn(prefix, available_prefixes, f"Missing required snippet prefix: '{prefix}'")

    def test_snippet_structure(self):
        for name, snippet in self.snippets.items():
            self.assertIn("prefix", snippet, f"Snippet '{name}' missing prefix")
            self.assertIn("body", snippet, f"Snippet '{name}' missing body")
            self.assertIn("description", snippet, f"Snippet '{name}' missing description")
            body = snippet["body"]
            self.assertTrue(
                isinstance(body, list) and len(body) > 0 or isinstance(body, str) and len(body) > 0,
                f"Snippet '{name}' body is empty"
            )


class TestELEGraphiteTheme(unittest.TestCase):
    def test_optional_theme_contribution_and_scopes(self):
        pkg = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        themes = pkg["contributes"].get("themes", [])
        graphite = next((theme for theme in themes if theme.get("label") == "ELE Graphite Dark"), None)
        self.assertIsNotNone(graphite, "Optional ELE Graphite Dark theme is missing")
        self.assertEqual(graphite["uiTheme"], "vs-dark")
        theme_path = (EDITORS_DIR / graphite["path"]).resolve()
        self.assertTrue(theme_path.is_relative_to(EDITORS_DIR.resolve()))
        self.assertTrue(theme_path.is_file(), "Color theme file must be bundled")
        theme = json.loads(theme_path.read_text(encoding="utf-8"))
        self.assertEqual(theme["type"], "dark")
        self.assertIn("editor.background", theme["colors"])
        scopes = set()
        for rule in theme["tokenColors"]:
            scope = rule.get("scope", [])
            scopes.update(scope if isinstance(scope, list) else [scope])
            self.assertRegex(rule["settings"]["foreground"], r"^#[0-9A-Fa-f]{6}$")
        for scope in (
            "keyword.declaration.ele",
            "keyword.control.ele",
            "storage.modifier.ownership.ele",
            "entity.name.function.method.ele",
            "support.type.primitive.ele",
            "constant.numeric.float.ele",
            "string.quoted.double.ele",
        ):
            self.assertIn(scope, scopes)


class TestELEBrandedIcons(unittest.TestCase):
    def test_language_and_extension_png_icons(self):
        pkg = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        self.assertEqual(pkg["version"], "0.1.6")
        logo = (EDITORS_DIR / pkg["icon"]).resolve()
        self.assertTrue(logo.is_relative_to(EDITORS_DIR.resolve()))
        self.assertTrue(logo.is_file())

        def dimensions(p):
            data = p.read_bytes()
            self.assertEqual(data[:8], bytes.fromhex("89504e470d0a1a0a"))
            return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")

        width, height = dimensions(logo)
        self.assertGreaterEqual(width, 128)
        self.assertGreaterEqual(height, 128)
        lang = next(l for l in pkg["contributes"]["languages"] if l["id"] == "ele")
        for appearance in ("light", "dark"):
            file_icon = (EDITORS_DIR / lang["icon"][appearance]).resolve()
            self.assertTrue(file_icon.is_relative_to(EDITORS_DIR.resolve()))
            self.assertTrue(file_icon.is_file())
            self.assertGreaterEqual(dimensions(file_icon)[0], 64)

    def test_file_icon_theme_mapping(self):
        pkg = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        contributions = pkg["contributes"]["iconThemes"]
        icon_theme = next(t for t in contributions if t["id"] == "ele-file-icons")
        theme_path = (EDITORS_DIR / icon_theme["path"]).resolve()
        self.assertTrue(theme_path.is_relative_to(EDITORS_DIR.resolve()))
        theme = json.loads(theme_path.read_text(encoding="utf-8"))
        self.assertEqual(theme["fileExtensions"]["l"], "_ele_source")
        self.assertEqual(theme["languageIds"]["ele"], "_ele_source")
        image_path = (theme_path.parent / theme["iconDefinitions"]["_ele_source"]["iconPath"]).resolve()
        self.assertTrue(image_path.is_relative_to(EDITORS_DIR.resolve()))
        self.assertTrue(image_path.is_file())
        self.assertEqual(image_path.suffix, ".svg")
        svg = image_path.read_text(encoding="utf-8")
        self.assertIn("<svg ", svg)
        self.assertIn('viewBox="0 0 64 64"', svg)
        self.assertIn("#0EADA8", svg)
        self.assertIn("#FFFFFF", svg)
        self.assertNotIn("filter=", svg)
        fallback = (EDITORS_DIR / pkg["contributes"]["languages"][0]["icon"]["dark"]).resolve()
        self.assertTrue(fallback.is_file())
        self.assertEqual(fallback.suffix, ".png")
        self.assertEqual(fallback.name, "ele-icon-v016.png")
        self.assertEqual(image_path.name, "ele-icon-v016.svg")


if __name__ == "__main__":
    unittest.main()
