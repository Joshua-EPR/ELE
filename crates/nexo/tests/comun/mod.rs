//! Utilidades compartidas por las pruebas de NEXO.
#![allow(dead_code)]

use nexo::Regla;
use nexo::ir::*;
use nexo::rt::{Config, Metricas, Valor, ejecutar};
use nexo::verif::{ProgramaVerificado, verificar};

/// Programa base: `Nodo` (enlazable: valor Int, siguiente Enlace) y `Dato`
/// (pila: un Int).
pub struct Fx {
    pub p: Programa,
    pub nodo: ClaseId,
    pub dato: ClaseId,
}

pub fn fx() -> Fx {
    let mut p = Programa::default();
    let nodo = p.clase_nueva("Nodo", true, &[TipoCampo::Int, TipoCampo::Enlace]);
    let dato = p.clase_nueva("Dato", false, &[TipoCampo::Int]);
    Fx { p, nodo, dato }
}

/// Verifica y devuelve el programa elaborado; falla mostrando los
/// diagnósticos si se rechaza.
pub fn ok(p: &Programa) -> ProgramaVerificado {
    match verificar(p) {
        Ok(v) => v,
        Err(ds) => {
            let t: Vec<String> = ds.iter().map(|d| d.to_string()).collect();
            panic!("programa rechazado:\n{}", t.join("\n"))
        }
    }
}

/// Reglas violadas; falla si el programa se acepta.
pub fn reglas(p: &Programa) -> Vec<Regla> {
    match verificar(p) {
        Ok(_) => panic!("se esperaba un rechazo"),
        Err(ds) => {
            for d in &ds {
                eprintln!("{d}");
            }
            ds.iter().map(|d| d.regla).collect()
        }
    }
}

pub fn rechaza(p: &Programa, r: Regla) {
    let rs = reglas(p);
    assert!(rs.contains(&r), "se esperaba {r}, se obtuvo {rs:?}");
}

pub fn correr(pv: &ProgramaVerificado, entrada: &str) -> (Option<Valor>, Metricas) {
    match ejecutar(pv, entrada, Config::default()) {
        Ok(x) => x,
        Err(a) => panic!("{a}"),
    }
}

/// Máquina sobre un programa verificado, con el oráculo de efectos activo.
pub fn maquina(pv: &ProgramaVerificado) -> nexo::rt::Maquina<'_> {
    nexo::rt::Maquina::nueva(&pv.programa, Config::default()).con_efectos(pv.efectos.clone())
}

/// Ejecuta IR sin verificar desde la función 0 y devuelve la violación.
pub fn violacion_bruta(p: &Programa) -> nexo::rt::Violacion {
    let mut m = nexo::rt::Maquina::nueva(p, Config::default());
    match m
        .llamar(FuncId(0), vec![], vec![])
        .and_then(|_| m.comprobar_fugas())
    {
        Ok(()) => panic!("se esperaba una violación del oráculo"),
        Err(a) => {
            eprintln!("{a}");
            a.violacion
        }
    }
}

/// Mensajes de diagnóstico de un programa rechazado.
pub fn mensajes(p: &Programa) -> Vec<String> {
    match verificar(p) {
        Ok(_) => panic!("se esperaba un rechazo"),
        Err(ds) => ds.iter().map(|d| d.to_string()).collect(),
    }
}

pub fn ty_nodo(f: &Fx, p: PoolRef) -> Ty {
    Ty::Dueno(f.nodo, Ubic::Pool(p))
}

pub fn view_nodo(f: &Fx, p: PoolRef) -> Ty {
    Ty::Prestamo(Modo::View, f.nodo, Ubic::Pool(p))
}

pub fn edit_nodo(f: &Fx, p: PoolRef) -> Ty {
    Ty::Prestamo(Modo::Edit, f.nodo, Ubic::Pool(p))
}
