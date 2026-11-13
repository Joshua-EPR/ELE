//! Fuzzer basado en propiedades para NEXO v0.2 (sin dependencias).
//!
//! # Generador
//!
//! Los programas se generan a partir de un **flujo de elecciones**
//! ([`Fuente`]): aleatorio (semilla xorshift64*), fijo (reproducción exacta de
//! un caso registrado) o guiado (enumeración exhaustiva de secuencias de
//! operaciones). Cada elección se registra, así que un caso se reproduce con
//! `Fuente::fija(registro)` y se reduce (*shrinking*) recortando, borrando o
//! poniendo a cero elecciones: como el generador interpreta cada elección
//! módulo su rango, cualquier flujo produce un programa estructuralmente
//! válido.
//!
//! El generador elige operandos entre las variables visibles de la categoría
//! adecuada sin seguir la linealidad, de modo que produce de forma natural
//! programas bien formados y mal formados (uso tras mover, doble destrucción,
//! destrucción en `revalidar`, préstamos en conflicto, mutación de pools
//! congelados…). Con `malformados`, además, a veces ignora la categoría.
//!
//! # Propiedades
//!
//! * **P1** (seguridad de aceptación): un programa aceptado se ejecuta sin
//!   violaciones del oráculo en varios órdenes de hilos.
//! * **P2** (linealidad): sin fugas ni dobles liberaciones (oráculo +
//!   `comprobar_fugas`).
//! * **P3** (generaciones): [`fuzz_pool`] comprueba que ningún par
//!   `(slot, gen)` se emite dos veces y que ningún enlace muerto vuelve a
//!   identificar un objeto vivo.
//! * **P4** (efectos): oráculo de efectos de la máquina en cada llamada.
//! * **P5** (sellado/niveles): el oráculo comprueba toda revalidación
//!   `Estatico`/`Congelado`.
//! * **P6** (concurrencia): detector de carreras de la máquina.
//! * **P7** (recuperación): accesos a subpáginas devueltas o slots muertos
//!   abortan; [`fuzz_pool`] lo comprueba también directamente.
//! * **P8** (convergencia): [`fuzz_efectos`] compara el punto fijo con el
//!   cierre transitivo calculado de forma independiente.

use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::time::{Duration, Instant};

use crate::Regla;
use crate::ir::s::*;
use crate::ir::*;
use crate::rt::pool::{Eventos, GEN_RETIRADO, Pool};
use crate::rt::{Aborto, Config, Maquina, Violacion};
use crate::verif::efectos::{EfectoPool, NivelEfecto};
use crate::verif::tipos::firma_de;
use crate::verif::verificar;

// ------------------------------------------------------------------ fuente

#[derive(Clone, Debug)]
enum ModoFuente {
    Aleatorio(u64),
    Fijo {
        datos: Vec<u32>,
        pos: usize,
    },
    Guiado {
        ops: Vec<u32>,
        pos: usize,
        sesgo: u32,
    },
}

/// Flujo de elecciones del generador.
#[derive(Clone, Debug)]
pub struct Fuente {
    modo: ModoFuente,
    /// Todas las elecciones devueltas, en orden (permite reproducir el caso).
    pub registro: Vec<u32>,
}

impl Fuente {
    pub fn aleatoria(semilla: u64) -> Self {
        Fuente {
            modo: ModoFuente::Aleatorio(semilla.max(1)),
            registro: Vec::new(),
        }
    }

    pub fn fija(datos: Vec<u32>) -> Self {
        Fuente {
            modo: ModoFuente::Fijo { datos, pos: 0 },
            registro: Vec::new(),
        }
    }

    /// Secuencia de operaciones dada; los operandos se eligen con `sesgo`.
    pub fn guiada(ops: Vec<u32>, sesgo: u32) -> Self {
        Fuente {
            modo: ModoFuente::Guiado { ops, pos: 0, sesgo },
            registro: Vec::new(),
        }
    }

    fn crudo(&mut self) -> u64 {
        match &mut self.modo {
            ModoFuente::Aleatorio(x) => {
                *x ^= *x >> 12;
                *x ^= *x << 25;
                *x ^= *x >> 27;
                x.wrapping_mul(0x2545_F491_4F6C_DD1D)
            }
            _ => 0,
        }
    }

    /// Elección de operando en `[0, n)`.
    pub fn eleccion(&mut self, n: u32) -> u32 {
        // Cada elección consume exactamente una posición en todos los modos,
        // también con n = 1: así el registro se reproduce con `fija`.
        let n = n.max(1);
        let v = {
            match &mut self.modo {
                ModoFuente::Aleatorio(_) => (self.crudo() % n as u64) as u32,
                ModoFuente::Fijo { datos, pos } => {
                    let v = datos.get(*pos).copied().unwrap_or(0) % n;
                    *pos += 1;
                    v
                }
                ModoFuente::Guiado { sesgo, .. } => *sesgo % n,
            }
        };
        self.registro.push(v);
        v
    }

    fn op(&mut self, k: u32) -> u32 {
        if let ModoFuente::Guiado { ops, pos, .. } = &mut self.modo {
            let v = ops.get(*pos).copied().unwrap_or(0) % k;
            *pos += 1;
            self.registro.push(v);
            return v;
        }
        self.eleccion(k)
    }

    fn longitud(&mut self, max: u32, raiz: bool) -> u32 {
        if let ModoFuente::Guiado { ops, pos, .. } = &mut self.modo {
            let quedan = ops.len().saturating_sub(*pos) as u32;
            let v = if raiz { quedan } else { quedan.min(1) };
            self.registro.push(v);
            return v;
        }
        self.eleccion(max + 1)
    }

    /// Operación según una tabla de pesos (uniforme en modo guiado, para que
    /// la enumeración exhaustiva cubra todas las secuencias por igual).
    fn op_pesada(&mut self, pesos: &[u32]) -> u32 {
        if matches!(self.modo, ModoFuente::Guiado { .. }) {
            return self.op(pesos.len() as u32);
        }
        let total: u32 = pesos.iter().sum();
        let mut r = self.eleccion(total);
        for (i, w) in pesos.iter().enumerate() {
            if r < *w {
                return i as u32;
            }
            r -= w;
        }
        pesos.len() as u32 - 1
    }

    fn agotada(&self) -> bool {
        matches!(&self.modo, ModoFuente::Guiado { ops, pos, .. } if *pos >= ops.len())
    }
}

