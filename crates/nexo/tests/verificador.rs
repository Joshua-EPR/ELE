//! Fase 1: verificador estático (R1–R9, C1–C6), efectos y elaboración.

mod comun;

use comun::*;
use nexo::Regla;
use nexo::ir::s::*;
use nexo::ir::*;
use nexo::verif::{EfectoPool, NivelEfecto};

// ---------------------------------------------------------------- aceptación

#[test]
fn acepta_crear_enlazar_revalidar_y_destruir() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let fun = c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(7), k(0)]),
        enlazar(l, a),
        revalidar(l, Modo::View, n, vec![leer(x, n, 0)], vec![]),
        destruir(a),
    ]);
    f.p.agregar(fun);
    let pv = ok(&f.p);
    // El enlace procede de `enlazar` sin destrucciones en medio: nivel estático.
    let Stmt::Revalidar { nivel, .. } = &pv.programa.funciones[0].cuerpo[2] else {
        panic!()
    };
    assert_eq!(*nivel, Some(Nivel::Estatico));
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.lecturas_gen, 0);
    assert_eq!(m.revalidaciones_estaticas, 1);
}

// ------------------------------------------------------------------------ R1

#[test]
fn r1_variable_usada_antes_de_definirse() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![copiar(y, x)]));
    rechaza(&f.p, Regla::R1);
}

#[test]
fn r1_crear_en_pool_view() {
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let p = c.pool_param("P", f.nodo, PermisoPool::View);
    let a = c.var("a", Ty::Int);
    // `a` es Int: el error relevante es el permiso, pero también hay
    // discrepancia de tipo; basta con que R1 aparezca.
    f.p.agregar(c.cuerpo(vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])]));
    rechaza(&f.p, Regla::R1);
}

// ------------------------------------------------------------------------ R2

#[test]
fn r2_clase_no_enlazable_en_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let _p = c.pool_local("P", f.dato);
    f.p.agregar(c.cuerpo(vec![]));
    rechaza(&f.p, Regla::R2);
}

#[test]
fn r2_enlazar_objeto_de_pila() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let _p = c.pool_local("P", f.nodo);
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let l = c.var("l", Ty::Enlace(PoolRef(0)));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        enlazar(l, d),
    ]));
    rechaza(&f.p, Regla::R2);
}

// ------------------------------------------------------------------------ R3

#[test]
fn r3_leer_por_enlace_sin_revalidar() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        leer(x, l, 0),
    ]));
    rechaza(&f.p, Regla::R3);
}

#[test]
fn r3_ligado_usado_en_la_rama_ausente() {
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let p = c.pool_param("P", f.nodo, PermisoPool::View);
    let l = c.param("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![revalidar(
        l,
        Modo::View,
        n,
        vec![],
        vec![leer(x, n, 0)],
    )]));
    rechaza(&f.p, Regla::R3);
}

// ------------------------------------------------------------------------ R4

#[test]
fn r4_retornar_enlace_a_pool_local() {
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let p = c.pool_local("P", f.nodo);
    c.retorna(Ty::Enlace(p));
    f.p.agregar(c.cuerpo(vec![]));
    rechaza(&f.p, Regla::R4);
}

#[test]
fn r4_enlace_guardado_en_objeto_de_otro_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let q = c.pool_local("Q", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let b = c.var("b", ty_nodo(&f, q));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        crear(b, f.nodo, Ubic::Pool(q), vec![k(2), v(l)]),
    ]));
    rechaza(&f.p, Regla::R4);
}

// ------------------------------------------------------------------------ R5

#[test]
fn r5_prestamo_almacenado_en_objeto() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let va = c.var("va", view_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        prestar(va, a, Modo::View),
        crear(b, f.nodo, Ubic::Pool(p), vec![k(2), v(va)]),
    ]));
    rechaza(&f.p, Regla::R5);
}

#[test]
fn r5_prestamo_usado_fuera_de_su_ambito() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let vd = c.var("vd", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        si(k(1), vec![prestar(vd, d, Modo::View)], vec![]),
        leer(x, vd, 0),
    ]));
    rechaza(&f.p, Regla::R5);
}

// ------------------------------------------------------------------------ R6

