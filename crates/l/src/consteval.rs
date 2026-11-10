//! Compile-time evaluation of the pure literal/operator subset of typed LIR.
use crate::{
    Diagnostic,
    lir::{Type, Value, ValueKind},
};

pub fn evaluate(value: &Value) -> Result<Value, Diagnostic> {
    validate(value)
        .and_then(|()| fold(value))
        .map_err(|e| e.classify("L0004", "const"))
}

fn validate(v: &Value) -> Result<(), Diagnostic> {
    match &v.kind {
        ValueKind::Int(_)
        | ValueKind::Float(_)
        | ValueKind::Bool(_)
        | ValueKind::Text(_)
        | ValueKind::Unit => Ok(()),
        ValueKind::Unary(_, a) => validate(a),
        ValueKind::Convert(a, _) => validate(a),
        ValueKind::Interpolate(parts) | ValueKind::Variant(_, _, parts) => {
            for part in parts {
                validate(part)?;
            }
            Ok(())
        }
        ValueKind::Binary(_, a, b) => {
            validate(a)?;
            validate(b)
        }
        _ => Err(Diagnostic::new(
            v.span,
            "const requiere expresión constante; variables runtime y llamadas no permitidas",
        )),
    }
}

fn fold(v: &Value) -> Result<Value, Diagnostic> {
    use ValueKind::*;
    let invalid = || Diagnostic::new(v.span, "operación constante inválida");
    let arithmetic = || {
        Diagnostic::new(
            v.span,
            "panic en const: overflow entero o división/resto por cero",
        )
    };
    let kind = match &v.kind {
        Interpolate(parts) => {
            let mut text = String::new();
            for part in parts {
                let value = fold(part)?;
                let piece = match value.kind {
                    Int(n) => n.to_string(),
                    Float(n) => n.to_string(),
                    Bool(b) => b.to_string(),
                    Text(s) => s,
                    _ => return Err(invalid()),
                };
                if text.len().saturating_add(piece.len()) > 1024 * 1024 {
                    return Err(Diagnostic::new(
                        v.span,
                        "límite de Text constante (1 MiB) excedido",
                    ));
                }
                text.push_str(&piece);
            }
            Text(text)
        }
        Unary(op, a) => match (op.as_str(), fold(a)?.kind) {
            ("-", Int(x)) => Int(x.checked_neg().ok_or_else(arithmetic)?),
            ("-", Float(x)) => Float(-x),
            ("!", Bool(x)) => Bool(!x),
            _ => return Err(invalid()),
        },
        Binary(op, a, b) => {
            let left = fold(a)?.kind;
            if op == "&&" && matches!(left, Bool(false)) {
                Bool(false)
            } else if op == "||" && matches!(left, Bool(true)) {
                Bool(true)
            } else {
                match (left, fold(b)?.kind) {
                    (Int(x), Int(y)) => match op.as_str() {
                        "+" => Int(x.checked_add(y).ok_or_else(arithmetic)?),
                        "-" => Int(x.checked_sub(y).ok_or_else(arithmetic)?),
                        "*" => Int(x.checked_mul(y).ok_or_else(arithmetic)?),
                        "/" => Int(x.checked_div(y).ok_or_else(arithmetic)?),
                        "%" => Int(x.checked_rem(y).ok_or_else(arithmetic)?),
                        "==" => Bool(x == y),
                        "!=" => Bool(x != y),
                        "<" => Bool(x < y),
                        "<=" => Bool(x <= y),
                        ">" => Bool(x > y),
                        ">=" => Bool(x >= y),
                        _ => return Err(invalid()),
                    },
                    (Float(x), Float(y)) => match op.as_str() {
                        "+" => Float(x + y),
                        "-" => Float(x - y),
                        "*" => Float(x * y),
                        "/" => Float(x / y),
                        "%" => Float(x % y),
                        "==" => Bool(x == y),
                        "!=" => Bool(x != y),
                        "<" => Bool(x < y),
                        "<=" => Bool(x <= y),
                        ">" => Bool(x > y),
                        ">=" => Bool(x >= y),
                        _ => return Err(invalid()),
                    },
                    (Bool(x), Bool(y)) => match op.as_str() {
                        "&&" => Bool(x && y),
                        "||" => Bool(x || y),
                        "==" => Bool(x == y),
                        "!=" => Bool(x != y),
                        _ => return Err(invalid()),
                    },
                    (Unit, Unit) if op == "==" || op == "!=" => Bool(op == "=="),
                    _ => return Err(invalid()),
                }
            }
        }
        Variant(id, variant, payload) => Variant(
            *id,
            *variant,
            payload.iter().map(fold).collect::<Result<_, _>>()?,
        ),
        Convert(a, target) => {
            let inner = fold(a)?;
            match (&inner.kind, target) {
                (Int(n), Type::Float) => Float(*n as f64),
                (Int(n), Type::F32) => Float((*n as f32) as f64),
                (Int(n), Type::Int) => Int(*n),
                (Float(x), Type::Float) => Float(*x),
                (Float(x), Type::F32) => Float((*x as f32) as f64),
                (Float(x), Type::Int) => {
                    let sat = if x.is_nan() {
                        0
                    } else if *x >= i64::MAX as f64 {
                        i64::MAX
                    } else if *x <= i64::MIN as f64 {
                        i64::MIN
                    } else {
                        *x as i64
                    };
                    Int(sat)
                }
                _ => return Err(invalid()),
            }
        }
        Int(_) | Float(_) | Bool(_) | Text(_) | Unit => v.kind.clone(),
        _ => return Err(invalid()),
    };
    Ok(Value {
        kind,
        ty: v.ty,
        span: v.span,
    })
}
