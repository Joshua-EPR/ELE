//! Máquina abstracta de NEXO v0.2 (Etapa 2).
//!
//! Ejecuta NEXO-Core sobre pools Bi-Slab simulados y una pila de datos por
//! ámbitos. El oráculo **no confía en la IR**: vigila cada acceso con la
//! información de ejecución (generación esperada, página confirmada, doble
//! liberación, préstamos invalidados, mutación de pools congelados,
//! particiones ajenas, permisos del marco, efectos de cada llamada frente a
//! los inferidos y carreras de datos) y comprueba sin contarlas las
//! revalidaciones que el verificador anotó como `Estatico` o `Congelado`.
//!
//! # Concurrencia
//!
//! El modelo es fork-join estructurado sin sincronización interna (no hay
//! barreras, cerrojos ni canales dentro de una región). La relación
//! *happens-before* consiste entonces en:
//! * el orden de programa dentro de cada hilo;
//! * `fork`: todo lo anterior a la región precede a cada hilo;
//! * `join`: cada hilo precede a todo lo posterior a la región.
//!
//! Dos accesos de hilos distintos de la misma región nunca están ordenados,
//! así que un par en conflicto (mismo gránulo, al menos una escritura) es una
//! carrera **en cualquier intercalación**. El detector registra cada acceso
//! con su hilo en todas las regiones activas (anidadas) y aborta ante el
//! primer par en conflicto: equivale a relojes vectoriales para esta forma de
//! programa. Los programas que necesitarían una barrera para ser correctos no
//! son expresables y, si se fuerzan, el detector los rechaza.
//!
//! Para el resto de propiedades del oráculo, que sí podrían depender del
//! orden, los hilos se ejecutan en el orden que elige `Config::orden_hilos`
//! (directo, inverso o permutación pseudoaleatoria); el fuzzer explora varios.

use std::collections::{HashMap, VecDeque};

use super::metricas::Metricas;
use super::oraculo::{Aborto, Granulo, Region, Violacion, abortar};
use super::pool::{Contadores, Destruido, Eventos, Palabra, Pool};
use crate::ir::*;
use crate::verif::ProgramaVerificado;
use crate::verif::efectos::{NivelEfecto, Resumen, efecto_llamada};

/// Referencia a un objeto.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefObj {
    Pila(u32),
    Pool { pool: usize, slot: u32, gener: u32 },
}

/// Valores en ejecución.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Valor {
    Int(i64),
    /// Dueño.
    Obj(RefObj),
    /// Préstamo; `epoca_re` es la época de reestructuración del pool al
    /// crearlo.
    Prest {
        r: RefObj,
        modo: Modo,
        nivel: Nivel,
        epoca_re: u64,
    },
    Enlace {
        pool: usize,
        slot: u32,
        gener: u32,
    },
    /// `valido == false` si el slot quedó retirado o la destrucción se
    /// difirió: el reuso cae al camino normal de asignación.
    Hueco {
        pool: usize,
        slot: u32,
        valido: bool,
    },
    Sello {
        pool: usize,
        epoca: u64,
    },
    Func(FuncId),
}

#[derive(Clone, Copy, Debug)]
pub struct Config {
    /// Superpáginas de 64 KiB reservadas por pool (reserva virtual fija).
    pub max_superpaginas: u32,
    pub max_profundidad: usize,
    /// Generación con la que nacen los slots de cada superpágina nueva (par).
    /// Permite probar el agotamiento sin 2³¹ ciclos.
    pub gen_inicial: u32,
    /// Orden de ejecución de los hilos de cada región: 0 = directo,
    /// 1 = inverso, otro valor = semilla de una permutación.
    pub orden_hilos: u64,
    /// Entradas de traza que se conservan (0 = sin traza).
    pub traza: usize,
    /// Comprobar los invariantes de todos los pools tras cada llamada.
    pub invariantes: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            max_superpaginas: 64,
            max_profundidad: 512,
            gen_inicial: 0,
            orden_hilos: 0,
            traza: 0,
            invariantes: false,
        }
    }
}

struct ObjPila {
    campos: Vec<Palabra>,
    vivo: bool,
}

struct Marco<'p> {
    f: &'p Funcion,
    vars: Vec<Option<Valor>>,
    pools: Vec<usize>,
    permisos: Vec<PermisoPool>,
}

enum Flujo {
    Normal,
    Retorno(Option<Valor>),
}

pub struct Maquina<'p> {
    prog: &'p Programa,
    cfg: Config,
    efectos: Option<Vec<Resumen>>,
    pools: Vec<Option<Pool>>,
    /// Clase de cada pool en ejecución.
    clase_pool: Vec<ClaseId>,
    pila: Vec<ObjPila>,
    met: Metricas,
    ev: Eventos,
    regiones: Vec<Region>,
    /// Pool en ejecución → asignador de la partición activa.
    particion: HashMap<usize, usize>,
    /// Colas de destrucción diferida (pool, slots).
    diferidos: Vec<(usize, Vec<(u32, u32)>)>,
    profundidad: usize,
    traza: VecDeque<String>,
    /// Hilo actual por región (para la traza).
    hilos: Vec<u32>,
}

type R<T> = Result<T, Aborto>;

/// Orden en que se ejecutan `n` hilos.
pub fn orden(n: usize, semilla: u64) -> Vec<usize> {
    let mut v: Vec<usize> = (0..n).collect();
    match semilla {
        0 => {}
        1 => v.reverse(),
        s => {
            let mut x = s;
            for i in (1..n).rev() {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                v.swap(i, (x % (i as u64 + 1)) as usize);
            }
        }
    }
    v
}

impl<'p> Maquina<'p> {
    pub fn nueva(prog: &'p Programa, cfg: Config) -> Self {
        Maquina {
            prog,
            cfg,
            efectos: None,
            pools: Vec::new(),
            clase_pool: Vec::new(),
            pila: Vec::new(),
            met: Metricas::default(),
            ev: Eventos::default(),
            regiones: Vec::new(),
            particion: HashMap::new(),
            diferidos: Vec::new(),
            profundidad: 0,
            traza: VecDeque::new(),
            hilos: Vec::new(),
        }
    }

    /// Activa el oráculo de efectos (P4) con los resúmenes del verificador.
    pub fn con_efectos(mut self, efectos: Vec<Resumen>) -> Self {
        self.efectos = Some(efectos);
        self
    }

