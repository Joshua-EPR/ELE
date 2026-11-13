//! Pase 1: tipos, ámbitos y permisos (R1), enlazabilidad (R2), acceso por
//! enlace (R3), vida de enlaces respecto a su pool (R4) y escape de préstamos
//! (R5). Los demás pases suponen un programa que supera este.

use std::collections::HashSet;

use crate::diag::{Diags, Regla, Ruta, nombres_bloques};
use crate::ir::*;

pub fn verificar(p: &Programa, d: &mut Diags) {
    for (i, c) in p.clases.iter().enumerate() {
        if c.enlazable && c.tam_slot() > TAM_SLOT_MAX {
            d.emitir(
                Regla::R2,
                "<programa>",
                &format!("clase[{i}]"),
                format!(
                    "la clase `{}` ocupa {} bytes y un slot de pool no puede superar {TAM_SLOT_MAX}",
                    c.nombre,
                    c.tam_slot()
                ),
            );
        }
        if c.tiene_enlaces() && !c.enlazable {
            d.emitir(
                Regla::R2,
                "<programa>",
                &format!("clase[{i}]"),
                format!(
                    "la clase `{}` tiene campos Enlace pero no es `enlazar`: los enlaces solo se almacenan dentro de su pool",
                    c.nombre
                ),
            );
        }
    }
    for f in &p.funciones {
        Tipos::new(p, f, d).funcion();
    }
}

struct Tipos<'a> {
    p: &'a Programa,
    f: &'a Funcion,
    d: &'a mut Diags,
    definidas: HashSet<VarId>,
    ambito: Vec<Vec<VarId>>,
    ligados: HashSet<VarId>,
}

/// Sustituye los pools de la firma del llamado por los del llamador.
pub fn sustituir(ty: &Ty, pools: &[PoolRef]) -> Option<Ty> {
    let m = |q: PoolRef| pools.get(q.0 as usize).copied();
    Some(match ty {
        Ty::Int => Ty::Int,
        Ty::Dueno(c, Ubic::Pila) => Ty::Dueno(*c, Ubic::Pila),
        Ty::Dueno(c, Ubic::Pool(q)) => Ty::Dueno(*c, Ubic::Pool(m(*q)?)),
        Ty::Prestamo(md, c, Ubic::Pila) => Ty::Prestamo(*md, *c, Ubic::Pila),
        Ty::Prestamo(md, c, Ubic::Pool(q)) => Ty::Prestamo(*md, *c, Ubic::Pool(m(*q)?)),
        Ty::Enlace(q) => Ty::Enlace(m(*q)?),
        Ty::Hueco(q) => Ty::Hueco(m(*q)?),
        Ty::Sello(q) => Ty::Sello(m(*q)?),
        Ty::Funcion(fi) => Ty::Funcion(fi.clone()),
    })
}

/// Firma de una función declarada, para compararla con un `Ty::Funcion`.
pub fn firma_de(f: &Funcion) -> Firma {
    Firma {
        pools: f.pools[..f.n_pool_params]
            .iter()
            .map(|d| (d.clase, d.permiso))
            .collect(),
        params: f.params.iter().map(|v| f.ty(*v).clone()).collect(),
        ret: f.ret.clone(),
        captura_mutable: false,
        opaca: false,
    }
}

impl<'a> Tipos<'a> {
    fn new(p: &'a Programa, f: &'a Funcion, d: &'a mut Diags) -> Self {
        Tipos {
            p,
            f,
            d,
            definidas: HashSet::new(),
            ambito: vec![Vec::new()],
            ligados: HashSet::new(),
        }
    }

    fn err(&mut self, r: Regla, ruta: &Ruta, m: String) {
        self.d.emitir(r, &self.f.nombre, &ruta.texto(), m);
    }

    fn n(&self, v: VarId) -> String {
        format!("`{}`", self.f.nombre_var(v))
    }

    fn np(&self, p: PoolRef) -> String {
        format!("`{}`", self.f.nombre_pool(p))
    }

    fn pool_valido(&mut self, p: PoolRef, ruta: &Ruta) -> bool {
        if (p.0 as usize) < self.f.pools.len() {
            true
        } else {
            self.err(Regla::R1, ruta, format!("pool #{} inexistente", p.0));
            false
        }
    }

