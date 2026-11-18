//! Input of the provisional backend: the ELE LIR text protocol, version 1,
//! written by the Stage 1 compiler (`sema-l archivo.l --emit-lir`).
//!
//! The text is parsed defensively into the block LIR (`cfg::Module`) that
//! the Cranelift backend already compiles. Every count, id, number and byte
//! is validated before use, so malformed input is a diagnostic, never a
//! panic. The parser does not run the Rust front end and does not redo the
//! language semantics: Stage 1 already lowered, ownership-checked and
//! drop-elaborated the program. `validate` then applies the existing
//! structural (`cfg::verify`) and ownership (`drops::verify`) checks of the
//! block LIR as a defensive boundary. See docs/LIR_PROTOCOL.md.
use crate::{
    Diagnostic, Span,
    cfg::{
        self, Arg, BinOp, Block, Const, Func, Inst, InstKind, Module, Operand, Place, Proj, Rvalue,
        Terminator, UnOp, VarTy,
    },
    drops,
    lir::{BorrowReturn, EnumDef, PlatformOp, Receiver, StructDef, Type},
};

pub const HEADER: &str = "ELE-LIR 1";
/// Largest accepted input, in bytes.
pub const MAX_INPUT: usize = 64 * 1024 * 1024;
/// Largest count of structs, fields, functions, variables, blocks or
/// instructions in one table.
pub const MAX_ITEMS: usize = 1 << 20;
/// Largest name or text constant, in bytes.
pub const MAX_TEXT: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolError {
    /// 1-based line of the LIR text.
    pub line: usize,
    pub message: String,
}

impl ProtocolError {
    pub fn into_diagnostic(self) -> Diagnostic {
        Diagnostic::new(
            Span::at(self.line, 1),
            format!("protocolo LIR inválido: {}", self.message),
        )
        .classify("L0017", "lir-protocolo")
    }
}

type Res<T> = Result<T, ProtocolError>;

struct Reader<'a> {
    lines: Vec<&'a str>,
    next: usize,
}

struct Line<'a> {
    number: usize,
    words: Vec<&'a str>,
    at: usize,
}

impl<'a> Line<'a> {
    fn fail<T>(&self, message: impl Into<String>) -> Res<T> {
        Err(ProtocolError {
            line: self.number,
            message: message.into(),
        })
    }
    fn word(&mut self) -> Res<&'a str> {
        match self.words.get(self.at) {
            Some(w) => {
                self.at += 1;
                Ok(w)
            }
            None => self.fail("faltan campos"),
        }
    }
    fn expect(&mut self, keyword: &str) -> Res<()> {
        let w = self.word()?;
        if w == keyword {
            Ok(())
        } else {
            self.fail(format!("se esperaba '{keyword}', no '{w}'"))
        }
    }
    fn count(&mut self, limit: usize) -> Res<usize> {
        let w = self.word()?;
        match w.parse::<usize>() {
            Ok(n) if n <= limit && !w.starts_with('+') => Ok(n),
            _ => self.fail(format!("cantidad inválida o excesiva: '{w}'")),
        }
    }
    /// `<prefix><index>` with `index < bound`.
    fn id(&mut self, prefix: char, bound: usize) -> Res<usize> {
        let w = self.word()?;
        let digits = w.strip_prefix(prefix).unwrap_or("");
        match digits.parse::<usize>() {
            Ok(n) if n < bound && !digits.starts_with('+') => Ok(n),
            _ => self.fail(format!("identificador inválido: '{w}'")),
        }
    }
    fn done(&self) -> Res<()> {
        if self.at == self.words.len() {
            Ok(())
        } else {
            self.fail("campos sobrantes")
        }
    }
}