fn revalidar_y_destruir(diferir: bool) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let cuerpo = vec![leer(x, n, 0), destruir(b)];
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        crear(b, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]),
        enlazar(l, a),
        if diferir {
            revalidar_diferido(l, Modo::View, n, cuerpo, vec![])
        } else {
            revalidar(l, Modo::View, n, cuerpo, vec![])
        },
    ]));
    f.p
}

#[test]
fn r6_destruir_dentro_de_revalidar() {
    rechaza(&revalidar_y_destruir(false), Regla::R6);
}

#[test]
fn r6_destruccion_diferida_se_acepta_y_se_ejecuta_al_salir() {
    let pv = ok(&revalidar_y_destruir(true));
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.destrucciones_diferidas, 1);
    assert_eq!(m.slots_liberados, 2);
}

#[test]
fn r6_reestructurar_no_se_difiere() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        revalidar_diferido(
            l,
            Modo::View,
            n,
            vec![Stmt::Reestructurar { pool: p }],
            vec![],
        ),
    ]));
    rechaza(&f.p, Regla::R6);
}

#[test]
fn r6_llamada_con_destruye_dentro_de_revalidar() {
    let mut f = fx();
    // destruye(P): consume el dueño recibido.
    let mut g = Constructor::nueva("tira");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let x = g.param("x", ty_nodo(&f, gp));
    let tira = f.p.agregar(g.cuerpo(vec![destruir(x)]));

    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        crear(b, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]),
        enlazar(l, a),
        revalidar(
            l,
            Modo::View,
            n,
            vec![llamar(tira, vec![p], vec![v(b)], None)],
            vec![],
        ),
    ]));
    rechaza(&f.p, Regla::R6);
}

// ------------------------------------------------------------------------ R7

#[test]
fn r7_edit_y_view_simultaneos() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let e = c.var("e", Ty::Prestamo(Modo::Edit, f.dato, Ubic::Pila));
    let w = c.var("w", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        prestar(e, d, Modo::Edit),
        prestar(w, d, Modo::View),
        escribir(e, 0, k(2)),
        leer(x, w, 0),
    ]));
    rechaza(&f.p, Regla::R7);
}

#[test]
fn r7_prestamos_secuenciales_se_aceptan() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let e = c.var("e", Ty::Prestamo(Modo::Edit, f.dato, Ubic::Pila));
    let w = c.var("w", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        prestar(e, d, Modo::Edit),
        escribir(e, 0, k(41)),
        // `e` ya no se usa: su vida terminó (liveness).
        prestar(w, d, Modo::View),
        leer(x, w, 0),
        retornar(Some(v(x))),
    ]));
    let pv = ok(&f.p);
    let (r, _) = correr(&pv, "main");
    assert_eq!(r, Some(nexo::rt::Valor::Int(41)));
}

#[test]
fn r7_revalidar_edit_anidado_en_view_del_mismo_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let l1 = c.param("l1", Ty::Enlace(p));
    let l2 = c.param("l2", Ty::Enlace(p));
    let n1 = c.var("n1", view_nodo(&f, p));
    let n2 = c.var("n2", edit_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![revalidar(
        l1,
        Modo::View,
        n1,
        vec![
            revalidar(l2, Modo::Edit, n2, vec![escribir(n2, 0, k(9))], vec![]),
            leer(x, n1, 0),
        ],
        vec![],
    )]));
    rechaza(&f.p, Regla::R7);
}

#[test]
fn r7_escribir_dueno_con_prestamo_vivo() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let w = c.var("w", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        prestar(w, d, Modo::View),
        escribir(d, 0, k(2)),
        leer(x, w, 0),
    ]));
    rechaza(&f.p, Regla::R7);
}

// ------------------------------------------------------------------------ R8

#[test]
fn r8_uso_tras_mover() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let e = c.var("e", Ty::Dueno(f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        mover(e, d),
        leer(x, d, 0),
    ]));
    rechaza(&f.p, Regla::R8);
}

#[test]
fn r8_doble_destruccion() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        destruir(d),
        destruir(d),
    ]));
    rechaza(&f.p, Regla::R8);
}

#[test]
fn r8_consumo_dentro_de_bucle() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let i = c.var("i", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        repetir(k(3), i, vec![destruir(d)]),
    ]));
    rechaza(&f.p, Regla::R8);
}