    fn permiso(&self, p: PoolRef) -> PermisoPool {
        self.f.pools[p.0 as usize].permiso
    }

    fn requiere_edit(&mut self, p: PoolRef, ruta: &Ruta, que: &str, r: Regla) {
        if self.pool_valido(p, ruta) && self.permiso(p) == PermisoPool::View {
            let m = format!(
                "{que} requiere permiso edit sobre el pool {}, pero la función solo lo ve (view)",
                self.np(p)
            );
            self.err(r, ruta, m);
        }
    }

    fn ty_bien_formado(&mut self, ty: &Ty, ruta: &Ruta, que: &str) {
        match ty {
            Ty::Dueno(c, u) | Ty::Prestamo(_, c, u) => {
                if c.0 as usize >= self.p.clases.len() {
                    self.err(
                        Regla::R1,
                        ruta,
                        format!("{que}: clase #{} inexistente", c.0),
                    );
                    return;
                }
                if let Ubic::Pool(q) = u {
                    if !self.pool_valido(*q, ruta) {
                        return;
                    }
                    if self.f.pools[q.0 as usize].clase != *c {
                        let m = format!(
                            "{que}: el pool {} aloja `{}`, no `{}`",
                            self.np(*q),
                            self.p.clase(self.f.pools[q.0 as usize].clase).nombre,
                            self.p.clase(*c).nombre
                        );
                        self.err(Regla::R1, ruta, m);
                    }
                    let mutante = matches!(ty, Ty::Dueno(..) | Ty::Prestamo(Modo::Edit, ..));
                    if mutante && self.permiso(*q) == PermisoPool::View {
                        let m = format!(
                            "{que}: un dueño o edit de un objeto del pool {} requiere permiso edit sobre el pool",
                            self.np(*q)
                        );
                        self.err(Regla::R1, ruta, m);
                    }
                } else if matches!(ty, Ty::Dueno(..)) && self.p.clase(*c).tiene_enlaces() {
                    let m = format!(
                        "{que}: `{}` contiene enlaces y no puede vivir en la pila de datos",
                        self.p.clase(*c).nombre
                    );
                    self.err(Regla::R2, ruta, m);
                }
            }
            Ty::Enlace(q) | Ty::Hueco(q) | Ty::Sello(q) => {
                self.pool_valido(*q, ruta);
            }
            Ty::Int | Ty::Funcion(_) => {}
        }
    }

    fn funcion(mut self) {
        let raiz = Ruta::raiz();
        for (i, pd) in self.f.pools.iter().enumerate() {
            let c = pd.clase;
            if c.0 as usize >= self.p.clases.len() {
                self.err(
                    Regla::R1,
                    &raiz,
                    format!("pool `{}`: clase inexistente", pd.nombre),
                );
                continue;
            }
            if !self.p.clase(c).enlazable {
                let m = format!(
                    "el pool `{}` aloja `{}`, que no está marcada `enlazar`: los tipos no enlazables viven en la pila de datos",
                    pd.nombre,
                    self.p.clase(c).nombre
                );
                self.err(Regla::R2, &raiz, m);
            }
            let es_param = i < self.f.n_pool_params;
            if es_param == (pd.permiso == PermisoPool::Dueno) {
                let m = format!(
                    "pool `{}`: los parámetros pool son view/edit y los pools locales son dueño",
                    pd.nombre
                );
                self.err(Regla::R1, &raiz, m);
            }
        }
        for v in &self.f.params {
            let ty = self.f.ty(*v).clone();
            self.ty_bien_formado(&ty, &raiz, &format!("parámetro {}", self.n(*v)));
            if matches!(ty, Ty::Hueco(_)) {
                self.err(
                    Regla::R9,
                    &raiz,
                    format!(
                        "el parámetro {} es un hueco: los huecos no cruzan llamadas",
                        self.n(*v)
                    ),
                );
            }
            if let Some(q) = ty.pool()
                && !self.f.es_pool_param(q)
            {
                self.err(
                    Regla::R4,
                    &raiz,
                    format!("el parámetro {} está atado a un pool local", self.n(*v)),
                );
            }
            if !self.definidas.insert(*v) {
                self.err(
                    Regla::R1,
                    &raiz,
                    format!("parámetro {} repetido", self.n(*v)),
                );
            }
            self.ambito[0].push(*v);
        }
        if let Some(rt) = self.f.ret.clone() {
            self.ty_bien_formado(&rt, &raiz, "tipo de retorno");
            match &rt {
                Ty::Prestamo(..) => self.err(
                    Regla::R5,
                    &raiz,
                    "una función no puede devolver un préstamo: escaparía de su raíz".into(),
                ),
                Ty::Hueco(_) => self.err(
                    Regla::R9,
                    &raiz,
                    "una función no puede devolver un hueco".into(),
                ),
                _ => {}
            }
            if let Some(q) = rt.pool()
                && !self.f.es_pool_param(q)
            {
                let m = format!(
                    "el retorno está atado al pool local {}, que muere al salir de la función",
                    self.np(q)
                );
                self.err(Regla::R4, &raiz, m);
            }
        }
        let cuerpo = &self.f.cuerpo;
        self.bloque(cuerpo, &raiz, "cuerpo", &[]);
    }