impl<'a> Reader<'a> {
    fn line(&mut self) -> Res<Line<'a>> {
        let number = self.next + 1;
        let Some(text) = self.lines.get(self.next) else {
            return Err(ProtocolError {
                line: number,
                message: "fin inesperado del módulo".into(),
            });
        };
        self.next += 1;
        if text.contains("  ") || text.starts_with(' ') || text.ends_with(' ') {
            return Err(ProtocolError {
                line: number,
                message: "separadores inválidos".into(),
            });
        }
        Ok(Line {
            number,
            words: text.split(' ').collect(),
            at: 0,
        })
    }
}

/// `<length>:<byte>,<byte>,...` as UTF-8 text.
fn bytes_text(line: &mut Line) -> Res<String> {
    let w = line.word()?;
    let Some((len, rest)) = w.split_once(':') else {
        return line.fail("texto sin longitud");
    };
    let len: usize = match len.parse() {
        Ok(n) if n <= MAX_TEXT => n,
        _ => return line.fail("longitud de texto inválida"),
    };
    let mut bytes = Vec::with_capacity(len);
    if !rest.is_empty() {
        for b in rest.split(',') {
            match b.parse::<u8>() {
                Ok(v) if !b.starts_with('+') && bytes.len() < len => bytes.push(v),
                _ => return line.fail("byte de texto inválido"),
            }
        }
    }
    if bytes.len() != len {
        return line.fail("la longitud no coincide con los bytes");
    }
    match String::from_utf8(bytes) {
        Ok(s) => Ok(s),
        Err(_) => line.fail("texto que no es UTF-8"),
    }
}

fn parse_type(line: &mut Line, structs: usize, enums: usize, lists: usize) -> Res<Type> {
    let w = line.word()?;
    Ok(match w {
        "i" => Type::Int,
        "f" => Type::Float,
        "b" => Type::Bool,
        "t" => Type::Text,
        "u" => Type::Unit,
        _ => {
            if let Some(k) = w.strip_prefix('s').and_then(|d| d.parse::<usize>().ok()) {
                if k < structs && !w[1..].starts_with('+') {
                    Type::Struct(k)
                } else {
                    return line.fail(format!("struct inválido: '{w}'"));
                }
            } else if let Some(k) = w.strip_prefix('e').and_then(|d| d.parse::<usize>().ok()) {
                if k < enums && !w[1..].starts_with('+') {
                    Type::Enum(k)
                } else {
                    return line.fail(format!("enum inválido: '{w}'"));
                }
            } else if let Some(k) = w.strip_prefix('l').and_then(|d| d.parse::<usize>().ok()) {
                if k < lists && !w[1..].starts_with('+') {
                    Type::List(k)
                } else {
                    return line.fail(format!("lista inválida: '{w}'"));
                }
            } else {
                return line.fail(format!("tipo inválido: '{w}'"));
            }
        }
    })
}

struct FnCtx<'m> {
    vars: Vec<VarTy>,
    structs: &'m [StructDef],
    enums: &'m [EnumDef],
    lists: &'m [Type],
    funcs: usize,
}

