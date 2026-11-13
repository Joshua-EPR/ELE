//! Pase 2: linealidad de `dueño` (R8) y de `hueco` (R9), con elaboración.
//!
//! Estado abstracto por variable lineal: `Vivo`, `Consumido` o `Quizas`
//! (consumido solo en algunos caminos). La unión en un punto de encuentro de
//! `Vivo` y `Consumido` da `Quizas`, que no puede usarse (R8) y al final de su
//! ámbito se destruye con *drop flag* (`Destruir { condicional: true }`).
//! Los dueños aún vivos al final de su ámbito reciben un `Destruir` implícito.
//! Un hueco no consumido al final de su bloque básico se libera con
//! `LiberarHueco`; usarlo en otro bloque básico viola R9.

use std::collections::{HashMap, HashSet};

use crate::diag::{Diags, Regla, Ruta, nombres_bloques};
use crate::ir::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Lin {
    Vivo,
    Consumido,
    Quizas,
}

impl Lin {
    fn unir(a: Lin, b: Lin) -> Lin {
        if a == b { a } else { Lin::Quizas }
    }
}

/// Estado de un camino; `None` = camino muerto (tras `retornar`).
type Estado = Option<HashMap<VarId, Lin>>;

fn unir(a: &Estado, b: &Estado) -> Estado {
    match (a, b) {
        (None, x) | (x, None) => x.clone(),
        (Some(x), Some(y)) => {
            let mut r = HashMap::new();
            for (k, va) in x {
                if let Some(vb) = y.get(k) {
                    r.insert(*k, Lin::unir(*va, *vb));
                }
            }
            Some(r)
        }
    }
}

/// Resultado de la elaboración: número de drop flags y destrucciones
/// implícitas insertadas.
#[derive(Default, Debug, Clone, Copy)]
pub struct Elaboracion {
    pub drop_flags: usize,
    pub destrucciones_implicitas: usize,
    pub huecos_liberados: usize,
}

pub fn elaborar(p: &mut Programa, d: &mut Diags) -> Elaboracion {
    let mut total = Elaboracion::default();
    for f in &mut p.funciones {
        let mut l = Lineal {
            f,
            d,
            emitir: true,
            ambitos: Vec::new(),
            bandera: HashSet::new(),
            el: Elaboracion::default(),
            capturas: Vec::new(),
        };
        let cuerpo = l.f.cuerpo.clone();
        let mut st: Estado = Some(HashMap::new());
        for v in l.f.params.clone() {
            if l.f.ty(v).es_lineal() {
                st.as_mut().expect("vivo").insert(v, Lin::Vivo);
            }
        }
        let params = l.f.params.clone();
        let nuevo = l.bloque(&cuerpo, &mut st, &Ruta::raiz(), "cuerpo", &params);
        let el = l.el;
        f.cuerpo = nuevo;
        total.drop_flags += el.drop_flags;
        total.destrucciones_implicitas += el.destrucciones_implicitas;
        total.huecos_liberados += el.huecos_liberados;
    }
    total
}

struct Lineal<'a> {
    f: &'a Funcion,
    d: &'a mut Diags,
    /// En las iteraciones de punto fijo no se emiten diagnósticos ni código.
    emitir: bool,
    /// Variables lineales definidas en cada ámbito abierto.
    ambitos: Vec<Vec<VarId>>,
    /// Variables que requieren drop flag en algún punto.
    bandera: HashSet<VarId>,
    el: Elaboracion,
    /// Dueños capturados por un cuerpo de transferencia (se destruyen al final
    /// del cuerpo si siguen vivos).
    capturas: Vec<Vec<VarId>>,
}