    pub fn metricas(&self) -> Metricas {
        let mut m = self.met;
        m.superpaginas_reservadas = self.ev.superpaginas_reservadas;
        m.subpaginas_confirmadas = self.ev.subpaginas_confirmadas;
        m.subpaginas_reconfirmadas = self.ev.subpaginas_reconfirmadas;
        m.subpaginas_devueltas = self.ev.subpaginas_devueltas;
        m.slots_retirados = self.ev.slots_retirados;
        m
    }

    /// Últimas sentencias ejecutadas (si `Config::traza > 0`).
    pub fn traza(&self) -> Vec<String> {
        self.traza.iter().cloned().collect()
    }

    /// Resumen del estado de todos los pools vivos.
    pub fn estado_pools(&self) -> String {
        self.pools
            .iter()
            .flatten()
            .map(|p| p.resumen())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Crea un pool fuera de cualquier función (para llamar a funciones con
    /// pools parámetro).
    pub fn crear_pool(&mut self, clase: ClaseId) -> R<usize> {
        let Some(c) = self.prog.clases.get(clase.0 as usize) else {
            return abortar(
                Violacion::ValorInvalido,
                format!("clase #{} inexistente", clase.0),
            );
        };
        let id = self.pools.len();
        let pool = Pool::nuevo(
            id,
            c.campos.len(),
            c.tam_slot(),
            self.cfg.max_superpaginas,
            self.cfg.gen_inicial,
        )?;
        self.clase_pool.push(clase);
        self.pools.push(Some(pool));
        Ok(id)
    }

    pub fn pool(&self, p: usize) -> Option<&Pool> {
        self.pools.get(p).and_then(|x| x.as_ref())
    }

    pub fn pool_mut(&mut self, p: usize) -> Option<&mut Pool> {
        self.pools.get_mut(p).and_then(|x| x.as_mut())
    }

    /// Destruye un pool comprobando que no queden objetos ni huecos.
    pub fn destruir_pool(&mut self, p: usize) -> R<()> {
        let Some(pool) = self.pools.get(p).and_then(|x| x.as_ref()) else {
            return abortar(Violacion::PoolInexistente, format!("pool {p} inexistente"));
        };
        if pool.vivos > 0 || pool.huecos > 0 {
            return abortar(
                Violacion::Fuga,
                format!(
                    "el pool {p} se destruye con {} objetos y {} huecos vivos",
                    pool.vivos, pool.huecos
                ),
            );
        }
        self.pools[p] = None;
        Ok(())
    }

    /// Ejecuta `f` con los pools y argumentos dados. Los pools se ven con el
    /// permiso que declara `f`.
    pub fn llamar(&mut self, f: FuncId, pools: Vec<usize>, args: Vec<Valor>) -> R<Option<Valor>> {
        let Some(func) = self.prog.funciones.get(f.0 as usize) else {
            return abortar(
                Violacion::ValorInvalido,
                format!("función #{} inexistente", f.0),
            );
        };
        if pools.len() != func.n_pool_params || args.len() != func.params.len() {
            return abortar(
                Violacion::ValorInvalido,
                format!("llamada a `{}` con aridad incorrecta", func.nombre),
            );
        }
        self.profundidad += 1;
        if self.profundidad > self.cfg.max_profundidad {
            return abortar(
                Violacion::Desbordamiento,
                format!("recursión > {}", self.cfg.max_profundidad),
            );
        }
        let mut m = Marco {
            f: func,
            vars: vec![None; func.vars.len()],
            pools,
            permisos: func.pools.iter().map(|d| d.permiso).collect(),
        };
        let mut locales = Vec::new();
        for pd in &func.pools[func.n_pool_params..] {
            let id = self.crear_pool(pd.clase)?;
            m.pools.push(id);
            locales.push(id);
        }
        for (v, a) in func.params.iter().zip(args) {
            if let Some(slot) = m.vars.get_mut(v.0 as usize) {
                *slot = Some(a);
            }
        }
        let r = self.bloque(&mut m, &func.cuerpo)?;
        for id in locales {
            if self.pools[id].is_some() {
                self.destruir_pool(id)?;
            }
        }
        if self.cfg.invariantes {
            self.comprobar_invariantes()?;
        }
        self.profundidad -= 1;
        Ok(match r {
            Flujo::Normal => None,
            Flujo::Retorno(v) => v,
        })
    }

    /// Invariantes de cabecera e índice de todos los pools vivos.
    pub fn comprobar_invariantes(&self) -> R<()> {
        for p in self.pools.iter().flatten() {
            if let Err(e) = p.comprobar_invariantes() {
                return abortar(
                    Violacion::ValorInvalido,
                    format!("invariante Bi-Slab del pool {}: {e}", p.id),
                );
            }
        }
        Ok(())
    }

    /// Comprueba que no queden objetos de pila vivos (fin de programa).
    pub fn comprobar_fugas(&self) -> R<()> {
        let vivos = self.pila.iter().filter(|o| o.vivo).count();
        if vivos > 0 {
            return abortar(
                Violacion::Fuga,
                format!("{vivos} objetos de la pila de datos siguen vivos"),
            );
        }
        for p in self.pools.iter().flatten() {
            if p.vivos > 0 || p.huecos > 0 {
                return abortar(
                    Violacion::Fuga,
                    format!("el pool {} conserva {} objetos", p.id, p.vivos),
                );
            }
        }
        Ok(())
    }

    // ---- utilidades ----

    fn registrar(&mut self, g: Granulo, escritura: bool) -> R<()> {
        for r in &mut self.regiones {
            r.registrar(g, escritura)?;
        }
        Ok(())
    }

    fn p(&self, p: usize) -> R<&Pool> {
        match self.pools.get(p).and_then(|x| x.as_ref()) {
            Some(x) => Ok(x),
            None => abortar(
                Violacion::PoolInexistente,
                format!("pool {p} transferido o destruido"),
            ),
        }
    }

    fn pm(&mut self, p: usize) -> R<&mut Pool> {
        match self.pools.get_mut(p).and_then(|x| x.as_mut()) {
            Some(x) => Ok(x),
            None => abortar(
                Violacion::PoolInexistente,
                format!("pool {p} transferido o destruido"),
            ),
        }
    }

    fn asig(&self, p: usize) -> usize {
        self.particion.get(&p).copied().unwrap_or(0)
    }

    fn no_congelado(&self, p: usize, que: &str) -> R<()> {
        if self.p(p)?.congelado > 0 {
            return abortar(
                Violacion::MutacionCongelado,
                format!("{que} sobre el pool congelado {p}"),
            );
        }
        Ok(())
    }

    /// Permiso del marco sobre el pool en ejecución `p`.
    fn permiso(m: &Marco, p: usize) -> Option<PermisoPool> {
        m.pools
            .iter()
            .zip(&m.permisos)
            .filter(|(q, _)| **q == p)
            .map(|(_, k)| *k)
            .max()
    }

    fn exige_edit(m: &Marco, p: usize, que: &str) -> R<()> {
        match Self::permiso(m, p) {
            Some(PermisoPool::Edit | PermisoPool::Dueno) => Ok(()),
            Some(PermisoPool::View) => abortar(
                Violacion::PermisoInventado,
                format!(
                    "{que} en `{}` sobre el pool {p}, que esta función solo ve (view)",
                    m.f.nombre
                ),
            ),
            None => abortar(
                Violacion::PermisoInventado,
                format!(
                    "{que} en `{}` sobre el pool {p}, que esta función no recibió",
                    m.f.nombre
                ),
            ),
        }
    }

    fn exige_acceso(m: &Marco, p: usize, que: &str) -> R<()> {
        if Self::permiso(m, p).is_none() {
            return abortar(
                Violacion::PermisoInventado,
                format!(
                    "{que} en `{}` sobre el pool {p}, que esta función no recibió",
                    m.f.nombre
                ),
            );
        }
        Ok(())
    }

    fn val(&self, m: &Marco, v: VarId) -> R<Valor> {
        match m.vars.get(v.0 as usize).copied().flatten() {
            Some(x) => Ok(x),
            None => abortar(
                Violacion::UsoTrasConsumo,
                format!("variable #{} sin valor (consumida)", v.0),
            ),
        }
    }

    fn tomar(&self, m: &mut Marco, v: VarId) -> R<Valor> {
        match m.vars.get_mut(v.0 as usize).and_then(|x| x.take()) {
            Some(x) => Ok(x),
            None => abortar(
                Violacion::UsoTrasConsumo,
                format!("variable #{} ya consumida", v.0),
            ),
        }
    }

    fn op(&self, m: &Marco, o: &Operando) -> R<Valor> {
        match o {
            Operando::Const(k) => Ok(Valor::Int(*k)),
            Operando::Var(v) => self.val(m, *v),
        }
    }

    fn int(&self, m: &Marco, o: &Operando) -> R<i64> {
        match self.op(m, o)? {
            Valor::Int(k) => Ok(k),
            x => abortar(
                Violacion::ValorInvalido,
                format!("se esperaba Int, hay {x:?}"),
            ),
        }
    }

    /// Convierte un valor en la palabra del campo `campo` de un objeto de
    /// `destino` (pool) o de la pila. `Int(0)` en un campo Enlace es el
    /// enlace nulo (`slot 0, gen 0`: generación par, nunca vivo).
    fn palabra(&self, v: Valor, destino: Option<usize>, campo: usize) -> R<Palabra> {
        let es_enlace = destino
            .and_then(|p| self.clase_pool.get(p))
            .is_some_and(|c| self.prog.clase(*c).campos.get(campo) == Some(&TipoCampo::Enlace));
        match v {
            Valor::Int(0) if es_enlace => Ok(Palabra::Enlace { slot: 0, gener: 0 }),
            Valor::Int(k) if !es_enlace => Ok(Palabra::Int(k)),
            Valor::Enlace { pool, slot, gener } if Some(pool) == destino && es_enlace => {
                Ok(Palabra::Enlace { slot, gener })
            }
            Valor::Prest { .. } | Valor::Obj(_) => abortar(
                Violacion::PermisoInventado,
                format!("{v:?}: un dueño o préstamo no puede almacenarse en un objeto"),
            ),
            x => abortar(
                Violacion::ValorInvalido,
                format!("{x:?} no puede almacenarse en ese campo"),
            ),
        }
    }

    fn objeto(&self, m: &Marco, v: VarId) -> R<(RefObj, Option<Modo>, Nivel, Option<u64>)> {
        match self.val(m, v)? {
            Valor::Obj(r) => Ok((r, None, Nivel::Estatico, None)),
            Valor::Prest {
                r,
                modo,
                nivel,
                epoca_re,
            } => Ok((r, Some(modo), nivel, Some(epoca_re))),
            Valor::Enlace { .. } => abortar(
                Violacion::PermisoInventado,
                "un enlace usado como objeto sin revalidar no concede acceso",
            ),
            x => abortar(
                Violacion::PermisoInventado,
                format!("{x:?} no es un objeto"),
            ),
        }
    }

    fn epoca_re(&self, r: RefObj) -> R<u64> {
        match r {
            RefObj::Pila(_) => Ok(0),
            RefObj::Pool { pool, .. } => Ok(self.p(pool)?.epoca_reestructura),
        }
    }

    fn acceso(
        &mut self,
        r: RefObj,
        epoca: Option<u64>,
        campo: usize,
        escribir: Option<Palabra>,
    ) -> R<Palabra> {
        match r {
            RefObj::Pila(id) => {
                self.registrar(Granulo::Pila(id), escribir.is_some())?;
                let Some(o) = self.pila.get_mut(id as usize) else {
                    return abortar(
                        Violacion::FueraDeLimites,
                        format!("objeto de pila {id} inexistente"),
                    );
                };
                if !o.vivo {
                    return abortar(
                        Violacion::GeneracionObsoleta,
                        format!("acceso al objeto de pila {id} ya destruido"),
                    );
                }
                let Some(c) = o.campos.get_mut(campo) else {
                    return abortar(
                        Violacion::FueraDeLimites,
                        format!("campo {campo} fuera de rango"),
                    );
                };
                if let Some(w) = escribir {
                    *c = w;
                }
                Ok(*c)
            }
            RefObj::Pool { pool, slot, gener } => {
                if let Some(e) = epoca {
                    self.registrar(Granulo::Estructura(pool), false)?;
                    if self.p(pool)?.epoca_reestructura != e {
                        return abortar(
                            Violacion::PrestamoInvalidado,
                            format!(
                                "préstamo al slot {slot} del pool {pool} usado tras una reestructuración"
                            ),
                        );
                    }
                }
                self.registrar(Granulo::Dato(pool, slot), escribir.is_some())?;
                match escribir {
                    Some(w) => {
                        self.pm(pool)?.escribir(slot, gener, campo, w)?;
                        Ok(w)
                    }
                    None => self.p(pool)?.leer(slot, gener, campo),
                }
            }
        }
    }

    fn bump_epoca(&mut self, p: usize) -> R<()> {
        let a = self.asig(p);
        self.registrar(Granulo::Epoca(p, a), true)?;
        self.pm(p)?.destruye(a);
        Ok(())
    }

    fn invalidar_epoca(&mut self, p: usize) -> R<()> {
        self.pm(p)?.cont.invalidaciones_epoca += 1;
        self.bump_epoca(p)
    }

    fn crear_en_pool(&mut self, p: usize, campos: &[Palabra], invalida: bool) -> R<Valor> {
        self.no_congelado(p, "crear")?;
        let a = self.asig(p);
        self.registrar(Granulo::Meta(p, a), true)?;
        let (slot, gener) = {
            let ev = &mut self.ev;
            match self.pools.get_mut(p).and_then(|x| x.as_mut()) {
                Some(pool) => pool.asignar(a, ev)?,
                None => return abortar(Violacion::PoolInexistente, format!("pool {p}")),
            }
        };
        self.met.slots_asignados = self.met.slots_asignados.saturating_add(1);
        self.inicializar(p, slot, gener, campos, invalida)
    }

    fn inicializar(
        &mut self,
        p: usize,
        slot: u32,
        gener: u32,
        campos: &[Palabra],
        invalida: bool,
    ) -> R<Valor> {
        self.registrar(Granulo::Gen(p, slot), true)?;
        self.registrar(Granulo::Dato(p, slot), true)?;
        for (i, w) in campos.iter().enumerate() {
            self.pm(p)?.escribir(slot, gener, i, *w)?;
        }
        if invalida
            && campos
                .iter()
                .any(|w| matches!(w, Palabra::Enlace { gener, .. } if *gener != 0))
        {
            self.invalidar_epoca(p)?;
        }
        Ok(Valor::Obj(RefObj::Pool {
            pool: p,
            slot,
            gener,
        }))
    }

    fn destruir_slot(&mut self, p: usize, slot: u32, gener: u32, hueco: bool) -> R<Destruido> {
        self.no_congelado(p, "destruir")?;
        let a = self.asig(p);
        let duenio = self.p(p)?.asignador_de(slot)?;
        if a != 0 && duenio != a {
            return abortar(
                Violacion::ParticionAjena,
                format!(
                    "el trabajador de la partición {a} libera el slot {slot}, que pertenece a la partición {duenio}"
                ),
            );
        }
        self.registrar(Granulo::Meta(p, duenio), true)?;
        self.registrar(Granulo::Gen(p, slot), true)?;
        self.registrar(Granulo::Dato(p, slot), true)?;
        let r = {
            let ev = &mut self.ev;
            match self.pools.get_mut(p).and_then(|x| x.as_mut()) {
                Some(pool) => pool.destruir(slot, gener, hueco, ev)?,
                None => return abortar(Violacion::PoolInexistente, format!("pool {p}")),
            }
        };
        self.met.slots_liberados = self.met.slots_liberados.saturating_add(1);
        self.bump_epoca(p)?;
        Ok(r)
    }

    fn vaciar_diferidos(&mut self, cola: Vec<(u32, u32)>, p: usize) -> R<()> {
        for (s, g) in cola {
            self.destruir_slot(p, s, g, false)?;
        }
        Ok(())
    }

    fn anotar(&mut self, m: &Marco, s: &Stmt) {
        if self.cfg.traza == 0 {
            return;
        }
        if self.traza.len() == self.cfg.traza {
            self.traza.pop_front();
        }
        let hilos: Vec<String> = self.hilos.iter().map(|h| h.to_string()).collect();
        let hilo = if hilos.is_empty() {
            String::new()
        } else {
            format!(" [hilo {}]", hilos.join("."))
        };
        let usos: Vec<String> = s
            .usos()
            .iter()
            .map(|v| {
                format!(
                    "{}={:?}",
                    m.f.nombre_var(*v),
                    m.vars.get(v.0 as usize).copied().flatten()
                )
            })
            .collect();
        self.traza.push_back(format!(
            "{}{hilo}: {} {}",
            m.f.nombre,
            s.nombre(),
            usos.join(" ")
        ));
    }

    // ---- ejecución ----

    fn bloque(&mut self, m: &mut Marco<'p>, b: &'p [Stmt]) -> R<Flujo> {
        for s in b {
            if let Flujo::Retorno(v) = self.stmt(m, s)? {
                return Ok(Flujo::Retorno(v));
            }
        }
        Ok(Flujo::Normal)
    }

    fn set(m: &mut Marco, v: VarId, x: Valor) -> R<()> {
        match m.vars.get_mut(v.0 as usize) {
            Some(slot) => {
                *slot = Some(x);
                Ok(())
            }
            None => abortar(
                Violacion::FueraDeLimites,
                format!("variable #{} inexistente", v.0),
            ),
        }
    }

    fn pool_de(m: &Marco, q: PoolRef) -> R<usize> {
        match m.pools.get(q.0 as usize) {
            Some(p) => Ok(*p),
            None => abortar(
                Violacion::FueraDeLimites,
                format!("pool #{} inexistente en el marco", q.0),
            ),
        }
    }

    fn palabras(&self, m: &Marco, campos: &[Operando], destino: Option<usize>) -> R<Vec<Palabra>> {
        campos
            .iter()
            .enumerate()
            .map(|(i, o)| self.palabra(self.op(m, o)?, destino, i))
            .collect()
    }

    fn stmt(&mut self, m: &mut Marco<'p>, s: &'p Stmt) -> R<Flujo> {
        self.anotar(m, s);
        match s {
            Stmt::Const { dst, valor } => Self::set(m, *dst, Valor::Int(*valor))?,
            Stmt::Copiar { dst, src } => {
                let x = self.val(m, *src)?;
                Self::set(m, *dst, x)?;
            }
            Stmt::Mover { dst, src } => {
                let x = self.tomar(m, *src)?;
                Self::set(m, *dst, x)?;
            }
            Stmt::Aritmetica { dst, op, a, b } => {
                let (a, b) = (self.int(m, a)?, self.int(m, b)?);
                let r = match op {
                    OpArit::Sumar => a.wrapping_add(b),
                    OpArit::Restar => a.wrapping_sub(b),
                    OpArit::Menor => (a < b) as i64,
                    OpArit::Igual => (a == b) as i64,
                };
                Self::set(m, *dst, Valor::Int(r))?;
            }
            Stmt::Crear {
                dst,
                clase,
                ubic,
                campos,
                invalida_epoca,
            } => {
                let v = match ubic {
                    Ubic::Pila => {
                        let ws = self.palabras(m, campos, None)?;
                        self.pila.push(ObjPila {
                            campos: ws,
                            vivo: true,
                        });
                        Valor::Obj(RefObj::Pila(self.pila.len() as u32 - 1))
                    }
                    Ubic::Pool(q) => {
                        let p = Self::pool_de(m, *q)?;
                        Self::exige_edit(m, p, "crear")?;
                        if self.clase_pool.get(p) != Some(clase) {
                            return abortar(
                                Violacion::ValorInvalido,
                                "crear con una clase distinta de la del pool",
                            );
                        }
                        let ws = self.palabras(m, campos, Some(p))?;
                        self.crear_en_pool(p, &ws, invalida_epoca.unwrap_or(true))?
                    }
                };
                Self::set(m, *dst, v)?;
            }
            Stmt::Destruir {
                src,
                hueco,
                condicional,
                ..
            } => {
                let x = if *condicional {
                    match m.vars.get_mut(src.0 as usize).and_then(|x| x.take()) {
                        Some(x) => x,
                        None => {
                            self.met.drop_flags_saltados =
                                self.met.drop_flags_saltados.saturating_add(1);
                            return Ok(Flujo::Normal);
                        }
                    }
                } else {
                    self.tomar(m, *src)?
                };
                match x {
                    Valor::Obj(RefObj::Pila(id)) => {
                        self.registrar(Granulo::Pila(id), true)?;
                        let Some(o) = self.pila.get_mut(id as usize) else {
                            return abortar(
                                Violacion::FueraDeLimites,
                                format!("objeto de pila {id}"),
                            );
                        };
                        if !o.vivo {
                            return abortar(
                                Violacion::DobleLiberacion,
                                format!("objeto de pila {id} ya destruido"),
                            );
                        }
                        o.vivo = false;
                    }
                    Valor::Obj(RefObj::Pool { pool, slot, gener }) => {
                        Self::exige_edit(m, pool, "destruir")?;
                        let diferido = self.diferidos.iter().rposition(|(p, _)| *p == pool);
                        if let Some(i) = diferido {
                            self.no_congelado(pool, "destruir")?;
                            // El slot sigue vivo hasta vaciar la cola: se
                            // comprueba ahora para detectar dobles destrucciones.
                            if self.p(pool)?.gen_de(slot)? != gener
                                || self
                                    .diferidos
                                    .iter()
                                    .any(|(p, c)| *p == pool && c.contains(&(slot, gener)))
                            {
                                return abortar(
                                    Violacion::DobleLiberacion,
                                    format!("slot {slot} ya destruido o en la cola diferida"),
                                );
                            }
                            self.diferidos[i].1.push((slot, gener));
                            self.met.destrucciones_diferidas =
                                self.met.destrucciones_diferidas.saturating_add(1);
                            if let Some(h) = hueco {
                                Self::set(
                                    m,
                                    *h,
                                    Valor::Hueco {
                                        pool,
                                        slot,
                                        valido: false,
                                    },
                                )?;
                            }
                        } else {
                            let r = self.destruir_slot(pool, slot, gener, hueco.is_some())?;
                            if let Some(h) = hueco {
                                Self::set(
                                    m,
                                    *h,
                                    Valor::Hueco {
                                        pool,
                                        slot,
                                        valido: r == Destruido::Libre,
                                    },
                                )?;
                            }
                        }
                    }
                    x => {
                        return abortar(
                            Violacion::PermisoInventado,
                            format!("destruir {x:?}, que no es un dueño"),
                        );
                    }
                }
            }
            Stmt::ReusarHueco {
                dst,
                hueco,
                campos,
                invalida_epoca,
            } => {
                let Valor::Hueco { pool, slot, valido } = self.tomar(m, *hueco)? else {
                    return abortar(Violacion::PermisoInventado, "reusar_hueco sin hueco");
                };
                Self::exige_edit(m, pool, "reusar_hueco")?;
                let ws = self.palabras(m, campos, Some(pool))?;
                let inv = invalida_epoca.unwrap_or(true);
                let v = if valido {
                    self.no_congelado(pool, "reusar_hueco")?;
                    self.registrar(Granulo::Gen(pool, slot), true)?;
                    let gener = self.pm(pool)?.reusar_hueco(slot)?;
                    self.met.reusos_hueco = self.met.reusos_hueco.saturating_add(1);
                    self.inicializar(pool, slot, gener, &ws, inv)?
                } else {
                    self.crear_en_pool(pool, &ws, inv)?
                };
                Self::set(m, *dst, v)?;
            }
            Stmt::LiberarHueco { hueco } => match self.tomar(m, *hueco)? {
                Valor::Hueco {
                    pool,
                    slot,
                    valido: true,
                } => {
                    self.no_congelado(pool, "liberar_hueco")?;
                    let duenio = self.p(pool)?.asignador_de(slot)?;
                    self.registrar(Granulo::Meta(pool, duenio), true)?;
                    let ev = &mut self.ev;
                    if let Some(p) = self.pools.get_mut(pool).and_then(|x| x.as_mut()) {
                        p.liberar_hueco(slot, ev)?;
                    }
                    self.met.huecos_liberados = self.met.huecos_liberados.saturating_add(1);
                }
                Valor::Hueco { valido: false, .. } => {}
                x => {
                    return abortar(
                        Violacion::PermisoInventado,
                        format!("liberar_hueco de {x:?}"),
                    );
                }
            },
            Stmt::Prestar { dst, src, modo } => {
                let x = match self.val(m, *src)? {
                    Valor::Obj(r) => Valor::Prest {
                        r,
                        modo: *modo,
                        nivel: Nivel::Estatico,
                        epoca_re: self.epoca_re(r)?,
                    },
                    Valor::Prest {
                        r,
                        modo: md,
                        nivel,
                        epoca_re,
                    } => {
                        if md == Modo::View && *modo == Modo::Edit {
                            return abortar(
                                Violacion::PermisoInventado,
                                "edit obtenido a partir de un view",
                            );
                        }
                        Valor::Prest {
                            r,
                            modo: *modo,
                            nivel,
                            epoca_re,
                        }
                    }
                    x => return abortar(Violacion::PermisoInventado, format!("prestar {x:?}")),
                };
                Self::set(m, *dst, x)?;
            }
            Stmt::Leer { dst, obj, campo } => {
                let (r, _, nivel, ep) = self.objeto(m, *obj)?;
                if let RefObj::Pool { pool, .. } = r {
                    Self::exige_acceso(m, pool, "leer")?;
                }
                let w = self.acceso(r, ep, *campo as usize, None)?;
                self.met.acceso(nivel);
                let x = match (w, r) {
                    (Palabra::Int(k), _) => Valor::Int(k),
                    (Palabra::Enlace { slot, gener }, RefObj::Pool { pool, .. }) => {
                        Valor::Enlace { pool, slot, gener }
                    }
                    (w, _) => return abortar(Violacion::ValorInvalido, format!("palabra {w:?}")),
                };
                Self::set(m, *dst, x)?;
            }
            Stmt::Escribir {
                obj,
                campo,
                valor,
                invalida_epoca,
            } => {
                let (r, modo, nivel, ep) = self.objeto(m, *obj)?;
                if modo == Some(Modo::View) {
                    return abortar(
                        Violacion::PermisoInventado,
                        "escritura a través de un préstamo view",
                    );
                }
                let destino = match r {
                    RefObj::Pool { pool, .. } => {
                        Self::exige_edit(m, pool, "escribir")?;
                        self.no_congelado(pool, "escribir")?;
                        Some(pool)
                    }
                    RefObj::Pila(_) => None,
                };
                let w = self.palabra(self.op(m, valor)?, destino, *campo as usize)?;
                self.acceso(r, ep, *campo as usize, Some(w))?;
                self.met.acceso(nivel);
                if let (Some(p), Palabra::Enlace { gener, .. }) = (destino, w)
                    && gener != 0
                    && invalida_epoca.unwrap_or(true)
                {
                    self.invalidar_epoca(p)?;
                }
            }
            Stmt::Enlazar { dst, obj } => {
                let (r, _, _, _) = self.objeto(m, *obj)?;
                let RefObj::Pool { pool, slot, gener } = r else {
                    return abortar(Violacion::PermisoInventado, "enlazar un objeto de pila");
                };
                Self::set(m, *dst, Valor::Enlace { pool, slot, gener })?;
            }
            Stmt::Revalidar {
                enlace,
                modo,
                ligado,
                cuerpo,
                ausente,
                diferir,
                nivel,
            } => {
                let Valor::Enlace { pool, slot, gener } = self.val(m, *enlace)? else {
                    return abortar(
                        Violacion::PermisoInventado,
                        "revalidar algo que no es un enlace",
                    );
                };
                self.pre_revalidar(m, pool, *modo)?;
                let nivel = nivel.unwrap_or(Nivel::Comprobado);
                if !self.validar(pool, slot, gener, nivel)? {
                    self.met.ausentes = self.met.ausentes.saturating_add(1);
                    return self.bloque(m, ausente);
                }
                let x = Valor::Prest {
                    r: RefObj::Pool { pool, slot, gener },
                    modo: *modo,
                    nivel,
                    epoca_re: self.p(pool)?.epoca_reestructura,
                };
                Self::set(m, *ligado, x)?;
                if *diferir {
                    self.diferidos.push((pool, Vec::new()));
                }
                let r = self.bloque(m, cuerpo);
                if let Some(x) = m.vars.get_mut(ligado.0 as usize) {
                    *x = None;
                }
                if *diferir {
                    let (p, cola) = self.diferidos.pop().expect("cola diferida");
                    // La cola se procesa también en una salida anticipada
                    // (`retornar` dentro del cuerpo).
                    if r.is_ok() {
                        self.vaciar_diferidos(cola, p)?;
                    }
                }
                return r;
            }
            Stmt::RevalidarLote {
                enlaces,
                modo,
                ligados,
                cuerpo,
                ausente,
                niveles,
            } => {
                if enlaces.len() != ligados.len() || enlaces.len() != niveles.len() {
                    return abortar(Violacion::ValorInvalido, "revalidar_lote mal formado");
                }
                let mut refs = Vec::new();
                for (e, n) in enlaces.iter().zip(niveles) {
                    let Valor::Enlace { pool, slot, gener } = self.val(m, *e)? else {
                        return abortar(Violacion::PermisoInventado, "revalidar_lote sin enlace");
                    };
                    self.pre_revalidar(m, pool, *modo)?;
                    let n = n.unwrap_or(Nivel::Comprobado);
                    if !self.validar(pool, slot, gener, n)? {
                        // Salta a `Ausente` sin comprobar el resto ni exponer
                        // ningún ligado.
                        self.met.ausentes = self.met.ausentes.saturating_add(1);
                        return self.bloque(m, ausente);
                    }
                    refs.push((RefObj::Pool { pool, slot, gener }, n));
                }
                if *modo == Modo::Edit {
                    for i in 0..refs.len() {
                        if refs[..i].iter().any(|(r, _)| *r == refs[i].0) {
                            self.met.alias_en_lote = self.met.alias_en_lote.saturating_add(1);
                            self.met.ausentes = self.met.ausentes.saturating_add(1);
                            return self.bloque(m, ausente);
                        }
                    }
                }
                for (l, (r, n)) in ligados.iter().zip(&refs) {
                    let x = Valor::Prest {
                        r: *r,
                        modo: *modo,
                        nivel: *n,
                        epoca_re: self.epoca_re(*r)?,
                    };
                    Self::set(m, *l, x)?;
                }
                let r = self.bloque(m, cuerpo);
                for l in ligados {
                    if let Some(x) = m.vars.get_mut(l.0 as usize) {
                        *x = None;
                    }
                }
                return r;
            }
            Stmt::Sellar { dst, pool } => {
                let p = Self::pool_de(m, *pool)?;
                self.p(p)?;
                self.pm(p)?.cont.revalidaciones_view += 1;
                let vivos = self.p(p)?.slots_vivos();
                let mut ok = true;
                for (s, g) in vivos {
                    for c in 0..self.p(p)?.campos {
                        self.registrar(Granulo::Dato(p, s), false)?;
                        if let Palabra::Enlace { slot, gener } = self.p(p)?.leer(s, g, c)?
                            && gener != 0
                        {
                            self.registrar(Granulo::Gen(p, slot), false)?;
                            self.met.lecturas_gen_sellado =
                                self.met.lecturas_gen_sellado.saturating_add(1);
                            if self.p(p)?.gen_de(slot)? != gener {
                                ok = false;
                            }
                        }
                    }
                }
                self.registrar(Granulo::Epoca(p, 0), false)?;
                let epoca = if ok {
                    self.p(p)?.epoca_destruccion
                } else {
                    u64::MAX
                };
                Self::set(m, *dst, Valor::Sello { pool: p, epoca })?;
            }
            Stmt::SiSellado {
                sello,
                cuerpo,
                sino,
            } => {
                let Valor::Sello { pool, epoca } = self.val(m, *sello)? else {
                    return abortar(Violacion::PermisoInventado, "si_sellado sin sello");
                };
                Self::exige_acceso(m, pool, "si_sellado")?;
                self.registrar(Granulo::Epoca(pool, 0), false)?;
                let ok = epoca != u64::MAX && self.p(pool)?.epoca_destruccion == epoca;
                return self.bloque(m, if ok { cuerpo } else { sino });
            }
            Stmt::Reestructurar { pool } => {
                let p = Self::pool_de(m, *pool)?;
                Self::exige_edit(m, p, "reestructurar")?;
                self.no_congelado(p, "reestructurar")?;
                self.registrar(Granulo::Estructura(p), true)?;
                let pl = self.pm(p)?;
                pl.epoca_reestructura += 1;
                pl.cont.reestructuras += 1;
                self.bump_epoca(p)?;
            }
            Stmt::Congelar { pool, cuerpo } => {
                let p = Self::pool_de(m, *pool)?;
                self.pm(p)?.congelado += 1;
                let r = self.bloque(m, cuerpo);
                if let Some(x) = self.pool_mut(p) {
                    x.congelado -= 1;
                }
                return r;
            }
            Stmt::Paralelo { hilos } => {
                self.regiones.push(Region::default());
                self.hilos.push(0);
                for i in orden(hilos.len(), self.cfg.orden_hilos) {
                    self.regiones.last_mut().expect("región").hilo = i as u32;
                    *self.hilos.last_mut().expect("hilo") = i as u32;
                    if let Flujo::Retorno(_) = self.bloque(m, &hilos[i])? {
                        return abortar(Violacion::ValorInvalido, "retornar dentro de un hilo");
                    }
                }
                self.hilos.pop();
                self.regiones.pop();
            }
            Stmt::Dividir {
                pool,
                partes,
                indice,
                cuerpo,
            } => {
                let p = Self::pool_de(m, *pool)?;
                Self::exige_edit(m, p, "dividir")?;
                if self.p(p)?.particiones() > 0 {
                    return abortar(
                        Violacion::PermisoInventado,
                        format!(
                            "dividir el pool {p} desde un trabajador, que solo posee su partición"
                        ),
                    );
                }
                self.no_congelado(p, "dividir")?;
                if *partes == 0 {
                    return abortar(Violacion::ValorInvalido, "dividir en 0 partes");
                }
                self.pm(p)?.dividir(*partes)?;
                let previa = self.particion.get(&p).copied();
                self.regiones.push(Region::default());
                self.hilos.push(0);
                for k in orden(*partes as usize, self.cfg.orden_hilos) {
                    self.regiones.last_mut().expect("región").hilo = k as u32;
                    *self.hilos.last_mut().expect("hilo") = k as u32;
                    self.particion.insert(p, k + 1);
                    Self::set(m, *indice, Valor::Int(k as i64))?;
                    if let Flujo::Retorno(_) = self.bloque(m, cuerpo)? {
                        return abortar(Violacion::ValorInvalido, "retornar dentro de dividir");
                    }
                }
                self.hilos.pop();
                self.regiones.pop();
                match previa {
                    Some(a) => self.particion.insert(p, a),
                    None => self.particion.remove(&p),
                };
                self.pm(p)?.unir_particiones();
            }
            Stmt::TransferirPool { pool, cuerpo } => {
                let p = Self::pool_de(m, *pool)?;
                if Self::permiso(m, p) != Some(PermisoPool::Dueno) {
                    return abortar(
                        Violacion::PermisoInventado,
                        format!("transferir el pool {p}, que esta función no posee"),
                    );
                }
                if self.p(p)?.particiones() > 0 {
                    return abortar(
                        Violacion::PermisoInventado,
                        format!("transferir el pool {p} mientras está dividido entre trabajadores"),
                    );
                }
                let mut region = Region::default();
                region.hilo = 1;
                self.regiones.push(region);
                self.hilos.push(1);
                if let Flujo::Retorno(_) = self.bloque(m, cuerpo)? {
                    return abortar(
                        Violacion::ValorInvalido,
                        "retornar dentro de transferir_pool",
                    );
                }
                self.hilos.pop();
                self.regiones.pop();
                self.destruir_pool(p)?;
            }
            Stmt::RefFuncion { dst, func } => Self::set(m, *dst, Valor::Func(*func))?,
            Stmt::Llamar {
                destino,
                pools,
                args,
                dst,
            } => {
                let f = match destino {
                    Destino::Directa(f) => *f,
                    Destino::Indirecta(v) => match self.val(m, *v)? {
                        Valor::Func(f) => f,
                        x => return abortar(Violacion::PermisoInventado, format!("llamar {x:?}")),
                    },
                };
                let Some(callee) = self.prog.funciones.get(f.0 as usize) else {
                    return abortar(
                        Violacion::ValorInvalido,
                        format!("función #{} inexistente", f.0),
                    );
                };
                let mut ps = Vec::new();
                for (i, q) in pools.iter().enumerate() {
                    let p = Self::pool_de(m, *q)?;
                    if let Some(pd) = callee.pools.get(i)
                        && pd.permiso != PermisoPool::View
                    {
                        Self::exige_edit(m, p, &format!("pasar como edit a `{}`", callee.nombre))?;
                    }
                    ps.push(p);
                }
                let mut vs = Vec::new();
                for a in args {
                    let x = match a {
                        Operando::Var(v)
                            if matches!(m.vars.get(v.0 as usize), Some(Some(Valor::Obj(_)))) =>
                        {
                            self.tomar(m, *v)?
                        }
                        o => self.op(m, o)?,
                    };
                    vs.push(x);
                }
                let antes: Vec<Contadores> = ps
                    .iter()
                    .map(|p| self.p(*p).map(|x| x.cont))
                    .collect::<R<_>>()?;
                let r = self.llamar(f, ps.clone(), vs)?;
                self.comprobar_efectos(m, destino, pools, &ps, &antes, &callee.nombre)?;
                if let (Some(d), Some(x)) = (dst, r) {
                    Self::set(m, *d, x)?;
                }
            }
            Stmt::Si {
                cond,
                entonces,
                sino,
            } => {
                let c = self.int(m, cond)?;
                return self.bloque(m, if c != 0 { entonces } else { sino });
            }
            Stmt::Repetir {
                veces,
                indice,
                cuerpo,
            } => {
                let n = self.int(m, veces)?;
                for i in 0..n.max(0) {
                    Self::set(m, *indice, Valor::Int(i))?;
                    if let Flujo::Retorno(v) = self.bloque(m, cuerpo)? {
                        return Ok(Flujo::Retorno(v));
                    }
                }
            }
            Stmt::Retornar { valor } => {
                let v = match valor {
                    None => None,
                    Some(Operando::Var(v))
                        if matches!(m.vars.get(v.0 as usize), Some(Some(Valor::Obj(_)))) =>
                    {
                        Some(self.tomar(m, *v)?)
                    }
                    Some(o) => Some(self.op(m, o)?),
                };
                return Ok(Flujo::Retorno(v));
            }
        }
        Ok(Flujo::Normal)
    }

    fn pre_revalidar(&mut self, m: &Marco, pool: usize, modo: Modo) -> R<()> {
        // Primero la existencia del pool: un enlace a un pool destruido o
        // transferido es la violación más precisa.
        self.p(pool)?;
        match modo {
            Modo::Edit => {
                Self::exige_edit(m, pool, "revalidar en modo edit")?;
                self.no_congelado(pool, "revalidar en modo edit")?;
                self.pm(pool)?.cont.revalidaciones_edit += 1;
            }
            Modo::View => {
                Self::exige_acceso(m, pool, "revalidar")?;
                self.pm(pool)?.cont.revalidaciones_view += 1;
            }
        }
        Ok(())
    }

    /// Oráculo de efectos (P4): lo ejecutado por la llamada sobre cada pool
    /// no puede superar el efecto que el verificador infirió (llamada
    /// directa) o asumió (llamada indirecta).
    fn comprobar_efectos(
        &self,
        m: &Marco,
        destino: &Destino,
        pools: &[PoolRef],
        ps: &[usize],
        antes: &[Contadores],
        nombre: &str,
    ) -> R<()> {
        let Some(tabla) = &self.efectos else {
            return Ok(());
        };
        let supuesto = efecto_llamada(self.prog, m.f, tabla, destino, pools);
        for ((q, p), a) in pools.iter().zip(ps).zip(antes) {
            let Some(pool) = self.pool(*p) else { continue };
            let d = pool.cont;
            let e = supuesto
                .iter()
                .find(|(k, _)| k == q)
                .map(|(_, e)| *e)
                .unwrap_or_default();
            let mut fallos = Vec::new();
            if d.asignaciones > a.asignaciones && e.nivel < NivelEfecto::Crece {
                fallos.push("asignó slots");
            }
            if d.destrucciones > a.destrucciones && e.nivel < NivelEfecto::Destruye {
                fallos.push("destruyó slots");
            }
            if d.reestructuras > a.reestructuras && !e.reestructura {
                fallos.push("reestructuró");
            }
            if d.invalidaciones_epoca > a.invalidaciones_epoca && !e.invalida_epoca {
                fallos.push("invalidó la época");
            }
            if d.revalidaciones_view > a.revalidaciones_view && !e.lee_enlaces {
                fallos.push("leyó por enlaces");
            }
            if d.revalidaciones_edit > a.revalidaciones_edit && !e.edita_enlaces {
                fallos.push("editó por enlaces");
            }
            if !fallos.is_empty() {
                return abortar(
                    Violacion::EfectoSubestimado,
                    format!(
                        "la llamada a `{nombre}` desde `{}` {} sobre el pool {p}, pero su efecto estático era {e}",
                        m.f.nombre,
                        fallos.join(", ")
                    ),
                );
            }
        }
        Ok(())
    }

    /// Revalida un enlace según su nivel. Los niveles `Estatico` y
    /// `Congelado` no leen `gen[s]`; el oráculo lo comprueba igualmente sin
    /// contarlo y aborta si la prueba estática era falsa.
    fn validar(&mut self, pool: usize, slot: u32, gener: u32, nivel: Nivel) -> R<bool> {
        if slot == 0 && gener == 0 {
            // Enlace nulo: comparación en registro, sin leer la cabecera.
            return Ok(false);
        }
        self.met.revalidacion(nivel);
        let pl = self.p(pool)?;
        if slot as u64 >= pl.capacidad() {
            return abortar(
                Violacion::FueraDeLimites,
                format!("enlace al slot {slot} fuera de la reserva"),
            );
        }
        // Una superpágina nunca reservada no tiene cabecera: ningún enlace
        // emitido puede apuntar a ella.
        let actual = match pl.gen_de(slot) {
            Ok(g) => g,
            Err(_) => {
                return abortar(
                    Violacion::FueraDeLimites,
                    format!("enlace al slot {slot}, de una superpágina nunca reservada"),
                );
            }
        };
        match nivel {
            Nivel::Comprobado => {
                self.registrar(Granulo::Gen(pool, slot), false)?;
                self.met.lecturas_gen = self.met.lecturas_gen.saturating_add(1);
                Ok(actual == gener && gener & 1 == 1)
            }
            Nivel::Estatico | Nivel::Congelado => {
                if actual != gener || gener & 1 == 0 {
                    return abortar(
                        Violacion::NivelIncorrecto,
                        format!(
                            "revalidación {nivel} de un enlace obsoleto (slot {slot}, gen {gener}, actual {actual}): el verificador probó una validez falsa"
                        ),
                    );
                }
                if nivel == Nivel::Congelado && self.p(pool)?.congelado == 0 {
                    return abortar(
                        Violacion::NivelIncorrecto,
                        format!(
                            "revalidación congelada del slot {slot} sin que el pool {pool} esté congelado"
                        ),
                    );
                }
                Ok(true)
            }
        }
    }
}

/// Ejecuta la función `entrada` (sin parámetros) de un programa verificado,
/// con el oráculo de efectos activo, y comprueba fugas al terminar.
pub fn ejecutar(
    pv: &ProgramaVerificado,
    entrada: &str,
    cfg: Config,
) -> Result<(Option<Valor>, Metricas), Aborto> {
    let Some(f) = pv.programa.buscar(entrada) else {
        return abortar(
            Violacion::ValorInvalido,
            format!("no existe la función `{entrada}`"),
        );
    };
    let mut m = Maquina::nueva(&pv.programa, cfg).con_efectos(pv.efectos.clone());
    let r = m.llamar(f, Vec::new(), Vec::new())?;
    if let Some(Valor::Obj(_)) = r {
        return abortar(
            Violacion::Fuga,
            "la entrada devuelve un dueño que nadie destruye",
        );
    }
    m.comprobar_fugas()?;
    Ok((r, m.metricas()))
}
