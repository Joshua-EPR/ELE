use crate::{Diagnostic, Span};

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Word(String),
    Int(i64),
    IntMinMagnitude,
    Float(f64),
    Text(String),
    TextStart,
    TextEnd,
    InterpolationStart,
    InterpolationEnd,
    Sym(String),
    Newline,
    Eof,
}
#[derive(Debug, Clone)]
pub struct Token {
    pub kind: Kind,
    pub span: Span,
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
    line: usize,
    column: usize,
    tokens: Vec<Token>,
    depth: usize,
}
impl Lexer {
    fn span(&self) -> Span {
        Span {
            line: self.line,
            column: self.column,
        }
    }
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }
    fn pair(&self, a: char, b: char) -> bool {
        self.peek() == Some(a) && self.chars.get(self.pos + 1) == Some(&b)
    }
    fn bump(&mut self) {
        if let Some(c) = self.peek() {
            self.pos += 1;
            if c == '\n' {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
        }
    }
    fn emit(&mut self, kind: Kind, span: Span) -> Result<(), Diagnostic> {
        if self.tokens.len() >= 4096 {
            return Err(Diagnostic::new(
                span,
                "límite CORE-1 de 4096 tokens excedido",
            ));
        }
        self.tokens.push(Token { kind, span });
        Ok(())
    }
    fn scan(&mut self, interpolation: Option<Span>) -> Result<(), Diagnostic> {
        let mut braces = 0usize;
        while let Some(c) = self.peek() {
            let span = self.span();
            if interpolation.is_some() && c == '}' && braces == 0 {
                self.bump();
                self.emit(Kind::InterpolationEnd, span)?;
                return Ok(());
            }
            if c == '\n' {
                self.bump();
                self.emit(Kind::Newline, span)?;
                continue;
            }
            if c.is_whitespace() {
                self.bump();
                continue;
            }
            if self.pair('/', '/') {
                while self.peek().is_some_and(|c| c != '\n') {
                    self.bump();
                }
                continue;
            }
            if self.pair('/', '*') {
                self.bump();
                self.bump();
                let mut depth = 1;
                while self.peek().is_some() && depth > 0 {
                    if self.pair('/', '*') {
                        depth += 1;
                        self.bump();
                        self.bump();
                    } else if self.pair('*', '/') {
                        depth -= 1;
                        self.bump();
                        self.bump();
                    } else {
                        if self.peek() == Some('\n') {
                            self.emit(Kind::Newline, self.span())?;
                        }
                        self.bump();
                    }
                }
                if depth != 0 {
                    return Err(Diagnostic::new(span, "comentario sin cerrar"));
                }
                continue;
            }
            if c == '"' {
                self.string()?;
                continue;
            }
            let start = self.pos;
            let kind = if c.is_ascii_alphabetic() || c == '_' {
                self.bump();
                while self
                    .peek()
                    .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    self.bump();
                }
                Kind::Word(self.chars[start..self.pos].iter().collect())
            } else if c.is_ascii_digit() {
                self.number(span)?
            } else {
                let pair: String = self.chars[self.pos..self.chars.len().min(self.pos + 2)]
                    .iter()
                    .collect();
                if self.pair('.', '.') && self.chars.get(self.pos + 2) == Some(&'=') {
                    self.bump();
                    self.bump();
                    self.bump();
                    Kind::Sym("..=".into())
                } else if [
                    "->", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "..",
                    "=>", "??",
                ]
                .contains(&pair.as_str())
                {
                    self.bump();
                    self.bump();
                    Kind::Sym(pair)
                } else if "(){}[]:;,=+-*/%!<>.?&@".contains(c) {
                    if c == '{' {
                        braces += 1;
                    }
                    if c == '}' {
                        braces = braces.saturating_sub(1);
                    }
                    self.bump();
                    Kind::Sym(c.to_string())
                } else {
                    return Err(Diagnostic::new(
                        span,
                        format!("carácter no implementado o inválido: {c}"),
                    ));
                }
            };
            self.emit(kind, span)?;
        }
        if let Some(open) = interpolation {
            return Err(Diagnostic::new(open, "interpolación sin cerrar: falta '}'"));
        }
        Ok(())
    }
    fn number(&mut self, span: Span) -> Result<Kind, Diagnostic> {
        let start = self.pos;
        self.bump();
        while self.peek().is_some_and(|c| c.is_ascii_digit() || c == '_') {
            self.bump();
        }
        let mut float = false;
        if self.peek() == Some('.')
            && self
                .chars
                .get(self.pos + 1)
                .is_some_and(char::is_ascii_digit)
        {
            float = true;
            self.bump();
            while self.peek().is_some_and(|c| c.is_ascii_digit() || c == '_') {
                self.bump();
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            float = true;
            self.bump();
            if matches!(self.peek(), Some('+' | '-')) {
                self.bump();
            }
            while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                self.bump();
            }
        }
        let value: String = self.chars[start..self.pos]
            .iter()
            .filter(|c| **c != '_')
            .collect();
        if float {
            let n: f64 = value
                .parse()
                .map_err(|_| Diagnostic::new(span, "Float inválido"))?;
            if !n.is_finite() {
                return Err(Diagnostic::new(span, "literal Float fuera de rango"));
            }
            Ok(Kind::Float(n))
        } else if value == "9223372036854775808" {
            Ok(Kind::IntMinMagnitude)
        } else {
            Ok(Kind::Int(value.parse().map_err(|_| {
                Diagnostic::new(span, "Int fuera de rango o inválido")
            })?))
        }
    }
    fn escape(&mut self) -> Result<char, Diagnostic> {
        let span = self.span();
        self.bump();
        let c = match self.peek() {
            Some('n') => '\n',
            Some('t') => '\t',
            Some('r') => '\r',
            Some('"') => '"',
            Some('\\') => '\\',
            Some('u') => {
                self.bump();
                if self.peek() != Some('{') {
                    return Err(Diagnostic::new(span, "escape Unicode requiere \\u{HEX}"));
                }
                self.bump();
                let start = self.pos;
                while self.peek().is_some_and(|c| c.is_ascii_hexdigit()) {
                    self.bump();
                }
                if self.pos == start || self.pos - start > 6 || self.peek() != Some('}') {
                    return Err(Diagnostic::new(span, "escape Unicode inválido"));
                }
                let hex: String = self.chars[start..self.pos].iter().collect();
                u32::from_str_radix(&hex, 16)
                    .ok()
                    .and_then(char::from_u32)
                    .ok_or_else(|| Diagnostic::new(span, "scalar Unicode inválido"))?
            }
            _ => return Err(Diagnostic::new(span, "escape no implementado o inválido")),
        };
        self.bump();
        Ok(c)
    }
    fn string(&mut self) -> Result<(), Diagnostic> {
        let open = self.span();
        self.depth += 1;
        if self.depth > 64 {
            return Err(Diagnostic::new(
                open,
                "límite de anidamiento Text (64) excedido",
            ));
        }
        self.bump();
        let mut literal_span = self.span();
        let mut literal = String::new();
        let mut interpolated = false;
        while let Some(c) = self.peek() {
            match c {
                '"' => {
                    let close = self.span();
                    self.bump();
                    if interpolated {
                        self.emit(Kind::Text(literal), literal_span)?;
                        self.emit(Kind::TextEnd, close)?;
                    } else {
                        self.emit(Kind::Text(literal), open)?;
                    }
                    self.depth -= 1;
                    return Ok(());
                }
                '\n' | '\r' => return Err(Diagnostic::new(open, "cadena sin cerrar")),
                '\\' => literal.push(self.escape()?),
                '{' if self.pair('{', '{') => {
                    literal.push('{');
                    self.bump();
                    self.bump();
                }
                '}' if self.pair('}', '}') => {
                    literal.push('}');
                    self.bump();
                    self.bump();
                }
                '{' => {
                    if !interpolated {
                        self.emit(Kind::TextStart, open)?;
                        interpolated = true;
                    }
                    self.emit(Kind::Text(std::mem::take(&mut literal)), literal_span)?;
                    let brace = self.span();
                    self.bump();
                    self.emit(Kind::InterpolationStart, brace)?;
                    self.scan(Some(brace)).map_err(|e| {
                        if self.peek().is_none() {
                            Diagnostic::new(
                                brace,
                                format!("interpolación sin cerrar: {}", e.message),
                            )
                        } else {
                            e
                        }
                    })?;
                    literal_span = self.span();
                }
                '}' => {
                    return Err(Diagnostic::new(
                        self.span(),
                        "llave '}' sin apertura en Text; use '}}' para una llave literal",
                    ));
                }
                _ => {
                    literal.push(c);
                    self.bump();
                }
            }
        }
        Err(Diagnostic::new(open, "cadena sin cerrar"))
    }
}