impl Lineal<'_> {
    fn err(&mut self, r: Regla, ruta: &Ruta, m: String) {
        if self.emitir {
            self.d.emitir(r, &self.f.nombre, &ruta.texto(), m);
        }
    }

    fn n(&self, v: VarId) -> String {
        format!("`{}`", self.f.nombre_var(v))
    }

    fn lineal(&self, v: VarId) -> bool {
        self.f.ty(v).es_lineal()
    }

    fn es_hueco(&self, v: VarId) -> bool {
        matches!(self.f.ty(v), Ty::Hueco(_))
    }

    fn usar(&mut self, st: &mut Estado, v: VarId, consume: bool, ruta: &Ruta) {
        if !self.lineal(v) {
            return;
        }
        let Some(m) = st.as_mut() else { return };
        let estado = m.get(&v).copied();
        let (regla, que) = if self.es_hueco(v) {
            (Regla::R9, "el hueco")
        } else {
            (Regla::R8, "el dueño")
        };
        match estado {
            Some(Lin::Vivo) => {
                if consume {
                    m.insert(v, Lin::Consumido);
                }
            }
            Some(Lin::Consumido) => {
                let msg = format!("{que} {} ya fue consumido en este camino", self.n(v));
                self.err(regla, ruta, msg);
            }
            Some(Lin::Quizas) => {
                let msg = format!(
                    "{que} {} puede haber sido consumido en algún camino previo (consumo asimétrico o dentro de un bucle)",
                    self.n(v)
                );
                self.err(regla, ruta, msg);
            }
            None => {
                if self.es_hueco(v) {
                    let msg = format!("el hueco {} no pertenece a este bloque básico", self.n(v));
                    self.err(Regla::R9, ruta, msg);
                }
            }
        }
    }

    fn definir(&mut self, st: &mut Estado, v: VarId) {
        if !self.lineal(v) {
            return;
        }
        if let Some(m) = st.as_mut() {
            m.insert(v, Lin::Vivo);
        }
        if let Some(a) = self.ambitos.last_mut()
            && !a.contains(&v)
        {
            a.push(v);
        }
    }

    /// Libera los huecos vivos antes de una frontera de bloque básico.
    fn cerrar_bloque_basico(&mut self, st: &mut Estado, out: &mut Vec<Stmt>) {
        let Some(m) = st.as_mut() else { return };
        let mut vivos: Vec<VarId> = m
            .iter()
            .filter(|(v, l)| matches!(self.f.ty(**v), Ty::Hueco(_)) && **l == Lin::Vivo)
            .map(|(v, _)| *v)
            .collect();
        vivos.sort();
        for h in vivos {
            m.insert(h, Lin::Consumido);
            out.push(Stmt::LiberarHueco { hueco: h });
            if self.emitir {
                self.el.huecos_liberados += 1;
            }
        }
        // Un hueco no puede verse desde otro bloque básico.
        m.retain(|v, _| !matches!(self.f.ty(*v), Ty::Hueco(_)));
    }

    /// Destrucciones al cerrar los ámbitos `desde..` (para el final de un
    /// bloque, `desde` es el último; para `retornar`, todos).
    fn destruir_ambitos(
        &mut self,
        st: &mut Estado,
        desde: usize,
        out: &mut Vec<Stmt>,
        ruta: &Ruta,
    ) {
        let Some(m) = st.as_mut() else { return };
        let mut vars: Vec<VarId> = Vec::new();
        for a in self.ambitos[desde..].iter().rev() {
            for v in a.iter().rev() {
                vars.push(*v);
            }
        }
        for v in vars {
            if matches!(self.f.ty(v), Ty::Hueco(_)) {
                continue;
            }
            match m.get(&v).copied() {
                Some(Lin::Vivo) => {
                    out.push(Stmt::Destruir {
                        src: v,
                        hueco: None,
                        implicito: true,
                        condicional: false,
                    });
                    m.insert(v, Lin::Consumido);
                    if self.emitir {
                        self.el.destrucciones_implicitas += 1;
                    }
                }
                Some(Lin::Quizas) => {
                    out.push(Stmt::Destruir {
                        src: v,
                        hueco: None,
                        implicito: true,
                        condicional: true,
                    });
                    m.insert(v, Lin::Consumido);
                    if self.emitir && self.bandera.insert(v) {
                        self.el.drop_flags += 1;
                    }
                }
                _ => {}
            }
        }
        let _ = ruta;
    }

    fn bloque(
        &mut self,
        b: &[Stmt],
        st: &mut Estado,
        padre: &Ruta,
        nombre: &str,
        previas: &[VarId],
    ) -> Bloque {
        self.ambitos.push(Vec::new());
        for v in previas {
            self.definir(st, *v);
        }
        let mut out = Vec::new();
        for (i, s) in b.iter().enumerate() {
            let ruta = padre.hijo(nombre, i);
            if s.es_compuesta() {
                self.cerrar_bloque_basico(st, &mut out);
            }
            self.stmt(s, st, &ruta, &mut out);
        }
        self.cerrar_bloque_basico(st, &mut out);
        let nivel = self.ambitos.len() - 1;
        self.destruir_ambitos(st, nivel, &mut out, padre);
        let cerradas = self.ambitos.pop().unwrap_or_default();
        if let Some(m) = st.as_mut() {
            for v in cerradas {
                m.remove(&v);
            }
        }
        out
    }

    fn ops(&mut self, st: &mut Estado, os: &[Operando], ruta: &Ruta) {
        for o in os {
            if let Operando::Var(v) = o {
                self.usar(st, *v, true, ruta);
            }
        }
    }

    fn stmt(&mut self, s: &Stmt, st: &mut Estado, ruta: &Ruta, out: &mut Vec<Stmt>) {
        if st.is_none() {
            // Código inalcanzable tras `retornar`: se conserva sin analizar.
            out.push(s.clone());
            return;
        }
        let nb = nombres_bloques(s);
        match s {
            Stmt::Mover { dst, src } => {
                self.usar(st, *src, true, ruta);
                self.definir(st, *dst);
                out.push(s.clone());
            }
            Stmt::Destruir { src, hueco, .. } => {
                self.usar(st, *src, true, ruta);
                if let Some(h) = hueco {
                    self.definir(st, *h);
                }
                out.push(s.clone());
            }
            Stmt::ReusarHueco {
                dst, hueco, campos, ..
            } => {
                self.usar(st, *hueco, true, ruta);
                self.ops(st, campos, ruta);
                self.definir(st, *dst);
                out.push(s.clone());
            }
            Stmt::LiberarHueco { hueco } => {
                self.usar(st, *hueco, true, ruta);
                out.push(s.clone());
            }
            Stmt::Llamar { args, dst, .. } => {
                // Los dueños pasados por valor se consumen.
                self.ops(st, args, ruta);
                if let Some(dv) = dst {
                    self.definir(st, *dv);
                }
                out.push(s.clone());
            }
            Stmt::Retornar { valor } => {
                if let Some(o) = valor {
                    self.ops(st, std::slice::from_ref(o), ruta);
                }
                self.cerrar_bloque_basico(st, out);
                self.destruir_ambitos(st, 0, out, ruta);
                out.push(s.clone());
                *st = None;
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
                let mut a = st.clone();
                let c2 = self.bloque(cuerpo, st, ruta, &nb[0], &[*ligado]);
                let a2 = self.bloque(ausente, &mut a, ruta, &nb[1], &[]);
                *st = unir(st, &a);
                out.push(Stmt::Revalidar {
                    enlace: *enlace,
                    modo: *modo,
                    ligado: *ligado,
                    cuerpo: c2,
                    ausente: a2,
                    diferir: *diferir,
                    nivel: *nivel,
                });
            }
            Stmt::RevalidarLote {
                enlaces,
                modo,
                ligados,
                cuerpo,
                ausente,
                niveles,
            } => {
                let mut a = st.clone();
                let c2 = self.bloque(cuerpo, st, ruta, &nb[0], ligados);
                let a2 = self.bloque(ausente, &mut a, ruta, &nb[1], &[]);
                *st = unir(st, &a);
                out.push(Stmt::RevalidarLote {
                    enlaces: enlaces.clone(),
                    modo: *modo,
                    ligados: ligados.clone(),
                    cuerpo: c2,
                    ausente: a2,
                    niveles: niveles.clone(),
                });
            }
            Stmt::SiSellado {
                sello,
                cuerpo,
                sino,
            } => {
                let mut a = st.clone();
                let c2 = self.bloque(cuerpo, st, ruta, &nb[0], &[]);
                let a2 = self.bloque(sino, &mut a, ruta, &nb[1], &[]);
                *st = unir(st, &a);
                out.push(Stmt::SiSellado {
                    sello: *sello,
                    cuerpo: c2,
                    sino: a2,
                });
            }
            Stmt::Si {
                cond,
                entonces,
                sino,
            } => {
                let mut a = st.clone();
                let c2 = self.bloque(entonces, st, ruta, &nb[0], &[]);
                let a2 = self.bloque(sino, &mut a, ruta, &nb[1], &[]);
                *st = unir(st, &a);
                out.push(Stmt::Si {
                    cond: *cond,
                    entonces: c2,
                    sino: a2,
                });
            }
            Stmt::Congelar { pool, cuerpo } => {
                let c2 = self.bloque(cuerpo, st, ruta, &nb[0], &[]);
                out.push(Stmt::Congelar {
                    pool: *pool,
                    cuerpo: c2,
                });
            }
            Stmt::Repetir {
                veces,
                indice,
                cuerpo,
            } => {
                // Punto fijo: entrada ⊔ salida del cuerpo.
                let entrada = st.clone();
                let mut cabeza = entrada.clone();
                let emitir = self.emitir;
                self.emitir = false;
                for _ in 0..64 {
                    let mut x = cabeza.clone();
                    self.bloque(cuerpo, &mut x, ruta, &nb[0], &[*indice]);
                    let nueva = unir(&entrada, &x);
                    if nueva == cabeza {
                        break;
                    }
                    cabeza = nueva;
                }
                self.emitir = emitir;
                let mut x = cabeza.clone();
                let c2 = self.bloque(cuerpo, &mut x, ruta, &nb[0], &[*indice]);
                *st = unir(&cabeza, &x);
                out.push(Stmt::Repetir {
                    veces: *veces,
                    indice: *indice,
                    cuerpo: c2,
                });
            }
            Stmt::Paralelo { hilos } => {
                // Los hilos solo toman prestados los dueños externos (C4 lo
                // comprueba); cada hilo es un ámbito propio.
                let mut nuevos = Vec::new();
                for (i, h) in hilos.iter().enumerate() {
                    let mut x = st.clone();
                    nuevos.push(self.bloque(h, &mut x, ruta, &nb[i], &[]));
                    self.no_consume(st, &x, ruta, Regla::C4, "un hilo de `paralelo`");
                }
                out.push(Stmt::Paralelo { hilos: nuevos });
            }
            Stmt::Dividir {
                pool,
                partes,
                indice,
                cuerpo,
            } => {
                let mut x = st.clone();
                let c2 = self.bloque(cuerpo, &mut x, ruta, &nb[0], &[*indice]);
                self.no_consume(st, &x, ruta, Regla::C5, "un trabajador de `dividir`");
                out.push(Stmt::Dividir {
                    pool: *pool,
                    partes: *partes,
                    indice: *indice,
                    cuerpo: c2,
                });
            }
            Stmt::TransferirPool { pool, cuerpo } => {
                // Los dueños vivos de P se mueven con el pool al hilo destino.
                let movidos: Vec<VarId> = st
                    .as_ref()
                    .map(|m| {
                        let mut v: Vec<VarId> = m
                            .iter()
                            .filter(|(v, l)| {
                                **l != Lin::Consumido
                                    && matches!(self.f.ty(**v), Ty::Dueno(_, Ubic::Pool(q)) if q == pool)
                            })
                            .map(|(v, _)| *v)
                            .collect();
                        v.sort();
                        v
                    })
                    .unwrap_or_default();
                for v in &movidos {
                    if st.as_ref().and_then(|m| m.get(v)) == Some(&Lin::Quizas) {
                        let msg = format!(
                            "el dueño {} puede estar consumido al transferir su pool: no hay dueño único que mover",
                            self.n(*v)
                        );
                        self.err(Regla::R8, ruta, msg);
                    }
                }
                let mut x = st.clone();
                self.capturas.push(movidos.clone());
                // Dentro del cuerpo, los dueños capturados pertenecen a su
                // ámbito: se destruyen al final si siguen vivos.
                let c2 = self.bloque(cuerpo, &mut x, ruta, &nb[0], &movidos);
                self.capturas.pop();
                if let Some(m) = st.as_mut() {
                    for v in &movidos {
                        m.insert(*v, Lin::Consumido);
                    }
                }
                self.no_consume(
                    st,
                    &x,
                    ruta,
                    Regla::C2,
                    "el hilo destino de `transferir_pool`",
                );
                out.push(Stmt::TransferirPool {
                    pool: *pool,
                    cuerpo: c2,
                });
            }
            _ => {
                for v in s.usos() {
                    let consume = matches!(s, Stmt::Mover { .. });
                    self.usar(st, v, consume, ruta);
                }
                for v in s.defs() {
                    self.definir(st, v);
                }
                out.push(s.clone());
            }
        }
    }

    /// Un cuerpo concurrente no puede consumir dueños externos (solo
    /// prestarlos), salvo los movidos explícitamente por la transferencia.
    fn no_consume(&mut self, antes: &Estado, despues: &Estado, ruta: &Ruta, r: Regla, que: &str) {
        let (Some(a), Some(b)) = (antes, despues) else {
            return;
        };
        let mut malos: Vec<VarId> = a
            .iter()
            .filter(|(v, la)| **la == Lin::Vivo && b.get(v).is_some_and(|lb| *lb != Lin::Vivo))
            .map(|(v, _)| *v)
            .collect();
        malos.sort();
        for v in malos {
            let msg = format!(
                "{que} consume el dueño externo {}: los hilos solo toman prestados los dueños de fuera",
                self.n(v)
            );
            self.err(r, ruta, msg);
        }
    }
}