    fn en_ambito(&self, v: VarId) -> bool {
        self.ambito.iter().any(|a| a.contains(&v))
    }

    fn usar(&mut self, v: VarId, ruta: &Ruta) -> Option<Ty> {
        if v.0 as usize >= self.f.vars.len() {
            self.err(Regla::R1, ruta, format!("variable #{} inexistente", v.0));
            return None;
        }
        if !self.en_ambito(v) {
            let ty = self.f.ty(v).clone();
            if self.ligados.contains(&v) {
                let m = format!(
                    "{} solo existe dentro del cuerpo de su `revalidar`: fuera de él el objeto debe revalidarse",
                    self.n(v)
                );
                self.err(Regla::R3, ruta, m);
            } else if matches!(ty, Ty::Prestamo(..)) {
                self.err(
                    Regla::R5,
                    ruta,
                    format!(
                        "el préstamo {} se usa fuera del ámbito donde vive",
                        self.n(v)
                    ),
                );
            } else if self.definidas.contains(&v) {
                self.err(
                    Regla::R1,
                    ruta,
                    format!("{} se usa fuera de su ámbito", self.n(v)),
                );
            } else {
                self.err(
                    Regla::R1,
                    ruta,
                    format!("{} se usa antes de definirse", self.n(v)),
                );
            }
            return None;
        }
        Some(self.f.ty(v).clone())
    }

    fn definir(&mut self, v: VarId, ruta: &Ruta) -> Option<Ty> {
        if v.0 as usize >= self.f.vars.len() {
            self.err(Regla::R1, ruta, format!("variable #{} inexistente", v.0));
            return None;
        }
        if !self.definidas.insert(v) {
            self.err(
                Regla::R1,
                ruta,
                format!("{} se define dos veces", self.n(v)),
            );
        }
        let ty = self.f.ty(v).clone();
        self.ty_bien_formado(&ty, ruta, &format!("variable {}", self.n(v)));
        self.ambito.last_mut().expect("ámbito").push(v);
        Some(ty)
    }

    fn ty_op(&mut self, o: &Operando, ruta: &Ruta) -> Option<Ty> {
        match o {
            Operando::Const(_) => Some(Ty::Int),
            Operando::Var(v) => self.usar(*v, ruta),
        }
    }

    fn espera(&mut self, got: &Ty, want: &Ty, ruta: &Ruta, que: &str) {
        if got != want {
            self.err(
                Regla::R1,
                ruta,
                format!("{que}: se esperaba {want:?}, se obtuvo {got:?}"),
            );
        }
    }

    /// Valor que se almacena en el campo `i` de un objeto de la clase `c`
    /// ubicado en `u`.
    fn campo(&mut self, c: ClaseId, u: Ubic, i: usize, o: &Operando, ruta: &Ruta) {
        let tc = self.p.clase(c).campos[i];
        if tc == TipoCampo::Enlace && *o == Operando::Const(0) {
            // Enlace nulo: `slot 0, gen 0`, generación par que nunca está viva.
            return;
        }
        let Some(t) = self.ty_op(o, ruta) else { return };
        match (tc, &t) {
            (TipoCampo::Int, Ty::Int) => {}
            (_, Ty::Prestamo(..)) => self.err(
                Regla::R5,
                ruta,
                format!(
                    "campo {i}: un préstamo no puede almacenarse en un objeto que vive más que él"
                ),
            ),
            (TipoCampo::Enlace, Ty::Enlace(q)) => match u {
                Ubic::Pool(p) if p == *q => {}
                Ubic::Pool(p) => {
                    let m = format!(
                        "campo {i}: un enlace a {} no puede guardarse en un objeto de {}: sobreviviría a su pool",
                        self.np(*q),
                        self.np(p)
                    );
                    self.err(Regla::R4, ruta, m)
                }
                Ubic::Pila => self.err(
                    Regla::R2,
                    ruta,
                    format!("campo {i}: objeto de pila con enlace"),
                ),
            },
            _ => self.err(
                Regla::R1,
                ruta,
                format!("campo {i}: tipo {t:?} incompatible con {tc:?}"),
            ),
        }
    }

