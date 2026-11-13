//! Pase 3: efectos de pool por punto fijo sobre el grafo de llamadas y
//! validez estática de enlaces.
//!
//! Para cada función se infiere, por pool parámetro, un [`EfectoPool`]:
//! `puro(P)` < `crece(P)` < `destruye(P)`, más banderas que refinan el
//! análisis de alias (lee/edita objetos alcanzados por enlaces), la
//! reestructuración y la invalidación de época.
//!
//! La validez es un análisis hacia delante *must*: el conjunto de variables
//! `Enlace<P>` que en ese punto apuntan con certeza a un slot vivo. Se genera
//! con `enlazar`, al entrar en el cuerpo de un `revalidar` o al leer un enlace
//! de un objeto dentro de `si_sellado(P)`; se mata con todo efecto
//! `destruye(P)`. `crece(P)` no lo mata (N23). Con él se anota el nivel de
//! cada revalidación (`Estatico`, `Congelado`, `Comprobado`) y si una
//! escritura de enlace invalida la época del pool.
//!
//! Efectos y validez son mutuamente dependientes (una escritura de un enlace
//! no probado tiene el efecto `invalida_epoca`) y se resuelven juntos: los
//! efectos solo crecen y los hechos de validez solo decrecen, así que el
//! punto fijo termina.

use std::collections::HashSet;
use std::fmt;

use crate::ir::*;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Default, Hash)]
pub enum NivelEfecto {
    #[default]
    Puro,
    Crece,
    Destruye,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub struct EfectoPool {
    pub nivel: NivelEfecto,
    /// Reestructura almacenamiento (no diferible).
    pub reestructura: bool,
    /// Lee objetos alcanzados por enlaces (revalidar view, sellar).
    pub lee_enlaces: bool,
    /// Escribe objetos alcanzados por enlaces (revalidar edit).
    pub edita_enlaces: bool,
    /// Almacena enlaces no probados: incrementa `epoca_destruccion` sin
    /// liberar memoria.
    pub invalida_epoca: bool,
}

impl EfectoPool {
    pub fn unir(&mut self, o: EfectoPool) -> bool {
        let antes = *self;
        self.nivel = self.nivel.max(o.nivel);
        self.reestructura |= o.reestructura;
        self.lee_enlaces |= o.lee_enlaces;
        self.edita_enlaces |= o.edita_enlaces;
        self.invalida_epoca |= o.invalida_epoca;
        *self != antes
    }

    pub fn nivel(n: NivelEfecto) -> Self {
        EfectoPool {
            nivel: n,
            ..Default::default()
        }
    }

    pub fn total() -> Self {
        EfectoPool {
            nivel: NivelEfecto::Destruye,
            reestructura: true,
            lee_enlaces: true,
            edita_enlaces: true,
            invalida_epoca: true,
        }
    }

    /// Mata la validez de los enlaces del pool.
    pub fn invalida_enlaces(&self) -> bool {
        self.nivel == NivelEfecto::Destruye
    }
}

impl fmt::Display for EfectoPool {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self.nivel {
            NivelEfecto::Puro => "puro",
            NivelEfecto::Crece => "crece",
            NivelEfecto::Destruye => "destruye",
        })?;
        let mut extra = Vec::new();
        if self.reestructura {
            extra.push("reestructura");
        }
        if self.lee_enlaces {
            extra.push("lee");
        }
        if self.edita_enlaces {
            extra.push("edita");
        }
        if self.invalida_epoca {
            extra.push("invalida_epoca");
        }
        if !extra.is_empty() {
            write!(f, "[{}]", extra.join(","))?;
        }
        Ok(())
    }
}

/// Resumen de efectos de una función: uno por pool parámetro.
pub type Resumen = Vec<EfectoPool>;

/// Efecto de una llamada sobre los pools del llamador.
pub fn efecto_llamada(
    p: &Programa,
    f: &Funcion,
    tabla: &[Resumen],
    destino: &Destino,
    pools: &[PoolRef],
) -> Vec<(PoolRef, EfectoPool)> {
    let mut r: Vec<(PoolRef, EfectoPool)> = Vec::new();
    let mut agregar = |q: PoolRef, e: EfectoPool| {
        if let Some(x) = r.iter_mut().find(|(k, _)| *k == q) {
            x.1.unir(e);
        } else {
            r.push((q, e));
        }
    };
    match destino {
        Destino::Directa(fid) => {
            if let Some(res) = tabla.get(fid.0 as usize) {
                for (i, q) in pools.iter().enumerate() {
                    if let Some(e) = res.get(i) {
                        agregar(*q, *e);
                    }
                }
            }
        }
        Destino::Indirecta(v) => {
            let Ty::Funcion(fi) = f.ty(*v) else {
                return r;
            };
            if fi.opaca || fi.captura_mutable {
                // Efecto opaco: destruye(todos).
                for i in 0..f.pools.len() {
                    agregar(PoolRef(i as u32), EfectoPool::total());
                }
            } else {
                // Polimorfismo de efectos: sin edit ni capturas mutables, el
                // efecto sobre P está acotado por crece(P).
                for (q, (_, perm)) in pools.iter().zip(&fi.pools) {
                    let e = match perm {
                        PermisoPool::View => EfectoPool {
                            nivel: NivelEfecto::Crece,
                            lee_enlaces: true,
                            ..Default::default()
                        },
                        _ => EfectoPool::total(),
                    };
                    agregar(*q, e);
                }
            }
        }
    }
    let _ = p;
    r
}