/// Pesos de las operaciones en modo aleatorio (mismo orden que
/// [`NOMBRES_OPS`]): favorecen enlaces, revalidaciones y accesos para que
/// los programas aceptados ejerciten el núcleo del modelo.
pub const PESOS_OPS: [u32; NOPS as usize] = [
    6, 2, 5, 2, 6, 3, 12, 5, 4, 6, 5, 3, 2, 6, 1, 3, 3, 3, 1, 2, 1, 3, 4, 2,
];

// --------------------------------------------------------------- generador

/// Parámetros del generador.
#[derive(Clone, Copy, Debug)]
pub struct CfgGen {
    /// Sentencias máximas generadas en total (aprox. tamaño del programa).
    pub max_ops: u32,
    /// Profundidad máxima de bloques anidados.
    pub max_prof: u32,
    /// Longitud máxima de un bloque.
    pub max_bloque: u32,
    /// Ignorar a veces la categoría de los operandos (IR mal tipada).
    pub malformados: bool,
    /// Empezar `main` con objetos y enlaces ya creados en `P` y `Q`.
    pub preludio: bool,
}

impl Default for CfgGen {
    fn default() -> Self {
        CfgGen {
            max_ops: 12,
            max_prof: 2,
            max_bloque: 5,
            malformados: false,
            preludio: true,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Cat {
    /// `None` = pila de datos.
    Dueno(Option<PoolRef>),
    Prest(Modo, Option<PoolRef>),
    Enlace(PoolRef),
    Int,
    Sello(PoolRef),
}

/// Número de operaciones del generador.
pub const NOPS: u32 = 24;

/// Nombres de las operaciones (para informes).
pub const NOMBRES_OPS: [&str; NOPS as usize] = [
    "crear_pool",
    "crear_pila",
    "destruir",
    "mover",
    "enlazar",
    "copiar_enlace",
    "revalidar",
    "revalidar_lote",
    "prestar",
    "leer_int",
    "escribir",
    "si",
    "repetir",
    "llamar",
    "reestructurar",
    "congelar",
    "paralelo",
    "sellar",
    "retornar",
    "dividir",
    "transferir",
    "hueco",
    "leer_enlace",
    "const",
];

struct Ayudantes {
    crece: FuncId,
    lee: FuncId,
    tira: FuncId,
    reest: FuncId,
    edita: FuncId,
    rec: FuncId,
    mira: FuncId,
    firma_mira: Firma,
    firma_reest: Firma,
}

struct Gen<'a> {
    fu: &'a mut Fuente,
    cfg: CfgGen,
    c: Constructor,
    nodo: ClaseId,
    dato: ClaseId,
    ambito: Vec<Vec<(VarId, Cat)>>,
    nombres: u32,
    prof: u32,
    ops: u32,
    p: PoolRef,
    q: PoolRef,
    ay: &'a Ayudantes,
}

fn ayudantes(prog: &mut Programa, nodo: ClaseId) -> Ayudantes {
    let tn = |p| Ty::Dueno(nodo, Ubic::Pool(p));
    // crece(P edit) -> dueño
    let mut c = Constructor::nueva("crece");
    let p = c.pool_param("P", nodo, PermisoPool::Edit);
    let x = c.var("x", tn(p));
    c.retorna(tn(p));
    let crece = prog.agregar(c.cuerpo(vec![
        crear(x, nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        retornar(Some(v(x))),
    ]));
    // lee(P view, l) -> Int
    let mut c = Constructor::nueva("lee");
    let p = c.pool_param("P", nodo, PermisoPool::View);
    let l = c.param("l", Ty::Enlace(p));
    let n = c.var("n", Ty::Prestamo(Modo::View, nodo, Ubic::Pool(p)));
    let y = c.var("y", Ty::Int);
    c.retorna(Ty::Int);
    let lee = prog.agregar(c.cuerpo(vec![
        revalidar(l, Modo::View, n, vec![leer(y, n, 0)], vec![]),
        retornar(Some(k(0))),
    ]));
    // tira(P edit, x)
    let mut c = Constructor::nueva("tira");
    let p = c.pool_param("P", nodo, PermisoPool::Edit);
    let x = c.param("x", tn(p));
    let tira = prog.agregar(c.cuerpo(vec![destruir(x)]));
    // reest(P edit)
    let mut c = Constructor::nueva("reest");
    let p = c.pool_param("P", nodo, PermisoPool::Edit);
    let reest = prog.agregar(c.cuerpo(vec![Stmt::Reestructurar { pool: p }]));
    // edita(P edit, l)
    let mut c = Constructor::nueva("edita");
    let p = c.pool_param("P", nodo, PermisoPool::Edit);
    let l = c.param("l", Ty::Enlace(p));
    let n = c.var("n", Ty::Prestamo(Modo::Edit, nodo, Ubic::Pool(p)));
    let edita = prog.agregar(c.cuerpo(vec![revalidar(
        l,
        Modo::Edit,
        n,
        vec![escribir(n, 0, k(7))],
        vec![],
    )]));
    // rec(P edit, n): crea/destruye y se llama con n - 1.
    let rec = prog.declarar("rec");
    let mut c = Constructor::nueva("rec");
    let p = c.pool_param("P", nodo, PermisoPool::Edit);
    let nn = c.param("n", Ty::Int);
    let x = c.var("x", tn(p));
    let m = c.var("m", Ty::Int);
    prog.definir(
        rec,
        c.cuerpo(vec![si(
            v(nn),
            vec![
                crear(x, nodo, Ubic::Pool(p), vec![v(nn), k(0)]),
                destruir(x),
                Stmt::Aritmetica {
                    dst: m,
                    op: OpArit::Restar,
                    a: v(nn),
                    b: k(1),
                },
                llamar(rec, vec![p], vec![v(m)], None),
            ],
            vec![],
        )]),
    );
    // mira(P view): sella (lee por enlaces).
    let mut c = Constructor::nueva("mira");
    let p = c.pool_param("P", nodo, PermisoPool::View);
    let s = c.var("s", Ty::Sello(p));
    let mira = prog.agregar(c.cuerpo(vec![Stmt::Sellar { dst: s, pool: p }]));
    let firma_mira = firma_de(prog.funcion(mira));
    let mut firma_reest = firma_de(prog.funcion(reest));
    firma_reest.opaca = true;
    Ayudantes {
        crece,
        lee,
        tira,
        reest,
        edita,
        rec,
        mira,
        firma_mira,
        firma_reest,
    }
}

/// Genera un programa con ayudantes fijos y una función `main` aleatoria.
pub fn generar(fu: &mut Fuente, cfg: CfgGen) -> Programa {
    let mut prog = Programa::default();
    let nodo = prog.clase_nueva("Nodo", true, &[TipoCampo::Int, TipoCampo::Enlace]);
    let dato = prog.clase_nueva("Dato", false, &[TipoCampo::Int]);
    let ay = ayudantes(&mut prog, nodo);
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", nodo);
    let q = c.pool_local("Q", nodo);
    let mut g = Gen {
        fu,
        cfg,
        c,
        nodo,
        dato,
        ambito: Vec::new(),
        nombres: 0,
        prof: 0,
        ops: 0,
        p,
        q,
        ay: &ay,
    };
    let mut cuerpo = Vec::new();
    let mut previas = Vec::new();
    if cfg.preludio {
        // a, b en P (b → a) y c en Q, con sus enlaces; un dato de pila.
        let a = g.nueva_sin_ambito(Cat::Dueno(Some(p)));
        let la = g.nueva_sin_ambito(Cat::Enlace(p));
        let b = g.nueva_sin_ambito(Cat::Dueno(Some(p)));
        let lb = g.nueva_sin_ambito(Cat::Enlace(p));
        let c = g.nueva_sin_ambito(Cat::Dueno(Some(q)));
        let lc = g.nueva_sin_ambito(Cat::Enlace(q));
        let d = g.nueva_sin_ambito(Cat::Dueno(None));
        cuerpo.extend([
            crear(a, nodo, Ubic::Pool(p), vec![k(1), k(0)]),
            enlazar(la, a),
            crear(b, nodo, Ubic::Pool(p), vec![k(2), v(la)]),
            enlazar(lb, b),
            crear(c, nodo, Ubic::Pool(q), vec![k(3), k(0)]),
            enlazar(lc, c),
            crear(d, dato, Ubic::Pila, vec![k(4)]),
        ]);
        previas = vec![
            (a, Cat::Dueno(Some(p))),
            (la, Cat::Enlace(p)),
            (b, Cat::Dueno(Some(p))),
            (lb, Cat::Enlace(p)),
            (c, Cat::Dueno(Some(q))),
            (lc, Cat::Enlace(q)),
            (d, Cat::Dueno(None)),
        ];
    }
    cuerpo.extend(g.bloque(true, previas));
    let f = g.c.cuerpo(cuerpo);
    prog.agregar(f);
    prog
}

impl Gen<'_> {
    fn ty(&self, c: Cat) -> Ty {
        match c {
            Cat::Dueno(Some(p)) => Ty::Dueno(self.nodo, Ubic::Pool(p)),
            Cat::Dueno(None) => Ty::Dueno(self.dato, Ubic::Pila),
            Cat::Prest(m, Some(p)) => Ty::Prestamo(m, self.nodo, Ubic::Pool(p)),
            Cat::Prest(m, None) => Ty::Prestamo(m, self.dato, Ubic::Pila),
            Cat::Enlace(p) => Ty::Enlace(p),
            Cat::Int => Ty::Int,
            Cat::Sello(p) => Ty::Sello(p),
        }
    }

    fn nueva_sin_ambito(&mut self, cat: Cat) -> VarId {
        self.nombres += 1;
        let pref = match cat {
            Cat::Dueno(_) => "d",
            Cat::Prest(Modo::View, _) => "v",
            Cat::Prest(Modo::Edit, _) => "e",
            Cat::Enlace(_) => "l",
            Cat::Int => "i",
            Cat::Sello(_) => "s",
        };
        let ty = self.ty(cat);
        self.c.var(&format!("{pref}{}", self.nombres), ty)
    }

    fn nueva(&mut self, cat: Cat) -> VarId {
        let v = self.nueva_sin_ambito(cat);
        self.ambito.last_mut().expect("ámbito").push((v, cat));
        v
    }

    fn elegir(&mut self, pred: impl Fn(Cat) -> bool) -> Option<(VarId, Cat)> {
        let todos: Vec<(VarId, Cat)> = self.ambito.iter().flatten().copied().collect();
        let mut cand: Vec<(VarId, Cat)> = todos.iter().copied().filter(|(_, c)| pred(*c)).collect();
        if self.cfg.malformados && !todos.is_empty() && self.fu.eleccion(16) == 0 {
            cand = todos;
        }
        if cand.is_empty() {
            return None;
        }
        let i = self.fu.eleccion(cand.len() as u32) as usize;
        Some(cand[i])
    }

    fn pool(&mut self) -> PoolRef {
        if self.fu.eleccion(4) == 0 {
            self.q
        } else {
            self.p
        }
    }

    fn pool_de(c: Cat) -> Option<PoolRef> {
        match c {
            Cat::Dueno(p) | Cat::Prest(_, p) => p,
            Cat::Enlace(p) | Cat::Sello(p) => Some(p),
            Cat::Int => None,
        }
    }

    fn modo(&mut self) -> Modo {
        if self.fu.eleccion(3) == 0 {
            Modo::Edit
        } else {
            Modo::View
        }
    }

    fn enlace_o_nulo(&mut self, p: PoolRef) -> Operando {
        match self.elegir(|c| c == Cat::Enlace(p)) {
            Some((l, _)) if self.fu.eleccion(3) != 0 => v(l),
            _ => k(0),
        }
    }

    fn bloque(&mut self, raiz: bool, previas: Vec<(VarId, Cat)>) -> Bloque {
        self.ambito.push(previas);
        self.prof += 1;
        let mut out = Vec::new();
        let n = self.fu.longitud(self.cfg.max_bloque, raiz);
        for _ in 0..n {
            if self.ops >= self.cfg.max_ops || self.fu.agotada() {
                break;
            }
            self.ops += 1;
            let k = self.fu.op_pesada(&PESOS_OPS);
            if let Some(s) = self.op(k) {
                out.push(s);
            }
        }
        self.prof -= 1;
        self.ambito.pop();
        out
    }

    fn anidado(&mut self, previas: Vec<(VarId, Cat)>) -> Bloque {
        if self.prof > self.cfg.max_prof {
            return Vec::new();
        }
        self.bloque(false, previas)
    }

    fn op(&mut self, op: u32) -> Option<Stmt> {
        let nodo = self.nodo;
        Some(match op {
            0 => {
                let p = self.pool();
                let l = self.enlace_o_nulo(p);
                let x = self.fu.eleccion(5) as i64;
                let d = self.nueva(Cat::Dueno(Some(p)));
                crear(d, nodo, Ubic::Pool(p), vec![k(x), l])
            }
            1 => {
                let d = self.nueva(Cat::Dueno(None));
                crear(d, self.dato, Ubic::Pila, vec![k(1)])
            }
            2 => destruir(self.elegir(|c| matches!(c, Cat::Dueno(_)))?.0),
            3 => {
                let (src, cat) = self.elegir(|c| matches!(c, Cat::Dueno(_)))?;
                let d = self.nueva(cat);
                mover(d, src)
            }
            4 => {
                let (o, cat) =
                    self.elegir(|c| matches!(c, Cat::Dueno(Some(_)) | Cat::Prest(_, Some(_))))?;
                let p = Self::pool_de(cat)?;
                let l = self.nueva(Cat::Enlace(p));
                enlazar(l, o)
            }
            5 => {
                let (src, cat) = self.elegir(|c| matches!(c, Cat::Enlace(_)))?;
                let d = self.nueva(cat);
                copiar(d, src)
            }
            6 => {
                let (l, cat) = self.elegir(|c| matches!(c, Cat::Enlace(_)))?;
                let p = Self::pool_de(cat)?;
                let modo = self.modo();
                let diferir = self.fu.eleccion(4) == 0;
                let cl = Cat::Prest(modo, Some(p));
                let lig = self.nueva_sin_ambito(cl);
                let cuerpo = self.anidado(vec![(lig, cl)]);
                let ausente = self.anidado(Vec::new());
                Stmt::Revalidar {
                    enlace: l,
                    modo,
                    ligado: lig,
                    cuerpo,
                    ausente,
                    diferir,
                    nivel: None,
                }
            }
            7 => {
                let modo = self.modo();
                let n = 2 + self.fu.eleccion(2);
                let mut enlaces = Vec::new();
                let mut ligs = Vec::new();
                for _ in 0..n {
                    let (l, cat) = self.elegir(|c| matches!(c, Cat::Enlace(_)))?;
                    let cl = Cat::Prest(modo, Self::pool_de(cat));
                    enlaces.push(l);
                    ligs.push((self.nueva_sin_ambito(cl), cl));
                }
                let ligados: Vec<VarId> = ligs.iter().map(|x| x.0).collect();
                let cuerpo = self.anidado(ligs);
                let ausente = self.anidado(Vec::new());
                lote(enlaces, modo, ligados, cuerpo, ausente)
            }
            8 => {
                let (src, cat) = self.elegir(|c| matches!(c, Cat::Dueno(_) | Cat::Prest(..)))?;
                let modo = self.modo();
                let p = match cat {
                    Cat::Dueno(p) | Cat::Prest(_, p) => p,
                    _ => None,
                };
                let d = self.nueva(Cat::Prest(modo, p));
                prestar(d, src, modo)
            }
            9 => {
                let (o, _) = self.elegir(|c| matches!(c, Cat::Dueno(_) | Cat::Prest(..)))?;
                let d = self.nueva(Cat::Int);
                leer(d, o, 0)
            }
            10 => {
                let (o, cat) =
                    self.elegir(|c| matches!(c, Cat::Dueno(_) | Cat::Prest(Modo::Edit, _)))?;
                match Self::pool_de(cat) {
                    Some(p) if self.fu.eleccion(2) == 0 => {
                        let l = self.enlace_o_nulo(p);
                        escribir(o, 1, l)
                    }
                    _ => escribir(o, 0, k(self.fu.eleccion(9) as i64)),
                }
            }
            11 => {
                let cond = match self.elegir(|c| c == Cat::Int) {
                    Some((i, _)) if self.fu.eleccion(2) == 0 => v(i),
                    _ => k(self.fu.eleccion(2) as i64),
                };
                let a = self.anidado(Vec::new());
                let b = self.anidado(Vec::new());
                si(cond, a, b)
            }
            12 => {
                let n = 1 + self.fu.eleccion(3) as i64;
                let i = self.nueva_sin_ambito(Cat::Int);
                let cuerpo = self.anidado(vec![(i, Cat::Int)]);
                repetir(k(n), i, cuerpo)
            }
            13 => self.llamada()?,
            14 => {
                let p = self.pool();
                Stmt::Reestructurar { pool: p }
            }
            15 => {
                let p = self.pool();
                let cuerpo = self.anidado(Vec::new());
                Stmt::Congelar { pool: p, cuerpo }
            }
            16 => {
                let a = self.anidado(Vec::new());
                let b = self.anidado(Vec::new());
                Stmt::Paralelo { hilos: vec![a, b] }
            }
            17 => {
                let p = self.pool();
                let s = self.nueva(Cat::Sello(p));
                // El sello y su prueba van juntos: `si_sellado` inmediato.
                let cuerpo = self.anidado(Vec::new());
                let sino = self.anidado(Vec::new());
                return Some(self.envolver(vec![
                    Stmt::Sellar { dst: s, pool: p },
                    Stmt::SiSellado {
                        sello: s,
                        cuerpo,
                        sino,
                    },
                ]));
            }
            18 => retornar(None),
            19 => {
                let p = self.pool();
                let i = self.nueva_sin_ambito(Cat::Int);
                let cuerpo = self.anidado(vec![(i, Cat::Int)]);
                Stmt::Dividir {
                    pool: p,
                    partes: 2,
                    indice: i,
                    cuerpo,
                }
            }
            20 => {
                let cuerpo = self.anidado(Vec::new());
                Stmt::TransferirPool {
                    pool: self.q,
                    cuerpo,
                }
            }
            21 => {
                let (x, cat) = self.elegir(|c| matches!(c, Cat::Dueno(Some(_))))?;
                let p = Self::pool_de(cat)?;
                let h = self.nuevo_hueco(p);
                let l = self.enlace_o_nulo(p);
                let d = self.nueva(Cat::Dueno(Some(p)));
                return Some(
                    self.envolver(vec![destruir_en_hueco(x, h), reusar(d, h, vec![k(2), l])]),
                );
            }
            22 => {
                let (o, cat) =
                    self.elegir(|c| matches!(c, Cat::Dueno(Some(_)) | Cat::Prest(_, Some(_))))?;
                let p = Self::pool_de(cat)?;
                let d = self.nueva(Cat::Enlace(p));
                leer(d, o, 1)
            }
            _ => {
                let d = self.nueva(Cat::Int);
                constante(d, self.fu.eleccion(3) as i64)
            }
        })
    }

    fn nuevo_hueco(&mut self, p: PoolRef) -> VarId {
        self.nombres += 1;
        self.c.var(&format!("h{}", self.nombres), Ty::Hueco(p))
    }

    /// Dos sentencias que deben ir juntas en el mismo bloque se emiten en un
    /// `si 1 { … }` para conservar el ámbito de lo que definen solo dentro.
    /// (Las variables definidas quedan visibles para el resto del bloque
    /// actual en el generador, lo que produce también usos fuera de ámbito,
    /// que el verificador debe rechazar con R1/R5.)
    fn envolver(&mut self, ss: Vec<Stmt>) -> Stmt {
        si(k(1), ss, vec![])
    }

    fn llamada(&mut self) -> Option<Stmt> {
        let ay = self.ay;
        let p = self.pool();
        Some(match self.fu.eleccion(9) {
            0 => {
                let d = self.nueva(Cat::Dueno(Some(p)));
                llamar(ay.crece, vec![p], vec![], Some(d))
            }
            1 => {
                let (l, _) = self.elegir(|c| c == Cat::Enlace(p))?;
                let d = self.nueva(Cat::Int);
                llamar(ay.lee, vec![p], vec![v(l)], Some(d))
            }
            2 => {
                let (x, _) = self.elegir(|c| c == Cat::Dueno(Some(p)))?;
                llamar(ay.tira, vec![p], vec![v(x)], None)
            }
            3 => llamar(ay.reest, vec![p], vec![], None),
            4 => {
                let (l, _) = self.elegir(|c| c == Cat::Enlace(p))?;
                llamar(ay.edita, vec![p], vec![v(l)], None)
            }
            5 => llamar(ay.rec, vec![p], vec![k(self.fu.eleccion(3) as i64)], None),
            6 => llamar(ay.mira, vec![p], vec![], None),
            7 => {
                let f = self
                    .c
                    .var("cb_mira", Ty::Funcion(Box::new(ay.firma_mira.clone())));
                return Some(si(
                    k(1),
                    vec![
                        Stmt::RefFuncion {
                            dst: f,
                            func: ay.mira,
                        },
                        llamar_ind(f, vec![p], vec![], None),
                    ],
                    vec![],
                ));
            }
            _ => {
                let f = self
                    .c
                    .var("cb_opaca", Ty::Funcion(Box::new(ay.firma_reest.clone())));
                return Some(si(
                    k(1),
                    vec![
                        Stmt::RefFuncion {
                            dst: f,
                            func: ay.reest,
                        },
                        llamar_ind(f, vec![p], vec![], None),
                    ],
                    vec![],
                ));
            }
        })
    }
}

// --------------------------------------------------------------- ejecución

/// Órdenes de hilos explorados para cada programa aceptado.
pub fn ordenes(semilla: u64) -> [u64; 3] {
    [0, 1, (semilla | 2).wrapping_mul(0x9E37_79B9_7F4A_7C15) | 2]
}

/// Resultado de evaluar un caso.
#[derive(Clone, Debug)]
pub enum Veredicto {
    /// Aceptado y ejecutado sin violaciones en todos los órdenes.
    Seguro,
    /// Rechazado; `inseguro` indica si la ejecución sin verificar abortó.
    Rechazado {
        reglas: Vec<Regla>,
        inseguro: Option<Violacion>,
    },
    /// **Fallo de P1**: aceptado pero el oráculo detectó una violación.
    Fallo(Box<Fallo>),
}

#[derive(Clone, Debug)]
pub struct Fallo {
    pub orden_hilos: u64,
    pub gen_inicial: u32,
    pub aborto: Aborto,
    pub traza: Vec<String>,
    pub estado: String,
}

fn config_caso(fu: &mut Fuente) -> u32 {
    // Uno de cada 4 casos arranca cerca del agotamiento de generación.
    if fu.eleccion(4) == 0 {
        GEN_RETIRADO - 6
    } else {
        0
    }
}

/// Evalúa un programa: verificar; si se acepta, ejecutar en varios órdenes
/// de hilos con traza e invariantes; si se rechaza, ejecutar la IR cruda
/// para clasificar el rechazo.
pub fn evaluar(prog: &Programa, gen_inicial: u32, semilla: u64) -> Veredicto {
    match verificar(prog) {
        Ok(pv) => {
            for orden in ordenes(semilla) {
                let cfg = Config {
                    gen_inicial,
                    orden_hilos: orden,
                    traza: 48,
                    invariantes: true,
                    max_superpaginas: 8,
                    ..Config::default()
                };
                let Some(main) = pv.programa.buscar("main") else {
                    continue;
                };
                let mut m = Maquina::nueva(&pv.programa, cfg).con_efectos(pv.efectos.clone());
                let r = m
                    .llamar(main, Vec::new(), Vec::new())
                    .and_then(|_| m.comprobar_fugas())
                    .and_then(|_| m.comprobar_invariantes());
                if let Err(aborto) = r {
                    return Veredicto::Fallo(Box::new(Fallo {
                        orden_hilos: orden,
                        gen_inicial,
                        aborto,
                        traza: m.traza(),
                        estado: m.estado_pools(),
                    }));
                }
            }
            Veredicto::Seguro
        }
        Err(ds) => {
            let mut reglas: Vec<Regla> = ds.iter().map(|d| d.regla).collect();
            reglas.sort();
            reglas.dedup();
            let cfg = Config {
                gen_inicial,
                max_superpaginas: 8,
                max_profundidad: 64,
                ..Config::default()
            };
            let inseguro = prog.buscar("main").and_then(|main| {
                let mut m = Maquina::nueva(prog, cfg);
                m.llamar(main, Vec::new(), Vec::new())
                    .and_then(|_| m.comprobar_fugas())
                    .err()
                    .map(|a| a.violacion)
            });
            Veredicto::Rechazado { reglas, inseguro }
        }
    }
}

/// Un caso generado y evaluado.
pub struct Caso {
    pub programa: Programa,
    pub eleccion: Vec<u32>,
    pub gen_inicial: u32,
    pub veredicto: Veredicto,
}

pub fn caso(mut fu: Fuente, cfg: CfgGen, semilla: u64) -> Caso {
    let gen_inicial = config_caso(&mut fu);
    let programa = generar(&mut fu, cfg);
    let veredicto = evaluar(&programa, gen_inicial, semilla);
    Caso {
        programa,
        eleccion: fu.registro,
        gen_inicial,
        veredicto,
    }
}

/// Reduce un flujo de elecciones conservando `pred` (borrado de tramos,
/// borrado de elementos y reducción de valores a 0). Devuelve el mínimo
/// encontrado y el número de intentos.
pub fn reducir(
    eleccion: &[u32],
    mut pred: impl FnMut(&[u32]) -> bool,
    max_intentos: usize,
) -> (Vec<u32>, usize) {
    let mut actual = eleccion.to_vec();
    let mut intentos = 0;
    let mut mejora = true;
    while mejora && intentos < max_intentos {
        mejora = false;
        // Recortes de tramos decrecientes.
        let mut tramo = actual.len().max(1) / 2;
        while tramo >= 1 && intentos < max_intentos {
            let mut i = 0;
            while i + tramo <= actual.len() && intentos < max_intentos {
                let mut cand = actual.clone();
                cand.drain(i..i + tramo);
                intentos += 1;
                if pred(&cand) {
                    actual = cand;
                    mejora = true;
                } else {
                    i += tramo;
                }
            }
            tramo /= 2;
        }
        // Valores a 0 y a la mitad.
        for i in 0..actual.len() {
            for nuevo in [0, actual[i] / 2] {
                if actual[i] == nuevo || intentos >= max_intentos {
                    continue;
                }
                let mut cand = actual.clone();
                cand[i] = nuevo;
                intentos += 1;
                if pred(&cand) {
                    actual = cand;
                    mejora = true;
                    break;
                }
            }
        }
    }
    (actual, intentos)
}

/// Reduce un caso fallido de P1 conservando la misma violación.
pub fn reducir_fallo(c: &Caso, cfg: CfgGen, semilla: u64) -> (Vec<u32>, Programa) {
    let Veredicto::Fallo(f) = &c.veredicto else {
        return (c.eleccion.clone(), c.programa.clone());
    };
    let objetivo = f.aborto.violacion;
    let (min, _) = reducir(
        &c.eleccion,
        |e| matches!(&caso(Fuente::fija(e.to_vec()), cfg, semilla).veredicto, Veredicto::Fallo(g) if g.aborto.violacion == objetivo),
        3000,
    );
    let c2 = caso(Fuente::fija(min.clone()), cfg, semilla);
    (min, c2.programa)
}

// --------------------------------------------------------------- campañas

#[derive(Clone, Copy, Debug)]
pub struct CfgCampana {
    pub semilla: u64,
    pub casos: u64,
    pub generador: CfgGen,
    pub limite: Option<Duration>,
    /// Reducir los fallos encontrados (más lento).
    pub reducir: bool,
}

/// Informe de un fallo reproducible.
pub struct InformeFallo {
    pub semilla_caso: u64,
    pub eleccion: Vec<u32>,
    pub eleccion_reducida: Vec<u32>,
    pub programa_reducido: String,
    pub fallo: Fallo,
}

#[derive(Default)]
pub struct Informe {
    pub casos: u64,
    pub sentencias: u64,
    pub aceptados: u64,
    pub ejecuciones: u64,
    pub rechazados: u64,
    pub rechazos_por_regla: BTreeMap<Regla, u64>,
    pub rechazados_inseguros: BTreeMap<String, u64>,
    pub rechazados_limpios: u64,
    pub ops_aceptadas: BTreeMap<&'static str, u64>,
    pub fallos: Vec<InformeFallo>,
    pub duracion: Duration,
}

fn contar_ops(b: &[Stmt], n: &mut u64) {
    for s in b {
        *n += 1;
        for blq in s.bloques() {
            contar_ops(blq, n);
        }
    }
}

fn ops_de(b: &[Stmt], m: &mut BTreeMap<&'static str, u64>) {
    for s in b {
        *m.entry(s.nombre()).or_default() += 1;
        for blq in s.bloques() {
            ops_de(blq, m);
        }
    }
}

fn registrar(inf: &mut Informe, c: &Caso, semilla_caso: u64, cfg: &CfgCampana) {
    inf.casos += 1;
    let main = c.programa.funciones.last().expect("main");
    let mut n = 0;
    contar_ops(&main.cuerpo, &mut n);
    inf.sentencias += n;
    match &c.veredicto {
        Veredicto::Seguro => {
            inf.aceptados += 1;
            inf.ejecuciones += 3;
            ops_de(&main.cuerpo, &mut inf.ops_aceptadas);
        }
        Veredicto::Rechazado { reglas, inseguro } => {
            inf.rechazados += 1;
            for r in reglas {
                *inf.rechazos_por_regla.entry(*r).or_default() += 1;
            }
            match inseguro {
                Some(v) => {
                    *inf.rechazados_inseguros
                        .entry(format!("{v:?}"))
                        .or_default() += 1
                }
                None => inf.rechazados_limpios += 1,
            }
        }
        Veredicto::Fallo(f) => {
            let (reducida, prog) = if cfg.reducir {
                reducir_fallo(c, cfg.generador, semilla_caso)
            } else {
                (c.eleccion.clone(), c.programa.clone())
            };
            inf.fallos.push(InformeFallo {
                semilla_caso,
                eleccion: c.eleccion.clone(),
                eleccion_reducida: reducida,
                programa_reducido: crate::pretty::funcion(
                    &prog,
                    prog.funciones.last().expect("main"),
                ),
                fallo: (**f).clone(),
            });
        }
    }
}

/// Semilla del caso `i` de una campaña.
pub fn semilla_caso(semilla: u64, i: u64) -> u64 {
    semilla ^ (i.wrapping_add(1)).wrapping_mul(0x9E37_79B9_7F4A_7C15)
}

/// Campaña aleatoria reproducible.
pub fn campana(cfg: CfgCampana) -> Informe {
    let inicio = Instant::now();
    let mut inf = Informe::default();
    for i in 0..cfg.casos {
        if cfg.limite.is_some_and(|l| inicio.elapsed() > l) {
            break;
        }
        let s = semilla_caso(cfg.semilla, i);
        let c = caso(Fuente::aleatoria(s), cfg.generador, s);
        registrar(&mut inf, &c, s, &cfg);
    }
    inf.duracion = inicio.elapsed();
    inf
}

/// Enumeración exhaustiva de todas las secuencias de `longitud` operaciones
/// (cada operación anidada consume la siguiente de la secuencia), con
/// operandos elegidos por `sesgo` ∈ {0, 1} y generación inicial 0.
pub fn exhaustiva(longitud: u32, cfg: CfgCampana) -> Informe {
    let inicio = Instant::now();
    let mut inf = Informe::default();
    let total = (NOPS as u64).pow(longitud);
    let cfg_gen = CfgGen {
        max_ops: longitud,
        ..cfg.generador
    };
    for idx in 0..total {
        let mut ops = Vec::new();
        let mut x = idx;
        for _ in 0..longitud {
            ops.push((x % NOPS as u64) as u32);
            x /= NOPS as u64;
        }
        for sesgo in 0..2 {
            let mut fu = Fuente::guiada(ops.clone(), sesgo);
            // Primera elección: generación inicial 0 (sesgo 0) o cerca del
            // agotamiento (sesgo 1 → elección 1 % 4 ≠ 0 → 0).
            let gen_inicial = config_caso(&mut fu);
            let programa = generar(&mut fu, cfg_gen);
            let veredicto = evaluar(&programa, gen_inicial, idx);
            let c = Caso {
                programa,
                eleccion: fu.registro,
                gen_inicial,
                veredicto,
            };
            registrar(
                &mut inf,
                &c,
                idx,
                &CfgCampana {
                    reducir: false,
                    ..cfg
                },
            );
        }
    }
    inf.duracion = inicio.elapsed();
    inf
}

impl fmt::Display for Informe {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "casos: {} ({} sentencias) en {:.2?}; aceptados {} ({} ejecuciones con 3 órdenes de hilos), rechazados {}",
            self.casos,
            self.sentencias,
            self.duracion,
            self.aceptados,
            self.ejecuciones,
            self.rechazados
        )?;
        let reglas: Vec<String> = self
            .rechazos_por_regla
            .iter()
            .map(|(r, n)| format!("{r}:{n}"))
            .collect();
        writeln!(f, "rechazos por regla: {}", reglas.join(" "))?;
        let ins: Vec<String> = self
            .rechazados_inseguros
            .iter()
            .map(|(r, n)| format!("{r}:{n}"))
            .collect();
        writeln!(
            f,
            "rechazados que el oráculo confirma inseguros: {} [{}]; rechazados con ejecución limpia (conservadurismo): {}",
            self.rechazados_inseguros.values().sum::<u64>(),
            ins.join(" "),
            self.rechazados_limpios
        )?;
        let ops: Vec<String> = self
            .ops_aceptadas
            .iter()
            .map(|(o, n)| format!("{o}:{n}"))
            .collect();
        writeln!(f, "sentencias en programas aceptados: {}", ops.join(" "))?;
        writeln!(f, "FALLOS P1: {}", self.fallos.len())?;
        for x in &self.fallos {
            writeln!(
                f,
                "--- semilla de caso {:#x}, orden de hilos {}, gen inicial {:#x}\n{}\nelecciones ({}): {:?}\nreducidas ({}): {:?}\nprograma reducido:\n{}traza:\n  {}\nestado:\n{}",
                x.semilla_caso,
                x.fallo.orden_hilos,
                x.fallo.gen_inicial,
                x.fallo.aborto,
                x.eleccion.len(),
                x.eleccion,
                x.eleccion_reducida.len(),
                x.eleccion_reducida,
                x.programa_reducido,
                x.fallo.traza.join("\n  "),
                x.fallo.estado
            )?;
        }
        Ok(())
    }
}

