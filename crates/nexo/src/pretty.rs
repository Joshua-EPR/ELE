//! Impresión legible de programas NEXO-Core (informes del fuzzer, depuración).

use std::fmt::Write;

use crate::ir::*;

pub fn programa(p: &Programa) -> String {
    let mut s = String::new();
    for c in &p.clases {
        let campos: Vec<&str> = c
            .campos
            .iter()
            .map(|t| match t {
                TipoCampo::Int => "Int",
                TipoCampo::Enlace => "Enlace",
            })
            .collect();
        let _ = writeln!(
            s,
            "{}clase {} {{ {} }}",
            if c.enlazable { "enlazar " } else { "" },
            c.nombre,
            campos.join(", ")
        );
    }
    for f in &p.funciones {
        s.push_str(&funcion(p, f));
    }
    s
}

fn ty(p: &Programa, f: &Funcion, t: &Ty) -> String {
    let ub = |u: &Ubic| match u {
        Ubic::Pila => "pila".to_string(),
        Ubic::Pool(q) => f
            .pools
            .get(q.0 as usize)
            .map(|d| d.nombre.clone())
            .unwrap_or("?".into()),
    };
    let cl = |c: &ClaseId| {
        p.clases
            .get(c.0 as usize)
            .map(|c| c.nombre.clone())
            .unwrap_or("?".into())
    };
    let pn = |q: &PoolRef| {
        f.pools
            .get(q.0 as usize)
            .map(|d| d.nombre.clone())
            .unwrap_or("?".into())
    };
    match t {
        Ty::Int => "Int".into(),
        Ty::Dueno(c, u) => format!("dueño<{}@{}>", cl(c), ub(u)),
        Ty::Prestamo(Modo::View, c, u) => format!("view<{}@{}>", cl(c), ub(u)),
        Ty::Prestamo(Modo::Edit, c, u) => format!("edit<{}@{}>", cl(c), ub(u)),
        Ty::Enlace(q) => format!("Enlace<{}>", pn(q)),
        Ty::Hueco(q) => format!("hueco<{}>", pn(q)),
        Ty::Sello(q) => format!("Sello<{}>", pn(q)),
        Ty::Funcion(fi) => format!(
            "fn[{} pools{}{}]",
            fi.pools.len(),
            if fi.opaca { ", opaca" } else { "" },
            if fi.captura_mutable {
                ", captura_mutable"
            } else {
                ""
            }
        ),
    }
}

pub fn funcion(p: &Programa, f: &Funcion) -> String {
    let mut s = String::new();
    let pools: Vec<String> = f
        .pools
        .iter()
        .map(|d| {
            format!(
                "{} {:?}<{}>",
                d.nombre,
                d.permiso,
                p.clases
                    .get(d.clase.0 as usize)
                    .map(|c| c.nombre.as_str())
                    .unwrap_or("?")
            )
        })
        .collect();
    let params: Vec<String> = f
        .params
        .iter()
        .map(|v| format!("{}: {}", f.nombre_var(*v), ty(p, f, f.ty(*v))))
        .collect();
    let ret = f
        .ret
        .as_ref()
        .map(|t| format!(" -> {}", ty(p, f, t)))
        .unwrap_or_default();
    let _ = writeln!(
        s,
        "fn {}[{}]({}){ret} {{",
        f.nombre,
        pools.join(", "),
        params.join(", ")
    );
    bloque(p, f, &f.cuerpo, 1, &mut s);
    s.push_str("}\n");
    s
}

fn op(f: &Funcion, o: &Operando) -> String {
    match o {
        Operando::Const(k) => k.to_string(),
        Operando::Var(v) => n(f, *v),
    }
}

fn n(f: &Funcion, v: VarId) -> String {
    f.vars
        .get(v.0 as usize)
        .map(|d| d.nombre.clone())
        .unwrap_or(format!("#{}", v.0))
}