impl FnCtx<'_> {
    fn operand(&self, line: &mut Line) -> Res<Operand> {
        let w = line.word()?;
        if let Some(rest) = w.strip_prefix("ct") {
            line.at -= 1;
            line.words[line.at] = rest;
            return Ok(Operand::Const(Const::Text(bytes_text(line)?)));
        }
        Ok(match w {
            "cu" => Operand::Const(Const::Unit),
            "cb0" => Operand::Const(Const::Bool(false)),
            "cb1" => Operand::Const(Const::Bool(true)),
            _ => {
                if let Some(n) = w.strip_prefix("ci") {
                    match n.parse::<i64>() {
                        Ok(v) if !n.starts_with('+') => Operand::Const(Const::Int(v)),
                        _ => return line.fail(format!("entero inválido: '{w}'")),
                    }
                } else {
                    line.at -= 1;
                    Operand::Var(line.id('v', self.vars.len())?)
                }
            }
        })
    }
    /// `p<var>(.<field>)*([v<idx>])*`, checked against structs and lists.
    fn place(&self, line: &mut Line) -> Res<Place> {
        let w = line.word()?;
        let (root_part, mut rest) = match w.find(['.', '[']) {
            Some(idx) => (&w[..idx], &w[idx..]),
            None => (w, ""),
        };
        let var = match root_part
            .strip_prefix('p')
            .and_then(|d| d.parse::<usize>().ok())
        {
            Some(n) if n < self.vars.len() && !root_part[1..].starts_with('+') => n,
            _ => return line.fail(format!("lugar inválido: '{w}'")),
        };
        let mut ty = self.vars[var].pointee();
        let mut proj = Vec::new();
        while !rest.is_empty() {
            if rest.starts_with('.') {
                rest = &rest[1..];
                let (part, new_rest) = match rest.find(['.', '[']) {
                    Some(idx) => (&rest[..idx], &rest[idx..]),
                    None => (rest, ""),
                };
                rest = new_rest;
                let field = match (part.parse::<usize>(), ty) {
                    (Ok(f), Type::Struct(s)) if !part.starts_with('+') => {
                        match self.structs.get(s).and_then(|d| d.fields.get(f)) {
                            Some((_, t)) => {
                                ty = *t;
                                f
                            }
                            None => return line.fail(format!("campo inexistente en '{w}'")),
                        }
                    }
                    _ => return line.fail(format!("proyección inválida en '{w}'")),
                };
                proj.push(Proj::Field(field));
            } else if rest.starts_with('[') {
                let close = rest.find(']').ok_or_else(|| ProtocolError {
                    line: line.number,
                    message: format!("índice sin cerrar en '{w}'"),
                })?;
                let idx_part = &rest[1..close];
                rest = &rest[close + 1..];
                let idx_var = match idx_part
                    .strip_prefix('v')
                    .and_then(|d| d.parse::<usize>().ok())
                {
                    Some(v)
                        if v < self.vars.len()
                            && self.vars[v].pointee() == Type::Int
                            && !idx_part[1..].starts_with('+') =>
                    {
                        v
                    }
                    _ => return line.fail(format!("variable de índice inválida en '{w}'")),
                };
                ty = match ty {
                    Type::List(l) => self.lists.get(l).copied().ok_or_else(|| ProtocolError {
                        line: line.number,
                        message: format!("lista inexistente en '{w}'"),
                    })?,
                    _ => return line.fail(format!("indexación sobre tipo no indexable en '{w}'")),
                };
                proj.push(Proj::Index(idx_var));
            } else {
                return line.fail(format!("proyección malformada en '{w}'"));
            }
        }
        Ok(Place { var, proj })
    }
    fn arg(&self, line: &mut Line) -> Res<Arg> {
        match line.word()? {
            "val" => Ok(Arg::Value(self.operand(line)?)),
            "ref" => {
                let place = self.place(line)?;
                let mutable = match line.word()? {
                    "0" => false,
                    "1" => true,
                    _ => return line.fail("modo de préstamo inválido"),
                };
                Ok(Arg::Ref(place, mutable))
            }
            other => line.fail(format!("argumento inválido: '{other}'")),
        }
    }
    fn dst(&self, line: &mut Line) -> Res<usize> {
        line.id('v', self.vars.len())
    }
    fn flag(&self, line: &mut Line) -> Res<Option<usize>> {
        if line.words.get(line.at) == Some(&"-") {
            line.at += 1;
            return Ok(None);
        }
        Ok(Some(line.id('v', self.vars.len())?))
    }
    fn inst(&self, line: &mut Line) -> Res<InstKind> {
        let kind = line.word()?;
        Ok(match kind {
            "use" => {
                let d = self.dst(line)?;
                InstKind::Assign(d, Rvalue::Use(self.operand(line)?))
            }
            "unary" => {
                let d = self.dst(line)?;
                let op = match line.word()? {
                    "neg" => UnOp::Neg,
                    "not" => UnOp::Not,
                    other => return line.fail(format!("operador unario inválido: '{other}'")),
                };
                InstKind::Assign(d, Rvalue::Unary(op, self.operand(line)?))
            }
            "binary" => {
                let d = self.dst(line)?;
                let op = match line.word()? {
                    "add" => BinOp::Add,
                    "sub" => BinOp::Sub,
                    "mul" => BinOp::Mul,
                    "div" => BinOp::Div,
                    "rem" => BinOp::Rem,
                    "eq" => BinOp::Eq,
                    "ne" => BinOp::Ne,
                    "lt" => BinOp::Lt,
                    "le" => BinOp::Le,
                    "gt" => BinOp::Gt,
                    "ge" => BinOp::Ge,
                    other => return line.fail(format!("operador binario inválido: '{other}'")),
                };
                let a = self.operand(line)?;
                InstKind::Assign(d, Rvalue::Binary(op, a, self.operand(line)?))
            }
            "call" => {
                let d = self.dst(line)?;
                let f = line.id('f', self.funcs)?;
                let n = line.count(MAX_ITEMS)?;
                let mut args = Vec::new();
                for _ in 0..n {
                    args.push(self.arg(line)?);
                }
                InstKind::Assign(d, Rvalue::Call(f, args))
            }
            "struct" => {
                let d = self.dst(line)?;
                let s = line.id('s', self.structs.len())?;
                let n = line.count(MAX_ITEMS)?;
                if n != self.structs[s].fields.len() {
                    return line.fail("número de campos incorrecto");
                }
                let mut ops = Vec::new();
                for _ in 0..n {
                    ops.push(self.operand(line)?);
                }
                InstKind::Assign(d, Rvalue::Struct(s, ops))
            }
            "read" => {
                let d = self.dst(line)?;
                InstKind::Assign(d, Rvalue::Read(self.place(line)?))
            }
            "loan" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                let mutable = match line.word()? {
                    "0" => false,
                    "1" => true,
                    _ => return line.fail("modo de préstamo inválido"),
                };
                InstKind::Assign(d, Rvalue::Loan(place, mutable, self.vars[d].pointee()))
            }
            "textbuf" => {
                let d = self.dst(line)?;
                InstKind::Assign(d, Rvalue::TextBuffer(line.count(MAX_TEXT)?))
            }
            "append" => {
                let d = self.dst(line)?;
                InstKind::Append(d, self.arg(line)?)
            }
            "store" => {
                let place = self.place(line)?;
                InstKind::Store(place, self.operand(line)?)
            }
            "print" => InstKind::Print(self.arg(line)?),
            "drop" => {
                let d = self.dst(line)?;
                InstKind::Drop(d, self.flag(line)?)
            }
            "dropfield" => {
                let place = self.place(line)?;
                if place.proj.is_empty() {
                    return line.fail("dropfield requiere un campo");
                }
                InstKind::DropField(place, self.flag(line)?)
            }
            "len" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                InstKind::Assign(d, Rvalue::Len(place))
            }
            "cap" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                InstKind::Assign(d, Rvalue::Cap(place))
            }
            "listpush" => {
                let place = self.place(line)?;
                let op = self.operand(line)?;
                InstKind::ListPush(place, op)
            }
            "listpop" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                InstKind::Assign(d, Rvalue::ListTakeLast(place))
            }
            "listreserve" => {
                let place = self.place(line)?;
                let op = self.operand(line)?;
                InstKind::ListReserve(place, op)
            }
            "listlit" => {
                let d = self.dst(line)?;
                let l = line.id('l', self.lists.len())?;
                let n = line.count(MAX_ITEMS)?;
                let mut ops = Vec::new();
                for _ in 0..n {
                    ops.push(self.operand(line)?);
                }
                InstKind::Assign(d, Rvalue::ListLit(Type::List(l), ops))
            }
            "byteat" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                let op = self.operand(line)?;
                InstKind::Assign(d, Rvalue::BytesGet(place, op))
            }
            "platform" => {
                let d = self.dst(line)?;
                let op_name = line.word()?;
                let op = match op_name {
                    "argcount" => PlatformOp::ArgCount,
                    "arg" => PlatformOp::Arg,
                    "readtext" => PlatformOp::ReadText,
                    "printerror" => PlatformOp::PrintError,
                    "writebytes" => PlatformOp::WriteBytes,
                    other => {
                        return line
                            .fail(format!("operación de plataforma desconocida: '{other}'"));
                    }
                };
                let n = line.count(MAX_ITEMS)?;
                let mut args = Vec::new();
                for _ in 0..n {
                    args.push(self.arg(line)?);
                }
                InstKind::Assign(d, Rvalue::Platform(op, args, self.vars[d].pointee()))
            }
            "variant" => {
                let d = self.dst(line)?;
                let e = line.id('e', self.enums.len())?;
                let v = line.count(self.enums[e].variants.len().saturating_sub(1))?;
                if v >= self.enums[e].variants.len() {
                    return line.fail("variante inexistente para el enum");
                }
                let n = line.count(MAX_ITEMS)?;
                if n != self.enums[e].variants[v].1.len() {
                    return line.fail("aridad de payload incompatible con la variante");
                }
                let mut ops = Vec::new();
                for _ in 0..n {
                    ops.push(self.operand(line)?);
                }
                InstKind::Assign(d, Rvalue::Variant(e, v, ops))
            }
            "disc" => {
                let d = self.dst(line)?;
                let place = self.place(line)?;
                // The ELE-native reader implements `disc` for direct enum
                // values only. A reference or projected field must not be
                // silently accepted by the Rust protocol consumer.
                if !place.proj.is_empty()
                    || !matches!(self.vars[place.var], VarTy::Value(Type::Enum(_)))
                    || self.vars[d] != VarTy::Value(Type::Int)
                {
                    return line.fail("disc requiere un enum directo y un destino Int");
                }
                InstKind::Assign(d, Rvalue::Discriminant(place))
            }
            "payload" => {
                // Conservative ELE-LIR 1 extension shared with the ELE-written
                // bootstrap backend: `i payload vD pN eE V`. The payload must be
                // a lowerable value (`payload_ok`): Int, Bool, Text, a list, or
                // a struct/enum built recursively from them. Floats, units and
                // by-value cycles stay rejected. The runtime performs a
                // discriminant check on every access. An OWNED payload (one
                // that needs a drop) is moved out and consumes its whole enum:
                // the reader appends the explicit `Moved` marker of Stage 0,
                // so the ownership verifier sees no later use, drop or leak of
                // the enum (it never owns the payload twice).
                let d = self.dst(line)?;
                let place = self.place(line)?;
                let enum_id = line.id('e', self.enums.len())?;
                let variant_id =
                    line.count(self.enums[enum_id].variants.len().saturating_sub(1))?;
                if variant_id >= self.enums[enum_id].variants.len() {
                    return line.fail("variante inexistente para payload");
                }
                // `payload` reads a direct owned value. Allowing a Ref
                // root here would silently dereference a loan, whereas the
                // independent ELE reader rejects all `ref` locals. Explicit
                // borrow projections require their own verified protocol.
                if !place.proj.is_empty()
                    || self.vars[place.var] != VarTy::Value(Type::Enum(enum_id))
                {
                    return line
                        .fail("payload requiere un enum directo por valor del tipo indicado");
                }
                let payload = &self.enums[enum_id].variants[variant_id].1;
                if payload.len() != 1
                    || !payload_ok(payload[0], self.structs, self.enums, 0)
                    || self.vars[d] != VarTy::Value(payload[0])
                {
                    return line
                        .fail("payload requiere un único campo representable del tipo exacto");
                }
                if place.var == d {
                    return line.fail("payload no puede sobrescribir su propio enum");
                }
                InstKind::Assign(
                    d,
                    Rvalue::Read(Place {
                        var: place.var,
                        proj: vec![Proj::Payload(variant_id, 0)],
                    }),
                )
            }
            other => return line.fail(format!("instrucción desconocida: '{other}'")),
        })
    }
    /// The enum consumed by an owned `payload` extraction, if `kind` is one.
    /// Only the `payload` instruction produces a `Payload` projection.
    fn consumed_enum(&self, kind: &InstKind) -> Option<usize> {
        let InstKind::Assign(_, Rvalue::Read(place)) = kind else {
            return None;
        };
        let [Proj::Payload(variant, field)] = place.proj.as_slice() else {
            return None;
        };
        let VarTy::Value(Type::Enum(e)) = self.vars[place.var] else {
            return None;
        };
        let t = *self.enums.get(e)?.variants.get(*variant)?.1.get(*field)?;
        owns(t, self.structs, self.enums, 0).then_some(place.var)
    }
}