    fn campos(&mut self, c: ClaseId, u: Ubic, cs: &[Operando], ruta: &Ruta) {
        let n = self.p.clase(c).campos.len();
        if cs.len() != n {
            let m = format!(
                "`{}` tiene {n} campos y se inicializan {}",
                self.p.clase(c).nombre,
                cs.len()
            );
            self.err(Regla::R1, ruta, m);
            return;
        }
        for (i, o) in cs.iter().enumerate() {
            self.campo(c, u, i, o, ruta);
        }
    }

    fn objeto(&mut self, obj: VarId, ruta: &Ruta) -> Option<(Option<Modo>, ClaseId, Ubic)> {
        match self.usar(obj, ruta)? {
            Ty::Dueno(c, u) => Some((None, c, u)),
            Ty::Prestamo(m, c, u) => Some((Some(m), c, u)),
            Ty::Enlace(_) => {
                let m = format!(
                    "{} es un enlace: debe revalidarse (`revalidar`) antes de acceder al objeto",
                    self.n(obj)
                );
                self.err(Regla::R3, ruta, m);
                None
            }
            t => {
                self.err(
                    Regla::R1,
                    ruta,
                    format!("{} ({t:?}) no es un objeto", self.n(obj)),
                );
                None
            }
        }
    }

    fn bloque(&mut self, b: &[Stmt], padre: &Ruta, nombre: &str, previas: &[VarId]) {
        self.ambito.push(Vec::new());
        for v in previas {
            self.definir(*v, padre);
        }
        for (i, s) in b.iter().enumerate() {
            let ruta = padre.hijo(nombre, i);
            self.stmt(s, &ruta);
        }
        self.ambito.pop();
    }