/// Calcula los resúmenes por punto fijo y anota el programa (niveles de
/// revalidación y escrituras que invalidan la época).
pub fn analizar(p: &mut Programa) -> Vec<Resumen> {
    let mut tabla: Vec<Resumen> = p
        .funciones
        .iter()
        .map(|f| vec![EfectoPool::default(); f.n_pool_params])
        .collect();
    loop {
        let mut cambio = false;
        for (i, f) in p.funciones.iter().enumerate() {
            let (ef, _) = Validez::correr(p, f, &tabla);
            for (k, e) in ef.iter().take(f.n_pool_params).enumerate() {
                cambio |= tabla[i][k].unir(*e);
            }
        }
        if !cambio {
            break;
        }
    }
    let cuerpos: Vec<Bloque> = p
        .funciones
        .iter()
        .map(|f| Validez::correr(p, f, &tabla).1)
        .collect();
    for (f, c) in p.funciones.iter_mut().zip(cuerpos) {
        f.cuerpo = c;
    }
    tabla
}

type Hechos = Option<HashSet<VarId>>;

fn interseccion(a: &Hechos, b: &Hechos) -> Hechos {
    match (a, b) {
        (None, x) | (x, None) => x.clone(),
        (Some(x), Some(y)) => Some(x.intersection(y).copied().collect()),
    }
}

struct Validez<'a> {
    p: &'a Programa,
    f: &'a Funcion,
    tabla: &'a [Resumen],
    ef: Vec<EfectoPool>,
    congelados: Vec<PoolRef>,
    sellados: Vec<PoolRef>,
    diferidos: Vec<PoolRef>,
}

impl<'a> Validez<'a> {
    fn correr(p: &'a Programa, f: &'a Funcion, tabla: &'a [Resumen]) -> (Vec<EfectoPool>, Bloque) {
        let mut v = Validez {
            p,
            f,
            tabla,
            ef: vec![EfectoPool::default(); f.pools.len()],
            congelados: Vec::new(),
            sellados: Vec::new(),
            diferidos: Vec::new(),
        };
        let mut st: Hechos = Some(HashSet::new());
        let cuerpo = v.bloque(&f.cuerpo, &mut st);
        (v.ef, cuerpo)
    }

    fn efecto(&mut self, q: PoolRef, e: EfectoPool) {
        if let Some(x) = self.ef.get_mut(q.0 as usize) {
            x.unir(e);
        }
    }

    fn matar(&self, st: &mut Hechos, q: PoolRef) {
        if let Some(s) = st.as_mut() {
            s.retain(|v| self.f.ty(*v) != &Ty::Enlace(q));
        }
    }

    fn valido(&self, st: &Hechos, v: VarId) -> bool {
        match st {
            None => true,
            Some(s) => s.contains(&v),
        }
    }

    fn nivel(&self, st: &Hechos, e: VarId) -> Nivel {
        let Ty::Enlace(q) = self.f.ty(e) else {
            return Nivel::Comprobado;
        };
        if !self.valido(st, e) {
            Nivel::Comprobado
        } else if self.congelados.contains(q) {
            Nivel::Congelado
        } else {
            Nivel::Estatico
        }
    }

    fn pool_obj(&self, v: VarId) -> Option<PoolRef> {
        match self.f.ty(v) {
            Ty::Dueno(_, Ubic::Pool(q)) | Ty::Prestamo(_, _, Ubic::Pool(q)) => Some(*q),
            _ => None,
        }
    }

    /// Almacenar enlaces no probados invalida la época del pool destino.
    fn almacenar(&mut self, st: &Hechos, q: PoolRef, ops: &[Operando]) -> bool {
        let mut invalida = false;
        for o in ops {
            if let Operando::Var(v) = o
                && matches!(self.f.ty(*v), Ty::Enlace(_))
                && !self.valido(st, *v)
            {
                invalida = true;
            }
        }
        if invalida {
            self.efecto(
                q,
                EfectoPool {
                    invalida_epoca: true,
                    ..Default::default()
                },
            );
        }
        invalida
    }