#[test]
fn r8_consumo_asimetrico_emite_drop_flag() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let cond = c.param("cond", Ty::Int);
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        si(v(cond), vec![destruir(d)], vec![]),
    ]));
    let pv = ok(&f.p);
    assert_eq!(pv.elaboracion.drop_flags, 1);
    let ultimo = pv.programa.funciones[0].cuerpo.last().unwrap();
    assert!(
        matches!(
            ultimo,
            Stmt::Destruir {
                condicional: true,
                implicito: true,
                ..
            }
        ),
        "se esperaba destrucción condicional, hay {ultimo:?}"
    );
    // Ambos caminos ejecutan sin fugas ni dobles liberaciones.
    for c in [0, 1] {
        let mut m = nexo::rt::Maquina::nueva(&pv.programa, Default::default());
        m.llamar(FuncId(0), vec![], vec![nexo::rt::Valor::Int(c)])
            .unwrap();
        m.comprobar_fugas().unwrap();
        assert_eq!(m.metricas().drop_flags_saltados, c as u64);
    }
}

#[test]
fn r8_destruccion_implicita_al_final_del_ambito() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
    ]));
    let pv = ok(&f.p);
    assert_eq!(pv.elaboracion.destrucciones_implicitas, 2);
    correr(&pv, "main");
}

// ------------------------------------------------------------------------ R9

#[test]
fn r9_hueco_usado_en_otro_bloque_basico() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let h = c.var("h", Ty::Hueco(p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        destruir_en_hueco(a, h),
        si(k(1), vec![reusar(b, h, vec![k(2), k(0)])], vec![]),
    ]));
    rechaza(&f.p, Regla::R9);
}

#[test]
fn r9_hueco_no_reutilizado_se_libera_al_final_del_bloque() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let h = c.var("h", Ty::Hueco(p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        destruir_en_hueco(a, h),
    ]));
    let pv = ok(&f.p);
    assert_eq!(pv.elaboracion.huecos_liberados, 1);
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.huecos_liberados, 1);
}

#[test]
fn r9_hueco_de_otro_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let q = c.pool_local("Q", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, q));
    let h = c.var("h", Ty::Hueco(p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        destruir_en_hueco(a, h),
        reusar(b, h, vec![k(2), k(0)]),
    ]));
    rechaza(&f.p, Regla::R9);
}

// ------------------------------------------------------------------- efectos

#[test]
fn efectos_por_punto_fijo_en_recursion_mutua() {
    let mut f = fx();
    let fid_a = f.p.declarar("a");
    let fid_b = f.p.declarar("b");
    // a(P, n): si n > 0 llama a b(P, n - 1).
    let mut ca = Constructor::nueva("a");
    let pa = ca.pool_param("P", f.nodo, PermisoPool::Edit);
    let na = ca.param("n", Ty::Int);
    let ma = ca.var("m", Ty::Int);
    let ca = ca.cuerpo(vec![
        Stmt::Aritmetica {
            dst: ma,
            op: OpArit::Restar,
            a: v(na),
            b: k(1),
        },
        si(
            v(na),
            vec![llamar(fid_b, vec![pa], vec![v(ma)], None)],
            vec![],
        ),
    ]);
    // b(P, n): crea y destruye en P, y llama a a(P, n).
    let mut cb = Constructor::nueva("b");
    let pb = cb.pool_param("P", f.nodo, PermisoPool::Edit);
    let nb = cb.param("n", Ty::Int);
    let x = cb.var("x", ty_nodo(&f, pb));
    let cb = cb.cuerpo(vec![
        crear(x, f.nodo, Ubic::Pool(pb), vec![k(1), k(0)]),
        destruir(x),
        llamar(fid_a, vec![pb], vec![v(nb)], None),
    ]);
    f.p.definir(fid_a, ca);
    f.p.definir(fid_b, cb);
    // c(P): solo crece (devuelve el objeto).
    let mut cc = Constructor::nueva("c");
    let pc = cc.pool_param("P", f.nodo, PermisoPool::Edit);
    let y = cc.var("y", ty_nodo(&f, pc));
    cc.retorna(ty_nodo(&f, pc));
    let fid_c = f.p.agregar(cc.cuerpo(vec![
        crear(y, f.nodo, Ubic::Pool(pc), vec![k(1), k(0)]),
        retornar(Some(v(y))),
    ]));
    // d(P view): solo lee.
    let mut cd = Constructor::nueva("d");
    let pd = cd.pool_param("P", f.nodo, PermisoPool::View);
    let l = cd.param("l", Ty::Enlace(pd));
    let n = cd.var("n", view_nodo(&f, pd));
    let fid_d =
        f.p.agregar(cd.cuerpo(vec![revalidar(l, Modo::View, n, vec![], vec![])]));
    let pv = ok(&f.p);
    eprintln!("{}", pv.informe_efectos());
    assert_eq!(
        pv.efecto(fid_a, 0).nivel,
        NivelEfecto::Destruye,
        "a hereda destruye de b"
    );
    assert_eq!(pv.efecto(fid_b, 0).nivel, NivelEfecto::Destruye);
    assert_eq!(pv.efecto(fid_c, 0), EfectoPool::nivel(NivelEfecto::Crece));
    assert_eq!(pv.efecto(fid_d, 0).nivel, NivelEfecto::Puro);
    assert!(pv.efecto(fid_d, 0).lee_enlaces);
}