    fn stmt(&mut self, s: &Stmt, ruta: &Ruta) {
        let nb = nombres_bloques(s);
        match s {
            Stmt::Const { dst, .. } => {
                if let Some(t) = self.definir(*dst, ruta) {
                    self.espera(&t, &Ty::Int, ruta, "const");
                }
            }
            Stmt::Copiar { dst, src } => {
                let ts = self.usar(*src, ruta);
                let td = self.definir(*dst, ruta);
                if let (Some(ts), Some(td)) = (ts, td) {
                    self.espera(&td, &ts, ruta, "copiar");
                    match ts {
                        Ty::Prestamo(Modo::Edit, ..) => self.err(
                            Regla::R7,
                            ruta,
                            format!("{} es edit y no es copiable", self.n(*src)),
                        ),
                        Ty::Dueno(..) => self.err(
                            Regla::R8,
                            ruta,
                            format!("{} es lineal: use `mover`", self.n(*src)),
                        ),
                        Ty::Hueco(_) => self.err(Regla::R9, ruta, "un hueco no es copiable".into()),
                        _ => {}
                    }
                }
            }
            Stmt::Mover { dst, src } => {
                let ts = self.usar(*src, ruta);
                let td = self.definir(*dst, ruta);
                if let (Some(ts), Some(td)) = (ts, td) {
                    self.espera(&td, &ts, ruta, "mover");
                    if !matches!(ts, Ty::Dueno(..)) {
                        self.err(
                            Regla::R1,
                            ruta,
                            format!("solo se mueven dueños; {} es {ts:?}", self.n(*src)),
                        );
                    }
                }
            }
            Stmt::Aritmetica { dst, a, b, .. } => {
                for o in [a, b] {
                    if let Some(t) = self.ty_op(o, ruta) {
                        self.espera(&t, &Ty::Int, ruta, "operando aritmético");
                    }
                }
                if let Some(t) = self.definir(*dst, ruta) {
                    self.espera(&t, &Ty::Int, ruta, "resultado aritmético");
                }
            }
            Stmt::Crear {
                dst,
                clase,
                ubic,
                campos,
                ..
            } => {
                if clase.0 as usize >= self.p.clases.len() {
                    self.err(Regla::R1, ruta, format!("clase #{} inexistente", clase.0));
                    return;
                }
                if let Ubic::Pool(q) = ubic {
                    self.requiere_edit(*q, ruta, "crear", Regla::R1);
                    if !self.p.clase(*clase).enlazable {
                        let m = format!(
                            "`{}` no es `enlazar` y no puede alojarse en el pool {}",
                            self.p.clase(*clase).nombre,
                            self.np(*q)
                        );
                        self.err(Regla::R2, ruta, m);
                    }
                }
                self.campos(*clase, *ubic, campos, ruta);
                if let Some(t) = self.definir(*dst, ruta) {
                    self.espera(&t, &Ty::Dueno(*clase, *ubic), ruta, "crear");
                }
            }
            Stmt::Destruir { src, hueco, .. } => {
                let Some(t) = self.usar(*src, ruta) else {
                    return;
                };
                let Ty::Dueno(_, u) = t else {
                    self.err(
                        Regla::R1,
                        ruta,
                        format!("destruir requiere un dueño; {} es {t:?}", self.n(*src)),
                    );
                    return;
                };
                if let Ubic::Pool(q) = u {
                    self.requiere_edit(q, ruta, "destruir", Regla::R1);
                }
                if let Some(h) = hueco
                    && let Some(th) = self.definir(*h, ruta)
                {
                    match (u, th) {
                        (Ubic::Pool(q), Ty::Hueco(qh)) if q == qh => {}
                        (Ubic::Pool(_), Ty::Hueco(_)) => {
                            self.err(Regla::R9, ruta, "el hueco pertenece a otro pool".into())
                        }
                        (Ubic::Pila, _) => self.err(
                            Regla::R9,
                            ruta,
                            "solo los objetos de pool producen huecos".into(),
                        ),
                        (_, th) => self.err(
                            Regla::R1,
                            ruta,
                            format!("{} ({th:?}) no es un hueco", self.n(*h)),
                        ),
                    }
                }
            }
            Stmt::ReusarHueco {
                dst, hueco, campos, ..
            } => {
                let th = self.usar(*hueco, ruta);
                let td = self.definir(*dst, ruta);
                let (Some(th), Some(td)) = (th, td) else {
                    return;
                };
                let Ty::Hueco(q) = th else {
                    self.err(
                        Regla::R9,
                        ruta,
                        format!("{} no es un hueco", self.n(*hueco)),
                    );
                    return;
                };
                match td {
                    Ty::Dueno(c, Ubic::Pool(qd)) if qd == q => {
                        self.campos(c, Ubic::Pool(q), campos, ruta)
                    }
                    Ty::Dueno(..) => self.err(
                        Regla::R9,
                        ruta,
                        format!(
                            "el hueco de {} solo puede reutilizarse en ese pool",
                            self.np(q)
                        ),
                    ),
                    t => self.err(
                        Regla::R1,
                        ruta,
                        format!("reusar_hueco define un dueño, no {t:?}"),
                    ),
                }
            }
            Stmt::LiberarHueco { hueco } => {
                if let Some(t) = self.usar(*hueco, ruta)
                    && !matches!(t, Ty::Hueco(_))
                {
                    self.err(
                        Regla::R9,
                        ruta,
                        format!("{} no es un hueco", self.n(*hueco)),
                    );
                }
            }
            Stmt::Prestar { dst, src, modo } => {
                let o = self.objeto(*src, ruta);
                let td = self.definir(*dst, ruta);
                let (Some((m, c, u)), Some(td)) = (o, td) else {
                    return;
                };
                if m == Some(Modo::View) && *modo == Modo::Edit {
                    self.err(
                        Regla::R7,
                        ruta,
                        format!("no se obtiene edit a partir del view {}", self.n(*src)),
                    );
                }
                self.espera(&td, &Ty::Prestamo(*modo, c, u), ruta, "prestar");
            }
            Stmt::Leer { dst, obj, campo } => {
                let o = self.objeto(*obj, ruta);
                let td = self.definir(*dst, ruta);
                let (Some((_, c, u)), Some(td)) = (o, td) else {
                    return;
                };
                match self.p.clase(c).campos.get(*campo as usize) {
                    None => self.err(Regla::R1, ruta, format!("campo {campo} inexistente")),
                    Some(TipoCampo::Int) => self.espera(&td, &Ty::Int, ruta, "leer"),
                    Some(TipoCampo::Enlace) => match u {
                        Ubic::Pool(q) => self.espera(&td, &Ty::Enlace(q), ruta, "leer"),
                        Ubic::Pila => self.err(Regla::R2, ruta, "objeto de pila con enlace".into()),
                    },
                }
            }
            Stmt::Escribir {
                obj, campo, valor, ..
            } => {
                let Some((m, c, u)) = self.objeto(*obj, ruta) else {
                    return;
                };
                if m == Some(Modo::View) {
                    self.err(
                        Regla::R7,
                        ruta,
                        format!("{} es view: no permite escribir", self.n(*obj)),
                    );
                }
                if (*campo as usize) >= self.p.clase(c).campos.len() {
                    self.err(Regla::R1, ruta, format!("campo {campo} inexistente"));
                    return;
                }
                self.campo(c, u, *campo as usize, valor, ruta);
            }
            Stmt::Enlazar { dst, obj } => {
                let o = self.objeto(*obj, ruta);
                let td = self.definir(*dst, ruta);
                let (Some((_, _, u)), Some(td)) = (o, td) else {
                    return;
                };
                match u {
                    Ubic::Pool(q) => self.espera(&td, &Ty::Enlace(q), ruta, "enlazar"),
                    Ubic::Pila => self.err(
                        Regla::R2,
                        ruta,
                        format!(
                            "{} vive en la pila de datos: solo se enlazan objetos de pool",
                            self.n(*obj)
                        ),
                    ),
                }
            }
            Stmt::Revalidar {
                enlace,
                modo,
                ligado,
                cuerpo,
                ausente,
                ..
            } => {
                if let Some(t) = self.usar(*enlace, ruta) {
                    match t {
                        Ty::Enlace(q) => {
                            if *modo == Modo::Edit {
                                self.requiere_edit(q, ruta, "revalidar en modo edit", Regla::R1);
                            }
                            let c = self.f.pools[q.0 as usize].clase;
                            let tl = self.f.ty(*ligado).clone();
                            self.espera(
                                &tl,
                                &Ty::Prestamo(*modo, c, Ubic::Pool(q)),
                                ruta,
                                "ligado",
                            );
                        }
                        t => self.err(
                            Regla::R1,
                            ruta,
                            format!("revalidar requiere un enlace; {} es {t:?}", self.n(*enlace)),
                        ),
                    }
                }
                self.ligados.insert(*ligado);
                self.bloque(cuerpo, ruta, &nb[0], &[*ligado]);
                self.bloque(ausente, ruta, &nb[1], &[]);
            }
            Stmt::RevalidarLote {
                enlaces,
                modo,
                ligados,
                cuerpo,
                ausente,
                niveles,
            } => {
                if enlaces.is_empty()
                    || enlaces.len() != ligados.len()
                    || niveles.len() != enlaces.len()
                {
                    self.err(
                        Regla::R1,
                        ruta,
                        "revalidar_lote requiere tantos ligados como enlaces (≥ 1)".into(),
                    );
                    return;
                }
                for (e, l) in enlaces.iter().zip(ligados) {
                    match self.usar(*e, ruta) {
                        Some(Ty::Enlace(q)) => {
                            if *modo == Modo::Edit {
                                self.requiere_edit(
                                    q,
                                    ruta,
                                    "revalidar_lote en modo edit",
                                    Regla::R1,
                                );
                            }
                            let c = self.f.pools[q.0 as usize].clase;
                            let tl = self.f.ty(*l).clone();
                            self.espera(
                                &tl,
                                &Ty::Prestamo(*modo, c, Ubic::Pool(q)),
                                ruta,
                                "ligado de lote",
                            );
                        }
                        Some(t) => self.err(
                            Regla::R1,
                            ruta,
                            format!("{} ({t:?}) no es un enlace", self.n(*e)),
                        ),
                        None => {}
                    }
                    self.ligados.insert(*l);
                }
                self.bloque(cuerpo, ruta, &nb[0], ligados);
                self.bloque(ausente, ruta, &nb[1], &[]);
            }
            Stmt::Sellar { dst, pool } => {
                if self.pool_valido(*pool, ruta)
                    && let Some(t) = self.definir(*dst, ruta)
                {
                    self.espera(&t, &Ty::Sello(*pool), ruta, "sellar");
                }
            }
            Stmt::SiSellado {
                sello,
                cuerpo,
                sino,
            } => {
                if let Some(t) = self.usar(*sello, ruta)
                    && !matches!(t, Ty::Sello(_))
                {
                    self.err(
                        Regla::R1,
                        ruta,
                        format!("{} no es un sello", self.n(*sello)),
                    );
                }
                self.bloque(cuerpo, ruta, &nb[0], &[]);
                self.bloque(sino, ruta, &nb[1], &[]);
            }
            Stmt::Reestructurar { pool } => {
                self.requiere_edit(*pool, ruta, "reestructurar", Regla::R1)
            }
            Stmt::Congelar { pool, cuerpo } => {
                self.pool_valido(*pool, ruta);
                self.bloque(cuerpo, ruta, &nb[0], &[]);
            }
            Stmt::Paralelo { hilos } => {
                if hilos.is_empty() {
                    self.err(Regla::R1, ruta, "paralelo sin hilos".into());
                }
                for (i, h) in hilos.iter().enumerate() {
                    self.bloque(h, ruta, &nb[i], &[]);
                }
            }
            Stmt::Dividir {
                pool,
                partes,
                indice,
                cuerpo,
            } => {
                if *partes == 0 || *partes > MAX_PARTICIONES_NEXO {
                    self.err(
                        Regla::C6,
                        ruta,
                        format!(
                            "dividir requiere entre 1 y {MAX_PARTICIONES_NEXO} particiones, recibidas {partes}"
                        ),
                    );
                }
                self.requiere_edit(*pool, ruta, "dividir", Regla::C6);
                if self.f.ty(*indice) != &Ty::Int {
                    self.err(Regla::R1, ruta, "el índice de dividir es Int".into());
                }
                self.bloque(cuerpo, ruta, &nb[0], &[*indice]);
            }
            Stmt::TransferirPool { pool, cuerpo } => {
                if self.pool_valido(*pool, ruta) && self.permiso(*pool) != PermisoPool::Dueno {
                    let m = format!(
                        "solo un pool local (dueño) puede transferirse; {} es un parámetro",
                        self.np(*pool)
                    );
                    self.err(Regla::C2, ruta, m);
                }
                self.bloque(cuerpo, ruta, &nb[0], &[]);
            }
            Stmt::RefFuncion { dst, func } => {
                let Some(t) = self.definir(*dst, ruta) else {
                    return;
                };
                let Some(callee) = self.p.funciones.get(func.0 as usize) else {
                    self.err(Regla::R1, ruta, format!("función #{} inexistente", func.0));
                    return;
                };
                match t {
                    Ty::Funcion(fi) => {
                        let real = firma_de(callee);
                        if fi.pools != real.pools || fi.params != real.params || fi.ret != real.ret
                        {
                            let m = format!(
                                "la firma de {} no coincide con `{}`",
                                self.n(*dst),
                                callee.nombre
                            );
                            self.err(Regla::R1, ruta, m);
                        }
                    }
                    t => self.err(
                        Regla::R1,
                        ruta,
                        format!("ref_funcion define una función, no {t:?}"),
                    ),
                }
            }
            Stmt::Llamar {
                destino,
                pools,
                args,
                dst,
            } => self.llamar(destino, pools, args, dst, ruta),
            Stmt::Si {
                cond,
                entonces,
                sino,
            } => {
                if let Some(t) = self.ty_op(cond, ruta) {
                    self.espera(&t, &Ty::Int, ruta, "condición");
                }
                self.bloque(entonces, ruta, &nb[0], &[]);
                self.bloque(sino, ruta, &nb[1], &[]);
            }
            Stmt::Repetir {
                veces,
                indice,
                cuerpo,
            } => {
                if let Some(t) = self.ty_op(veces, ruta) {
                    self.espera(&t, &Ty::Int, ruta, "repeticiones");
                }
                if self.f.ty(*indice) != &Ty::Int {
                    self.err(Regla::R1, ruta, "el índice de repetir es Int".into());
                }
                self.bloque(cuerpo, ruta, &nb[0], &[*indice]);
            }
            Stmt::Retornar { valor } => {
                let t = valor.as_ref().and_then(|o| self.ty_op(o, ruta));
                match (&self.f.ret.clone(), valor, t) {
                    (None, None, _) => {}
                    (Some(r), Some(_), Some(t)) => {
                        if matches!(t, Ty::Prestamo(..)) {
                            self.err(Regla::R5, ruta, "se devuelve un préstamo".into());
                        } else {
                            self.espera(&t, r, ruta, "retornar");
                        }
                    }
                    (Some(_), Some(_), None) => {}
                    _ => self.err(
                        Regla::R1,
                        ruta,
                        "retornar no coincide con el tipo de retorno".into(),
                    ),
                }
            }
        }
    }