fn pn(f: &Funcion, q: PoolRef) -> String {
    f.pools
        .get(q.0 as usize)
        .map(|d| d.nombre.clone())
        .unwrap_or(format!("P#{}", q.0))
}

fn ops(f: &Funcion, os: &[Operando]) -> String {
    os.iter().map(|o| op(f, o)).collect::<Vec<_>>().join(", ")
}

fn nivel(x: &Option<Nivel>) -> String {
    x.map(|n| format!(" @{n}")).unwrap_or_default()
}

fn bloque(p: &Programa, f: &Funcion, b: &[Stmt], ind: usize, s: &mut String) {
    for st in b {
        stmt(p, f, st, ind, s);
    }
}

fn stmt(p: &Programa, f: &Funcion, st: &Stmt, ind: usize, s: &mut String) {
    let sang = "  ".repeat(ind);
    let linea = |s: &mut String, t: String| {
        let _ = writeln!(s, "{sang}{t}");
    };
    let sub = |s: &mut String, nombre: &str, b: &[Stmt]| {
        let _ = writeln!(s, "{sang}{nombre} {{");
        bloque(p, f, b, ind + 1, s);
        let _ = writeln!(s, "{sang}}}");
    };
    match st {
        Stmt::Const { dst, valor } => linea(s, format!("{} = {valor}", n(f, *dst))),
        Stmt::Copiar { dst, src } => linea(s, format!("{} = copiar {}", n(f, *dst), n(f, *src))),
        Stmt::Mover { dst, src } => linea(s, format!("{} = mover {}", n(f, *dst), n(f, *src))),
        Stmt::Aritmetica { dst, op: o, a, b } => linea(
            s,
            format!("{} = {:?}({}, {})", n(f, *dst), o, op(f, a), op(f, b)),
        ),
        Stmt::Crear {
            dst,
            clase,
            ubic,
            campos,
            invalida_epoca,
        } => linea(
            s,
            format!(
                "{} = crear {}@{}({}){}",
                n(f, *dst),
                p.clases
                    .get(clase.0 as usize)
                    .map(|c| c.nombre.as_str())
                    .unwrap_or("?"),
                match ubic {
                    Ubic::Pila => "pila".into(),
                    Ubic::Pool(q) => pn(f, *q),
                },
                ops(f, campos),
                if *invalida_epoca == Some(true) {
                    " !época"
                } else {
                    ""
                }
            ),
        ),
        Stmt::Destruir {
            src,
            hueco,
            implicito,
            condicional,
        } => linea(
            s,
            format!(
                "destruir{}{} {}{}",
                if *implicito { "_implícito" } else { "" },
                if *condicional { "_si_vivo" } else { "" },
                n(f, *src),
                hueco
                    .map(|h| format!(" -> {}", n(f, h)))
                    .unwrap_or_default()
            ),
        ),
        Stmt::ReusarHueco {
            dst, hueco, campos, ..
        } => linea(
            s,
            format!(
                "{} = reusar_hueco {}({})",
                n(f, *dst),
                n(f, *hueco),
                ops(f, campos)
            ),
        ),
        Stmt::LiberarHueco { hueco } => linea(s, format!("liberar_hueco {}", n(f, *hueco))),
        Stmt::Prestar { dst, src, modo } => {
            linea(s, format!("{} = {:?} {}", n(f, *dst), modo, n(f, *src)))
        }
        Stmt::Leer { dst, obj, campo } => {
            linea(s, format!("{} = {}.{campo}", n(f, *dst), n(f, *obj)))
        }
        Stmt::Escribir {
            obj,
            campo,
            valor,
            invalida_epoca,
        } => linea(
            s,
            format!(
                "{}.{campo} = {}{}",
                n(f, *obj),
                op(f, valor),
                if *invalida_epoca == Some(true) {
                    " !época"
                } else {
                    ""
                }
            ),
        ),
        Stmt::Enlazar { dst, obj } => linea(s, format!("{} = enlazar {}", n(f, *dst), n(f, *obj))),
        Stmt::Revalidar {
            enlace,
            modo,
            ligado,
            cuerpo,
            ausente,
            diferir,
            nivel: nv,
        } => {
            sub(
                s,
                &format!(
                    "revalidar{} {} {:?} como {}{}",
                    if *diferir { "_diferido" } else { "" },
                    n(f, *enlace),
                    modo,
                    n(f, *ligado),
                    nivel(nv)
                ),
                cuerpo,
            );
            sub(s, "ausente", ausente);
        }
        Stmt::RevalidarLote {
            enlaces,
            modo,
            ligados,
            cuerpo,
            ausente,
            niveles,
        } => {
            let pares: Vec<String> = enlaces
                .iter()
                .zip(ligados)
                .zip(niveles)
                .map(|((e, l), nv)| format!("{} como {}{}", n(f, *e), n(f, *l), nivel(nv)))
                .collect();
            sub(
                s,
                &format!("revalidar_lote {:?} [{}]", modo, pares.join(", ")),
                cuerpo,
            );
            sub(s, "ausente", ausente);
        }
        Stmt::Sellar { dst, pool } => linea(s, format!("{} = sellar {}", n(f, *dst), pn(f, *pool))),
        Stmt::SiSellado {
            sello,
            cuerpo,
            sino,
        } => {
            sub(s, &format!("si_sellado {}", n(f, *sello)), cuerpo);
            sub(s, "sino", sino);
        }
        Stmt::Reestructurar { pool } => linea(s, format!("reestructurar {}", pn(f, *pool))),
        Stmt::Congelar { pool, cuerpo } => sub(s, &format!("congelar {}", pn(f, *pool)), cuerpo),
        Stmt::Paralelo { hilos } => {
            for (i, h) in hilos.iter().enumerate() {
                sub(s, &format!("hilo {i}"), h);
            }
        }
        Stmt::Dividir {
            pool,
            partes,
            indice,
            cuerpo,
        } => sub(
            s,
            &format!("dividir {} en {partes} ({})", pn(f, *pool), n(f, *indice)),
            cuerpo,
        ),
        Stmt::TransferirPool { pool, cuerpo } => {
            sub(s, &format!("transferir {}", pn(f, *pool)), cuerpo)
        }
        Stmt::RefFuncion { dst, func } => linea(
            s,
            format!(
                "{} = &{}",
                n(f, *dst),
                p.funciones
                    .get(func.0 as usize)
                    .map(|g| g.nombre.as_str())
                    .unwrap_or("?")
            ),
        ),
        Stmt::Llamar {
            destino,
            pools,
            args,
            dst,
        } => {
            let nombre = match destino {
                Destino::Directa(g) => p
                    .funciones
                    .get(g.0 as usize)
                    .map(|g| g.nombre.clone())
                    .unwrap_or("?".into()),
                Destino::Indirecta(v) => format!("*{}", n(f, *v)),
            };
            let ps: Vec<String> = pools.iter().map(|q| pn(f, *q)).collect();
            let d = dst.map(|d| format!("{} = ", n(f, d))).unwrap_or_default();
            linea(
                s,
                format!("{d}{nombre}[{}]({})", ps.join(", "), ops(f, args)),
            )
        }
        Stmt::Si {
            cond,
            entonces,
            sino,
        } => {
            sub(s, &format!("si {}", op(f, cond)), entonces);
            sub(s, "sino", sino);
        }
        Stmt::Repetir {
            veces,
            indice,
            cuerpo,
        } => sub(
            s,
            &format!("repetir {} ({})", op(f, veces), n(f, *indice)),
            cuerpo,
        ),
        Stmt::Retornar { valor } => linea(
            s,
            format!(
                "retornar {}",
                valor.as_ref().map(|o| op(f, o)).unwrap_or_default()
            ),
        ),
    }
}