// ------------------------------------------------------- P3/P7: pool directo

#[derive(Default, Debug, Clone, Copy)]
pub struct InformePool {
    pub operaciones: u64,
    pub asignaciones: u64,
    pub liberaciones: u64,
    pub huecos: u64,
    pub retirados: u64,
    pub devueltas: u64,
    pub agotamientos: u64,
    pub sondeos_obsoletos: u64,
}

/// Opera directamente sobre un `Pool` con una secuencia aleatoria y
/// comprueba tras cada paso:
/// * invariantes de cabecera, bitmaps e índice por densidad;
/// * P3: ningún `(slot, gen)` se emite dos veces y ningún par muerto vuelve
///   a ser válido;
/// * P7: leer por un par muerto aborta (generación obsoleta o página devuelta).
pub fn fuzz_pool(semilla: u64, ops: u64) -> Result<InformePool, String> {
    let mut fu = Fuente::aleatoria(semilla);
    let tams = [64u32, 72, 128, 1000, 4096];
    let tam = tams[fu.eleccion(tams.len() as u32) as usize];
    let campos = (tam / 8).min(4) as usize;
    let gen_inicial = if fu.eleccion(2) == 0 {
        0
    } else {
        GEN_RETIRADO - 2 * (1 + fu.eleccion(4))
    };
    let max_sp = 1 + fu.eleccion(3);
    let mut p = Pool::nuevo(0, campos, tam, max_sp, gen_inicial).map_err(|e| e.to_string())?;
    let mut ev = Eventos::default();
    let mut vivos: Vec<(u32, u32)> = Vec::new();
    let mut muertos: Vec<(u32, u32)> = Vec::new();
    let mut emitidos: HashSet<(u32, u32)> = HashSet::new();
    let mut inf = InformePool::default();
    for paso in 0..ops {
        inf.operaciones += 1;
        match fu.eleccion(6) {
            0..=2 => match p.asignar(0, &mut ev) {
                Ok((s, g)) => {
                    if !emitidos.insert((s, g)) {
                        return Err(contexto(
                            semilla,
                            paso,
                            &p,
                            format!("P3: ({s}, {g:#x}) emitido dos veces"),
                        ));
                    }
                    if g & 1 != 1 || g >= GEN_RETIRADO {
                        return Err(contexto(
                            semilla,
                            paso,
                            &p,
                            format!("generación viva inválida {g:#x}"),
                        ));
                    }
                    p.escribir(s, g, 0, crate::rt::pool::Palabra::Int(paso as i64))
                        .map_err(|e| contexto(semilla, paso, &p, e.to_string()))?;
                    vivos.push((s, g));
                    inf.asignaciones += 1;
                }
                Err(e) if e.violacion == Violacion::AgotamientoVirtual => inf.agotamientos += 1,
                Err(e) => return Err(contexto(semilla, paso, &p, e.to_string())),
            },
            3 | 4 if !vivos.is_empty() => {
                let i = fu.eleccion(vivos.len() as u32) as usize;
                let (s, g) = vivos.swap_remove(i);
                let hueco = fu.eleccion(3) == 0;
                let r = p
                    .destruir(s, g, hueco, &mut ev)
                    .map_err(|e| contexto(semilla, paso, &p, e.to_string()))?;
                muertos.push((s, g));
                inf.liberaciones += 1;
                if hueco && r == crate::rt::pool::Destruido::Libre {
                    inf.huecos += 1;
                    if fu.eleccion(2) == 0 {
                        let g2 = p
                            .reusar_hueco(s)
                            .map_err(|e| contexto(semilla, paso, &p, e.to_string()))?;
                        if g2 != g + 2 || !emitidos.insert((s, g2)) {
                            return Err(contexto(
                                semilla,
                                paso,
                                &p,
                                format!("hueco: gen {g2:#x} tras {g:#x}"),
                            ));
                        }
                        vivos.push((s, g2));
                    } else {
                        p.liberar_hueco(s, &mut ev)
                            .map_err(|e| contexto(semilla, paso, &p, e.to_string()))?;
                    }
                }
            }
            _ => {
                // Sondeo de pares muertos: nunca válidos, nunca legibles.
                inf.sondeos_obsoletos += muertos.len().min(8) as u64;
                for (s, g) in muertos.iter().rev().take(8) {
                    if p.gen_de(*s)
                        .map_err(|e| contexto(semilla, paso, &p, e.to_string()))?
                        == *g
                    {
                        return Err(contexto(
                            semilla,
                            paso,
                            &p,
                            format!("P3: el par muerto ({s}, {g:#x}) vuelve a ser válido"),
                        ));
                    }
                    if p.leer(*s, *g, 0).is_ok() {
                        return Err(contexto(
                            semilla,
                            paso,
                            &p,
                            format!("P7: lectura por el par muerto ({s}, {g:#x})"),
                        ));
                    }
                }
            }
        }
        p.comprobar_invariantes()
            .map_err(|e| contexto(semilla, paso, &p, e))?;
    }
    inf.retirados = ev.slots_retirados;
    inf.devueltas = ev.subpaginas_devueltas;
    Ok(inf)
}

