// Verification test script for VS Code ELE extension manifests and syntax
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const rootDir = __dirname;
const pkgPath = path.join(rootDir, 'package.json');
const langCfgPath = path.join(rootDir, 'language-configuration.json');
const syntaxPath = path.join(rootDir, 'syntaxes', 'ele.tmLanguage.json');
const snippetsPath = path.join(rootDir, 'snippets', 'ele.json');

console.log('Testing VS Code ELE extension files...');

// 1. package.json
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
assert.strictEqual(pkg.name, 'ele-vscode', 'package.json name must be ele-vscode');
assert.ok(pkg.contributes.languages.some(l => l.id === 'ele' && l.extensions.includes('.l')), 'ele language contribution missing');
assert.ok(pkg.contributes.grammars.some(g => g.language === 'ele'), 'grammar contribution missing');
assert.ok(pkg.contributes.snippets.some(s => s.language === 'ele'), 'snippets contribution missing');

// Problem Matcher test
const problemMatcher = pkg.contributes.problemMatchers.find(m => m.name === 'ele');
assert.ok(problemMatcher, 'ele problemMatcher missing');
const diagRegex = new RegExp(problemMatcher.pattern.regexp);

const diagLine = 'src/main.l:10:4: error[L0005]: uso de valor movido';
const matchDiag = diagLine.match(diagRegex);
assert.ok(matchDiag, 'Diagnostic line must match problemMatcher regexp');
assert.strictEqual(matchDiag[1], 'src/main.l');
assert.strictEqual(matchDiag[2], '10');
assert.strictEqual(matchDiag[3], '4');

const parserLine = 'src/test.l:1:1: error[PARSER]: se esperaba expresión';
const matchParser = parserLine.match(diagRegex);
assert.ok(matchParser, 'Parser error line must match problemMatcher regexp');

// 2. language-configuration.json
const langCfg = JSON.parse(fs.readFileSync(langCfgPath, 'utf8'));
assert.strictEqual(langCfg.comments.lineComment, '//');
assert.deepStrictEqual(langCfg.comments.blockComment, ['/*', '*/']);

// 3. syntaxes/ele.tmLanguage.json
const syntax = JSON.parse(fs.readFileSync(syntaxPath, 'utf8'));
assert.strictEqual(syntax.scopeName, 'source.ele');
assert.ok(syntax.repository.method_calls, 'method_calls missing in grammar repository');

const methodPattern = syntax.repository.method_calls.patterns[0].match;
const methodRegex = new RegExp(methodPattern);
const testCall = 'target@compute(42)';
assert.ok(methodRegex.test(testCall), 'target@compute(42) must match canonical method call');

// Verify keywords
const v2Keywords = [
  'flow', 'shape', 'choice', 'extend', 'contract',
  'hold', 'change', 'fixed', 'give', 'when', 'otherwise',
  'during', 'repeat', 'leave', 'proceed', 'this',
  'exclusive', 'direct', 'later', 'wait', 'launch',
  'take', 'space', 'zone', 'expose', 'view', 'edit'
];

const keywordPatterns = syntax.repository.keywords.patterns.map(p => new RegExp(p.match));
for (const kw of v2Keywords) {
  const matched = keywordPatterns.some(r => r.test(kw));
  assert.ok(matched, `Keyword ${kw} must be matched in grammar`);
}

// 4. snippets/ele.json
const snippets = JSON.parse(fs.readFileSync(snippetsPath, 'utf8'));
const requiredSnippets = [
  'flow', 'shape', 'choice', 'extend', 'contract',
  'hold', 'change', 'fixed', 'give', 'when', 'otherwise',
  'during', 'each', 'take', 'expose'
];
const snippetPrefixes = Object.values(snippets).map(s => s.prefix);
for (const prefix of requiredSnippets) {
  assert.ok(snippetPrefixes.includes(prefix), `Snippet prefix ${prefix} missing`);
}

console.log('All VS Code ELE extension validations passed successfully!');
