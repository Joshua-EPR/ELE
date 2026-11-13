//! Casos nuevos de NEXO v0.2 (N23–N28).

mod comun;

use comun::*;
use nexo::Regla;
use nexo::ir::s::*;
use nexo::ir::*;
use nexo::rt::{Config, Maquina, RefObj, Valor, Violacion};

/// N23: una llamada con efecto `crece(P)` dentro de `revalidar l en B` no
/// invalida `l`: se acepta y solo hay una comprobación de generación.
#[test]
fn n23_crece_dentro_de_revalidar_una_sola_comprobacion() {
    let mut f = fx();
    let mut g = Constructor::nueva("crece");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let y = g.var("y", ty_nodo(&f, gp));
    g.retorna(ty_nodo(&f, gp));
    let crece = f.p.agregar(g.cuerpo(vec![
        crear(y, f.nodo, Ubic::Pool(gp), vec![k(0), k(0)]),
        retornar(Some(v(y))),
    ]));

    let mut u = Constructor::nueva("usa");
    let p = u.pool_param("P", f.nodo, PermisoPool::Edit);
    let l = u.param("l", Ty::Enlace(p));
    let n1 = u.var("n1", view_nodo(&f, p));
    let n2 = u.var("n2", view_nodo(&f, p));
    let nuevo = u.var("nuevo", ty_nodo(&f, p));
    let x = u.var("x", Ty::Int);
    let usa = f.p.agregar(u.cuerpo(vec![revalidar_diferido(
        l,
        Modo::View,
        n1,
        vec![
            llamar(crece, vec![p], vec![], Some(nuevo)),
            // `l` sigue probado válido tras crece(P): revalidación estática.
            revalidar(l, Modo::View, n2, vec![leer(x, n2, 0)], vec![]),
            destruir(nuevo),
        ],
        vec![],
    )]));

    let mut c = Constructor::nueva("main");
    let mp = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, mp));
    let la = c.var("la", Ty::Enlace(mp));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(mp), vec![k(1), k(0)]),
        enlazar(la, a),
        llamar(usa, vec![mp], vec![v(la)], None),
    ]));

    let pv = ok(&f.p);
    assert_eq!(pv.efecto(crece, 0).nivel, nexo::verif::NivelEfecto::Crece);
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.lecturas_gen, 1, "una sola comprobación de generación");
    assert_eq!(m.revalidaciones_comprobadas, 1);
    assert_eq!(m.revalidaciones_estaticas, 1);
}

