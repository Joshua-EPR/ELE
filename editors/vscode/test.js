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

// 5. The optional ELE Graphite Dark theme is packaged and scopes match ELE grammar.
const themeContribution = pkg.contributes.themes.find(t => t.label === 'ELE Graphite Dark');
assert.ok(themeContribution, 'ELE Graphite Dark must be registered as an optional theme');
assert.strictEqual(themeContribution.uiTheme, 'vs-dark');
const themePath = path.resolve(rootDir, themeContribution.path);
assert.ok(fs.existsSync(themePath), 'theme file must exist inside the extension');
const theme = JSON.parse(fs.readFileSync(themePath, 'utf8'));
assert.strictEqual(theme.name, 'ELE Graphite Dark');
assert.strictEqual(theme.type, 'dark');
assert.ok(theme.colors['editor.background'], 'theme needs editor background');
const themeScopes = theme.tokenColors.flatMap(r => Array.isArray(r.scope) ? r.scope : [r.scope]);
for (const scope of [
  'keyword.declaration.ele',
  'keyword.control.ele',
  'storage.modifier.ownership.ele',
  'entity.name.function.method.ele',
  'support.type.primitive.ele',
  'constant.numeric.float.ele',
  'string.quoted.double.ele'
]) {
  assert.ok(themeScopes.includes(scope), `ELE theme is missing scope ${scope}`);
}
for (const [token, color] of Object.entries(theme.colors)) {
  if (typeof color === 'string' && color.startsWith('#')) {
    assert.match(color, /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/, `Invalid color for ${token}`);
  }
}
for (const rule of theme.tokenColors) {
  assert.match(rule.settings.foreground, /^#[0-9a-fA-F]{6}$/, 'Invalid foreground in token rule');
}

// 6. ELE binding scopes: keep keywords, methods, types and strings intact.
const bindingPatterns = syntax.repository.bindings.patterns;
const constDecl = 'fixed MAX_WEIGHTS: Int = 4'.match(new RegExp(bindingPatterns[0].match));
const holdDecl = 'hold input: [Float; 2]'.match(new RegExp(bindingPatterns[1].match));
const changeDecl = 'change weights = List[]'.match(new RegExp(bindingPatterns[1].match));
const parameter = '(value: Float'.match(new RegExp(bindingPatterns[2].match));
assert.strictEqual(constDecl?.[2], 'MAX_WEIGHTS');
assert.strictEqual(holdDecl?.[2], 'input');
assert.strictEqual(changeDecl?.[2], 'weights');
assert.strictEqual(parameter?.[1], 'value');
const namedConstant = new RegExp(syntax.repository.constants.patterns.find(p => p.name === 'constant.other.identifier.ele').match);
assert.ok(namedConstant.test('MAX_WEIGHTS'), 'named constant references should be highlighted');
assert.ok(!namedConstant.test('Float'), 'primitive type must not be treated as named constant');
const variableRules = syntax.repository.variables.patterns;
const member = 'column.activeCount'.match(new RegExp(variableRules[0].match));
assert.strictEqual(member?.[2], 'activeCount');
const variableRef = new RegExp(variableRules[1].match);
assert.ok(variableRef.test('weights'), 'variable references should be recognized');
assert.ok(!variableRef.test('Int'), 'type names should not match variable fallback');

const includes = s => themeScopes.includes(s);
for (const scope of [
  'variable.other.constant.declaration.ele',
  'constant.other.identifier.ele',
  'variable.other.declaration.ele',
  'variable.other.readwrite.ele',
  'variable.other.member.ele',
  'variable.parameter.ele'
]) {
  assert.ok(includes(scope), `Graphite Dark theme missing new ELE scope: ${scope}`);
}
const palette = ['ELE local variables','ELE parameters','ELE member fields','ELE named constants']
  .map(name => theme.tokenColors.find(r => r.name === name)?.settings.foreground);
assert.strictEqual(new Set(palette).size, 4, 'variables, parameters, fields and constants require distinct colors');
assert.ok(palette.every(Boolean), 'all binding roles must have colors');
const grammarOrder = syntax.patterns.map(p => p.include);
assert.ok(grammarOrder.indexOf('#bindings') < grammarOrder.indexOf('#keywords'), 'binding declarations must be captured before keywords');
assert.ok(grammarOrder.indexOf('#constants') < grammarOrder.indexOf('#types'), 'uppercase constant identifiers need precedence over broad type pattern');
assert.ok(grammarOrder.indexOf('#variables') > grammarOrder.indexOf('#functions'), 'function names must not become variables');
const mirror = JSON.parse(fs.readFileSync(path.resolve(rootDir, '../../syntaxes/ele.tmLanguage.json'), 'utf8'));
assert.deepStrictEqual(syntax, mirror, 'root TextMate grammar must remain identical to VS Code extension grammar');

// 7. ELE language/logo and source icon assets must be genuine bundled PNG files.
function bundledPath(relativePath) {
  const asset = path.resolve(rootDir, relativePath);
  assert.ok(asset.startsWith(rootDir + path.sep), 'Asset must stay inside extension root');
  assert.ok(fs.existsSync(asset), `Missing extension asset: ${relativePath}`);
  return asset;
}
function pngDimensions(relativePath) {
  const image = fs.readFileSync(bundledPath(relativePath));
  assert.ok(image.length > 32, 'PNG must contain nonempty image data');
  assert.ok(image.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a','hex')), `Invalid PNG signature: ${relativePath}`);
  return {width:image.readUInt32BE(16),height:image.readUInt32BE(20)};
}
const extensionLogo = pngDimensions(pkg.icon);
assert.ok(extensionLogo.width >= 128 && extensionLogo.height >= 128, 'VS Code extension marketplace icon must be at least 128x128');
const eleLanguage = pkg.contributes.languages.find(l => l.id === 'ele');
assert.ok(eleLanguage.icon, 'ELE language must define fallback file icons');
const lightFileIcon = pngDimensions(eleLanguage.icon.light);
const darkFileIcon = pngDimensions(eleLanguage.icon.dark);
assert.ok(lightFileIcon.width >= 64 && darkFileIcon.width >= 64, 'ELE source file icon must remain legible');
const eleThemeContribution = pkg.contributes.iconThemes.find(t => t.id === 'ele-file-icons');
assert.ok(eleThemeContribution, 'Missing opt-in ELE File Icons theme contribution');
const iconTheme = JSON.parse(fs.readFileSync(bundledPath(eleThemeContribution.path), 'utf8'));
assert.strictEqual(iconTheme.fileExtensions.l, '_ele_source');
assert.strictEqual(iconTheme.languageIds.ele, '_ele_source');
const imgRef = iconTheme.iconDefinitions._ele_source.iconPath;
const resolvedFileIcon = path.resolve(path.dirname(bundledPath(eleThemeContribution.path)),imgRef);
assert.strictEqual(path.extname(resolvedFileIcon), '.svg', 'Explorer icons must be resolution-independent SVG');
assert.ok(fs.existsSync(resolvedFileIcon), 'Scalable ELE File Icons asset must be bundled');
const svg = fs.readFileSync(resolvedFileIcon, 'utf8');
assert.ok(svg.includes('<svg '), 'ELE file icon must contain an SVG root');
assert.match(svg, /viewBox="0 0 128 128"/, 'ELE file icon must declare its viewBox');
assert.match(svg, /#70C7BE/, 'ELE file icon must contain the bold teal E mark');
assert.strictEqual(darkFileIcon.width, 128, 'Fallback file icon must be 128px');
assert.strictEqual(darkFileIcon.height, 128, 'Fallback file icon must be square');
assert.strictEqual(eleLanguage.icon.light, eleLanguage.icon.dark, 'Icon fallback must work in both themes');
assert.strictEqual(pkg.version, '0.1.5', 'Branded extension must carry the new version');
assert.strictEqual(extensionLogo.width, 256, 'Logo must be 256 pixels for VS Code');
assert.strictEqual(extensionLogo.height, 256, 'Logo must be square');
assert.ok(fs.statSync(bundledPath(pkg.icon)).size < 16384, 'Minimal ELE emblem should stay lightweight');

console.log('All VS Code ELE extension validations passed successfully!');