pub fn lex(source: &str) -> Result<Vec<Token>, Diagnostic> {
    let mut lexer = Lexer {
        chars: source.chars().collect(),
        pos: 0,
        line: 1,
        column: 1,
        tokens: Vec::new(),
        depth: 0,
    };
    lexer
        .scan(None)
        .and_then(|()| lexer.emit(Kind::Eof, lexer.span()))
        .map_err(|e| e.classify("L0002", "léxico"))?;
    Ok(lexer.tokens)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interpolation_delimiters_and_positions() {
        let tokens = lex("\"á{x+1}\"").unwrap();
        assert!(matches!(tokens[0].kind, Kind::TextStart));
        assert!(matches!(tokens[2].kind, Kind::InterpolationStart));
        assert!(matches!(&tokens[3].kind, Kind::Word(s) if s == "x"));
        assert_eq!(tokens[3].span, Span { line: 1, column: 4 });
        assert!(matches!(tokens[6].kind, Kind::InterpolationEnd));
    }
    #[test]
    fn escaped_braces_remain_plain_text() {
        let tokens = lex(r#""{{x}} \u{7b}y\u{7d}""#).unwrap();
        assert!(matches!(&tokens[0].kind, Kind::Text(s) if s == "{x} {y}"));
        assert_eq!(tokens.len(), 2);
    }
}