/// N24: destruir un dueño y alojar otro del mismo pool en el mismo bloque
/// reutiliza `hueco<P, s>` sin tocar la lista libre; `gen[s]` avanza +2 y
/// los enlaces viejos dan `Ausente`.
#[test]
fn n24_reuso_de_hueco_avanza_generacion_dos() {
    let mut f = fx();
    let mut c1 = Constructor::nueva("nace");
    let p1 = c1.pool_param("P", f.nodo, PermisoPool::Edit);
    let a = c1.var("a", ty_nodo(&f, p1));
    c1.retorna(ty_nodo(&f, p1));
    let nace = f.p.agregar(c1.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p1), vec![k(1), k(0)]),
        retornar(Some(v(a))),
    ]));
    let mut c2 = Constructor::nueva("recicla");
    let p2 = c2.pool_param("P", f.nodo, PermisoPool::Edit);
    let viejo = c2.param("viejo", ty_nodo(&f, p2));
    let b = c2.var("b", ty_nodo(&f, p2));
    c2.retorna(ty_nodo(&f, p2));
    let recicla = f.p.agregar(c2.cuerpo(vec![
        destruir(viejo),
        crear(b, f.nodo, Ubic::Pool(p2), vec![k(2), k(0)]),
        retornar(Some(v(b))),
    ]));
    let mut c3 = Constructor::nueva("prueba");
    let p3 = c3.pool_param("P", f.nodo, PermisoPool::View);
    let l = c3.param("l", Ty::Enlace(p3));
    let n = c3.var("n", view_nodo(&f, p3));
    let r = c3.var("r", Ty::Dueno(f.dato, Ubic::Pila));
    let x = c3.var("x", Ty::Int);
    c3.retorna(Ty::Int);
    let prueba = f.p.agregar(c3.cuerpo(vec![
        crear(r, f.dato, Ubic::Pila, vec![k(0)]),
        revalidar(l, Modo::View, n, vec![escribir(r, 0, k(1))], vec![]),
        leer(x, r, 0),
        retornar(Some(v(x))),
    ]));

    let pv = ok(&f.p);
    assert_eq!(pv.huecos_formados, 1);
    assert!(matches!(
        pv.programa.funcion(recicla).cuerpo[1],
        Stmt::ReusarHueco { .. }
    ));
    let mut m = Maquina::nueva(&pv.programa, Config::default());
    let pool = m.crear_pool(f.nodo).unwrap();
    let Some(Valor::Obj(RefObj::Pool {
        slot: s1,
        gener: g1,
        ..
    })) = m.llamar(nace, vec![pool], vec![]).unwrap()
    else {
        panic!()
    };
    let asignados_antes = m.metricas().slots_asignados;
    let antes = Valor::Obj(RefObj::Pool {
        pool,
        slot: s1,
        gener: g1,
    });
    let Some(
        nuevo @ Valor::Obj(RefObj::Pool {
            slot: s2,
            gener: g2,
            ..
        }),
    ) = m.llamar(recicla, vec![pool], vec![antes]).unwrap()
    else {
        panic!()
    };
    assert_eq!(s2, s1, "mismo slot");
    assert_eq!(g2, g1 + 2, "gen[s] avanza +2");
    assert_eq!(m.metricas().reusos_hueco, 1);
    assert_eq!(
        m.metricas().slots_asignados,
        asignados_antes,
        "no toca la lista libre"
    );
    let viejo_enlace = Valor::Enlace {
        pool,
        slot: s1,
        gener: g1,
    };
    assert_eq!(
        m.llamar(prueba, vec![pool], vec![viejo_enlace]).unwrap(),
        Some(Valor::Int(0)),
        "Ausente"
    );
    let enlace_nuevo = Valor::Enlace {
        pool,
        slot: s2,
        gener: g2,
    };
    assert_eq!(
        m.llamar(prueba, vec![pool], vec![enlace_nuevo]).unwrap(),
        Some(Valor::Int(1))
    );
    let _ = nuevo;
}

