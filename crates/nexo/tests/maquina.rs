//! Fase 2: pools Bi-Slab, máquina abstracta y oráculo.
//!
//! Las pruebas del oráculo ejecutan IR **sin verificar** (o con anotaciones
//! falsificadas) para comprobar que el runtime detecta cada violación.

mod comun;

use comun::*;
use nexo::ir::s::*;
use nexo::ir::*;
use nexo::rt::pool::{
    CABECERA, EstadoSub, Eventos, GEN_RETIRADO, MAX_SLOTS_SUPERPAGINA, Pool, SUBPAGINA,
    SUPERPAGINA, desempaquetar, empaquetar,
};
use nexo::rt::{Config, Maquina, Violacion};

// ------------------------------------------------------------ pool Bi-Slab

#[test]
fn bislab_disposicion_y_base_fija() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 2, 64, 8, 0).unwrap();
    assert_eq!(p.base % SUPERPAGINA, 0, "base alineada a 64 KiB");
    assert_eq!(p.slots_por_sub, 64);
    assert!(p.slots_por_superpagina() <= MAX_SLOTS_SUPERPAGINA);
    let base = p.base;
    let (s0, g0) = p.asignar(0, &mut ev).unwrap();
    assert_eq!(g0 & 1, 1, "generación impar = vivo");
    assert_eq!(
        p.direccion(s0).unwrap(),
        base + CABECERA,
        "el primer slot sigue a la cabecera de 4 KiB"
    );
    // Llenar más de una superpágina: la base nunca se mueve.
    let mut ultimos = Vec::new();
    for _ in 0..(p.slots_por_superpagina() + 10) {
        ultimos.push(p.asignar(0, &mut ev).unwrap());
    }
    assert_eq!(p.base, base);
    assert_eq!(ev.superpaginas_reservadas, 2);
    let (s, _) = *ultimos.last().unwrap();
    let off = p.direccion(s).unwrap() - base;
    assert!(
        off % SUPERPAGINA >= CABECERA,
        "los datos nunca invaden la cabecera"
    );
    assert_eq!((off % SUPERPAGINA - CABECERA) % SUBPAGINA % 64, 0);
    assert_eq!(desempaquetar(empaquetar(s, 7)), (s, 7));
    assert_eq!(std::mem::size_of_val(&empaquetar(s, 7)), 8);
}

#[test]
fn bislab_prioriza_la_subpagina_mas_densa() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 8, 0).unwrap();
    let todos: Vec<(u32, u32)> = (0..128).map(|_| p.asignar(0, &mut ev).unwrap()).collect();
    // Subpágina 0: libera 60 (quedan 4 vivos). Subpágina 1: libera 2 (62 vivos).
    for (s, g) in &todos[..60] {
        p.destruir(*s, *g, false, &mut ev).unwrap();
    }
    for (s, g) in &todos[64..66] {
        p.destruir(*s, *g, false, &mut ev).unwrap();
    }
    // Debe reutilizar la subpágina 1 (más densa) para vaciar la 0.
    let (s, _) = p.asignar(0, &mut ev).unwrap();
    assert!(
        (64..128).contains(&s),
        "slot {s} no está en la subpágina más densa"
    );
}

#[test]
fn bislab_devuelve_subpaginas_vacias_al_so() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 8, 0).unwrap();
    let xs: Vec<(u32, u32)> = (0..64).map(|_| p.asignar(0, &mut ev).unwrap()).collect();
    assert_eq!(p.subpaginas_confirmadas(), 1);
    for (s, g) in &xs {
        p.destruir(*s, *g, false, &mut ev).unwrap();
    }
    assert_eq!(ev.subpaginas_devueltas, 1);
    assert_eq!(p.estado_subpagina(xs[0].0), Some(EstadoSub::Devuelta));
    assert_eq!(p.subpaginas_confirmadas(), 0);
    // La cabecera conserva las generaciones (par = libre).
    assert_eq!(p.gen_de(xs[0].0).unwrap(), xs[0].1 + 1);
    // Leer datos de la subpágina devuelta aborta.
    let e = p.leer(xs[0].0, xs[0].1, 0).unwrap_err();
    assert_eq!(e.violacion, Violacion::PaginaDevuelta);
    // Reasignar la reconfirma.
    let (s, g) = p.asignar(0, &mut ev).unwrap();
    assert_eq!(ev.subpaginas_reconfirmadas, 1);
    assert_eq!(g, xs[s as usize].1 + 2);
}