/// Whether `t` can be the payload of `i payload`: Int, Bool, Text, a list,
/// or a struct/enum whose parts are recursively such values. Floats, units
/// and (malformed) types containing themselves by value are rejected.
fn payload_ok(t: Type, structs: &[StructDef], enums: &[EnumDef], depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match t {
        Type::Int | Type::Bool | Type::Text | Type::List(_) => true,
        Type::Struct(s) => structs.get(s).is_some_and(|def| {
            !def.fields.is_empty()
                && def
                    .fields
                    .iter()
                    .all(|(_, f)| payload_ok(*f, structs, enums, depth + 1))
        }),
        Type::Enum(e) => enums.get(e).is_some_and(|def| {
            def.variants.iter().all(|(_, payload)| {
                payload.len() <= 1
                    && payload
                        .iter()
                        .all(|p| payload_ok(*p, structs, enums, depth + 1))
            })
        }),
        _ => false,
    }
}

/// Whether a value of type `t` owns a resource (Text, a list, or an
/// aggregate containing one). Callers bound the type by `payload_ok` first.
fn owns(t: Type, structs: &[StructDef], enums: &[EnumDef], depth: usize) -> bool {
    if depth > 8 {
        return true;
    }
    match t {
        Type::Text | Type::List(_) => true,
        Type::Struct(s) => structs.get(s).is_some_and(|def| {
            def.fields
                .iter()
                .any(|(_, f)| owns(*f, structs, enums, depth + 1))
        }),
        Type::Enum(e) => enums.get(e).is_some_and(|def| {
            def.variants
                .iter()
                .any(|(_, payload)| payload.iter().any(|p| owns(*p, structs, enums, depth + 1)))
        }),
        _ => false,
    }
}