/// Construye una lista a→b→c→d en `P`, la sella y la recorre desde
/// `recorrer`. Si `destruir_antes`, destruye un nodo extra tras sellar.
fn grafo(destruido: Option<usize>) -> (Programa, FuncId) {
    let mut f = fx();
    let mut r = Constructor::nueva("recorrer");
    let p = r.pool_param("P", f.nodo, PermisoPool::View);
    let raiz = r.param("raiz", Ty::Enlace(p));
    let sello = r.param("sello", Ty::Sello(p));
    let acc = r.var("acc", Ty::Dueno(f.dato, Ubic::Pila));
    let ns: Vec<VarId> = (0..4)
        .map(|i| r.var(&format!("n{i}"), view_nodo(&f, p)))
        .collect();
    let es: Vec<VarId> = (0..3)
        .map(|i| r.var(&format!("e{i}"), Ty::Enlace(p)))
        .collect();
    let val = r.var("val", Ty::Int);
    let res = r.var("res", Ty::Int);
    r.retorna(Ty::Int);
    // Cuerpo más interno: lee el valor del último nodo.
    let mut dentro = vec![leer(val, ns[3], 0), escribir(acc, 0, v(val))];
    for i in (0..3).rev() {
        dentro = vec![
            leer(es[i], ns[i], 1),
            revalidar(es[i], Modo::View, ns[i + 1], dentro, vec![]),
        ];
    }
    let recorrer = f.p.agregar(r.cuerpo(vec![
        crear(acc, f.dato, Ubic::Pila, vec![k(-1)]),
        Stmt::SiSellado {
            sello,
            cuerpo: vec![revalidar(raiz, Modo::View, ns[0], dentro, vec![])],
            sino: vec![escribir(acc, 0, k(-2))],
        },
        leer(res, acc, 0),
        retornar(Some(v(res))),
    ]));

    let mut c = Constructor::nueva("main");
    let mp = c.pool_local("P", f.nodo);
    let nodos: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("x{i}"), ty_nodo(&f, mp)))
        .collect();
    let ls: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("l{i}"), Ty::Enlace(mp)))
        .collect();
    let extra = c.var("extra", ty_nodo(&f, mp));
    let s = c.var("s", Ty::Sello(mp));
    let out = c.var("out", Ty::Int);
    c.retorna(Ty::Int);
    let mut cuerpo = vec![crear(extra, f.nodo, Ubic::Pool(mp), vec![k(0), k(0)])];
    for i in (0..4).rev() {
        let sig = if i == 3 { k(0) } else { v(ls[i + 1]) };
        cuerpo.push(crear(
            nodos[i],
            f.nodo,
            Ubic::Pool(mp),
            vec![k(10 * (i as i64 + 1)), sig],
        ));
        cuerpo.push(enlazar(ls[i], nodos[i]));
    }
    cuerpo.push(Stmt::Sellar { dst: s, pool: mp });
    if let Some(i) = destruido {
        cuerpo.push(destruir(if i < 4 { nodos[i] } else { extra }));
    }
    cuerpo.push(llamar(recorrer, vec![mp], vec![v(ls[0]), v(s)], Some(out)));
    cuerpo.push(retornar(Some(v(out))));
    f.p.agregar(c.cuerpo(cuerpo));
    (f.p, recorrer)
}

/// N25: con `epoca_validada == pool.epoca_destruccion` y sin `destruye(P)`
/// en el bloque, el recorrido hace 0 comprobaciones de generación por arista.
#[test]
fn n25_recorrido_sellado_sin_comprobaciones_por_arista() {
    let (p, _) = grafo(None);
    let pv = ok(&p);
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(40)), "llega al cuarto nodo");
    assert_eq!(m.revalidaciones_estaticas, 3, "3 aristas, todas estáticas");
    assert_eq!(m.lecturas_gen, 1, "solo la raíz (parámetro) se comprueba");
    assert_eq!(m.lecturas_gen_sellado, 3);
    eprintln!("{m}");
}

#[test]
fn n25_epoca_cambiada_toma_la_rama_sino() {
    let (p, _) = grafo(Some(4));
    let pv = ok(&p);
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(-2)));
    assert_eq!(m.lecturas_gen, 0);
}

#[test]
fn n25_destruir_dentro_de_si_sellado_viola_r6() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let s = c.var("s", Ty::Sello(p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        Stmt::Sellar { dst: s, pool: p },
        Stmt::SiSellado {
            sello: s,
            cuerpo: vec![destruir(a)],
            sino: vec![],
        },
    ]));
    rechaza(&f.p, Regla::R6);
}

