//! Pase 4: préstamos y concurrencia.
//!
//! * R6: dentro de `revalidar l en B` sobre `P` ninguna sentencia tiene el
//!   efecto `destruye(P)`, salvo destrucciones encoladas con `diferir`; dentro
//!   de `si_sellado(P)` tampoco se invalida la época.
//! * R7: exclusividad. Cada préstamo tiene una raíz: un dueño local, un
//!   préstamo parámetro o el espacio de objetos de `P` alcanzado por enlaces
//!   (`ligado`). Los objetos de `P` alcanzados por enlaces pueden ser los de
//!   cualquier dueño de `P`, así que esas raíces se solapan. Un acceso de
//!   escritura o consumo a una raíz choca con todo préstamo vivo solapado; uno
//!   de lectura, con los préstamos `edit`. La vida de un préstamo es su
//!   *liveness* (último uso), no su ámbito léxico.
//! * C1–C6: concurrencia estructurada.

use std::collections::{HashMap, HashSet};

use crate::diag::{Diags, Regla, Ruta, nombres_bloques};
use crate::ir::*;

use super::efectos::{EfectoPool, NivelEfecto, Resumen, efecto_llamada};

pub fn verificar(p: &Programa, tabla: &[Resumen], d: &mut Diags) {
    for f in &p.funciones {
        let mut vivos = HashMap::new();
        liveness(&f.cuerpo, &HashSet::new(), &mut vivos);
        let mut c = Prest {
            p,
            f,
            tabla,
            d,
            vivos,
            raices: HashMap::new(),
            padre: HashMap::new(),
            lotes: HashMap::new(),
            protegidos: Vec::new(),
            congelados: Vec::new(),
            transferidos: HashSet::new(),
            concurrente: 0,
            bucles: 0,
            transfiriendo: Vec::new(),
            trabajadores: Vec::new(),
        };
        for v in &f.params {
            if matches!(f.ty(*v), Ty::Prestamo(..)) {
                c.raices.insert(*v, Raiz::Param(*v));
            }
        }
        c.bloque(&f.cuerpo, &Ruta::raiz(), "cuerpo");
    }
}

fn clave(s: &Stmt) -> usize {
    s as *const Stmt as usize
}

/// Liveness hacia atrás: guarda en `mapa` las variables vivas tras cada
/// sentencia y devuelve las vivas a la entrada del bloque.
fn liveness(
    b: &[Stmt],
    fuera: &HashSet<VarId>,
    mapa: &mut HashMap<usize, HashSet<VarId>>,
) -> HashSet<VarId> {
    let mut vivo = fuera.clone();
    for s in b.iter().rev() {
        mapa.insert(clave(s), vivo.clone());
        vivo = transferir(s, &vivo, mapa);
    }
    vivo
}