#[test]
fn bislab_retira_slot_al_agotar_la_generacion() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 8, 0).unwrap();
    let (s, _) = p.asignar(0, &mut ev).unwrap();
    let (_otro, _) = p.asignar(0, &mut ev).unwrap();
    p.depuracion_fijar_generacion(s, GEN_RETIRADO - 1);
    let r = p.destruir(s, GEN_RETIRADO - 1, false, &mut ev).unwrap();
    assert_eq!(r, nexo::rt::pool::Destruido::Retirado);
    assert_eq!(p.gen_de(s).unwrap(), GEN_RETIRADO);
    assert_eq!(ev.slots_retirados, 1);
    // El slot retirado no vuelve a asignarse.
    for _ in 0..200 {
        let (x, _) = p.asignar(0, &mut ev).unwrap();
        assert_ne!(x, s);
    }
}

#[test]
fn bislab_doble_liberacion_y_generacion_obsoleta() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 8, 0).unwrap();
    let (s, g) = p.asignar(0, &mut ev).unwrap();
    let _vecino = p.asignar(0, &mut ev).unwrap();
    p.destruir(s, g, false, &mut ev).unwrap();
    assert_eq!(
        p.destruir(s, g, false, &mut ev).unwrap_err().violacion,
        Violacion::DobleLiberacion
    );
    let (s2, g2) = p.asignar(0, &mut ev).unwrap();
    assert_eq!((s2, g2), (s, g + 2));
    assert_eq!(
        p.leer(s, g, 0).unwrap_err().violacion,
        Violacion::GeneracionObsoleta
    );
}

// ------------------------------------------------------------------ oráculo

/// main: crea `a` (y `vecino` para que la subpágina siga confirmada), la
/// destruye y después accede por un enlace anotado como estático.
fn uaf_por_nivel_falso(vecino: bool) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let mut cuerpo = vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])];
    if vecino {
        cuerpo.push(crear(b, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]));
    }
    cuerpo.extend([
        enlazar(l, a),
        destruir(a),
        Stmt::Revalidar {
            enlace: l,
            modo: Modo::View,
            ligado: n,
            cuerpo: vec![leer(x, n, 0)],
            ausente: vec![],
            diferir: false,
            nivel: Some(Nivel::Estatico),
        },
    ]);
    f.p.agregar(c.cuerpo(cuerpo));
    f.p
}

fn correr_bruto(p: &Programa) -> Result<(), nexo::rt::Aborto> {
    let mut m = Maquina::nueva(p, Config::default());
    m.llamar(FuncId(0), vec![], vec![]).map(|_| ())
}

#[test]
fn oraculo_detecta_nivel_estatico_falso() {
    let p = uaf_por_nivel_falso(true);
    assert!(
        nexo::verificar(&p).is_ok(),
        "el verificador lo anota como comprobado"
    );
    let e = correr_bruto(&p).unwrap_err();
    assert_eq!(e.violacion, Violacion::NivelIncorrecto, "{e}");
}

#[test]
fn oraculo_verificado_no_aborta_y_da_ausente() {
    let pv = ok(&uaf_por_nivel_falso(true));
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.ausentes, 1);
    assert_eq!(m.lecturas_gen, 1);
}