/// N26: `revalidar_lote` con 4 enlaces donde el 3.º está obsoleto salta a
/// `Ausente` sin ejecutar el cuerpo (ni comprobar el 4.º).
#[test]
fn n26_lote_con_tercer_enlace_obsoleto() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let xs: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("x{i}"), ty_nodo(&f, p)))
        .collect();
    let ls: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("l{i}"), Ty::Enlace(p)))
        .collect();
    let ns: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("n{i}"), view_nodo(&f, p)))
        .collect();
    let r = c.var("r", Ty::Dueno(f.dato, Ubic::Pila));
    let out = c.var("out", Ty::Int);
    c.retorna(Ty::Int);
    let mut cuerpo = vec![crear(r, f.dato, Ubic::Pila, vec![k(0)])];
    for i in 0..4 {
        cuerpo.push(crear(xs[i], f.nodo, Ubic::Pool(p), vec![k(i as i64), k(0)]));
        cuerpo.push(enlazar(ls[i], xs[i]));
    }
    cuerpo.push(destruir(xs[2]));
    cuerpo.push(lote(
        ls.clone(),
        Modo::View,
        ns.clone(),
        vec![escribir(r, 0, k(1))],
        vec![escribir(r, 0, k(2))],
    ));
    cuerpo.push(leer(out, r, 0));
    cuerpo.push(retornar(Some(v(out))));
    f.p.agregar(c.cuerpo(cuerpo));
    let pv = ok(&f.p);
    let (res, m) = correr(&pv, "main");
    assert_eq!(res, Some(Valor::Int(2)), "rama Ausente");
    assert_eq!(m.lecturas_gen, 3, "se detiene en el tercero");
    assert_eq!(m.ausentes, 1);
}

/// N27: una subpágina vaciada se devuelve al SO; revalidar un enlace antiguo
/// lee la cabecera y da `Ausente` sin tocar la subpágina desconfirmada.
#[test]
fn n27_revalidar_hacia_subpagina_devuelta() {
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
        destruir(a),
        revalidar(l, Modo::View, n, vec![leer(x, n, 0)], vec![]),
    ]));
    let pv = ok(&f.p);
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.subpaginas_devueltas, 1);
    assert_eq!(m.lecturas_gen, 1);
    assert_eq!(m.ausentes, 1);
    assert_eq!(m.accesos_totales(), 0, "no se tocó la subpágina de datos");
}

/// Programa N28: dos objetos preexistentes y `dividir(edit P, 2)`; cada
/// trabajador crea, edita y destruye en su partición y lee ambos objetos.
fn dividir_programa(editar_ajeno: bool) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let x0 = c.var("x0", ty_nodo(&f, p));
    let x1 = c.var("x1", ty_nodo(&f, p));
    let l0 = c.var("l0", Ty::Enlace(p));
    let l1 = c.var("l1", Ty::Enlace(p));
    let i = c.var("i", Ty::Int);
    let propio = c.var("propio", ty_nodo(&f, p));
    let lp = c.var("lp", Ty::Enlace(p));
    let ep = c.var("ep", edit_nodo(&f, p));
    let v0 = c.var("v0", view_nodo(&f, p));
    let v1 = c.var("v1", view_nodo(&f, p));
    let e0 = c.var("e0", edit_nodo(&f, p));
    let y0 = c.var("y0", Ty::Int);
    let y1 = c.var("y1", Ty::Int);
    let mut trabajador = vec![
        crear(propio, f.nodo, Ubic::Pool(p), vec![v(i), k(0)]),
        enlazar(lp, propio),
        revalidar(lp, Modo::Edit, ep, vec![escribir(ep, 0, k(5))], vec![]),
        revalidar(l0, Modo::View, v0, vec![leer(y0, v0, 0)], vec![]),
        revalidar(l1, Modo::View, v1, vec![leer(y1, v1, 0)], vec![]),
    ];
    if editar_ajeno {
        trabajador.push(revalidar(
            l0,
            Modo::Edit,
            e0,
            vec![escribir(e0, 0, k(9))],
            vec![],
        ));
    }
    f.p.agregar(c.cuerpo(vec![
        crear(x0, f.nodo, Ubic::Pool(p), vec![k(10), k(0)]),
        crear(x1, f.nodo, Ubic::Pool(p), vec![k(20), k(0)]),
        enlazar(l0, x0),
        enlazar(l1, x1),
        Stmt::Dividir {
            pool: p,
            partes: 2,
            indice: i,
            cuerpo: trabajador,
        },
    ]));
    f.p
}