/// Optional trailing `@line:col` source position.
fn span(line: &mut Line) -> Res<Span> {
    let Some(last) = line.words.last().copied() else {
        return Ok(Span::default());
    };
    let Some(pos) = last.strip_prefix('@') else {
        return Ok(Span::default());
    };
    line.words.pop();
    match pos.split_once(':') {
        Some((l, c)) => match (l.parse::<usize>(), c.parse::<usize>()) {
            (Ok(l), Ok(c)) if l < usize::MAX / 2 && c < usize::MAX / 2 => Ok(Span::at(l, c)),
            _ => line.fail("posición inválida"),
        },
        None => line.fail("posición inválida"),
    }
}

fn parse_func(
    r: &mut Reader,
    index: usize,
    structs: &[StructDef],
    enums: &[EnumDef],
    lists: &[Type],
    funcs: usize,
) -> Res<Func> {
    let mut line = r.line()?;
    line.expect("func")?;
    if line.id('f', funcs)? != index {
        return line.fail("las funciones deben aparecer en orden");
    }
    let name = bytes_text(&mut line)?;
    line.expect("params")?;
    let params = line.count(MAX_ITEMS)?;
    line.expect("result")?;
    let result = parse_type(&mut line, structs.len(), enums.len(), lists.len())?;
    let reference = line.count(1)? == 1;
    let exclusive = line.count(1)? == 1;
    line.expect("vars")?;
    let var_count = line.count(MAX_ITEMS)?;
    line.expect("blocks")?;
    let block_count = line.count(MAX_ITEMS)?;
    line.done()?;
    if params > var_count || block_count == 0 {
        return line.fail("parámetros o bloques inválidos");
    }
    let mut vars = Vec::new();
    for i in 0..var_count {
        let mut v = r.line()?;
        v.expect("var")?;
        if v.id('v', var_count)? != i {
            return v.fail("las variables deben aparecer en orden");
        }
        let by_ref = match v.word()? {
            "val" => false,
            "ref" => true,
            _ => return v.fail("clase de variable inválida"),
        };
        let ty = parse_type(&mut v, structs.len(), enums.len(), lists.len())?;
        v.done()?;
        vars.push(if by_ref {
            VarTy::Ref(ty)
        } else {
            VarTy::Value(ty)
        });
    }
    let ctx = FnCtx {
        vars,
        structs,
        enums,
        lists,
        funcs,
    };
    let mut blocks = Vec::new();
    for b in 0..block_count {
        let mut header = r.line()?;
        header.expect("block")?;
        if header.count(MAX_ITEMS)? != b {
            return header.fail("los bloques deben aparecer en orden");
        }
        let n = header.count(MAX_ITEMS)?;
        header.done()?;
        let mut insts = Vec::new();
        for _ in 0..n {
            let mut line = r.line()?;
            let at = span(&mut line)?;
            line.expect("i")?;
            let kind = ctx.inst(&mut line)?;
            line.done()?;
            let consumed = ctx.consumed_enum(&kind);
            insts.push(Inst { kind, span: at });
            if let Some(var) = consumed {
                insts.push(Inst {
                    kind: InstKind::Moved(var),
                    span: at,
                });
            }
        }
        let mut line = r.line()?;
        let at = span(&mut line)?;
        line.expect("t")?;
        let term = match line.word()? {
            "jump" => Terminator::Jump(line.count(block_count.saturating_sub(1))?),
            "branch" => {
                let cond = ctx.operand(&mut line)?;
                let a = line.count(block_count.saturating_sub(1))?;
                Terminator::Branch(cond, a, line.count(block_count.saturating_sub(1))?)
            }
            "return" => Terminator::Return(ctx.operand(&mut line)?),
            "returnref" => Terminator::ReturnRef(line.id('v', ctx.vars.len())?, at),
            "unreachable" => Terminator::Unreachable,
            other => return line.fail(format!("terminador desconocido: '{other}'")),
        };
        line.done()?;
        blocks.push(Block {
            insts,
            term: Some(term),
        });
    }
    let mut end = r.line()?;
    end.expect("endfunc")?;
    end.done()?;
    let param_vars: Vec<usize> = (0..params).collect();
    let borrow_return = reference.then(|| BorrowReturn {
        params: (0..params)
            .filter(|p| matches!(ctx.vars[*p], VarTy::Ref(_)))
            .collect(),
        mode: if exclusive {
            Receiver::Exclusive
        } else {
            Receiver::Shared
        },
    });
    Ok(Func {
        name,
        params: param_vars,
        vars: ctx.vars,
        result,
        borrow_return,
        view_return: None,
        blocks,
    })
}