fn programa_indirecto(opaca: bool) -> Programa {
    let mut f = fx();
    let firma = Firma {
        pools: vec![(f.nodo, PermisoPool::View)],
        params: vec![],
        ret: None,
        captura_mutable: false,
        opaca,
    };
    let mut c = Constructor::nueva("usa");
    let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let cb = c.param("cb", Ty::Funcion(Box::new(firma)));
    let l = c.param("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![revalidar(
        l,
        Modo::View,
        n,
        vec![llamar_ind(cb, vec![p], vec![], None), leer(x, n, 0)],
        vec![],
    )]));
    f.p
}

#[test]
fn efectos_polimorficos_en_llamada_indirecta() {
    // Sin edit ni capturas mutables: efecto ≤ crece(P), se acepta dentro de revalidar.
    let pv = ok(&programa_indirecto(false));
    assert_eq!(pv.efecto(FuncId(0), 0).nivel, NivelEfecto::Crece);
    // Efecto opaco: destruye(todos) → R6.
    rechaza(&programa_indirecto(true), Regla::R6);
}

// ------------------------------------------------------------------- C1–C6

fn dos_hilos_leen(congelar: bool) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n0 = c.var("n0", view_nodo(&f, p));
    let n1 = c.var("n1", view_nodo(&f, p));
    let x0 = c.var("x0", Ty::Int);
    let x1 = c.var("x1", Ty::Int);
    let par = Stmt::Paralelo {
        hilos: vec![
            vec![revalidar(l, Modo::View, n0, vec![leer(x0, n0, 0)], vec![])],
            vec![revalidar(l, Modo::View, n1, vec![leer(x1, n1, 0)], vec![])],
        ],
    };
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(5), k(0)]),
        enlazar(l, a),
        if congelar {
            Stmt::Congelar {
                pool: p,
                cuerpo: vec![par],
            }
        } else {
            par
        },
    ]));
    f.p
}

#[test]
fn c1_pool_compartido_sin_congelar() {
    rechaza(&dos_hilos_leen(false), Regla::C1);
}

#[test]
fn c3_lectura_congelada_entre_hilos_sin_comprobar_gen() {
    let pv = ok(&dos_hilos_leen(true));
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.revalidaciones_congeladas, 2);
    assert_eq!(m.accesos_congelados, 2);
    assert_eq!(m.lecturas_gen, 0);
}

#[test]
fn c3_crear_en_pool_congelado() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![Stmt::Congelar {
        pool: p,
        cuerpo: vec![crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)])],
    }]));
    rechaza(&f.p, Regla::C3);
}

#[test]
fn c2_enlace_vivo_tras_transferir() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let l2 = c.var("l2", Ty::Enlace(p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        Stmt::TransferirPool {
            pool: p,
            cuerpo: vec![],
        },
        copiar(l2, l),
    ]));
    rechaza(&f.p, Regla::C2);
}

#[test]
fn c2_transferencia_valida_mueve_los_duenos() {
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
        Stmt::TransferirPool {
            pool: p,
            cuerpo: vec![revalidar(l, Modo::View, n, vec![leer(x, n, 0)], vec![])],
        },
    ]));
    let pv = ok(&f.p);
    let (_, m) = correr(&pv, "main");
    assert_eq!(
        m.slots_liberados, 1,
        "el dueño movido se destruye en el hilo destino"
    );
}

#[test]
fn c4_dos_hilos_escriben_el_mismo_dueno() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        Stmt::Paralelo {
            hilos: vec![vec![escribir(d, 0, k(2))], vec![escribir(d, 0, k(3))]],
        },
    ]));
    rechaza(&f.p, Regla::C4);
}