/// N28: `dividir(edit P, 2)` en concurrencia estructurada: ambos hilos
/// crean y destruyen en su partición y leen la otra sin carreras de datos.
#[test]
fn n28_dividir_sin_carreras() {
    let pv = ok(&dividir_programa(false));
    let (_, m) = correr(&pv, "main");
    assert_eq!(m.slots_asignados, 4, "2 preexistentes + 1 por trabajador");
    assert_eq!(m.slots_liberados, 4);
    assert_eq!(m.accesos_totales(), 2 * 3);
    eprintln!("{m}");
}

#[test]
fn n28_editar_objeto_de_otra_particion_viola_c5() {
    rechaza(&dividir_programa(true), Regla::C5);
}

#[test]
fn n28_oraculo_detecta_la_carrera_si_se_salta_el_verificador() {
    let p = dividir_programa(true);
    let mut m = Maquina::nueva(&p, Config::default());
    let e = m.llamar(FuncId(0), vec![], vec![]).unwrap_err();
    assert_eq!(e.violacion, Violacion::CarreraDeDatos, "{e}");
}

// ------------------------------------------- compatibilidad reforzada (fase 3)

/// N23 (negativa): una llamada con `crece(P)` que además edita objetos
/// alcanzados por enlaces no puede ejecutarse mientras un préstamo
/// revalidado está vivo: podría modificar los datos referenciados.
#[test]
fn n23_crece_que_edita_objetos_existentes_viola_r7() {
    let mut f = fx();
    let mut g = Constructor::nueva("crece_y_edita");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let gl = g.param("l", Ty::Enlace(gp));
    let y = g.var("y", ty_nodo(&f, gp));
    let e = g.var("e", edit_nodo(&f, gp));
    g.retorna(ty_nodo(&f, gp));
    let fun = f.p.agregar(g.cuerpo(vec![
        revalidar(gl, Modo::Edit, e, vec![escribir(e, 0, k(99))], vec![]),
        crear(y, f.nodo, Ubic::Pool(gp), vec![k(0), k(0)]),
        retornar(Some(v(y))),
    ]));
    let mut u = Constructor::nueva("usa");
    let p = u.pool_param("P", f.nodo, PermisoPool::Edit);
    let l = u.param("l", Ty::Enlace(p));
    let n = u.var("n", view_nodo(&f, p));
    let nuevo = u.var("nuevo", ty_nodo(&f, p));
    let x = u.var("x", Ty::Int);
    f.p.agregar(u.cuerpo(vec![revalidar_diferido(
        l,
        Modo::View,
        n,
        vec![
            llamar(fun, vec![p], vec![v(l)], Some(nuevo)),
            leer(x, n, 0),
            destruir(nuevo),
        ],
        vec![],
    )]));
    rechaza(&f.p, Regla::R7);
}

/// N25 (forjada): tras sellar se destruye un nodo de la cadena; el sello
/// deja de valer y el recorrido verificado toma `sino`. Si se elimina la
/// comprobación de época conservando las anotaciones `Estatico`, el oráculo
/// detecta la generación incorrecta: la igualdad de épocas no es opcional.
#[test]
fn n25_estatico_forjado_lo_detecta_el_oraculo() {
    let (p, recorrer) = grafo(Some(2));
    let pv = ok(&p);
    let (r, _) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(-2)), "el sello caducó: rama sino");
    let mut forjado = pv.programa.clone();
    let cuerpo = &mut forjado.funciones[recorrer.0 as usize].cuerpo;
    let pos = cuerpo
        .iter()
        .position(|s| matches!(s, Stmt::SiSellado { .. }))
        .unwrap();
    let Stmt::SiSellado {
        cuerpo: dentro,
        sino,
        ..
    } = cuerpo[pos].clone()
    else {
        unreachable!()
    };
    cuerpo[pos] = si(k(1), dentro, sino);
    let mut m = Maquina::nueva(&forjado, Config::default());
    let main = forjado.buscar("main").unwrap();
    let e = m.llamar(main, vec![], vec![]).unwrap_err();
    assert_eq!(e.violacion, Violacion::NivelIncorrecto, "{e}");
}