    fn llamar(
        &mut self,
        destino: &Destino,
        pools: &[PoolRef],
        args: &[Operando],
        dst: &Option<VarId>,
        ruta: &Ruta,
    ) {
        let firma = match destino {
            Destino::Directa(fid) => match self.p.funciones.get(fid.0 as usize) {
                Some(callee) => firma_de(callee),
                None => {
                    self.err(Regla::R1, ruta, format!("función #{} inexistente", fid.0));
                    return;
                }
            },
            Destino::Indirecta(v) => match self.usar(*v, ruta) {
                Some(Ty::Funcion(fi)) => *fi,
                Some(t) => {
                    self.err(
                        Regla::R1,
                        ruta,
                        format!("{} ({t:?}) no es una función", self.n(*v)),
                    );
                    return;
                }
                None => return,
            },
        };
        if pools.len() != firma.pools.len() {
            let m = format!(
                "se pasan {} pools y la firma espera {}",
                pools.len(),
                firma.pools.len()
            );
            self.err(Regla::R1, ruta, m);
            return;
        }
        for (i, (q, (c, perm))) in pools.iter().zip(&firma.pools).enumerate() {
            if !self.pool_valido(*q, ruta) {
                return;
            }
            if self.f.pools[q.0 as usize].clase != *c {
                self.err(
                    Regla::R1,
                    ruta,
                    format!("pool argumento {i}: clase distinta"),
                );
            }
            if *perm != PermisoPool::View {
                self.requiere_edit(
                    *q,
                    ruta,
                    &format!("pasar el pool argumento {i} como edit"),
                    Regla::R1,
                );
                for (j, (q2, (_, p2))) in pools.iter().zip(&firma.pools).enumerate() {
                    if j != i && q2 == q {
                        let m = format!(
                            "el pool {} se pasa como edit (arg {i}) y a la vez como {:?} (arg {j}): dos caminos a los mismos objetos",
                            self.np(*q),
                            p2
                        );
                        self.err(Regla::R7, ruta, m);
                    }
                }
            }
        }
        if args.len() != firma.params.len() {
            let m = format!(
                "se pasan {} argumentos y la firma espera {}",
                args.len(),
                firma.params.len()
            );
            self.err(Regla::R1, ruta, m);
            return;
        }
        for (i, (a, pt)) in args.iter().zip(&firma.params).enumerate() {
            let Some(t) = self.ty_op(a, ruta) else {
                continue;
            };
            match sustituir(pt, pools) {
                Some(want) => self.espera(&t, &want, ruta, &format!("argumento {i}")),
                None => self.err(
                    Regla::R1,
                    ruta,
                    format!("argumento {i}: pool de la firma inexistente"),
                ),
            }
        }
        match (dst, &firma.ret) {
            (None, _) => {}
            (Some(d), Some(rt)) => {
                if let Some(t) = self.definir(*d, ruta) {
                    match sustituir(rt, pools) {
                        Some(want) => self.espera(&t, &want, ruta, "resultado"),
                        None => self.err(Regla::R1, ruta, "retorno con pool inexistente".into()),
                    }
                }
            }
            (Some(_), None) => self.err(
                Regla::R1,
                ruta,
                "la función llamada no devuelve valor".into(),
            ),
        }
    }
}