/// Parse a whole LIR module.
pub fn parse(text: &str) -> Result<Module, ProtocolError> {
    if text.len() > MAX_INPUT {
        return Err(ProtocolError {
            line: 1,
            message: "el módulo excede el tamaño máximo".into(),
        });
    }
    let mut r = Reader {
        lines: text.lines().collect(),
        next: 0,
    };
    let version = r.line()?;
    if version.words.join(" ") != HEADER {
        return version.fail(format!("versión desconocida; se esperaba '{HEADER}'"));
    }
    let mut line = r.line()?;
    line.expect("module")?;
    line.expect("structs")?;
    let struct_count = line.count(MAX_ITEMS)?;
    let enum_count = if line.words.get(line.at) == Some(&"enums") {
        line.at += 1;
        line.count(MAX_ITEMS)?
    } else {
        0
    };
    let list_count = if line.words.get(line.at) == Some(&"lists") {
        line.at += 1;
        line.count(MAX_ITEMS)?
    } else {
        0
    };
    line.expect("funcs")?;
    let func_count = line.count(MAX_ITEMS)?;
    line.expect("main")?;
    let main = line.id('f', func_count)?;
    line.done()?;
    let mut structs = Vec::new();
    for k in 0..struct_count {
        let mut s = r.line()?;
        s.expect("struct")?;
        if s.id('s', struct_count)? != k {
            return s.fail("los structs deben aparecer en orden");
        }
        let name = bytes_text(&mut s)?;
        s.expect("fields")?;
        let n = s.count(MAX_ITEMS)?;
        s.done()?;
        let mut fields = Vec::new();
        for _ in 0..n {
            let mut f = r.line()?;
            f.expect("field")?;
            let field = bytes_text(&mut f)?;
            let ty = parse_type(&mut f, struct_count, enum_count, list_count)?;
            f.done()?;
            fields.push((field, ty));
        }
        structs.push(StructDef { name, fields });
    }
    let mut enums = Vec::new();
    for k in 0..enum_count {
        let mut e = r.line()?;
        e.expect("enum")?;
        if e.id('e', enum_count)? != k {
            return e.fail("los enums deben aparecer en orden");
        }
        let name = bytes_text(&mut e)?;
        e.expect("variants")?;
        let n = e.count(MAX_ITEMS)?;
        if n == 0 {
            return e.fail("un enum debe declarar al menos una variante");
        }
        e.done()?;
        let mut variants = Vec::new();
        for _ in 0..n {
            let mut v = r.line()?;
            v.expect("variant")?;
            let var_name = bytes_text(&mut v)?;
            v.expect("types")?;
            let m = v.count(MAX_ITEMS)?;
            let mut tys = Vec::new();
            for _ in 0..m {
                tys.push(parse_type(&mut v, struct_count, enum_count, list_count)?);
            }
            v.done()?;
            variants.push((var_name, tys));
        }
        enums.push(EnumDef { name, variants });
    }
    let mut lists = Vec::new();
    for k in 0..list_count {
        let mut l = r.line()?;
        l.expect("list")?;
        if l.id('l', list_count)? != k {
            return l.fail("las listas deben aparecer en orden");
        }
        let elem_ty = parse_type(&mut l, struct_count, enum_count, list_count)?;
        l.done()?;
        lists.push(elem_ty);
    }
    let mut funcs = Vec::new();
    for index in 0..func_count {
        funcs.push(parse_func(
            &mut r, index, &structs, &enums, &lists, func_count,
        )?);
    }
    let end = r.line()?;
    if end.words != ["end"] {
        return end.fail("se esperaba 'end'");
    }
    if r.next != r.lines.len() {
        return Err(ProtocolError {
            line: r.next + 1,
            message: "contenido después de 'end'".into(),
        });
    }
    Ok(Module {
        structs,
        enums,
        arrays: Vec::new(),
        slices: Vec::new(),
        lists,
        task_groups: Vec::new(),
        futures: Vec::new(),
        funcs,
        main,
    })
}

/// Defensive checks of a parsed module before code generation: block LIR
/// well-formedness and ownership (no use after move, no double drop, no
/// leak at return) with the Stage 0 verifiers.
pub fn validate(module: &Module) -> Result<(), Diagnostic> {
    cfg::verify(module).map_err(cfg::VerifyError::into_diagnostic)?;
    let ownership = drops::Ownership::new(
        &module.structs,
        &module.enums,
        &module.arrays,
        &module.lists,
    );
    for func in &module.funcs {
        drops::verify(func, &ownership)
            .and_then(|()| drops::verify_flags(func, &ownership))
            .map_err(|v| {
                Diagnostic::new(
                    Span::at(1, 1),
                    format!(
                        "LIR rechazada en {} (bloque {}): {}",
                        func.name, v.block, v.message
                    ),
                )
                .classify("L0017", "lir-protocolo")
            })?;
    }
    Ok(())
}