/// N25: el sello está tipado por pool: no puede usarse con otro pool.
#[test]
fn n25_sello_de_otro_pool_se_rechaza() {
    let mut f = fx();
    let mut g = Constructor::nueva("usa");
    let gp = g.pool_param("P", f.nodo, PermisoPool::View);
    let gs = g.param("s", Ty::Sello(gp));
    let usa = f.p.agregar(g.cuerpo(vec![Stmt::SiSellado {
        sello: gs,
        cuerpo: vec![],
        sino: vec![],
    }]));
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let q = c.pool_local("Q", f.nodo);
    let s = c.var("s", Ty::Sello(p));
    f.p.agregar(c.cuerpo(vec![
        Stmt::Sellar { dst: s, pool: p },
        llamar(usa, vec![q], vec![v(s)], None),
    ]));
    rechaza(&f.p, Regla::R1);
}

/// N26: una validación parcial no expone préstamos: en IR manipulada, la
/// rama `Ausente` que usa un ligado aborta (uso de un valor inexistente).
#[test]
fn n26_validacion_parcial_no_expone_ligados() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let xs: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("x{i}"), ty_nodo(&f, p)))
        .collect();
    let ls: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("l{i}"), Ty::Enlace(p)))
        .collect();
    let ns: Vec<VarId> = (0..4)
        .map(|i| c.var(&format!("n{i}"), view_nodo(&f, p)))
        .collect();
    let y = c.var("y", Ty::Int);
    let mut cuerpo = Vec::new();
    for i in 0..4 {
        cuerpo.push(crear(xs[i], f.nodo, Ubic::Pool(p), vec![k(i as i64), k(0)]));
        cuerpo.push(enlazar(ls[i], xs[i]));
    }
    cuerpo.push(destruir(xs[2]));
    // n0 se validó antes de encontrar l2 obsoleto; el ausente intenta usarlo.
    cuerpo.push(lote(
        ls.clone(),
        Modo::View,
        ns.clone(),
        vec![],
        vec![leer(y, ns[0], 0)],
    ));
    f.p.agregar(c.cuerpo(cuerpo));
    rechaza(&f.p, Regla::R3);
    let mut m = Maquina::nueva(&f.p, Config::default());
    let e = m.llamar(FuncId(0), vec![], vec![]).unwrap_err();
    assert_eq!(e.violacion, Violacion::UsoTrasConsumo, "{e}");
}

/// N26 (edit): los ligados de un lote edit son slots distintos y pueden
/// escribirse a la vez; si dos enlaces apuntan al mismo slot, el lote va a
/// `Ausente` en lugar de crear dos `edit` al mismo objeto.
#[test]
fn n26_lote_edit_escribe_y_detecta_alias() {
    for alias in [false, true] {
        let mut f = fx();
        let mut c = Constructor::nueva("main");
        let p = c.pool_local("P", f.nodo);
        let a = c.var("a", ty_nodo(&f, p));
        let b = c.var("b", ty_nodo(&f, p));
        let la = c.var("la", Ty::Enlace(p));
        let lb = c.var("lb", Ty::Enlace(p));
        let ea = c.var("ea", edit_nodo(&f, p));
        let eb = c.var("eb", edit_nodo(&f, p));
        let r = c.var("r", Ty::Dueno(f.dato, Ubic::Pila));
        let out = c.var("out", Ty::Int);
        c.retorna(Ty::Int);
        f.p.agregar(c.cuerpo(vec![
            crear(r, f.dato, Ubic::Pila, vec![k(0)]),
            crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
            crear(b, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]),
            enlazar(la, a),
            if alias {
                enlazar(lb, a)
            } else {
                enlazar(lb, b)
            },
            lote(
                vec![la, lb],
                Modo::Edit,
                vec![ea, eb],
                vec![
                    escribir(ea, 0, k(10)),
                    escribir(eb, 0, k(20)),
                    escribir(r, 0, k(1)),
                ],
                vec![escribir(r, 0, k(2))],
            ),
            leer(out, r, 0),
            retornar(Some(v(out))),
        ]));
        let pv = ok(&f.p);
        let (res, m) = correr(&pv, "main");
        assert_eq!(res, Some(Valor::Int(if alias { 2 } else { 1 })));
        assert_eq!(m.alias_en_lote, alias as u64);
    }
}