#[test]
fn c6_dividir_con_prestamo_vivo_del_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let va = c.var("va", view_nodo(&f, p));
    let i = c.var("i", Ty::Int);
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        prestar(va, a, Modo::View),
        Stmt::Dividir {
            pool: p,
            partes: 2,
            indice: i,
            cuerpo: vec![],
        },
        leer(x, va, 0),
    ]));
    rechaza(&f.p, Regla::C6);
}

#[test]
fn c6_dividir_en_cero_partes() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let i = c.var("i", Ty::Int);
    f.p.agregar(c.cuerpo(vec![Stmt::Dividir {
        pool: p,
        partes: 0,
        indice: i,
        cuerpo: vec![],
    }]));
    rechaza(&f.p, Regla::C6);
}

#[test]
fn diagnostico_nombra_regla_funcion_y_ruta() {
    let p = revalidar_y_destruir(false);
    let ds = nexo::verificar(&p).unwrap_err();
    let t = ds[0].to_string();
    assert!(t.starts_with("error[R6]"), "{t}");
    assert!(
        t.contains("`main`") && t.contains("cuerpo[3].cuerpo[1]"),
        "{t}"
    );
}

// ------------------------------------------- regresiones halladas por el fuzzer

/// Fuzzer, elecciones `[0, 2, 19, 0, 1, 20, 0]`: `dividir Q { transferir Q }`
/// se aceptaba y el segundo trabajador usaba un pool ya cedido.
#[test]
fn regresion_fuzz_transferir_dentro_de_dividir() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let q = c.pool_local("Q", f.nodo);
    let i = c.var("i", Ty::Int);
    f.p.agregar(c.cuerpo(vec![Stmt::Dividir {
        pool: q,
        partes: 2,
        indice: i,
        cuerpo: vec![Stmt::TransferirPool {
            pool: q,
            cuerpo: vec![],
        }],
    }]));
    let rs = reglas(&f.p);
    assert!(rs.contains(&Regla::C5) && rs.contains(&Regla::C2), "{rs:?}");
    // Sin verificador, la máquina aborta sin pánico.
    let mut m = nexo::rt::Maquina::nueva(&f.p, Default::default());
    assert_eq!(
        m.llamar(FuncId(0), vec![], vec![]).unwrap_err().violacion,
        nexo::rt::Violacion::PermisoInventado
    );
}

/// Fuzzer, elecciones `[0, 2, 20, 1, 20, 0]`: `transferir Q { transferir Q }`
/// se aceptaba y el pool se destruía dos veces.
#[test]
fn regresion_fuzz_retransferir_desde_el_hilo_destino() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let q = c.pool_local("Q", f.nodo);
    f.p.agregar(c.cuerpo(vec![Stmt::TransferirPool {
        pool: q,
        cuerpo: vec![Stmt::TransferirPool {
            pool: q,
            cuerpo: vec![],
        }],
    }]));
    rechaza(&f.p, Regla::C2);
}

/// Dividir de nuevo el pool dividido o congelarlo desde un trabajador: C5.
#[test]
fn regresion_fuzz_dividir_o_congelar_desde_un_trabajador() {
    for anidado in [true, false] {
        let mut f = fx();
        let mut c = Constructor::nueva("main");
        let p = c.pool_local("P", f.nodo);
        let i = c.var("i", Ty::Int);
        let j = c.var("j", Ty::Int);
        let interior = if anidado {
            Stmt::Dividir {
                pool: p,
                partes: 2,
                indice: j,
                cuerpo: vec![],
            }
        } else {
            Stmt::Congelar {
                pool: p,
                cuerpo: vec![],
            }
        };
        f.p.agregar(c.cuerpo(vec![Stmt::Dividir {
            pool: p,
            partes: 2,
            indice: i,
            cuerpo: vec![interior],
        }]));
        rechaza(&f.p, Regla::C5);
    }
}

#[test]
fn c6_rechaza_dividir_en_demasiadas_particiones_antes_del_runtime() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let i = c.var("i", Ty::Int);
    f.p.agregar(c.cuerpo(vec![Stmt::Dividir {
        pool: p,
        partes: u32::MAX,
        indice: i,
        cuerpo: vec![],
    }]));
    rechaza(&f.p, Regla::C6);
}