fn transferir(
    s: &Stmt,
    fuera: &HashSet<VarId>,
    mapa: &mut HashMap<usize, HashSet<VarId>>,
) -> HashSet<VarId> {
    let mut r: HashSet<VarId> = match s {
        Stmt::Retornar { .. } => HashSet::new(),
        Stmt::Repetir { cuerpo, indice, .. } => {
            let mut x = fuera.clone();
            for _ in 0..64 {
                let mut nuevo = fuera.clone();
                nuevo.extend(liveness(cuerpo, &x, mapa));
                nuevo.remove(indice);
                if nuevo == x {
                    break;
                }
                x = nuevo;
            }
            liveness(cuerpo, &x, mapa);
            x
        }
        _ if s.es_compuesta() => {
            let mut x = HashSet::new();
            for b in s.bloques() {
                x.extend(liveness(b, fuera, mapa));
            }
            if matches!(
                s,
                Stmt::Congelar { .. } | Stmt::Dividir { .. } | Stmt::TransferirPool { .. }
            ) || s.bloques().iter().any(|b| b.is_empty())
            {
                x.extend(fuera.iter().copied());
            }
            match s {
                Stmt::Revalidar { ligado, .. } => {
                    x.remove(ligado);
                }
                Stmt::RevalidarLote { ligados, .. } => {
                    for l in ligados {
                        x.remove(l);
                    }
                }
                Stmt::Dividir { indice, .. } => {
                    x.remove(indice);
                }
                _ => {}
            }
            x
        }
        _ => {
            let mut x = fuera.clone();
            for d in s.defs() {
                x.remove(&d);
            }
            x
        }
    };
    r.extend(s.usos());
    r
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Raiz {
    /// Dueño local.
    Var(VarId),
    /// Préstamo recibido como parámetro.
    Param(VarId),
    /// Objetos de `P` alcanzados por enlaces revalidados.
    Ligado(PoolRef),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Acceso {
    Lectura,
    Escritura,
    Consumo,
}

impl Acceso {
    fn texto(self) -> &'static str {
        match self {
            Acceso::Lectura => "lectura",
            Acceso::Escritura => "escritura",
            Acceso::Consumo => "consumo",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum R6Tipo {
    /// Libera slots (diferible con `revalidar … diferir`).
    Libera,
    /// Reestructura el almacenamiento (nunca diferible).
    Reestructura,
    /// Almacena un enlace no probado (incrementa la época).
    InvalidaEpoca,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Proteccion {
    Revalidar { diferir: bool },
    Sellado,
}

struct Trabajador {
    pool: PoolRef,
    definidas: HashSet<VarId>,
    propios: HashSet<VarId>,
}

struct Prest<'a> {
    p: &'a Programa,
    f: &'a Funcion,
    tabla: &'a [Resumen],
    d: &'a mut Diags,
    vivos: HashMap<usize, HashSet<VarId>>,
    raices: HashMap<VarId, Raiz>,
    padre: HashMap<VarId, VarId>,
    /// Ligado de `revalidar_lote` edit → identificador del lote.
    lotes: HashMap<VarId, usize>,
    protegidos: Vec<(PoolRef, Proteccion)>,
    congelados: Vec<PoolRef>,
    transferidos: HashSet<PoolRef>,
    concurrente: usize,
    bucles: usize,
    /// Pools cuyo cuerpo de transferencia se está recorriendo.
    transfiriendo: Vec<PoolRef>,
    trabajadores: Vec<Trabajador>,
}

impl Prest<'_> {
    fn err(&mut self, r: Regla, ruta: &Ruta, m: String) {
        self.d.emitir(r, &self.f.nombre, &ruta.texto(), m);
    }

    fn n(&self, v: VarId) -> String {
        format!("`{}`", self.f.nombre_var(v))
    }

    fn np(&self, p: PoolRef) -> String {
        format!("`{}`", self.f.nombre_pool(p))
    }

    fn pool_var(&self, v: VarId) -> Option<PoolRef> {
        self.f.ty(v).pool()
    }

    fn pool_raiz(&self, r: Raiz) -> Option<PoolRef> {
        match r {
            Raiz::Var(v) | Raiz::Param(v) => match self.f.ty(v) {
                Ty::Dueno(_, Ubic::Pool(q)) | Ty::Prestamo(_, _, Ubic::Pool(q)) => Some(*q),
                _ => None,
            },
            Raiz::Ligado(q) => Some(q),
        }
    }

    fn solapan(&self, a: Raiz, b: Raiz) -> bool {
        match (a, b) {
            (Raiz::Var(x), Raiz::Var(y)) | (Raiz::Param(x), Raiz::Param(y)) => x == y,
            (Raiz::Ligado(p), Raiz::Ligado(q)) => p == q,
            (Raiz::Ligado(p), o) | (o, Raiz::Ligado(p)) => self.pool_raiz(o) == Some(p),
            _ => false,
        }
    }

    fn modo(&self, b: VarId) -> Modo {
        match self.f.ty(b) {
            Ty::Prestamo(m, ..) => *m,
            _ => Modo::View,
        }
    }

    fn raiz_de(&self, v: VarId) -> Option<Raiz> {
        match self.f.ty(v) {
            Ty::Dueno(..) => Some(Raiz::Var(v)),
            Ty::Prestamo(..) => self.raices.get(&v).copied(),
            _ => None,
        }
    }

    /// Lote (en modo edit) del que procede el préstamo `b`, si lo hay.
    fn lote_de_raiz(&self, b: VarId) -> Option<usize> {
        let mut x = b;
        loop {
            if let Some(l) = self.lotes.get(&x) {
                return Some(*l);
            }
            x = *self.padre.get(&x)?;
        }
    }

    fn ancestros(&self, b: VarId) -> HashSet<VarId> {
        let mut r = HashSet::new();
        let mut x = Some(b);
        while let Some(v) = x {
            if !r.insert(v) {
                break;
            }
            x = self.padre.get(&v).copied();
        }
        r
    }

    /// Préstamos vivos tras `s` (sin los que define `s`).
    fn prestamos_vivos(&self, s: &Stmt) -> Vec<VarId> {
        let defs = s.defs();
        let mut v: Vec<VarId> = self
            .vivos
            .get(&clave(s))
            .map(|x| {
                x.iter()
                    .copied()
                    .filter(|b| matches!(self.f.ty(*b), Ty::Prestamo(..)) && !defs.contains(b))
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }

    /// Comprueba un acceso a `raiz` contra los préstamos vivos. `via` es el
    /// préstamo por el que se accede (se excluyen él y sus ancestros).
    #[allow(clippy::too_many_arguments)]
    fn acceso(
        &mut self,
        s: &Stmt,
        raiz: Raiz,
        tipo: Acceso,
        via: Option<VarId>,
        extra: &[VarId],
        regla: Regla,
        ruta: &Ruta,
        que: &str,
    ) {
        let excluidos = via.map(|b| self.ancestros(b)).unwrap_or_default();
        // Los ligados hermanos de un mismo `revalidar_lote` apuntan a slots
        // distintos: el runtime lo comprueba antes de entrar al cuerpo.
        let lote_via = via.and_then(|b| self.lote_de_raiz(b));
        let mut candidatos = self.prestamos_vivos(s);
        for e in extra {
            if !candidatos.contains(e) {
                candidatos.push(*e);
            }
        }
        for b in candidatos {
            if excluidos.contains(&b) {
                continue;
            }
            if lote_via.is_some() && self.lote_de_raiz(b) == lote_via {
                continue;
            }
            let Some(rb) = self.raices.get(&b).copied() else {
                continue;
            };
            // Consumir (mover/destruir) un dueño solo choca con los préstamos
            // tomados de ese mismo dueño: la interacción de una liberación con
            // los objetos alcanzados por enlaces es materia de R6 (y de
            // `diferir`), y mover no altera la memoria.
            if tipo == Acceso::Consumo && rb != raiz {
                continue;
            }
            if !self.solapan(rb, raiz) {
                continue;
            }
            let mb = self.modo(b);
            if tipo == Acceso::Lectura && mb == Modo::View {
                continue;
            }
            let pista = if matches!((rb, raiz), (Raiz::Ligado(_), Raiz::Ligado(_))) {
                "; para acceder a varios objetos del pool a la vez use `revalidar_lote`"
            } else {
                ""
            };
            let m = format!(
                "{que}: {} sobre {} mientras el préstamo {} ({}) sigue vivo{pista}",
                tipo.texto(),
                self.texto_raiz(raiz),
                self.n(b),
                if mb == Modo::Edit { "edit" } else { "view" }
            );
            self.err(regla, ruta, m);
        }
    }

    fn texto_raiz(&self, r: Raiz) -> String {
        match r {
            Raiz::Var(v) | Raiz::Param(v) => self.n(v),
            Raiz::Ligado(q) => format!("los objetos de {} alcanzados por enlaces", self.np(q)),
        }
    }

    /// Acceso a un objeto `obj` (dueño directo o a través de un préstamo).
    fn acceso_obj(&mut self, s: &Stmt, obj: VarId, tipo: Acceso, ruta: &Ruta, que: &str) {
        let Some(r) = self.raiz_de(obj) else { return };
        let via = matches!(self.f.ty(obj), Ty::Prestamo(..)).then_some(obj);
        self.acceso(s, r, tipo, via, &[], Regla::R7, ruta, que);
    }

    fn pools_de_stmt(&self, s: &Stmt) -> HashSet<PoolRef> {
        let mut r = HashSet::new();
        match s {
            Stmt::Crear {
                ubic: Ubic::Pool(q),
                ..
            } => {
                r.insert(*q);
            }
            Stmt::Sellar { pool, .. }
            | Stmt::Reestructurar { pool }
            | Stmt::Congelar { pool, .. }
            | Stmt::Dividir { pool, .. }
            | Stmt::TransferirPool { pool, .. } => {
                r.insert(*pool);
            }
            Stmt::Llamar { pools, .. } => r.extend(pools.iter().copied()),
            _ => {}
        }
        for v in s.usos().into_iter().chain(s.defs()) {
            if let Some(q) = self.pool_var(v) {
                r.insert(q);
            }
        }
        match s {
            Stmt::Revalidar { ligado, .. } => {
                if let Some(q) = self.pool_var(*ligado) {
                    r.insert(q);
                }
            }
            Stmt::Dividir { .. } | Stmt::Repetir { .. } => {}
            _ => {}
        }
        r
    }

    fn bloque(&mut self, b: &[Stmt], padre: &Ruta, nombre: &str) {
        for (i, s) in b.iter().enumerate() {
            let ruta = padre.hijo(nombre, i);
            self.stmt(s, &ruta);
        }
    }

    /// R6: efecto destructivo `tipo` sobre `q` dentro de un bloque protegido.
    fn r6(&mut self, q: PoolRef, tipo: R6Tipo, ruta: &Ruta, que: &str) {
        let prot: Vec<Proteccion> = self
            .protegidos
            .iter()
            .filter(|(p, _)| *p == q)
            .map(|(_, k)| *k)
            .collect();
        let pool = self.f.nombre_pool(q).to_string();
        for k in prot {
            let m = match (k, tipo) {
                (Proteccion::Sellado, R6Tipo::InvalidaEpoca) => format!(
                    "{que} almacena un enlace no probado en `{pool}` dentro de `si_sellado`: invalidaría la época validada"
                ),
                (Proteccion::Sellado, _) => format!(
                    "{que} tiene el efecto destruye({pool}) dentro de `si_sellado`: la época validada dejaría de valer"
                ),
                (Proteccion::Revalidar { diferir: false }, R6Tipo::Libera) => format!(
                    "{que} tiene el efecto destruye({pool}) dentro de un `revalidar` sobre ese pool; use `revalidar … diferir` para encolar la destrucción a la salida del bloque"
                ),
                (Proteccion::Revalidar { .. }, R6Tipo::Reestructura) => format!(
                    "{que} reestructura `{pool}` dentro de un `revalidar` sobre ese pool (una reestructuración no puede diferirse)"
                ),
                _ => continue,
            };
            self.err(Regla::R6, ruta, m);
            return;
        }
    }

    fn c3(&mut self, q: PoolRef, ruta: &Ruta, que: &str) {
        if self.congelados.contains(&q) {
            let m = format!("{que} modifica el pool congelado {}", self.np(q));
            self.err(Regla::C3, ruta, m);
        }
    }

    /// Mutación de una variable externa dentro de un trabajador de `dividir`.
    fn c5_mutacion(&mut self, v: VarId, ruta: &Ruta, que: &str) {
        let Some(t) = self.trabajadores.last() else {
            return;
        };
        let raiz = match self.raiz_de(v) {
            Some(Raiz::Var(x)) | Some(Raiz::Param(x)) => x,
            Some(Raiz::Ligado(_)) | None => v,
        };
        if !t.definidas.contains(&raiz) && !t.definidas.contains(&v) {
            let m = format!(
                "{que}: un trabajador de `dividir` muta {}, que es externo y lo comparten todas las particiones",
                self.n(v)
            );
            self.err(Regla::C5, ruta, m);
        }
    }

    fn post_transferencia(&mut self, s: &Stmt, ruta: &Ruta) {
        if self.transferidos.is_empty() {
            return;
        }
        let usados = self.pools_de_stmt(s);
        let mut malos: Vec<PoolRef> = usados.intersection(&self.transferidos).copied().collect();
        malos.sort();
        for q in malos {
            let m = format!(
                "el pool {} ya fue transferido a otro hilo y no puede usarse aquí",
                self.np(q)
            );
            self.err(Regla::C2, ruta, m);
        }
    }

    fn stmt(&mut self, s: &Stmt, ruta: &Ruta) {
        self.post_transferencia(s, ruta);
        let nb = nombres_bloques(s);
        match s {
            Stmt::Copiar { dst, src } => {
                if let Some(r) = self.raices.get(src).copied() {
                    self.raices.insert(*dst, r);
                    self.padre.insert(*dst, *src);
                }
                if self
                    .trabajadores
                    .last()
                    .is_some_and(|t| t.propios.contains(src))
                    && let Some(t) = self.trabajadores.last_mut()
                {
                    t.propios.insert(*dst);
                }
            }
            Stmt::Mover { src, .. } => {
                self.acceso(
                    s,
                    Raiz::Var(*src),
                    Acceso::Consumo,
                    None,
                    &[],
                    Regla::R7,
                    ruta,
                    "mover",
                );
            }
            Stmt::Crear { ubic, .. } => {
                if let Ubic::Pool(q) = ubic {
                    self.c3(*q, ruta, "crear");
                }
            }
            Stmt::ReusarHueco { hueco, .. } | Stmt::LiberarHueco { hueco } => {
                if let Ty::Hueco(q) = self.f.ty(*hueco) {
                    let q = *q;
                    self.c3(q, ruta, s.nombre());
                }
            }
            Stmt::Destruir { src, implicito, .. } => {
                let que = if *implicito {
                    format!(
                        "la destrucción implícita de {} al cerrar su ámbito",
                        self.n(*src)
                    )
                } else {
                    format!("destruir {}", self.n(*src))
                };
                self.acceso(
                    s,
                    Raiz::Var(*src),
                    Acceso::Consumo,
                    None,
                    &[],
                    Regla::R7,
                    ruta,
                    &que,
                );
                if let Ty::Dueno(_, Ubic::Pool(q)) = self.f.ty(*src) {
                    let q = *q;
                    self.r6(q, R6Tipo::Libera, ruta, &que);
                    self.c3(q, ruta, &que);
                }
            }
            Stmt::Prestar { dst, src, modo } => {
                let tipo = if *modo == Modo::Edit {
                    Acceso::Escritura
                } else {
                    Acceso::Lectura
                };
                self.acceso_obj(s, *src, tipo, ruta, "prestar");
                if let Some(r) = self.raiz_de(*src) {
                    self.raices.insert(*dst, r);
                    if matches!(self.f.ty(*src), Ty::Prestamo(..)) {
                        self.padre.insert(*dst, *src);
                    }
                }
                if *modo == Modo::Edit {
                    if let Some(q) = self.pool_var(*src) {
                        self.c3(q, ruta, "prestar en modo edit");
                    }
                    self.c5_mutacion(*src, ruta, "prestar en modo edit");
                }
            }
            Stmt::Leer { obj, .. } => self.acceso_obj(s, *obj, Acceso::Lectura, ruta, "leer"),
            Stmt::Enlazar { obj, dst } => {
                self.acceso_obj(s, *obj, Acceso::Lectura, ruta, "enlazar");
                let propio = self.trabajadores.last().is_some_and(|t| {
                    let raiz = match self.raiz_de(*obj) {
                        Some(Raiz::Var(x)) => x,
                        _ => *obj,
                    };
                    t.definidas.contains(&raiz)
                });
                if propio && let Some(t) = self.trabajadores.last_mut() {
                    t.propios.insert(*dst);
                }
            }
            Stmt::Escribir {
                obj,
                invalida_epoca,
                ..
            } => {
                self.acceso_obj(s, *obj, Acceso::Escritura, ruta, "escribir");
                if let Some(q) = self.pool_var(*obj) {
                    self.c3(q, ruta, "escribir");
                    if invalida_epoca.unwrap_or(true) {
                        self.r6(q, R6Tipo::InvalidaEpoca, ruta, "escribir");
                    }
                }
                self.c5_mutacion(*obj, ruta, "escribir");
            }
            Stmt::Revalidar {
                enlace,
                modo,
                ligado,
                cuerpo,
                ausente,
                diferir,
                ..
            } => {
                let Ty::Enlace(q) = *self.f.ty(*enlace) else {
                    return;
                };
                self.revalidar_comun(s, q, *modo, &[*enlace], ruta);
                self.raices.insert(*ligado, Raiz::Ligado(q));
                self.protegidos
                    .push((q, Proteccion::Revalidar { diferir: *diferir }));
                self.bloque(cuerpo, ruta, &nb[0]);
                self.protegidos.pop();
                self.bloque(ausente, ruta, &nb[1]);
            }
            Stmt::RevalidarLote {
                enlaces,
                modo,
                ligados,
                cuerpo,
                ausente,
                ..
            } => {
                let mut pools: Vec<PoolRef> = Vec::new();
                for (e, l) in enlaces.iter().zip(ligados) {
                    if let Ty::Enlace(q) = *self.f.ty(*e) {
                        if !pools.contains(&q) {
                            pools.push(q);
                        }
                        self.raices.insert(*l, Raiz::Ligado(q));
                        if *modo == Modo::Edit {
                            let id = clave(s);
                            self.lotes.insert(*l, id);
                        }
                    }
                }
                for q in &pools {
                    self.revalidar_comun(s, *q, *modo, enlaces, ruta);
                    self.protegidos
                        .push((*q, Proteccion::Revalidar { diferir: false }));
                }
                self.bloque(cuerpo, ruta, &nb[0]);
                for _ in &pools {
                    self.protegidos.pop();
                }
                self.bloque(ausente, ruta, &nb[1]);
            }
            Stmt::Sellar { pool, .. } => {
                self.acceso(
                    s,
                    Raiz::Ligado(*pool),
                    Acceso::Lectura,
                    None,
                    &[],
                    Regla::R7,
                    ruta,
                    "sellar",
                );
                self.c5_pool(*pool, ruta, "sellar");
            }
            Stmt::SiSellado {
                sello,
                cuerpo,
                sino,
            } => {
                if let Ty::Sello(q) = *self.f.ty(*sello) {
                    self.c5_pool(q, ruta, "si_sellado");
                    self.protegidos.push((q, Proteccion::Sellado));
                    self.bloque(cuerpo, ruta, &nb[0]);
                    self.protegidos.pop();
                } else {
                    self.bloque(cuerpo, ruta, &nb[0]);
                }
                self.bloque(sino, ruta, &nb[1]);
            }
            Stmt::Reestructurar { pool } => {
                self.acceso(
                    s,
                    Raiz::Ligado(*pool),
                    Acceso::Escritura,
                    None,
                    &[],
                    Regla::R7,
                    ruta,
                    "reestructurar (invalida los préstamos derivados del pool)",
                );
                self.r6(*pool, R6Tipo::Reestructura, ruta, "reestructurar");
                self.c3(*pool, ruta, "reestructurar");
                self.c5_pool(*pool, ruta, "reestructurar");
            }
            Stmt::Congelar { pool, cuerpo } => {
                // Congelar el pool que se está dividiendo desde un trabajador
                // no detiene a los demás trabajadores, que siguen mutándolo.
                self.c5_pool(*pool, ruta, "congelar");
                self.congelados.push(*pool);
                self.bloque(cuerpo, ruta, &nb[0]);
                self.congelados.pop();
            }
            Stmt::Paralelo { hilos } => {
                self.paralelo(hilos, ruta);
                self.concurrente += 1;
                for (i, h) in hilos.iter().enumerate() {
                    self.bloque(h, ruta, &nb[i]);
                }
                self.concurrente -= 1;
            }
            Stmt::Dividir {
                pool,
                partes,
                indice,
                cuerpo,
            } => {
                self.acceso(
                    s,
                    Raiz::Ligado(*pool),
                    Acceso::Escritura,
                    None,
                    &[],
                    Regla::C6,
                    ruta,
                    "dividir exige edit exclusivo del pool",
                );
                if self.congelados.contains(pool) {
                    let m = format!("no se puede dividir el pool congelado {}", self.np(*pool));
                    self.err(Regla::C6, ruta, m);
                }
                if self.protegidos.iter().any(|(q, _)| q == pool) {
                    let m = format!(
                        "dividir {} dentro de un revalidar/si_sellado sobre ese pool",
                        self.np(*pool)
                    );
                    self.err(Regla::C6, ruta, m);
                }
                // Un trabajador solo posee su partición: no puede volver a
                // dividir el pool entero.
                self.c5_pool(*pool, ruta, "dividir de nuevo");
                let mut definidas = HashSet::new();
                definidas.insert(*indice);
                recolectar_defs(cuerpo, &mut definidas);
                // Otros pools en un cuerpo replicado ≥ 2 veces: C1.
                if *partes >= 2 {
                    let mut info = InfoHilo::default();
                    self.recolectar(cuerpo, &mut info);
                    let mut otros: Vec<PoolRef> = info
                        .pools
                        .iter()
                        .copied()
                        .filter(|q| q != pool && !self.congelados.contains(q))
                        .collect();
                    otros.sort();
                    for q in otros {
                        let m = format!(
                            "los {partes} trabajadores de `dividir` usarían el pool {}, que no está congelado: los pools son locales al hilo",
                            self.np(q)
                        );
                        self.err(Regla::C1, ruta, m);
                    }
                }
                self.trabajadores.push(Trabajador {
                    pool: *pool,
                    definidas,
                    propios: HashSet::new(),
                });
                // El cuerpo se ejecuta una vez por partición: a efectos de
                // transferencias (C2) es como un bucle.
                self.concurrente += 1;
                self.bucles += 1;
                self.bloque(cuerpo, ruta, &nb[0]);
                self.bucles -= 1;
                self.concurrente -= 1;
                self.trabajadores.pop();
            }
            Stmt::TransferirPool { pool, cuerpo } => {
                self.transferir(s, *pool, cuerpo, ruta, &nb[0])
            }
            Stmt::Llamar {
                destino,
                pools,
                args,
                ..
            } => self.llamar(s, destino, pools, args, ruta),
            Stmt::Si { entonces, sino, .. } => {
                self.bloque(entonces, ruta, &nb[0]);
                self.bloque(sino, ruta, &nb[1]);
            }
            Stmt::Repetir { cuerpo, .. } => {
                self.bucles += 1;
                self.bloque(cuerpo, ruta, &nb[0]);
                self.bucles -= 1;
            }
            Stmt::Retornar { .. } => {
                if self.concurrente > 0 {
                    self.err(
                        Regla::R1,
                        ruta,
                        "`retornar` dentro de un hilo, trabajador o transferencia: los cuerpos concurrentes terminan al final de su bloque".into(),
                    );
                }
            }
            Stmt::Const { .. } | Stmt::Aritmetica { .. } | Stmt::RefFuncion { .. } => {}
        }
    }

    fn c5_pool(&mut self, q: PoolRef, ruta: &Ruta, que: &str) {
        if self.trabajadores.iter().any(|t| t.pool == q) {
            let m = format!(
                "{que} sobre {} dentro de `dividir`: la época y la estructura del pool son compartidas por todas las particiones",
                self.np(q)
            );
            self.err(Regla::C5, ruta, m);
        }
    }

    fn revalidar_comun(
        &mut self,
        s: &Stmt,
        q: PoolRef,
        modo: Modo,
        enlaces: &[VarId],
        ruta: &Ruta,
    ) {
        let tipo = if modo == Modo::Edit {
            Acceso::Escritura
        } else {
            Acceso::Lectura
        };
        self.acceso(
            s,
            Raiz::Ligado(q),
            tipo,
            None,
            &[],
            Regla::R7,
            ruta,
            s.nombre(),
        );
        if modo == Modo::Edit {
            self.c3(q, ruta, "revalidar en modo edit");
            let mut ajenos: Vec<VarId> = Vec::new();
            if let Some(t) = self.trabajadores.iter().rev().find(|t| t.pool == q) {
                ajenos = enlaces
                    .iter()
                    .copied()
                    .filter(|e| !t.propios.contains(e))
                    .collect();
            }
            for e in ajenos {
                let m = format!(
                    "revalidar {} en modo edit dentro de `dividir`: el enlace no procede de un objeto creado por este trabajador y podría apuntar a otra partición",
                    self.n(e)
                );
                self.err(Regla::C5, ruta, m);
            }
        }
    }

    fn transferir(&mut self, s: &Stmt, q: PoolRef, cuerpo: &[Stmt], ruta: &Ruta, nombre: &str) {
        self.c5_pool(q, ruta, "transferir");
        if self.transfiriendo.contains(&q) {
            let m = format!(
                "retransferir {} desde el hilo que lo recibió: el pool se destruye al terminar ese hilo y no puede cederse otra vez",
                self.np(q)
            );
            self.err(Regla::C2, ruta, m);
        }
        if self.congelados.contains(&q) {
            let m = format!("transferir el pool congelado {}", self.np(q));
            self.err(Regla::C3, ruta, m);
        }
        if self.protegidos.iter().any(|(p, _)| *p == q) {
            let m = format!(
                "transferir {} dentro de un revalidar/si_sellado sobre ese pool",
                self.np(q)
            );
            self.err(Regla::R6, ruta, m);
        }
        if self.bucles > 0 {
            let m = format!(
                "transferir {} dentro de un bucle o de un cuerpo replicado de `dividir`: la segunda ejecución usaría un pool ya cedido",
                self.np(q)
            );
            self.err(Regla::C2, ruta, m);
        }
        // Préstamos vivos hacia P al ceder el pool.
        let vivos = self.prestamos_vivos(s);
        for b in vivos {
            if let Some(r) = self.raices.get(&b).copied()
                && self.pool_raiz(r) == Some(q)
            {
                let m = format!(
                    "el préstamo {} hacia {} sigue vivo al transferir el pool",
                    self.n(b),
                    self.np(q)
                );
                self.err(Regla::C2, ruta, m);
            }
        }
        // Enlaces vivos en el hilo origen tras la transferencia.
        let mut enlaces: Vec<VarId> = self
            .vivos
            .get(&clave(s))
            .map(|x| {
                x.iter()
                    .copied()
                    .filter(|v| self.f.ty(*v) == &Ty::Enlace(q))
                    .collect()
            })
            .unwrap_or_default();
        enlaces.sort();
        for e in enlaces {
            let m = format!(
                "el enlace {} a {} sigue vivo en el hilo origen tras transferir el pool",
                self.n(e),
                self.np(q)
            );
            self.err(Regla::C2, ruta, m);
        }
        // El hilo destino solo puede capturar valores que viajan con el pool.
        let mut info = InfoHilo::default();
        self.recolectar(cuerpo, &mut info);
        let mut externos: Vec<VarId> = info
            .vars
            .keys()
            .copied()
            .filter(|v| !info.defs.contains(v))
            .collect();
        externos.sort();
        for v in externos {
            let ok = match self.f.ty(v) {
                Ty::Int | Ty::Funcion(_) => true,
                Ty::Enlace(p) | Ty::Sello(p) => *p == q,
                Ty::Dueno(_, Ubic::Pool(p)) => *p == q,
                Ty::Prestamo(..) => {
                    let m = format!(
                        "el préstamo {} no puede capturarse en el hilo destino de una transferencia",
                        self.n(v)
                    );
                    self.err(Regla::R5, ruta, m);
                    true
                }
                _ => false,
            };
            if !ok {
                let m = format!(
                    "el hilo destino de `transferir_pool` captura {}, que no viaja con el pool {}",
                    self.n(v),
                    self.np(q)
                );
                self.err(Regla::C2, ruta, m);
            }
        }
        let mut otros: Vec<PoolRef> = info.pools.iter().copied().filter(|p| *p != q).collect();
        otros.sort();
        for p in otros {
            let m = format!("el hilo destino usa el pool {} del hilo origen", self.np(p));
            self.err(Regla::C1, ruta, m);
        }
        self.concurrente += 1;
        self.transfiriendo.push(q);
        self.bloque(cuerpo, ruta, nombre);
        self.transfiriendo.pop();
        self.concurrente -= 1;
        self.transferidos.insert(q);
    }

    fn llamar(
        &mut self,
        s: &Stmt,
        destino: &Destino,
        pools: &[PoolRef],
        args: &[Operando],
        ruta: &Ruta,
    ) {
        let mut prestados: Vec<VarId> = Vec::new();
        for a in args {
            let Operando::Var(v) = a else { continue };
            match self.f.ty(*v) {
                Ty::Dueno(..) => {
                    // El llamado puede escribir el objeto directamente: cuenta
                    // como escritura sobre todo lo que lo solape (incluidos
                    // los objetos de su pool alcanzados por enlaces).
                    self.acceso(
                        s,
                        Raiz::Var(*v),
                        Acceso::Escritura,
                        None,
                        &[],
                        Regla::R7,
                        ruta,
                        "pasar por valor",
                    );
                }
                Ty::Prestamo(m, ..) => {
                    if *m == Modo::Edit {
                        self.c5_mutacion(*v, ruta, "pasar como edit");
                    }
                    prestados.push(*v);
                }
                _ => {}
            }
        }
        // Alias entre argumentos.
        for (i, a) in prestados.iter().enumerate() {
            for b in &prestados[i + 1..] {
                let (Some(ra), Some(rb)) =
                    (self.raices.get(a).copied(), self.raices.get(b).copied())
                else {
                    continue;
                };
                if self.solapan(ra, rb)
                    && (self.modo(*a) == Modo::Edit || self.modo(*b) == Modo::Edit)
                {
                    let m = format!(
                        "los argumentos {} y {} pueden apuntar al mismo objeto y uno de ellos es edit",
                        self.n(*a),
                        self.n(*b)
                    );
                    self.err(Regla::R7, ruta, m);
                }
            }
        }
        for a in &prestados {
            let Some(r) = self.raices.get(a).copied() else {
                continue;
            };
            let tipo = if self.modo(*a) == Modo::Edit {
                Acceso::Escritura
            } else {
                Acceso::Lectura
            };
            let mut excl = self.ancestros(*a);
            excl.extend(prestados.iter().copied());
            let vivos: Vec<VarId> = self
                .prestamos_vivos(s)
                .into_iter()
                .filter(|b| !excl.contains(b))
                .collect();
            for b in vivos {
                let Some(rb) = self.raices.get(&b).copied() else {
                    continue;
                };
                if self.solapan(r, rb) && (tipo == Acceso::Escritura || self.modo(b) == Modo::Edit)
                {
                    let m = format!(
                        "pasar {} a la llamada mientras el préstamo {} sigue vivo sobre el mismo objeto",
                        self.n(*a),
                        self.n(b)
                    );
                    self.err(Regla::R7, ruta, m);
                }
            }
        }
        // Efectos de la llamada.
        let efectos = efecto_llamada(self.p, self.f, self.tabla, destino, pools);
        for (q, e) in efectos {
            self.efecto_llamada_en(s, q, e, &prestados, ruta);
        }
    }

    fn efecto_llamada_en(
        &mut self,
        s: &Stmt,
        q: PoolRef,
        e: EfectoPool,
        prestados: &[VarId],
        ruta: &Ruta,
    ) {
        let mut cand = self.prestamos_vivos(s);
        cand.extend(prestados.iter().copied());
        cand.sort();
        cand.dedup();
        for b in cand {
            let Some(rb) = self.raices.get(&b).copied() else {
                continue;
            };
            if self.pool_raiz(rb) != Some(q) {
                continue;
            }
            let choca =
                e.reestructura || e.edita_enlaces || (e.lee_enlaces && self.modo(b) == Modo::Edit);
            if choca {
                let m = format!(
                    "la llamada tiene efecto {e} sobre {} y podría alcanzar el objeto del préstamo vivo {}",
                    self.np(q),
                    self.n(b)
                );
                self.err(Regla::R7, ruta, m);
            }
        }
        let que = format!("la llamada (efecto {e})");
        if e.reestructura {
            self.r6(q, R6Tipo::Reestructura, ruta, &que);
        } else if e.nivel == NivelEfecto::Destruye {
            self.r6(q, R6Tipo::Libera, ruta, &que);
        }
        if e.invalida_epoca {
            self.r6(q, R6Tipo::InvalidaEpoca, ruta, &que);
        }
        let muta =
            e.nivel > NivelEfecto::Puro || e.edita_enlaces || e.invalida_epoca || e.reestructura;
        if muta {
            self.c3(q, ruta, &format!("la llamada (efecto {e})"));
        }
        if self.trabajadores.iter().any(|t| t.pool == q) && (e.edita_enlaces || e.reestructura) {
            let m = format!(
                "la llamada (efecto {e}) dentro de `dividir` podría modificar objetos de otras particiones de {}",
                self.np(q)
            );
            self.err(Regla::C5, ruta, m);
        }
    }

    /// C1 y C4 para `paralelo`.
    fn paralelo(&mut self, hilos: &[Bloque], ruta: &Ruta) {
        let infos: Vec<InfoHilo> = hilos
            .iter()
            .map(|h| {
                let mut i = InfoHilo::default();
                self.recolectar(h, &mut i);
                i
            })
            .collect();
        // C1: un pool no congelado solo puede usarlo un hilo.
        let mut cuenta: HashMap<PoolRef, usize> = HashMap::new();
        for i in &infos {
            for q in &i.pools {
                *cuenta.entry(*q).or_default() += 1;
            }
        }
        let mut compartidos: Vec<PoolRef> = cuenta
            .into_iter()
            .filter(|(q, n)| *n >= 2 && !self.congelados.contains(q))
            .map(|(q, _)| q)
            .collect();
        compartidos.sort();
        for q in compartidos {
            let m = format!(
                "varios hilos usan el pool {} sin congelarlo: los pools son locales al hilo (use `congelar` o `dividir`)",
                self.np(q)
            );
            self.err(Regla::C1, ruta, m);
        }
        // C4: alias mutable entre hilos.
        let raices: Vec<Vec<(Raiz, bool, VarId)>> = infos
            .iter()
            .map(|i| {
                let mut v: Vec<(Raiz, bool, VarId)> = i
                    .vars
                    .iter()
                    .filter(|(x, _)| !i.defs.contains(x))
                    .filter_map(|(x, m)| self.raiz_de(*x).map(|r| (r, *m, *x)))
                    .collect();
                v.sort_by_key(|(_, _, x)| *x);
                v
            })
            .collect();
        for a in 0..raices.len() {
            for b in a + 1..raices.len() {
                for (ra, ma, xa) in &raices[a] {
                    for (rb, mb, xb) in &raices[b] {
                        if self.solapan(*ra, *rb) && (*ma || *mb) {
                            let m = format!(
                                "los hilos {a} y {b} acceden a {} / {} y al menos uno lo modifica",
                                self.n(*xa),
                                self.n(*xb)
                            );
                            self.err(Regla::C4, ruta, m);
                        }
                    }
                }
            }
        }
    }

    fn recolectar(&self, b: &[Stmt], info: &mut InfoHilo) {
        for s in b {
            info.pools.extend(self.pools_de_stmt(s));
            for d in s.defs() {
                info.defs.insert(d);
            }
            match s {
                Stmt::Revalidar { ligado, .. } => {
                    info.defs.insert(*ligado);
                }
                Stmt::RevalidarLote { ligados, .. } => info.defs.extend(ligados.iter().copied()),
                Stmt::Dividir { indice, .. } | Stmt::Repetir { indice, .. } => {
                    info.defs.insert(*indice);
                }
                _ => {}
            }
            let mutados: Vec<VarId> = match s {
                Stmt::Escribir { obj, .. } => vec![*obj],
                Stmt::Prestar {
                    src,
                    modo: Modo::Edit,
                    ..
                } => vec![*src],
                _ => Vec::new(),
            };
            for u in s.usos() {
                let edit = matches!(self.f.ty(u), Ty::Prestamo(Modo::Edit, ..));
                let e = info.vars.entry(u).or_insert(false);
                *e |= edit || mutados.contains(&u);
            }
            for blq in s.bloques() {
                self.recolectar(blq, info);
            }
        }
    }
}

#[derive(Default)]
struct InfoHilo {
    pools: HashSet<PoolRef>,
    /// Variable usada → ¿la muta?
    vars: HashMap<VarId, bool>,
    defs: HashSet<VarId>,
}

fn recolectar_defs(b: &[Stmt], defs: &mut HashSet<VarId>) {
    for s in b {
        defs.extend(s.defs());
        match s {
            Stmt::Revalidar { ligado, .. } => {
                defs.insert(*ligado);
            }
            Stmt::RevalidarLote { ligados, .. } => defs.extend(ligados.iter().copied()),
            Stmt::Dividir { indice, .. } | Stmt::Repetir { indice, .. } => {
                defs.insert(*indice);
            }
            _ => {}
        }
        for blq in s.bloques() {
            recolectar_defs(blq, defs);
        }
    }
}