/// N27: la devolución al SO es simulada (estado `Devuelta` y datos
/// descartados); la revalidación solo lee la cabecera.
#[test]
fn n27_devolucion_simulada_y_cabecera_intacta() {
    use nexo::rt::pool::{EstadoSub, Eventos, Pool};
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 2, 64, 1, 0).unwrap();
    let (s, g) = p.asignar(0, &mut ev).unwrap();
    p.destruir(s, g, false, &mut ev).unwrap();
    assert_eq!(p.estado_subpagina(s), Some(EstadoSub::Devuelta));
    assert_eq!(p.gen_de(s).unwrap(), g + 1, "la cabecera sigue legible");
    assert_eq!(
        p.leer(s, g, 0).unwrap_err().violacion,
        Violacion::PaginaDevuelta
    );
    p.comprobar_invariantes().unwrap();
}

/// N28-B: un trabajador escribe un objeto preexistente mientras otro lo lee,
/// sin sincronización. Rechazo estático (C5) y, sin verificador, carrera
/// detectada en todos los órdenes de hilos.
#[test]
fn n28b_lectura_cruzada_con_escritura_concurrente() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let x0 = c.var("x0", ty_nodo(&f, p));
    let l0 = c.var("l0", Ty::Enlace(p));
    let i = c.var("i", Ty::Int);
    let es0 = c.var("es0", Ty::Int);
    let e = c.var("e", edit_nodo(&f, p));
    let w = c.var("w", view_nodo(&f, p));
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(x0, f.nodo, Ubic::Pool(p), vec![k(10), k(0)]),
        enlazar(l0, x0),
        Stmt::Dividir {
            pool: p,
            partes: 2,
            indice: i,
            cuerpo: vec![
                Stmt::Aritmetica {
                    dst: es0,
                    op: OpArit::Igual,
                    a: v(i),
                    b: k(0),
                },
                si(
                    v(es0),
                    // Trabajador 0: propietario de x0, lo escribe.
                    vec![revalidar(
                        l0,
                        Modo::Edit,
                        e,
                        vec![escribir(e, 0, k(11))],
                        vec![],
                    )],
                    // Trabajador 1: lo lee.
                    vec![revalidar(l0, Modo::View, w, vec![leer(y, w, 0)], vec![])],
                ),
            ],
        },
    ]));
    rechaza(&f.p, Regla::C5);
    for orden in [0, 1, 7] {
        let mut m = Maquina::nueva(
            &f.p,
            Config {
                orden_hilos: orden,
                ..Config::default()
            },
        );
        let e = m.llamar(FuncId(0), vec![], vec![]).unwrap_err();
        assert_eq!(e.violacion, Violacion::CarreraDeDatos, "orden {orden}: {e}");
    }
}

/// N28-A en todos los órdenes de hilos explorados.
#[test]
fn n28a_sin_carreras_en_todos_los_ordenes() {
    let pv = ok(&dividir_programa(false));
    for orden in [0, 1, 7, 0xDEAD] {
        let cfg = Config {
            orden_hilos: orden,
            invariantes: true,
            ..Config::default()
        };
        nexo::rt::ejecutar(&pv, "main", cfg).unwrap();
    }
}
