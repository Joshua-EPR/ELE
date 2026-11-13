//! Formación de huecos: dentro de un mismo bloque básico, un `destruir` de un
//! dueño del pool `P` seguido de un `crear` en `P` se reescribe como
//! `destruir … → hueco<P, s>` + `reusar_hueco`, de modo que el segundo objeto
//! ocupa el slot del primero sin tocar la lista libre (y `gen[s]` avanza +2).

use crate::ir::*;

/// Aplica la reescritura a todas las funciones. Devuelve cuántos pares se
/// fusionaron.
pub fn formar(p: &mut Programa) -> usize {
    let mut total = 0;
    for f in &mut p.funciones {
        let mut cuerpo = std::mem::take(&mut f.cuerpo);
        total += bloque(&mut cuerpo, &mut f.vars);
        f.cuerpo = cuerpo;
    }
    total
}

fn pool_de(vars: &[VarDecl], v: VarId) -> Option<PoolRef> {
    match vars.get(v.0 as usize)?.ty {
        Ty::Dueno(_, Ubic::Pool(p)) => Some(p),
        _ => None,
    }
}

fn bloque(b: &mut [Stmt], vars: &mut Vec<VarDecl>) -> usize {
    let mut n = 0;
    for s in b.iter_mut() {
        n += anidados(s, vars);
    }
    let mut inicio = 0;
    while inicio < b.len() {
        let mut fin = inicio;
        while fin < b.len() && !b[fin].es_compuesta() && !matches!(b[fin], Stmt::Retornar { .. }) {
            fin += 1;
        }
        n += segmento(&mut b[inicio..fin], vars);
        inicio = fin + 1;
    }
    n
}

fn anidados(s: &mut Stmt, vars: &mut Vec<VarDecl>) -> usize {
    match s {
        Stmt::Revalidar {
            cuerpo, ausente, ..
        }
        | Stmt::RevalidarLote {
            cuerpo, ausente, ..
        } => bloque(cuerpo, vars) + bloque(ausente, vars),
        Stmt::SiSellado { cuerpo, sino, .. } => bloque(cuerpo, vars) + bloque(sino, vars),
        Stmt::Si { entonces, sino, .. } => bloque(entonces, vars) + bloque(sino, vars),
        Stmt::Congelar { cuerpo, .. }
        | Stmt::Dividir { cuerpo, .. }
        | Stmt::TransferirPool { cuerpo, .. }
        | Stmt::Repetir { cuerpo, .. } => bloque(cuerpo, vars),
        Stmt::Paralelo { hilos } => hilos.iter_mut().map(|h| bloque(h, vars)).sum(),
        _ => 0,
    }
}

fn segmento(seg: &mut [Stmt], vars: &mut Vec<VarDecl>) -> usize {
    let mut n = 0;
    for i in 0..seg.len() {
        let (src, p) = match &seg[i] {
            Stmt::Destruir {
                src,
                hueco: None,
                implicito: false,
                condicional: false,
            } => match pool_de(vars, *src) {
                Some(p) => (*src, p),
                None => continue,
            },
            _ => continue,
        };
        let pareja = (i + 1..seg.len()).find(|&j| {
            matches!(&seg[j], Stmt::Crear { ubic: Ubic::Pool(q), dst, .. } if *q == p && *dst != src)
        });
        let Some(j) = pareja else { continue };
        let nombre = format!("hueco_{}", vars[src.0 as usize].nombre);
        vars.push(VarDecl {
            nombre,
            ty: Ty::Hueco(p),
        });
        let h = VarId(vars.len() as u32 - 1);
        if let Stmt::Destruir { hueco, .. } = &mut seg[i] {
            *hueco = Some(h);
        }
        if let Stmt::Crear { dst, campos, .. } = &seg[j] {
            seg[j] = Stmt::ReusarHueco {
                dst: *dst,
                hueco: h,
                campos: campos.clone(),
                invalida_epoca: None,
            };
        }
        n += 1;
    }
    n
}