    fn bloque(&mut self, b: &[Stmt], st: &mut Hechos) -> Bloque {
        b.iter().map(|s| self.stmt(s, st)).collect()
    }

    fn stmt(&mut self, s: &Stmt, st: &mut Hechos) -> Stmt {
        match s {
            Stmt::Copiar { dst, src } => {
                if self.valido(st, *src)
                    && matches!(self.f.ty(*src), Ty::Enlace(_))
                    && let Some(x) = st.as_mut()
                {
                    x.insert(*dst);
                }
                s.clone()
            }
            Stmt::Enlazar { dst, .. } => {
                if let Some(x) = st.as_mut() {
                    x.insert(*dst);
                }
                s.clone()
            }
            Stmt::Leer { dst, obj, .. } => {
                if let (Ty::Enlace(_), Some(q)) = (self.f.ty(*dst), self.pool_obj(*obj))
                    && self.sellados.contains(&q)
                    && let Some(x) = st.as_mut()
                {
                    x.insert(*dst);
                }
                s.clone()
            }
            Stmt::Crear {
                dst,
                clase,
                ubic,
                campos,
                ..
            } => {
                let mut invalida = false;
                if let Ubic::Pool(q) = ubic {
                    self.efecto(*q, EfectoPool::nivel(NivelEfecto::Crece));
                    invalida = self.almacenar(st, *q, campos);
                }
                Stmt::Crear {
                    dst: *dst,
                    clase: *clase,
                    ubic: *ubic,
                    campos: campos.clone(),
                    invalida_epoca: Some(invalida),
                }
            }
            Stmt::ReusarHueco {
                dst, hueco, campos, ..
            } => {
                let mut invalida = false;
                if let Ty::Hueco(q) = self.f.ty(*hueco) {
                    let q = *q;
                    self.efecto(q, EfectoPool::nivel(NivelEfecto::Crece));
                    invalida = self.almacenar(st, q, campos);
                }
                Stmt::ReusarHueco {
                    dst: *dst,
                    hueco: *hueco,
                    campos: campos.clone(),
                    invalida_epoca: Some(invalida),
                }
            }
            Stmt::Destruir { src, .. } => {
                if let Ty::Dueno(_, Ubic::Pool(q)) = self.f.ty(*src) {
                    let q = *q;
                    self.efecto(q, EfectoPool::nivel(NivelEfecto::Destruye));
                    if !self.diferidos.contains(&q) {
                        self.matar(st, q);
                    }
                }
                s.clone()
            }
            Stmt::Escribir {
                obj, campo, valor, ..
            } => {
                let mut invalida = false;
                if let Some(q) = self.pool_obj(*obj) {
                    invalida = self.almacenar(st, q, std::slice::from_ref(valor));
                }
                Stmt::Escribir {
                    obj: *obj,
                    campo: *campo,
                    valor: *valor,
                    invalida_epoca: Some(invalida),
                }
            }
            Stmt::Reestructurar { pool } => {
                self.efecto(
                    *pool,
                    EfectoPool {
                        nivel: NivelEfecto::Destruye,
                        reestructura: true,
                        ..Default::default()
                    },
                );
                self.matar(st, *pool);
                s.clone()
            }
            Stmt::Sellar { pool, .. } => {
                self.efecto(
                    *pool,
                    EfectoPool {
                        lee_enlaces: true,
                        ..Default::default()
                    },
                );
                s.clone()
            }
            Stmt::Llamar { destino, pools, .. } => {
                for (q, e) in efecto_llamada(self.p, self.f, self.tabla, destino, pools) {
                    self.efecto(q, e);
                    if e.invalida_enlaces() && !(self.diferidos.contains(&q) && !e.reestructura) {
                        self.matar(st, q);
                    }
                }
                s.clone()
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
                let nivel = self.nivel(st, *enlace);
                let q = match self.f.ty(*enlace) {
                    Ty::Enlace(q) => *q,
                    _ => PoolRef(u32::MAX),
                };
                self.marcar_acceso(q, *modo);
                let mut a = st.clone();
                if let Some(x) = st.as_mut() {
                    x.insert(*enlace);
                }
                if *diferir {
                    self.diferidos.push(q);
                }
                let c2 = self.bloque(cuerpo, st);
                if *diferir {
                    self.diferidos.pop();
                    self.matar(st, q);
                }
                if let Some(x) = a.as_mut() {
                    x.remove(enlace);
                }
                let a2 = self.bloque(ausente, &mut a);
                *st = interseccion(st, &a);
                Stmt::Revalidar {
                    enlace: *enlace,
                    modo: *modo,
                    ligado: *ligado,
                    cuerpo: c2,
                    ausente: a2,
                    diferir: *diferir,
                    nivel: Some(nivel),
                }
            }
            Stmt::RevalidarLote {
                enlaces,
                modo,
                ligados,
                cuerpo,
                ausente,
                ..
            } => {
                let niveles: Vec<Option<Nivel>> =
                    enlaces.iter().map(|e| Some(self.nivel(st, *e))).collect();
                for e in enlaces {
                    if let Ty::Enlace(q) = self.f.ty(*e) {
                        self.marcar_acceso(*q, *modo);
                    }
                }
                let mut a = st.clone();
                if let Some(x) = st.as_mut() {
                    x.extend(enlaces.iter().copied());
                }
                let c2 = self.bloque(cuerpo, st);
                let a2 = self.bloque(ausente, &mut a);
                *st = interseccion(st, &a);
                Stmt::RevalidarLote {
                    enlaces: enlaces.clone(),
                    modo: *modo,
                    ligados: ligados.clone(),
                    cuerpo: c2,
                    ausente: a2,
                    niveles,
                }
            }
            Stmt::SiSellado {
                sello,
                cuerpo,
                sino,
            } => {
                let q = match self.f.ty(*sello) {
                    Ty::Sello(q) => *q,
                    _ => PoolRef(u32::MAX),
                };
                let mut a = st.clone();
                self.sellados.push(q);
                let c2 = self.bloque(cuerpo, st);
                self.sellados.pop();
                let a2 = self.bloque(sino, &mut a);
                *st = interseccion(st, &a);
                Stmt::SiSellado {
                    sello: *sello,
                    cuerpo: c2,
                    sino: a2,
                }
            }
            Stmt::Si {
                cond,
                entonces,
                sino,
            } => {
                let mut a = st.clone();
                let c2 = self.bloque(entonces, st);
                let a2 = self.bloque(sino, &mut a);
                *st = interseccion(st, &a);
                Stmt::Si {
                    cond: *cond,
                    entonces: c2,
                    sino: a2,
                }
            }
            Stmt::Repetir {
                veces,
                indice,
                cuerpo,
            } => {
                let entrada = st.clone();
                let mut cabeza = entrada.clone();
                for _ in 0..64 {
                    let mut x = cabeza.clone();
                    self.bloque(cuerpo, &mut x);
                    let nueva = interseccion(&entrada, &x);
                    if nueva == cabeza {
                        break;
                    }
                    cabeza = nueva;
                }
                let mut x = cabeza.clone();
                let c2 = self.bloque(cuerpo, &mut x);
                *st = interseccion(&cabeza, &x);
                Stmt::Repetir {
                    veces: *veces,
                    indice: *indice,
                    cuerpo: c2,
                }
            }
            Stmt::Congelar { pool, cuerpo } => {
                self.congelados.push(*pool);
                let c2 = self.bloque(cuerpo, st);
                self.congelados.pop();
                Stmt::Congelar {
                    pool: *pool,
                    cuerpo: c2,
                }
            }
            Stmt::Paralelo { hilos } => {
                let entrada = st.clone();
                let mut salida: Hechos = None;
                let mut nuevos = Vec::new();
                for h in hilos {
                    let mut x = entrada.clone();
                    nuevos.push(self.bloque(h, &mut x));
                    salida = match salida {
                        None => x,
                        Some(_) => interseccion(&salida, &x),
                    };
                }
                *st = interseccion(&entrada, &salida);
                Stmt::Paralelo { hilos: nuevos }
            }
            Stmt::Dividir {
                pool,
                partes,
                indice,
                cuerpo,
            } => {
                let entrada = st.clone();
                let mut x = entrada.clone();
                let c2 = self.bloque(cuerpo, &mut x);
                *st = interseccion(&entrada, &x);
                Stmt::Dividir {
                    pool: *pool,
                    partes: *partes,
                    indice: *indice,
                    cuerpo: c2,
                }
            }
            Stmt::TransferirPool { pool, cuerpo } => {
                let mut x = st.clone();
                let c2 = self.bloque(cuerpo, &mut x);
                self.efecto(*pool, EfectoPool::total());
                self.matar(st, *pool);
                Stmt::TransferirPool {
                    pool: *pool,
                    cuerpo: c2,
                }
            }
            Stmt::Retornar { .. } => {
                *st = None;
                s.clone()
            }
            _ => s.clone(),
        }
    }

    fn marcar_acceso(&mut self, q: PoolRef, modo: Modo) {
        let e = match modo {
            Modo::View => EfectoPool {
                lee_enlaces: true,
                ..Default::default()
            },
            Modo::Edit => EfectoPool {
                lee_enlaces: true,
                edita_enlaces: true,
                ..Default::default()
            },
        };
        self.efecto(q, e);
    }
}