fn uso_tras_liberar_por_prestamo(vecino: bool) -> Result<(), nexo::rt::Aborto> {
    // IR sin verificar: préstamo usado tras destruir su dueño.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let va = c.var("va", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let mut cuerpo = vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])];
    if vecino {
        cuerpo.push(crear(b, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]));
    }
    cuerpo.extend([prestar(va, a, Modo::View), destruir(a), leer(x, va, 0)]);
    f.p.agregar(c.cuerpo(cuerpo));
    assert!(
        nexo::verificar(&f.p).is_err(),
        "R7 lo rechaza estáticamente"
    );
    correr_bruto(&f.p)
}

#[test]
fn oraculo_uso_tras_liberar_generacion_obsoleta() {
    assert_eq!(
        uso_tras_liberar_por_prestamo(true).unwrap_err().violacion,
        Violacion::GeneracionObsoleta
    );
}

#[test]
fn oraculo_uso_tras_liberar_pagina_devuelta() {
    assert_eq!(
        uso_tras_liberar_por_prestamo(false).unwrap_err().violacion,
        Violacion::PaginaDevuelta
    );
}

#[test]
fn oraculo_doble_liberacion() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let a2 = c.var("a2", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    // `copiar` de un dueño: IR mal tipada a propósito.
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        crear(b, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        copiar(a2, a),
        destruir(a),
        destruir(a2),
    ]));
    assert_eq!(
        correr_bruto(&f.p).unwrap_err().violacion,
        Violacion::DobleLiberacion
    );
}

#[test]
fn oraculo_prestamo_invalidado_por_reestructuracion() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        revalidar(
            l,
            Modo::View,
            n,
            vec![Stmt::Reestructurar { pool: p }, leer(x, n, 0)],
            vec![],
        ),
        destruir(a),
    ]));
    assert!(nexo::verificar(&f.p).is_err());
    assert_eq!(
        correr_bruto(&f.p).unwrap_err().violacion,
        Violacion::PrestamoInvalidado
    );
}

#[test]
fn oraculo_mutacion_de_pool_congelado() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![Stmt::Congelar {
        pool: p,
        cuerpo: vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])],
    }]));
    assert_eq!(
        correr_bruto(&f.p).unwrap_err().violacion,
        Violacion::MutacionCongelado
    );
}

#[test]
fn oraculo_carrera_de_datos_entre_hilos() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        Stmt::Paralelo {
            hilos: vec![vec![escribir(d, 0, k(2))], vec![escribir(d, 0, k(3))]],
        },
        destruir(d),
    ]));
    assert_eq!(
        correr_bruto(&f.p).unwrap_err().violacion,
        Violacion::CarreraDeDatos
    );
}

#[test]
fn oraculo_fuga_al_destruir_pool_local() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])]));
    assert_eq!(correr_bruto(&f.p).unwrap_err().violacion, Violacion::Fuga);
    // Verificado, la destrucción implícita evita la fuga.
    correr(&ok(&f.p), "main");
}

#[test]
fn metricas_de_acceso_estatico_y_comprobado() {
    let mut f = fx();
    // lee(P, l): revalidación comprobada (el enlace llega como parámetro).
    let mut g = Constructor::nueva("lee");
    let gp = g.pool_param("P", f.nodo, PermisoPool::View);
    let l = g.param("l", Ty::Enlace(gp));
    let n = g.var("n", view_nodo(&f, gp));
    let x = g.var("x", Ty::Int);
    let lee = f.p.agregar(g.cuerpo(vec![revalidar(
        l,
        Modo::View,
        n,
        vec![leer(x, n, 0)],
        vec![],
    )]));
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let la = c.var("la", Ty::Enlace(p));
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        leer(y, a, 0),
        enlazar(la, a),
        llamar(lee, vec![p], vec![v(la)], None),
    ]));
    let pv = ok(&f.p);
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.accesos_estaticos, 1);
    assert_eq!(m.accesos_comprobados, 1);
    assert_eq!(m.pct_estatico(), 50.0);
    assert_eq!(m.lecturas_gen, 1);
    eprintln!("{m}");
}