// ------------------------------------------------------- P8: efectos

/// Efectos propios posibles de una función del grafo aleatorio.
const PROPIOS: [&str; 5] = ["lee", "edita", "reestructura", "destruye", "invalida"];

fn efecto_propio(i: usize) -> EfectoPool {
    match i {
        0 => EfectoPool {
            lee_enlaces: true,
            ..Default::default()
        },
        1 => EfectoPool {
            lee_enlaces: true,
            edita_enlaces: true,
            ..Default::default()
        },
        2 => EfectoPool {
            nivel: NivelEfecto::Destruye,
            reestructura: true,
            ..Default::default()
        },
        3 => EfectoPool::nivel(NivelEfecto::Destruye),
        _ => EfectoPool {
            nivel: NivelEfecto::Destruye,
            invalida_epoca: true,
            ..Default::default()
        },
    }
}

/// P8: genera un grafo de llamadas aleatorio (con ciclos) y compara los
/// efectos del punto fijo con el cierre transitivo calculado aparte.
pub fn fuzz_efectos(semilla: u64) -> Result<usize, String> {
    let mut fu = Fuente::aleatoria(semilla);
    let mut prog = Programa::default();
    let nodo = prog.clase_nueva("Nodo", true, &[TipoCampo::Int, TipoCampo::Enlace]);
    let n = 2 + fu.eleccion(6) as usize;
    let ids: Vec<FuncId> = (0..n).map(|i| prog.declarar(&format!("f{i}"))).collect();
    let mut propios: Vec<Vec<usize>> = Vec::new();
    let mut llamadas: Vec<Vec<usize>> = Vec::new();
    for i in 0..n {
        let mut c = Constructor::nueva(&format!("f{i}"));
        let p = c.pool_param("P", nodo, PermisoPool::Edit);
        let l = c.param("l", Ty::Enlace(p));
        let mut cuerpo = Vec::new();
        let mut mios = Vec::new();
        for e in 0..PROPIOS.len() {
            if fu.eleccion(4) != 0 {
                continue;
            }
            mios.push(e);
            match e {
                0 => {
                    let nv = c.var(
                        &format!("n{e}"),
                        Ty::Prestamo(Modo::View, nodo, Ubic::Pool(p)),
                    );
                    cuerpo.push(revalidar(l, Modo::View, nv, vec![], vec![]));
                }
                1 => {
                    let nv = c.var(
                        &format!("n{e}"),
                        Ty::Prestamo(Modo::Edit, nodo, Ubic::Pool(p)),
                    );
                    cuerpo.push(revalidar(l, Modo::Edit, nv, vec![], vec![]));
                }
                2 => cuerpo.push(Stmt::Reestructurar { pool: p }),
                3 => {
                    let x = c.var("x3", Ty::Dueno(nodo, Ubic::Pool(p)));
                    cuerpo.push(crear(x, nodo, Ubic::Pool(p), vec![k(0), k(0)]));
                    cuerpo.push(destruir(x));
                }
                _ => {
                    let x = c.var("x4", Ty::Dueno(nodo, Ubic::Pool(p)));
                    cuerpo.push(crear(x, nodo, Ubic::Pool(p), vec![k(0), v(l)]));
                    cuerpo.push(destruir(x));
                }
            }
        }
        let mut sal = Vec::new();
        for (j, id) in ids.iter().enumerate() {
            if fu.eleccion(3) == 0 {
                sal.push(j);
                cuerpo.push(llamar(*id, vec![p], vec![v(l)], None));
            }
        }
        prog.definir(ids[i], c.cuerpo(cuerpo));
        propios.push(mios);
        llamadas.push(sal);
    }
    let pv =
        verificar(&prog).map_err(|ds| format!("semilla {semilla:#x}: rechazado: {}", ds[0]))?;
    // Cierre transitivo independiente (BFS por función).
    for (i, id) in ids.iter().enumerate() {
        let mut esperado = EfectoPool::default();
        let mut vistos = vec![false; n];
        let mut pila = vec![i];
        while let Some(x) = pila.pop() {
            if std::mem::replace(&mut vistos[x], true) {
                continue;
            }
            for e in &propios[x] {
                esperado.unir(efecto_propio(*e));
            }
            pila.extend(llamadas[x].iter().copied());
        }
        let obtenido = pv.efecto(*id, 0);
        if obtenido != esperado {
            return Err(format!(
                "semilla {semilla:#x}: f{i}: punto fijo {obtenido} ≠ cierre {esperado}\n{}",
                crate::pretty::programa(&prog)
            ));
        }
    }
    // Estabilidad: re-verificar el programa elaborado da los mismos efectos.
    let pv2 = verificar(&prog).map_err(|_| "re-verificación rechazada".to_string())?;
    if pv2.efectos != pv.efectos {
        return Err(format!("semilla {semilla:#x}: punto fijo no determinista"));
    }
    Ok(n)
}

fn contexto(semilla: u64, paso: u64, p: &Pool, m: String) -> String {
    format!("semilla {semilla:#x}, paso {paso}: {m}\n{}", p.resumen())
}
