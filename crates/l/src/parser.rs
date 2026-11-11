use crate::{
    Diagnostic, Span,
    effects::{Attribute, Effect, EffectSet, EffectsAnnotation},
    lexer::{Kind, Token},
};

pub use crate::lir::Type;

/// Syntactic type. Named types are resolved by semantic analysis.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeExpr {
    Prim(Type),
    /// Name with type arguments (`Option<Int>`); `T?` is `Option<T>`.
    Named(String, Vec<TypeExpr>, Span),
    /// Reference type: `&T` (mutable=false) or `&mut T` (mutable=true).
    Ref(Box<TypeExpr>, bool, Span),
    /// `[T; N]`: fixed-size array.
    Array(Box<TypeExpr>, usize, Span),
    /// `[T]`: slice element type, only valid behind `&`/`&mut` in a parameter.
    Slice(Box<TypeExpr>, Span),
}

#[derive(Debug, Clone)]
pub struct Pattern {
    pub kind: PatternKind,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub enum PatternKind {
    Wild,
    /// Binding, or an unqualified prelude unit variant such as `None`.
    Name(String),
    Int(i64),
    Float(f64),
    Bool(bool),
    Text(String),
    /// Optional qualifier (`Estado.`), variant name, sub-patterns.
    Variant(Option<String>, String, Vec<Pattern>),
}
#[derive(Debug, Clone)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: Vec<Stmt>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeParam {
    pub name: String,
    pub bound: Option<String>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub enum ExprKind {
    Int(i64),
    Float(f64),
    Bool(bool),
    Unit,
    Text(String),
    Interpolate(Vec<Expr>),
    Name(String),
    Call(String, Vec<Expr>),
    GenericCall(String, Vec<TypeExpr>, Vec<Expr>),
    /// `name: value` argument; only valid inside a struct constructor call.
    Named(String, Box<Expr>),
    Field(Box<Expr>, String),
    MethodCall(Box<Expr>, String, Vec<Expr>),
    GenericMethodCall(Box<Expr>, String, Vec<TypeExpr>, Vec<Expr>),
    Match(Box<Expr>, Vec<MatchArm>),
    /// Postfix `?` propagation.
    Try(Box<Expr>),
    /// `await expr`: polls the future until it is ready, suspending the
    /// enclosing async function while it is pending.
    Await(Box<Expr>),
    /// `spawn f(args)`: schedules the async call as an independent task.
    Spawn(Box<Expr>),
    /// `[a, b, c]`: fixed-size array literal.
    ArrayLit(Vec<Expr>),
    /// `List[a, b, c]`: dynamic list literal.
    ListLit(Vec<Expr>),
    /// `base[index]`.
    Index(Box<Expr>, Box<Expr>),
    Unary(String, Box<Expr>),
    Binary(String, Box<Expr>, Box<Expr>),
}
#[derive(Debug, Clone)]
pub enum Stmt {
    Let(String, bool, Option<TypeExpr>, Expr),
    Const(Constant),
    /// Target (name or field chain), operator, value, span.
    Assign(Expr, String, Expr, Span),
    Expr(Expr, bool),
    Return(Expr),
    If(Expr, Vec<Stmt>, Vec<Stmt>, bool),
    While(Expr, Vec<Stmt>),
    /// `for name in start..end` / `..=` (inclusive flag), body.
    For(String, Span, Expr, Expr, bool, Vec<Stmt>),
    Loop(Vec<Stmt>),
    Break(Span),
    Continue(Span),
    Block(Vec<Stmt>, bool),
    /// `for nombre in colección`: name, span, iterated expression, body.
    ForEach(String, Span, Expr, Vec<Stmt>),
    /// `region nombre { ... }`: name, span of the name, body.
    Region(String, Span, Vec<Stmt>),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FnKind {
    Free,
    /// `fn` inside `impl`: implicit `self` shared borrow.
    Method,
    /// `mut fn` inside `impl`: implicit `self` exclusive borrow.
    MutMethod,
    /// `static fn` inside `impl`: no `self`.
    Static,
}
#[derive(Debug, Clone)]
pub struct Function {
    pub name: String,
    pub public: bool,
    /// `async fn`: calling it builds a future instead of running the body.
    pub is_async: bool,
    pub kind: FnKind,
    pub type_params: Vec<TypeParam>,
    pub params: Vec<(String, TypeExpr, Span)>,
    /// `None` when `-> T` is omitted: the result type is inferred from the body.
    pub result: Option<TypeExpr>,
    pub effects: Option<EffectsAnnotation>,
    pub attributes: Vec<Attribute>,
    pub body: Vec<Stmt>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct Field {
    pub name: String,
    pub public: bool,
    pub ty: TypeExpr,
    pub default: Option<Expr>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct StructDecl {
    pub name: String,
    pub public: bool,
    pub params: Vec<TypeParam>,
    pub fields: Vec<Field>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct Variant {
    pub name: String,
    pub payload: Vec<TypeExpr>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct EnumDecl {
    pub name: String,
    pub public: bool,
    pub params: Vec<String>,
    pub variants: Vec<Variant>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct TraitDecl {
    pub name: String,
    pub public: bool,
    pub params: Vec<TypeParam>,
    pub methods: Vec<Function>,
    pub span: Span,
}
#[derive(Debug, Clone)]
pub struct ImplDecl {
    pub params: Vec<TypeParam>,
    pub trait_name: Option<String>,
    pub target: String,
    pub target_args: Vec<TypeExpr>,
    pub methods: Vec<Function>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Constant {
    pub name: String,
    pub public: bool,
    pub annotation: Option<TypeExpr>,
    pub value: Expr,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct ImportDecl {
    pub path: String,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct Program {
    pub imports: Vec<ImportDecl>,
    pub functions: Vec<Function>,
    pub constants: Vec<Constant>,
    pub structs: Vec<StructDecl>,
    pub enums: Vec<EnumDecl>,
    pub traits: Vec<TraitDecl>,
    pub impls: Vec<ImplDecl>,
}

/// Original ELE surface spellings; historic tokens remain accepted during
/// bootstrap migration. AST/LIR identities do not change.
fn canonical_ele_keyword(word: &str) -> &str {
    match word {
        "flow" => "fn",
        "shape" => "struct",
        "extend" => "impl",
        "choice" => "enum",
        "contract" => "trait",
        "expose" => "pub",
        "hold" => "let",
        "change" => "var",
        "fixed" => "const",
        "give" => "return",
        "choose" => "match",
        "when" => "if",
        "otherwise" => "else",
        "each" => "for",
        "among" => "in",
        "during" => "while",
        "repeat" => "loop",
        "leave" => "break",
        "proceed" => "continue",
        "this" => "self",
        "exclusive" => "mut",
        "direct" => "static",
        "later" => "async",
        "wait" => "await",
        "launch" => "spawn",
        "take" => "import",
        "space" => "module",
        "zone" => "region",
        _ => word,
    }
}

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    depth: usize,
    parens: usize,
}
impl Parser {
    fn token(&self) -> &Token {
        &self.tokens[self.pos.min(self.tokens.len() - 1)]
    }
    fn at(&self, s: &str) -> bool {
        match &self.token().kind {
            Kind::Word(x) => x == s || canonical_ele_keyword(x) == s,
            Kind::Sym(x) => x == s,
            _ => false,
        }
    }
    fn take(&mut self, s: &str) -> bool {
        if self.at(s) {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn error(&self, msg: impl Into<String>) -> Diagnostic {
        Diagnostic::new(self.token().span, msg)
    }
    fn need(&mut self, s: &str) -> Result<(), Diagnostic> {
        if self.take(s) {
            Ok(())
        } else {
            Err(self.error(format!("se esperaba '{s}'")))
        }
    }
    fn nl(&mut self) {
        while matches!(self.token().kind, Kind::Newline) {
            self.pos += 1;
        }
    }
    fn sep(&mut self) {
        while self.take(";") || matches!(self.token().kind, Kind::Newline) {
            if matches!(self.token().kind, Kind::Newline) {
                self.pos += 1;
            }
        }
    }
    fn name(&mut self) -> Result<String, Diagnostic> {
        if let Kind::Word(s) = self.token().kind.clone() {
            if [
                "fn", "let", "var", "const", "struct", "impl", "trait", "enum", "module", "import",
                "pub", "return", "if", "else", "match", "for", "in", "while", "loop", "break",
                "continue", "async", "await", "spawn", "mut", "static", "unsafe", "region",
                "extern", "as", "true", "false", "None", "move", "self", "view", "edit",
            ]
            .contains(&canonical_ele_keyword(&s))
            {
                return Err(self.error("se esperaba identificador, no palabra reservada"));
            }
            self.pos += 1;
            Ok(s)
        } else {
            Err(self.error("se esperaba identificador"))
        }
    }
    /// Variant or member name: an identifier, or reserved words usable as members (e.g. `None`, `spawn`).
    fn member(&mut self) -> Result<String, Diagnostic> {
        if self.take("None") {
            Ok("None".into())
        } else if self.take("spawn") {
            Ok("spawn".into())
        } else {
            self.name()
        }
    }
    /// Like `name`, but also accepts `self` (resolved semantically).
    fn name_or_self(&mut self) -> Result<String, Diagnostic> {
        if self.take("self") {
            Ok("self".into())
        } else {
            self.name()
        }
    }
    fn ty(&mut self) -> Result<TypeExpr, Diagnostic> {
        let mut t = self.ty_atom()?;
        // In type position `??` (one token) is two `?` suffixes.
        while self.at("?") || self.at("??") {
            let span = self.token().span;
            let layers = if self.take("??") { 2 } else { 1 };
            self.pos += usize::from(layers == 1);
            for _ in 0..layers {
                t = TypeExpr::Named("Option".into(), vec![t], span);
            }
        }
        Ok(t)
    }
    fn ty_atom(&mut self) -> Result<TypeExpr, Diagnostic> {
        self.depth += 1;
        if self.depth > 128 {
            return Err(self.error("límite de anidamiento (128) excedido"));
        }
        let result = self.ty_inner();
        self.depth -= 1;
        result
    }
    fn ty_inner(&mut self) -> Result<TypeExpr, Diagnostic> {
        if self.take("view") {
            let span = self.tokens[self.pos - 1].span;
            return Ok(TypeExpr::Ref(Box::new(self.ty()?), false, span));
        }
        if self.take("edit") {
            let span = self.tokens[self.pos - 1].span;
            return Ok(TypeExpr::Ref(Box::new(self.ty()?), true, span));
        }
        if self.take("&") {
            let span = self.tokens[self.pos - 1].span;
            let mutable = self.take("mut");
            let inner = self.ty()?;
            return Ok(TypeExpr::Ref(Box::new(inner), mutable, span));
        }
        if self.at("[") {
            let span = self.token().span;
            self.pos += 1;
            let elem = self.ty()?;
            if self.take(";") {
                let len = match self.token().kind {
                    Kind::Int(n) if n >= 0 => n as usize,
                    _ => {
                        return Err(
                            self.error("se esperaba la longitud del array (entero literal)")
                        );
                    }
                };
                self.pos += 1;
                self.need("]")?;
                return Ok(TypeExpr::Array(Box::new(elem), len, span));
            }
            self.need("]")?;
            return Ok(TypeExpr::Slice(Box::new(elem), span));
        }
        let prim = if self.take("Int") {
            Type::Int
        } else if self.take("Float") || self.take("f64") {
            Type::Float
        } else if self.take("f32") {
            Type::F32
        } else if self.take("Bool") {
            Type::Bool
        } else if self.take("Text") {
            Type::Text
        } else if self.take("(") {
            self.need(")")?;
            Type::Unit
        } else if matches!(&self.token().kind, Kind::Word(w) if w.starts_with(|c: char| c.is_ascii_uppercase()))
        {
            let span = self.token().span;
            let name = self.name()?;
            let mut args = Vec::new();
            if self.take("<") {
                loop {
                    args.push(self.ty()?);
                    if self.take(">") {
                        break;
                    }
                    self.need(",")?;
                }
            }
            if self.at("[") {
                return Err(self.error("feature not implemented: arrays"));
            }
            return Ok(TypeExpr::Named(name, args, span));
        } else {
            return Err(self.error(
                "feature not implemented: tipo; soportados Int/Float/Bool/Text/(), struct y enum",
            ));
        };
        Ok(TypeExpr::Prim(prim))
    }

    fn parse_type_params(&mut self) -> Result<Vec<TypeParam>, Diagnostic> {
        let mut params = Vec::new();
        if self.take("<") {
            loop {
                self.nl();
                let span = self.token().span;
                let name = self.name()?;
                let bound = if self.take(":") {
                    self.nl();
                    Some(self.name()?)
                } else {
                    None
                };
                params.push(TypeParam { name, bound, span });
                self.nl();
                if self.take(">") {
                    break;
                }
                self.need(",")?;
                self.nl();
                if self.take(">") {
                    break;
                }
            }
        }
        Ok(params)
    }

    fn attribute(&mut self) -> Result<Attribute, Diagnostic> {
        let span = self.token().span;
        self.need("@")?;
        let name = self.name()?;
        match name.as_str() {
            "noalloc" => Ok(Attribute::NoAlloc(span)),
            _ => Err(self.error(format!(
                "atributo desconocido: @{name}. Atributos válidos: @noalloc"
            ))),
        }
    }

    fn effects_annotation(&mut self) -> Result<EffectsAnnotation, Diagnostic> {
        let span = self.token().span;
        self.need("!")?;
        self.need("{")?;
        let mut set = EffectSet::default();
        self.nl();
        if !self.take("}") {
            loop {
                self.nl();
                let sp = self.token().span;
                let name = self.name()?;
                match name.as_str() {
                    "alloc" => set.insert(Effect::Alloc),
                    "io" => set.insert(Effect::Io),
                    "panic" => set.insert(Effect::Panic),
                    "block" => set.insert(Effect::Block),
                    _ => {
                        return Err(Diagnostic::new(
                            sp,
                            format!(
                                "efecto desconocido: '{name}'. Efectos válidos: alloc, io, panic, block"
                            ),
                        ));
                    }
                }
                self.nl();
                if self.take("}") {
                    break;
                }
                self.need(",")?;
                self.nl();
                if self.take("}") {
                    break;
                }
            }
        }
        Ok(EffectsAnnotation { allowed: set, span })
    }

    fn try_type_args_call(&mut self) -> Option<Vec<TypeExpr>> {
        let saved_pos = self.pos;
        let saved_parens = self.parens;
        if !self.take("<") {
            return None;
        }
        let mut args = Vec::new();
        loop {
            let ty = match self.ty() {
                Ok(t) => t,
                Err(_) => {
                    self.pos = saved_pos;
                    self.parens = saved_parens;
                    return None;
                }
            };
            args.push(ty);
            if self.take(">") {
                break;
            }
            if !self.take(",") {
                self.pos = saved_pos;
                self.parens = saved_parens;
                return None;
            }
        }
        if self.at("(") {
            Some(args)
        } else {
            self.pos = saved_pos;
            self.parens = saved_parens;
            None
        }
    }
    /// Comma-separated call arguments after '('. `name: expr` becomes `Named`.
    fn arguments(&mut self) -> Result<Vec<Expr>, Diagnostic> {
        self.parens += 1;
        let mut args = Vec::new();
        self.nl();
        if !self.take(")") {
            loop {
                let is_named = matches!(self.token().kind, Kind::Word(_))
                    && matches!(&self.tokens.get(self.pos + 1).map(|t| &t.kind), Some(Kind::Sym(s)) if s == ":");
                if is_named {
                    let span = self.token().span;
                    let name = self.name()?;
                    self.need(":")?;
                    self.nl();
                    let value = self.expr(0)?;
                    args.push(Expr {
                        kind: ExprKind::Named(name, Box::new(value)),
                        span,
                    });
                } else {
                    args.push(self.expr(0)?);
                }
                self.nl();
                if self.take(")") {
                    break;
                }
                self.need(",")?;
                self.nl();
                if self.take(")") {
                    break;
                }
            }
        }
        self.parens -= 1;
        Ok(args)
    }
    fn expr(&mut self, min: u8) -> Result<Expr, Diagnostic> {
        self.depth += 1;
        if self.depth > 128 {
            return Err(self.error("límite de anidamiento (128) excedido"));
        }
        let result = self.expr_inner(min);
        self.depth -= 1;
        result
    }
    fn expr_inner(&mut self, min: u8) -> Result<Expr, Diagnostic> {
        let t = self.token().clone();
        self.pos += 1;
        let kind = match t.kind {
            Kind::Int(v) => ExprKind::Int(v),
            Kind::IntMinMagnitude => {
                return Err(Diagnostic::new(
                    t.span,
                    "Int fuera de rango: magnitud solo válida tras '-'",
                ));
            }
            Kind::Float(v) => ExprKind::Float(v),
            Kind::Text(s) => ExprKind::Text(s),
            Kind::TextStart => {
                let mut parts = Vec::new();
                while !matches!(self.token().kind, Kind::TextEnd) {
                    let token = self.token().clone();
                    match token.kind {
                        Kind::Text(s) => {
                            self.pos += 1;
                            parts.push(Expr {
                                kind: ExprKind::Text(s),
                                span: token.span,
                            });
                        }
                        Kind::InterpolationStart => {
                            self.pos += 1;
                            self.parens += 1;
                            self.nl();
                            parts.push(self.expr(0)?);
                            self.nl();
                            self.parens -= 1;
                            if !matches!(self.token().kind, Kind::InterpolationEnd) {
                                return Err(
                                    self.error("se esperaba '}' después de expresión interpolada")
                                );
                            }
                            self.pos += 1;
                        }
                        _ => return Err(self.error("cadena interpolada incompleta o inválida")),
                    }
                }
                self.pos += 1;
                ExprKind::Interpolate(parts)
            }
            Kind::Word(ref s) if s == "true" || s == "false" => ExprKind::Bool(s == "true"),
            Kind::Word(ref s) if s == "None" => ExprKind::Name("None".into()),
            Kind::Word(ref s) if s == "view" || s == "edit" => {
                self.nl();
                ExprKind::Unary(
                    if s == "edit" { "&mut" } else { "&" }.into(),
                    Box::new(self.expr(8)?),
                )
            },
            Kind::Word(ref s) if canonical_ele_keyword(s) == "match" => self.match_expr()?,
            // `await` binds like a unary operator: `await f() + 1` awaits the
            // call. Where it may appear is decided by semantic analysis.
            Kind::Word(ref s) if canonical_ele_keyword(s) == "await" => {
                self.nl();
                ExprKind::Await(Box::new(self.expr(8)?))
            }
            // `spawn` takes a call to an async function, like `await`.
            Kind::Word(ref s) if canonical_ele_keyword(s) == "spawn" => {
                self.nl();
                ExprKind::Spawn(Box::new(self.expr(8)?))
            }
            Kind::Word(ref s)
                if s == "List" && matches!(&self.token().kind, Kind::Sym(b) if b == "[") =>
            {
                self.pos += 1;
                ExprKind::ListLit(self.elements()?)
            }
            Kind::Sym(ref s) if s == "[" => ExprKind::ArrayLit(self.elements()?),
            Kind::Word(s) => {
                self.pos -= 1;
                let name = self.name_or_self()?;
                if self.at("<") {
                    if let Some(type_args) = self.try_type_args_call() {
                        self.need("(")?;
                        ExprKind::GenericCall(name, type_args, self.arguments()?)
                    } else {
                        ExprKind::Name(s)
                    }
                } else if self.take("(") {
                    ExprKind::Call(name, self.arguments()?)
                } else {
                    ExprKind::Name(s)
                }
            }
            Kind::Sym(s) if s == "(" => {
                self.parens += 1;
                self.nl();
                let result = if self.take(")") {
                    ExprKind::Unit
                } else {
                    let e = self.expr(0)?;
                    self.nl();
                    self.need(")")?;
                    e.kind
                };
                self.parens -= 1;
                result
            }
            Kind::Sym(s) if s == "-" || s == "!" => {
                self.nl();
                if s == "-" && matches!(self.token().kind, Kind::IntMinMagnitude) {
                    self.pos += 1;
                    ExprKind::Int(i64::MIN)
                } else {
                    ExprKind::Unary(s, Box::new(self.expr(8)?))
                }
            }
            Kind::Sym(s) if s == "&" => {
                self.nl();
                let mutable = self.take("mut");
                let op = if mutable {
                    "&mut".to_string()
                } else {
                    "&".to_string()
                };
                ExprKind::Unary(op, Box::new(self.expr(8)?))
            }
            _ => {
                return Err(Diagnostic::new(
                    t.span,
                    "se esperaba expresión; característica inválida o no implementada",
                ));
            }
        };
        let mut lhs = Expr { kind, span: t.span };
        // Postfix access and `?` bind tighter than any prefix or binary operator.
        while self.at(".") || self.at("@") || self.at("?") || self.at("[") {
            let span = self.token().span;
            if self.take("[") {
                self.parens += 1;
                self.nl();
                let index = self.expr(0)?;
                self.nl();
                self.parens -= 1;
                self.need("]")?;
                lhs = Expr {
                    kind: ExprKind::Index(Box::new(lhs), Box::new(index)),
                    span,
                };
                continue;
            }
            if self.take("?") {
                lhs = Expr {
                    kind: ExprKind::Try(Box::new(lhs)),
                    span,
                };
                continue;
            }
            let method_only = self.take("@");
            if !method_only {
                self.need(".")?;
            }
            let member = self.member()?;
            let kind = if self.at("<")
                && let Some(type_args) = self.try_type_args_call()
            {
                self.need("(")?;
                ExprKind::GenericMethodCall(Box::new(lhs), member, type_args, self.arguments()?)
            } else if self.take("(") {
                ExprKind::MethodCall(Box::new(lhs), member, self.arguments()?)
            } else if method_only {
                return Err(self.error("se esperaba llamada '(...)' después de '@método'"));
            } else {
                ExprKind::Field(Box::new(lhs), member)
            };
            lhs = Expr { kind, span };
        }
        loop {
            // Within parentheses, newlines are whitespace. Outside, only an operator
            // already consumed continues an expression.
            if self.parens > 0 {
                self.nl();
            }
            let op = match &self.token().kind {
                Kind::Sym(s) => s.clone(),
                _ => break,
            };
            let prec = match op.as_str() {
                "??" => 1,
                "||" => 2,
                "&&" => 3,
                "==" | "!=" => 4,
                "<" | "<=" | ">" | ">=" => 5,
                "+" | "-" => 6,
                "*" | "/" | "%" => 7,
                _ => break,
            };
            if prec < min {
                break;
            }
            if prec == 5
                && matches!(&lhs.kind, ExprKind::Binary(p, _, _) if ["<","<=",">",">="].contains(&p.as_str()))
            {
                return Err(self.error("comparaciones encadenadas prohibidas"));
            }
            self.pos += 1;
            self.nl();
            // `??` is right associative; every other binary operator is left associative.
            let rhs = self.expr(if op == "??" { prec } else { prec + 1 })?;
            lhs = Expr {
                kind: ExprKind::Binary(op, Box::new(lhs), Box::new(rhs)),
                span: t.span,
            };
        }
        Ok(lhs)
    }
    /// `match expr { pattern => body, ... }` after the `match` keyword.
    fn match_expr(&mut self) -> Result<ExprKind, Diagnostic> {
        // Inside the braces newlines separate arms even if the match itself sits
        // inside parentheses.
        let saved = self.parens;
        self.parens = 0;
        let result = self.match_inner();
        self.parens = saved;
        result
    }
    fn match_inner(&mut self) -> Result<ExprKind, Diagnostic> {
        let scrutinee = self.expr(0)?;
        self.nl();
        self.need("{")?;
        let mut arms = Vec::new();
        loop {
            while self.take(",") || matches!(self.token().kind, Kind::Newline) {
                if matches!(self.token().kind, Kind::Newline) {
                    self.pos += 1;
                }
            }
            if self.take("}") {
                break;
            }
            if matches!(self.token().kind, Kind::Eof) {
                return Err(self.error("match sin cerrar"));
            }
            let span = self.token().span;
            let pattern = self.pattern()?;
            if self.at("if") {
                return Err(self.error("feature not implemented: guardas en match"));
            }
            if !self.take(":") {
                self.need("=>")?;
            }
            self.nl();
            let body = if self.at("{") {
                self.block()?
            } else if self.at("return") || self.at("break") || self.at("continue") {
                let span = self.token().span;
                if self.take("return") {
                    let e = if self.at("}")
                        || self.at(",")
                        || matches!(self.token().kind, Kind::Newline)
                    {
                        Expr {
                            kind: ExprKind::Unit,
                            span,
                        }
                    } else {
                        self.expr(0)?
                    };
                    vec![Stmt::Return(e)]
                } else if self.take("break") {
                    vec![Stmt::Break(span)]
                } else {
                    self.need("continue")?;
                    vec![Stmt::Continue(span)]
                }
            } else {
                vec![Stmt::Expr(self.expr(0)?, false)]
            };
            arms.push(MatchArm {
                pattern,
                body,
                span,
            });
            if !self.at("}") && !self.at(",") && !matches!(self.token().kind, Kind::Newline) {
                return Err(self.error("se esperaba ',', nueva línea o '}' tras brazo de match"));
            }
        }
        Ok(ExprKind::Match(Box::new(scrutinee), arms))
    }
    fn pattern(&mut self) -> Result<Pattern, Diagnostic> {
        self.depth += 1;
        if self.depth > 128 {
            return Err(self.error("límite de anidamiento (128) excedido"));
        }
        let result = self.pattern_inner();
        self.depth -= 1;
        result
    }
    fn pattern_inner(&mut self) -> Result<Pattern, Diagnostic> {
        let t = self.token().clone();
        let kind = match t.kind {
            Kind::Int(v) => {
                self.pos += 1;
                PatternKind::Int(v)
            }
            Kind::Float(v) => {
                self.pos += 1;
                PatternKind::Float(v)
            }
            Kind::Text(s) => {
                self.pos += 1;
                PatternKind::Text(s)
            }
            Kind::Sym(ref s) if s == "-" => {
                self.pos += 1;
                let kind = match self.token().kind.clone() {
                    Kind::Int(v) => PatternKind::Int(-v),
                    Kind::IntMinMagnitude => PatternKind::Int(i64::MIN),
                    Kind::Float(v) => PatternKind::Float(-v),
                    _ => return Err(self.error("se esperaba literal numérico en patrón")),
                };
                self.pos += 1;
                kind
            }
            Kind::Word(ref w) if w == "_" => {
                self.pos += 1;
                PatternKind::Wild
            }
            Kind::Word(ref w) if w == "true" || w == "false" => {
                self.pos += 1;
                PatternKind::Bool(w == "true")
            }
            Kind::Word(_) => {
                let first = self.member()?;
                let (qualifier, name) = if self.take(".") {
                    (Some(first), self.member()?)
                } else {
                    (None, first)
                };
                if self.take("(") {
                    let mut subs = Vec::new();
                    self.nl();
                    if !self.take(")") {
                        loop {
                            subs.push(self.pattern()?);
                            self.nl();
                            if self.take(")") {
                                break;
                            }
                            self.need(",")?;
                            self.nl();
                            if self.take(")") {
                                break;
                            }
                        }
                    }
                    PatternKind::Variant(qualifier, name, subs)
                } else if qualifier.is_some() {
                    PatternKind::Variant(qualifier, name, Vec::new())
                } else {
                    PatternKind::Name(name)
                }
            }
            _ => {
                return Err(
                    self.error("patrón inválido: se esperaba _, nombre, literal o variante")
                );
            }
        };
        Ok(Pattern { kind, span: t.span })
    }
    fn constant(&mut self) -> Result<Constant, Diagnostic> {
        let span = self.token().span;
        self.need("const")?;
        let name = self.name()?;
        let annotation = if self.take(":") {
            Some(self.ty()?)
        } else {
            None
        };
        self.need("=")?;
        self.nl();
        Ok(Constant {
            name,
            public: false,
            annotation,
            value: self.expr(0)?,
            span,
        })
    }
    fn conditional(&mut self) -> Result<Stmt, Diagnostic> {
        self.depth += 1;
        if self.depth > 128 {
            return Err(self.error("límite de anidamiento (128) excedido"));
        }
        self.need("if")?;
        let cond = self.expr(0)?;
        self.nl();
        let yes = self.block()?;
        let saved = self.pos;
        self.nl();
        let no = if self.take("else") {
            self.nl();
            if self.at("if") {
                vec![self.conditional()?]
            } else {
                self.block()?
            }
        } else {
            self.pos = saved;
            Vec::new()
        };
        self.depth -= 1;
        Ok(Stmt::If(cond, yes, no, self.at(";")))
    }
    fn block(&mut self) -> Result<Vec<Stmt>, Diagnostic> {
        self.depth += 1;
        if self.depth > 128 {
            return Err(self.error("límite de anidamiento (128) excedido"));
        }
        self.need("{")?;
        self.sep();
        let mut body = Vec::new();
        while !self.take("}") {
            if matches!(self.token().kind, Kind::Eof) {
                return Err(self.error("bloque sin cerrar"));
            }
            let stmt = if self.at("const") {
                Stmt::Const(self.constant()?)
            } else if self.at("let") || self.at("var") {
                let mutable = self.take("var");
                if !mutable {
                    self.need("let")?;
                }
                let name = self.name()?;
                let ty = if self.take(":") {
                    Some(self.ty()?)
                } else {
                    None
                };
                self.need("=")?;
                self.nl();
                Stmt::Let(name, mutable, ty, self.expr(0)?)
            } else if self.take("return") {
                let e =
                    if self.at("}") || self.at(";") || matches!(self.token().kind, Kind::Newline) {
                        Expr {
                            kind: ExprKind::Unit,
                            span: self.token().span,
                        }
                    } else {
                        self.expr(0)?
                    };
                Stmt::Return(e)
            } else if self.at("if") {
                body.push(self.conditional()?);
                self.sep();
                continue;
            } else if self.take("while") {
                let cond = self.expr(0)?;
                self.nl();
                let b = self.block()?;
                body.push(Stmt::While(cond, b));
                self.sep();
                continue;
            } else if self.at("match") {
                let e = self.expr(0)?;
                body.push(Stmt::Expr(e, self.at(";")));
                self.sep();
                continue;
            } else if self.at("for") {
                let stmt = self.for_loop()?;
                body.push(stmt);
                self.sep();
                continue;
            } else if self.take("region") {
                let span = self.token().span;
                let name = self.name()?;
                self.nl();
                let block = self.block()?;
                body.push(Stmt::Region(name, span, block));
                self.sep();
                continue;
            } else if self.take("loop") {
                self.nl();
                body.push(Stmt::Loop(self.block()?));
                self.sep();
                continue;
            } else if self.at("break") || self.at("continue") {
                let span = self.token().span;
                let is_break = self.take("break");
                if !is_break {
                    self.need("continue")?;
                }
                if !self.at("}") && !self.at(";") && !matches!(self.token().kind, Kind::Newline) {
                    return Err(self.error("feature not implemented: break/continue con valor"));
                }
                if is_break {
                    Stmt::Break(span)
                } else {
                    Stmt::Continue(span)
                }
            } else if self.at("{") {
                let block = self.block()?;
                body.push(Stmt::Block(block, self.at(";")));
                self.sep();
                continue;
            } else {
                let e = self.expr(0)?;
                if ["=", "+=", "-=", "*=", "/=", "%="]
                    .iter()
                    .any(|s| self.at(s))
                {
                    let op = match self.token().kind.clone() {
                        Kind::Sym(s) => s,
                        _ => return Err(self.error("se esperaba operador de asignación")),
                    };
                    self.pos += 1;
                    self.nl();
                    if is_place(&e) {
                        let span = e.span;
                        Stmt::Assign(e, op, self.expr(0)?, span)
                    } else {
                        return Err(Diagnostic::new(e.span, "destino de asignación inválido"));
                    }
                } else {
                    let explicit = self.at(";");
                    Stmt::Expr(e, explicit)
                }
            };
            body.push(stmt);
            if !self.at("}") && !self.at(";") && !matches!(self.token().kind, Kind::Newline) {
                return Err(self.error("se esperaba nueva línea o ';'"));
            }
            self.sep();
        }
        self.depth -= 1;
        Ok(body)
    }
    /// Comma-separated elements after `[` up to `]` (newlines allowed).
    fn elements(&mut self) -> Result<Vec<Expr>, Diagnostic> {
        self.parens += 1;
        let mut items = Vec::new();
        self.nl();
        while !self.take("]") {
            items.push(self.expr(0)?);
            self.nl();
            if self.take("]") {
                break;
            }
            self.need(",")?;
            self.nl();
        }
        self.parens -= 1;
        Ok(items)
    }
    fn for_loop(&mut self) -> Result<Stmt, Diagnostic> {
        self.need("for")?;
        let span = self.token().span;
        let name = self.name()?;
        self.need("in")?;
        let start = self.expr(0)?;
        let inclusive = if self.take("..=") {
            true
        } else if self.take("..") {
            false
        } else {
            // `for x in colección` (or `&colección`): element iteration.
            self.nl();
            let body = self.block()?;
            return Ok(Stmt::ForEach(name, span, start, body));
        };
        let end = self.expr(0)?;
        self.nl();
        let body = self.block()?;
        Ok(Stmt::For(name, span, start, end, inclusive, body))
    }
    /// `fn name(params) [-> T] (= expr | block)` after an optional `mut`/`static`.
    fn function(&mut self, kind: FnKind) -> Result<Function, Diagnostic> {
        let span = self.token().span;
        self.need("fn")?;
        let name = self.name()?;
        let type_params = self.parse_type_params()?;
        self.need("(")?;
        self.nl();
        let mut params = Vec::new();
        if !self.take(")") {
            loop {
                let sp = self.token().span;
                if self.at("self") {
                    return Err(
                        self.error("self es implícito en métodos; no se declara como parámetro")
                    );
                }
                let n = self.name()?;
                self.need(":")?;
                let ty = self.ty()?;
                params.push((n, ty, sp));
                self.nl();
                if self.take(")") {
                    break;
                }
                self.need(",")?;
                self.nl();
                if self.take(")") {
                    break;
                }
            }
        }
        let mut effects = None;
        if self.at("!") {
            effects = Some(self.effects_annotation()?);
        }
        let result = if (self.take("->") || self.take("=>")) {
            Some(self.ty()?)
        } else {
            None
        };
        if self.at("!") {
            if effects.is_some() {
                return Err(self.error("anotación de efectos duplicada"));
            }
            effects = Some(self.effects_annotation()?);
        }
        self.nl();
        let body = if self.take("=") {
            self.nl();
            let e = self.expr(0)?;
            if !matches!(self.token().kind, Kind::Newline | Kind::Eof)
                && !self.at(";")
                && !self.at("}")
            {
                return Err(self.error("se esperaba terminador de función"));
            }
            vec![Stmt::Return(e)]
        } else {
            self.block()?
        };
        Ok(Function {
            name,
            public: false,
            is_async: false,
            kind,
            type_params,
            params,
            result,
            effects,
            attributes: Vec::new(),
            body,
            span,
        })
    }
    fn struct_decl(&mut self) -> Result<StructDecl, Diagnostic> {
        let span = self.token().span;
        self.need("struct")?;
        let name = self.name()?;
        let params = self.parse_type_params()?;
        self.nl();
        self.need("{")?;
        let mut fields = Vec::new();
        loop {
            while self.take(",") || matches!(self.token().kind, Kind::Newline) {
                if matches!(self.token().kind, Kind::Newline) {
                    self.pos += 1;
                }
            }
            if self.take("}") {
                break;
            }
            let public = self.take("pub");
            let span = self.token().span;
            let field = self.name()?;
            self.need(":")?;
            let ty = self.ty()?;
            let default = if self.take("=") {
                self.nl();
                Some(self.expr(0)?)
            } else {
                None
            };
            fields.push(Field {
                name: field,
                public,
                ty,
                default,
                span,
            });
            if !self.at("}") && !self.at(",") && !matches!(self.token().kind, Kind::Newline) {
                return Err(self.error("se esperaba nueva línea, ',' o '}' tras campo"));
            }
        }
        Ok(StructDecl {
            name,
            public: false,
            params,
            fields,
            span,
        })
    }
    fn enum_decl(&mut self) -> Result<EnumDecl, Diagnostic> {
        let span = self.token().span;
        self.need("enum")?;
        let name = self.name()?;
        let mut params = Vec::new();
        if self.take("<") {
            loop {
                params.push(self.name()?);
                if self.take(">") {
                    break;
                }
                self.need(",")?;
            }
        }
        self.nl();
        self.need("{")?;
        let mut variants = Vec::new();
        loop {
            while self.take(",") || matches!(self.token().kind, Kind::Newline) {
                if matches!(self.token().kind, Kind::Newline) {
                    self.pos += 1;
                }
            }
            if self.take("}") {
                break;
            }
            let span = self.token().span;
            let variant = self.member()?;
            let mut payload = Vec::new();
            if self.take("(") {
                self.nl();
                if !self.take(")") {
                    loop {
                        payload.push(self.ty()?);
                        self.nl();
                        if self.take(")") {
                            break;
                        }
                        self.need(",")?;
                        self.nl();
                        if self.take(")") {
                            break;
                        }
                    }
                }
            }
            variants.push(Variant {
                name: variant,
                payload,
                span,
            });
            if !self.at("}") && !self.at(",") && !matches!(self.token().kind, Kind::Newline) {
                return Err(self.error("se esperaba nueva línea, ',' o '}' tras variante"));
            }
        }
        Ok(EnumDecl {
            name,
            public: false,
            params,
            variants,
            span,
        })
    }
    fn trait_decl(&mut self) -> Result<TraitDecl, Diagnostic> {
        let span = self.token().span;
        self.need("trait")?;
        let name = self.name()?;
        let params = self.parse_type_params()?;
        self.nl();
        self.need("{")?;
        let mut methods = Vec::new();
        loop {
            self.sep();
            if self.take("}") {
                break;
            }
            if matches!(self.token().kind, Kind::Eof) {
                return Err(self.error("trait sin cerrar"));
            }
            let mut attributes = Vec::new();
            while self.at("@") {
                attributes.push(self.attribute()?);
                self.nl();
            }
            let public = self.take("pub");
            while self.at("@") {
                attributes.push(self.attribute()?);
                self.nl();
            }
            let kind = if self.take("mut") {
                FnKind::MutMethod
            } else if self.take("static") {
                FnKind::Static
            } else {
                FnKind::Method
            };
            if self.at("async") {
                return Err(self.error("feature not implemented: métodos async en traits"));
            }
            if !self.at("fn") {
                return Err(self.error("se esperaba fn, mut fn o static fn dentro de trait"));
            }
            let mut method = self.trait_method(kind)?;
            method.public = public;
            method.attributes = attributes;
            methods.push(method);
        }
        Ok(TraitDecl {
            name,
            public: false,
            params,
            methods,
            span,
        })
    }
    fn trait_method(&mut self, kind: FnKind) -> Result<Function, Diagnostic> {
        let span = self.token().span;
        self.need("fn")?;
        let name = self.name()?;
        let type_params = self.parse_type_params()?;
        self.need("(")?;
        self.nl();
        let mut params = Vec::new();
        if !self.take(")") {
            loop {
                let sp = self.token().span;
                if self.at("self") {
                    return Err(
                        self.error("self es implícito en métodos; no se declara como parámetro")
                    );
                }
                let n = self.name()?;
                self.need(":")?;
                let ty = self.ty()?;
                params.push((n, ty, sp));
                self.nl();
                if self.take(")") {
                    break;
                }
                self.need(",")?;
                self.nl();
                if self.take(")") {
                    break;
                }
            }
        }
        let mut effects = None;
        if self.at("!") {
            effects = Some(self.effects_annotation()?);
        }
        let result = if (self.take("->") || self.take("=>")) {
            Some(self.ty()?)
        } else {
            None
        };
        if self.at("!") {
            if effects.is_some() {
                return Err(self.error("anotación de efectos duplicada"));
            }
            effects = Some(self.effects_annotation()?);
        }
        self.nl();
        let body = if self.take("=") {
            self.nl();
            let e = self.expr(0)?;
            vec![Stmt::Return(e)]
        } else if self.at("{") {
            self.block()?
        } else {
            Vec::new()
        };
        Ok(Function {
            name,
            public: false,
            is_async: false,
            kind,
            type_params,
            params,
            result,
            effects,
            attributes: Vec::new(),
            body,
            span,
        })
    }
    fn impl_decl(&mut self) -> Result<ImplDecl, Diagnostic> {
        let span = self.token().span;
        self.need("impl")?;
        let params = self.parse_type_params()?;
        let first = self.name()?;
        let (trait_name, target, target_args) = if self.take("for") {
            let target = self.name()?;
            let mut target_args = Vec::new();
            if self.take("<") {
                loop {
                    target_args.push(self.ty()?);
                    if self.take(">") {
                        break;
                    }
                    self.need(",")?;
                }
            }
            (Some(first), target, target_args)
        } else {
            let mut target_args = Vec::new();
            if self.take("<") {
                loop {
                    target_args.push(self.ty()?);
                    if self.take(">") {
                        break;
                    }
                    self.need(",")?;
                }
            }
            (None, first, target_args)
        };
        self.nl();
        self.need("{")?;
        let mut methods = Vec::new();
        loop {
            self.sep();
            if self.take("}") {
                break;
            }
            if matches!(self.token().kind, Kind::Eof) {
                return Err(self.error("impl sin cerrar"));
            }
            let mut attributes = Vec::new();
            while self.at("@") {
                attributes.push(self.attribute()?);
                self.nl();
            }
            let public = self.take("pub");
            while self.at("@") {
                attributes.push(self.attribute()?);
                self.nl();
            }
            let kind = if self.take("mut") {
                FnKind::MutMethod
            } else if self.take("static") {
                FnKind::Static
            } else {
                FnKind::Method
            };
            if self.at("async") {
                return Err(self.error(
                    "feature not implemented: métodos async; declare una función async libre",
                ));
            }
            if !self.at("fn") {
                return Err(self.error("se esperaba fn, mut fn o static fn dentro de impl"));
            }
            let mut method = self.function(kind)?;
            method.public = public;
            method.attributes = attributes;
            methods.push(method);
        }
        Ok(ImplDecl {
            params,
            trait_name,
            target,
            target_args,
            methods,
            span,
        })
    }
}

/// Assignable expression: a name or a field chain rooted at a name.
fn is_place(e: &Expr) -> bool {
    match &e.kind {
        ExprKind::Name(_) => true,
        ExprKind::Field(base, _) | ExprKind::Index(base, _) => is_place(base),
        _ => false,
    }
}

pub fn parse(tokens: Vec<Token>) -> Result<Program, Diagnostic> {
    parse_inner(tokens).map_err(|e| e.classify("L0003", "sintaxis"))
}
fn parse_inner(tokens: Vec<Token>) -> Result<Program, Diagnostic> {
    if tokens.is_empty() || !matches!(tokens.last().map(|t| &t.kind), Some(Kind::Eof)) {
        return Err(Diagnostic::new(
            Span::default(),
            "secuencia de tokens incompleta",
        ));
    }
    if tokens.len() > 4096 {
        return Err(Diagnostic::new(
            tokens[4096].span,
            "límite CORE-1 de 4096 tokens excedido",
        ));
    }
    let mut p = Parser {
        tokens,
        pos: 0,
        depth: 0,
        parens: 0,
    };
    let mut imports = Vec::new();
    let mut functions = Vec::new();
    let mut constants = Vec::new();
    let mut structs = Vec::new();
    let mut enums = Vec::new();
    let mut traits = Vec::new();
    let mut impls = Vec::new();
    p.sep();
    while !matches!(p.token().kind, Kind::Eof) {
        let mut attributes = Vec::new();
        while p.at("@") {
            attributes.push(p.attribute()?);
            p.nl();
        }
        let public = p.take("pub");
        while p.at("@") {
            attributes.push(p.attribute()?);
            p.nl();
        }
        if public
            && !(p.at("fn")
                || p.at("async")
                || p.at("struct")
                || p.at("enum")
                || p.at("trait")
                || p.at("const"))
        {
            return Err(p.error("pub solo se admite antes de fn, struct, enum, trait o const"));
        }
        if !attributes.is_empty() && !(p.at("fn") || p.at("async")) {
            return Err(p.error("atributos solo se admiten antes de fn o métodos"));
        }
        if p.at("const") {
            let mut constant = p.constant()?;
            constant.public = public;
            constants.push(constant);
            if !p.at(";") && !matches!(p.token().kind, Kind::Newline | Kind::Eof) {
                return Err(p.error("se esperaba terminador de const"));
            }
            p.sep();
            continue;
        }
        if p.at("import") {
            p.need("import")?;
            let span = p.token().span;
            let mut path = p.name()?;
            while p.take(".") {
                path.push('.');
                path.push_str(&p.name()?);
            }
            if !matches!(p.token().kind, Kind::Newline | Kind::Eof) && !p.at(";") {
                return Err(p.error("se esperaba terminador de módulo/import"));
            }
            p.sep();
            imports.push(ImportDecl { path, span });
            continue;
        }
        if p.at("module") {
            p.need("module")?;
            let mut path = p.name()?;
            while p.take(".") {
                path.push('.');
                path.push_str(&p.name()?);
            }
            if !matches!(p.token().kind, Kind::Newline | Kind::Eof) && !p.at(";") {
                return Err(p.error("se esperaba terminador de módulo/import"));
            }
            p.sep();
            continue;
        }
        if p.at("struct") {
            let mut decl = p.struct_decl()?;
            decl.public = public;
            structs.push(decl);
        } else if p.at("enum") {
            let mut decl = p.enum_decl()?;
            decl.public = public;
            enums.push(decl);
        } else if p.at("trait") {
            let mut decl = p.trait_decl()?;
            decl.public = public;
            traits.push(decl);
        } else if p.at("impl") {
            impls.push(p.impl_decl()?);
        } else if p.at("fn") {
            let mut decl = p.function(FnKind::Free)?;
            decl.public = public;
            decl.attributes = attributes;
            functions.push(decl);
        } else if p.at("async") {
            let span = p.token().span;
            p.pos += 1;
            if !p.at("fn") {
                return Err(p.error("se esperaba fn tras async"));
            }
            let mut decl = p.function(FnKind::Free)?;
            decl.public = public;
            decl.attributes = attributes;
            decl.is_async = true;
            decl.span = span;
            functions.push(decl);
        } else {
            return Err(p.error(
                "feature not implemented: declaración; se esperaba fn, struct, enum, trait, impl o const",
            ));
        }
        p.sep();
    }
    Ok(Program {
        imports,
        functions,
        constants,
        structs,
        enums,
        traits,
        impls,
    })
}
