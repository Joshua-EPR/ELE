//! Especificación normativa N01–N22 de NEXO v0.2 (fase 3), con variantes
//! negativas estáticas y variantes de IR manipulada para el oráculo.

mod comun;

use comun::*;
use nexo::Regla;
use nexo::ir::s::*;
use nexo::ir::*;
use nexo::rt::pool::GEN_RETIRADO;
use nexo::rt::{Config, Maquina, RefObj, Valor, Violacion};

// =================================================== A: propiedad y linealidad

/// N01: crear, usar y destruir exactamente una vez.
#[test]
fn n01_creacion_y_destruccion_valida() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(3), k(0)]),
        crear(d, f.dato, Ubic::Pila, vec![k(4)]),
        leer(x, a, 0),
        leer(y, d, 0),
        destruir(a),
        destruir(d),
    ]));
    let pv = ok(&f.p);
    assert_eq!(pv.elaboracion.destrucciones_implicitas, 0);
    let (_, m) = correr(&pv, "main"); // `correr` comprueba fugas al final
    assert_eq!((m.slots_asignados, m.slots_liberados), (1, 1));
    assert_eq!(m.subpaginas_devueltas, 1);
}

/// N02: mover `A` a `B`; `B` conserva la propiedad exclusiva.
#[test]
fn n02_transferencia_de_propiedad() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(9), k(0)]),
        mover(b, a),
        leer(x, b, 0),
        destruir(b),
        retornar(Some(v(x))),
    ]));
    let pv = ok(&f.p);
    assert_eq!(
        pv.elaboracion.destrucciones_implicitas, 0,
        "`a` no se destruye: se movió"
    );
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(9)));
    assert_eq!(m.slots_liberados, 1);
}

fn mover_y_usar(uso: Stmt, a: VarId, b: VarId, f: &mut Fx, c: Constructor, p: PoolRef) {
    let fun = c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        mover(b, a),
        uso,
        destruir(b),
    ]);
    f.p.agregar(fun);
}

/// N03: leer, escribir o destruir `A` tras moverlo es un rechazo estático
/// que nombra la ruta consumida.
#[test]
fn n03_uso_despues_de_movimiento() {
    for caso in 0..3 {
        let mut f = fx();
        let mut c = Constructor::nueva("main");
        let p = c.pool_local("P", f.nodo);
        let a = c.var("a", ty_nodo(&f, p));
        let b = c.var("b", ty_nodo(&f, p));
        let x = c.var("x", Ty::Int);
        let uso = match caso {
            0 => leer(x, a, 0),
            1 => escribir(a, 0, k(5)),
            _ => destruir(a),
        };
        mover_y_usar(uso, a, b, &mut f, c, p);
        let ms = mensajes(&f.p);
        assert!(
            ms.iter().any(|m| m.starts_with("error[R8]")
                && m.contains("`a`")
                && m.contains("cuerpo[2]")),
            "{ms:?}"
        );
    }
}

/// N03 (IR manipulada): `copiar` en lugar de `mover` deja vivo el origen;
/// tras destruir `B`, el acceso por `A` lo detecta el oráculo.
#[test]
fn n03_oraculo_detecta_origen_no_invalidado() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let vecino = c.var("vecino", ty_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(vecino, f.nodo, Ubic::Pool(p), vec![k(0), k(0)]),
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        copiar(b, a),
        destruir(b),
        leer(x, a, 0),
    ]));
    assert!(nexo::verificar(&f.p).is_err());
    assert_eq!(violacion_bruta(&f.p), Violacion::GeneracionObsoleta);
    // Con `mover` correcto, el uso posterior del origen es uso tras consumo.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        mover(b, a),
        leer(x, a, 0),
    ]));
    assert_eq!(violacion_bruta(&f.p), Violacion::UsoTrasConsumo);
}

/// N04: doble `destruir`: rechazo por linealidad; sin verificador, el
/// oráculo detecta la doble liberación (pool y pila).
#[test]
fn n04_doble_destruccion() {
    for ubic_pool in [true, false] {
        let mut f = fx();
        let mut c = Constructor::nueva("main");
        let p = c.pool_local("P", f.nodo);
        let (ty, clase, ubic, campos) = if ubic_pool {
            (ty_nodo(&f, p), f.nodo, Ubic::Pool(p), vec![k(1), k(0)])
        } else {
            (
                Ty::Dueno(f.dato, Ubic::Pila),
                f.dato,
                Ubic::Pila,
                vec![k(1)],
            )
        };
        let a = c.var("a", ty.clone());
        let a2 = c.var("a2", ty);
        let ancla = c.var("ancla", ty_nodo(&f, p));
        f.p.agregar(c.cuerpo(vec![
            crear(ancla, f.nodo, Ubic::Pool(p), vec![k(0), k(0)]),
            crear(a, clase, ubic, campos),
            destruir(a),
            destruir(a),
        ]));
        rechaza(&f.p, Regla::R8);
        // Manipulada: un alias de dueño (copiar) para burlar la linealidad.
        if let Stmt::Destruir { src, .. } = &mut f.p.funciones[0].cuerpo[3] {
            *src = a2;
        }
        f.p.funciones[0].cuerpo.insert(2, copiar(a2, a));
        let mut m = Maquina::nueva(&f.p, Config::default());
        let e = m.llamar(FuncId(0), vec![], vec![]).unwrap_err();
        assert_eq!(e.violacion, Violacion::DobleLiberacion, "{e}");
    }
}

/// N05: propiedad condicional, salida anticipada y ruta de error. Cada ruta
/// destruye o consume el dueño exactamente una vez (drop flags).
#[test]
fn n05_propiedad_condicional_y_drop_flags() {
    let mut f = fx();
    let mut g = Constructor::nueva("consume");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let gx = g.param("x", ty_nodo(&f, gp));
    let consume = f.p.agregar(g.cuerpo(vec![destruir(gx)]));

    let mut c = Constructor::nueva("main");
    let c1 = c.param("c1", Ty::Int);
    let c2 = c.param("c2", Ty::Int);
    let c3 = c.param("c3", Ty::Int);
    let p = c.pool_local("P", f.nodo);
    let d = c.var("d", ty_nodo(&f, p));
    let e = c.var("e", ty_nodo(&f, p));
    let x = c.var("x", ty_nodo(&f, p));
    let lx = c.var("lx", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    c.retorna(Ty::Int);
    let main = f.p.agregar(c.cuerpo(vec![
        crear(d, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        crear(x, f.nodo, Ubic::Pool(p), vec![k(2), k(0)]),
        enlazar(lx, x),
        si(v(c3), vec![destruir(x)], vec![]),
        si(
            v(c1),
            vec![mover(e, d), llamar(consume, vec![p], vec![v(e)], None)],
            vec![],
        ),
        si(v(c2), vec![retornar(Some(k(1)))], vec![]),
        // Ruta de error: el enlace a `x` está obsoleto si c3.
        revalidar(lx, Modo::View, n, vec![], vec![retornar(Some(k(2)))]),
        retornar(Some(k(0))),
    ]));
    let pv = ok(&f.p);
    assert!(
        pv.elaboracion.drop_flags >= 2,
        "d y x necesitan drop flag: {:?}",
        pv.elaboracion
    );
    for bits in 0..8i64 {
        let (b1, b2, b3) = (bits & 1, (bits >> 1) & 1, (bits >> 2) & 1);
        let mut m = maquina(&pv);
        let r = m
            .llamar(
                main,
                vec![],
                vec![Valor::Int(b1), Valor::Int(b2), Valor::Int(b3)],
            )
            .unwrap_or_else(|a| panic!("c1={b1} c2={b2} c3={b3}: {a}"));
        m.comprobar_fugas().unwrap();
        let esperado = if b2 == 1 {
            1
        } else if b3 == 1 {
            2
        } else {
            0
        };
        assert_eq!(r, Some(Valor::Int(esperado)));
        let met = m.metricas();
        assert_eq!(
            met.slots_liberados, 2,
            "cada dueño se libera exactamente una vez"
        );
    }
    // Negativa: consumir en una rama y usar después.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let cnd = c.param("c", Ty::Int);
    let p = c.pool_local("P", f.nodo);
    let d = c.var("d", ty_nodo(&f, p));
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        si(v(cnd), vec![destruir(d)], vec![]),
        leer(y, d, 0),
    ]));
    rechaza(&f.p, Regla::R8);
}

// ===================================================== B: préstamos y alcance

/// N06: dos `view` simultáneos sobre el mismo dueño.
#[test]
fn n06_multiples_prestamos_de_lectura() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let v1 = c.var("v1", view_nodo(&f, p));
    let v2 = c.var("v2", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    let z = c.var("z", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(21), k(0)]),
        prestar(v1, a, Modo::View),
        prestar(v2, a, Modo::View),
        leer(x, v1, 0),
        leer(y, v2, 0),
        Stmt::Aritmetica {
            dst: z,
            op: OpArit::Sumar,
            a: v(x),
            b: v(y),
        },
        destruir(a),
        retornar(Some(v(z))),
    ]));
    let pv = ok(&f.p);
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(42)));
    assert_eq!(m.slots_asignados, 1, "los préstamos no asignan");
    assert_eq!(m.accesos_estaticos, 2);
}

fn dos_prestamos(m1: Modo, m2: Modo) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let b1 = c.var("b1", Ty::Prestamo(m1, f.dato, Ubic::Pila));
    let b2 = c.var("b2", Ty::Prestamo(m2, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        prestar(b1, d, m1),
        prestar(b2, d, m2),
        leer(x, b1, 0),
        leer(y, b2, 0),
    ]));
    f.p
}

/// N07: `edit` + `edit` y `edit` + `view` vivos a la vez son rechazados.
/// Préstamos por campo disjunto: no soportados (los préstamos son de objeto
/// completo), así que se rechazan de forma conservadora.
#[test]
fn n07_exclusividad_de_edicion() {
    rechaza(&dos_prestamos(Modo::Edit, Modo::Edit), Regla::R7);
    rechaza(&dos_prestamos(Modo::Edit, Modo::View), Regla::R7);
    rechaza(&dos_prestamos(Modo::View, Modo::Edit), Regla::R7);
    ok(&dos_prestamos(Modo::View, Modo::View));
    // Campos 0 y 1 de un Nodo: disjuntos, pero el préstamo es del objeto.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let e1 = c.var("e1", edit_nodo(&f, p));
    let e2 = c.var("e2", edit_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        prestar(e1, a, Modo::Edit),
        prestar(e2, a, Modo::Edit),
        escribir(e1, 0, k(2)),
        escribir(e2, 1, k(0)),
    ]));
    rechaza(&f.p, Regla::R7);
}

/// N08: un préstamo no escapa a una raíz que vive más que su dueño.
#[test]
fn n08_prestamo_que_escapa() {
    // Almacenado en un objeto.
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
    // Devuelto.
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let vd = c.var("vd", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    c.retorna(Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    f.p.agregar(c.cuerpo(vec![
        crear(d, f.dato, Ubic::Pila, vec![k(1)]),
        prestar(vd, d, Modo::View),
        retornar(Some(v(vd))),
    ]));
    rechaza(&f.p, Regla::R5);
    // Sacado de su ámbito.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let d = c.var("d", Ty::Dueno(f.dato, Ubic::Pila));
    let vd = c.var("vd", Ty::Prestamo(Modo::View, f.dato, Ubic::Pila));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        si(
            k(1),
            vec![
                crear(d, f.dato, Ubic::Pila, vec![k(1)]),
                prestar(vd, d, Modo::View),
            ],
            vec![],
        ),
        leer(x, vd, 0),
    ]));
    rechaza(&f.p, Regla::R5);
}

fn destruir_con_prestamo(uso_despues: bool) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let va = c.var("va", view_nodo(&f, p));
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    let mut cuerpo = vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        prestar(va, a, Modo::View),
        leer(x, va, 0),
        destruir(a),
    ];
    if uso_despues {
        cuerpo.push(leer(y, va, 0));
    }
    f.p.agregar(c.cuerpo(cuerpo));
    f.p
}

/// N09: destruir el dueño antes del último uso del préstamo → rechazo; si
/// el último uso es anterior, se acepta.
#[test]
fn n09_destruccion_con_prestamo_vivo() {
    rechaza(&destruir_con_prestamo(true), Regla::R7);
    let pv = ok(&destruir_con_prestamo(false));
    correr(&pv, "main");
}

// ===================================================== C: enlaces generacionales

/// `lee(P view, l) -> Int`: devuelve el campo 0 o -1 si el enlace está ausente.
fn funcion_lee(f: &mut Fx) -> FuncId {
    let mut g = Constructor::nueva("lee");
    let gp = g.pool_param("P", f.nodo, PermisoPool::View);
    let l = g.param("l", Ty::Enlace(gp));
    let n = g.var("n", view_nodo(f, gp));
    let r = g.var("r", Ty::Dueno(f.dato, Ubic::Pila));
    let x = g.var("x", Ty::Int);
    let y = g.var("y", Ty::Int);
    g.retorna(Ty::Int);
    f.p.agregar(g.cuerpo(vec![
        crear(r, f.dato, Ubic::Pila, vec![k(-1)]),
        revalidar(
            l,
            Modo::View,
            n,
            vec![leer(x, n, 0), escribir(r, 0, v(x))],
            vec![],
        ),
        leer(y, r, 0),
        retornar(Some(v(y))),
    ]))
}

/// N10: revalidación comprobada de un enlace válido.
#[test]
fn n10_enlace_valido() {
    let mut f = fx();
    let lee = funcion_lee(&mut f);
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let r = c.var("r", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(77), k(0)]),
        enlazar(l, a),
        llamar(lee, vec![p], vec![v(l)], Some(r)),
        retornar(Some(v(r))),
    ]));
    let pv = ok(&f.p);
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(77)));
    assert_eq!(m.lecturas_gen, 1, "una lectura real de gen[s]");
    assert_eq!(m.revalidaciones_comprobadas, 1);
    assert_eq!(m.accesos_comprobados, 1);
}

/// N11: enlace copiado, dueño destruido: `Ausente` sin tocar datos. Usarlo
/// como referencia sin revalidar es R3; en IR manipulada, el oráculo lo
/// trata como permiso inventado.
#[test]
fn n11_enlace_obsoleto() {
    let mut f = fx();
    let lee = funcion_lee(&mut f);
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let vecino = c.var("vecino", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let l2 = c.var("l2", Ty::Enlace(p));
    let r = c.var("r", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(vecino, f.nodo, Ubic::Pool(p), vec![k(0), k(0)]),
        crear(a, f.nodo, Ubic::Pool(p), vec![k(77), k(0)]),
        enlazar(l, a),
        copiar(l2, l),
        destruir(a),
        llamar(lee, vec![p], vec![v(l2)], Some(r)),
        retornar(Some(v(r))),
    ]));
    let pv = ok(&f.p);
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(-1)), "Ausente");
    assert_eq!(m.accesos_comprobados, 0);
    assert_eq!(m.ausentes, 1);

    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        destruir(a),
        leer(x, l, 0),
    ]));
    rechaza(&f.p, Regla::R3);
    assert_eq!(violacion_bruta(&f.p), Violacion::PermisoInventado);
}

/// N12: ciclo A ↔ B. Los enlaces no son propiedad: cada objeto se libera
/// una sola vez y el ciclo se recorre por revalidación.
#[test]
fn n12_ciclo_de_enlaces() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let la = c.var("la", Ty::Enlace(p));
    let lb = c.var("lb", Ty::Enlace(p));
    let n1 = c.var("n1", view_nodo(&f, p));
    let n2 = c.var("n2", view_nodo(&f, p));
    let n3 = c.var("n3", view_nodo(&f, p));
    let e1 = c.var("e1", Ty::Enlace(p));
    let e2 = c.var("e2", Ty::Enlace(p));
    let x = c.var("x", Ty::Int);
    let r = c.var("r", Ty::Dueno(f.dato, Ubic::Pila));
    let out = c.var("out", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        crear(r, f.dato, Ubic::Pila, vec![k(0)]),
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(la, a),
        crear(b, f.nodo, Ubic::Pool(p), vec![k(2), v(la)]),
        enlazar(lb, b),
        escribir(a, 1, v(lb)),
        // a → b → a
        revalidar(
            la,
            Modo::View,
            n1,
            vec![
                leer(e1, n1, 1),
                revalidar(
                    e1,
                    Modo::View,
                    n2,
                    vec![
                        leer(e2, n2, 1),
                        revalidar(
                            e2,
                            Modo::View,
                            n3,
                            vec![leer(x, n3, 0), escribir(r, 0, v(x))],
                            vec![],
                        ),
                    ],
                    vec![],
                ),
            ],
            vec![],
        ),
        destruir(a),
        destruir(b),
        leer(out, r, 0),
        retornar(Some(v(out))),
    ]));
    let pv = ok(&f.p);
    let Stmt::Escribir { invalida_epoca, .. } = &pv.programa.funciones[0].cuerpo[5] else {
        panic!()
    };
    assert_eq!(
        *invalida_epoca,
        Some(false),
        "el enlace almacenado está probado"
    );
    let (r, m) = correr(&pv, "main");
    assert_eq!(r, Some(Valor::Int(1)), "a → b → a");
    assert_eq!((m.slots_asignados, m.slots_liberados), (2, 2));
}

/// N13: un enlace no sobrevive a su pool.
#[test]
fn n13_enlace_que_sobrevive_a_su_pool() {
    // Devolver un enlace a un pool local: R4.
    let mut f = fx();
    let mut g = Constructor::nueva("fuga");
    let q = g.pool_local("Q", f.nodo);
    let a = g.var("a", ty_nodo(&f, q));
    let l = g.var("l", Ty::Enlace(q));
    g.retorna(Ty::Enlace(q));
    f.p.agregar(g.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(q), vec![k(1), k(0)]),
        enlazar(l, a),
        destruir(a),
        retornar(Some(v(l))),
    ]));
    rechaza(&f.p, Regla::R4);
    // Usar el enlace tras transferir (= destruir para el origen) el pool: C2.
    let mut f2 = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f2.nodo);
    let a = c.var("a", ty_nodo(&f2, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f2, p));
    f2.p.agregar(c.cuerpo(vec![
        crear(a, f2.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        Stmt::TransferirPool {
            pool: p,
            cuerpo: vec![],
        },
        revalidar(l, Modo::View, n, vec![], vec![]),
    ]));
    rechaza(&f2.p, Regla::C2);
    // IR manipulada: el llamador revalida el enlace devuelto por `fuga`
    // cuando su pool ya no existe.
    let fuga = FuncId(0);
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    let main = f.p.agregar(c.cuerpo(vec![
        llamar(fuga, vec![], vec![], Some(l)),
        revalidar(l, Modo::View, n, vec![], vec![]),
    ]));
    let mut m = Maquina::nueva(&f.p, Config::default());
    let e = m.llamar(main, vec![], vec![]).unwrap_err();
    assert_eq!(e.violacion, Violacion::PoolInexistente, "{e}");
}

/// N14: el enlace nulo (`slot 0, gen 0`) da `Ausente` sin leer cabecera, sin
/// tocar datos y sin modificar el pool.
#[test]
fn n14_enlace_nulo() {
    let mut f = fx();
    let lee = funcion_lee(&mut f);
    let pv = ok(&f.p);
    let mut m = maquina(&pv);
    let pool = m.crear_pool(f.nodo).unwrap();
    let nulo = Valor::Enlace {
        pool,
        slot: 0,
        gener: 0,
    };
    assert_eq!(
        m.llamar(lee, vec![pool], vec![nulo]).unwrap(),
        Some(Valor::Int(-1))
    );
    let met = m.metricas();
    assert_eq!(met.lecturas_gen, 0);
    assert_eq!(
        met.accesos_totales(),
        1,
        "solo la escritura del resultado en la pila"
    );
    assert_eq!(met.accesos_comprobados + met.accesos_congelados, 0);
    assert_eq!(met.superpaginas_reservadas, 0);
    let pl = m.pool(pool).unwrap();
    assert_eq!(
        (pl.vivos, pl.epoca_destruccion, pl.subpaginas_confirmadas()),
        (0, 0, 0)
    );
    assert_eq!(nexo::rt::pool::empaquetar(0, 0), 0);
}

/// N15: reutilización por la ruta ordinaria: mismo slot, gen +2, enlace
/// viejo `Ausente`, enlace nuevo válido; y retirada al agotar la generación.
#[test]
fn n15_reutilizacion_generacional_ordinaria() {
    let mut f = fx();
    let lee = funcion_lee(&mut f);
    let mut g = Constructor::nueva("nace");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let gv = g.param("v", Ty::Int);
    let a = g.var("a", ty_nodo(&f, gp));
    g.retorna(ty_nodo(&f, gp));
    let nace = f.p.agregar(g.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(gp), vec![v(gv), k(0)]),
        retornar(Some(v(a))),
    ]));
    let mut t = Constructor::nueva("tira");
    let tp = t.pool_param("P", f.nodo, PermisoPool::Edit);
    let tx = t.param("x", ty_nodo(&f, tp));
    let tira = f.p.agregar(t.cuerpo(vec![destruir(tx)]));
    let pv = ok(&f.p);

    for gen_inicial in [0u32, GEN_RETIRADO - 2] {
        let mut m = Maquina::nueva(
            &pv.programa,
            Config {
                gen_inicial,
                ..Config::default()
            },
        )
        .con_efectos(pv.efectos.clone());
        let pool = m.crear_pool(f.nodo).unwrap();
        let Some(Valor::Obj(RefObj::Pool {
            slot: s1,
            gener: g1,
            ..
        })) = m.llamar(nace, vec![pool], vec![Valor::Int(1)]).unwrap()
        else {
            panic!()
        };
        let viejo = Valor::Enlace {
            pool,
            slot: s1,
            gener: g1,
        };
        let obj = Valor::Obj(RefObj::Pool {
            pool,
            slot: s1,
            gener: g1,
        });
        m.llamar(tira, vec![pool], vec![obj]).unwrap();
        let Some(Valor::Obj(RefObj::Pool {
            slot: s2,
            gener: g2,
            ..
        })) = m.llamar(nace, vec![pool], vec![Valor::Int(2)]).unwrap()
        else {
            panic!()
        };
        let nuevo = Valor::Enlace {
            pool,
            slot: s2,
            gener: g2,
        };
        assert_eq!(
            m.llamar(lee, vec![pool], vec![viejo]).unwrap(),
            Some(Valor::Int(-1))
        );
        assert_eq!(
            m.llamar(lee, vec![pool], vec![nuevo]).unwrap(),
            Some(Valor::Int(2))
        );
        assert_eq!(g2 & 1, 1);
        if gen_inicial == 0 {
            assert_eq!(
                s2, s1,
                "ruta ordinaria: la lista libre devuelve el mismo slot"
            );
            assert_eq!(g2, g1 + 2);
            assert_eq!(m.metricas().subpaginas_reconfirmadas, 1);
        } else {
            // g1 = 0xFFFF_FFFD: al destruir llega a GEN_RETIRADO y se retira.
            assert_eq!(g1, GEN_RETIRADO - 1);
            assert_ne!(s2, s1, "el slot retirado no se reutiliza");
            assert_eq!(m.metricas().slots_retirados, 1);
            assert_eq!(m.pool(pool).unwrap().gen_de(s1).unwrap(), GEN_RETIRADO);
        }
        m.llamar(
            tira,
            vec![pool],
            vec![Valor::Obj(RefObj::Pool {
                pool,
                slot: s2,
                gener: g2,
            })],
        )
        .unwrap();
        m.pool(pool).unwrap().comprobar_invariantes().unwrap();
    }
}

// ===================================================== D: efectos y revalidación

fn revalidar_y_llamar_puro(modo: Modo) -> Programa {
    let mut f = fx();
    let puro = funcion_lee(&mut f);
    let mut c = Constructor::nueva("usa");
    let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let l = c.param("l", Ty::Enlace(p));
    let otro = c.param("otro", Ty::Enlace(p));
    let n = c.var("n", Ty::Prestamo(modo, f.nodo, Ubic::Pool(p)));
    let x = c.var("x", Ty::Int);
    let y = c.var("y", Ty::Int);
    let z = c.var("z", Ty::Int);
    c.retorna(Ty::Int);
    f.p.agregar(c.cuerpo(vec![
        revalidar(
            l,
            modo,
            n,
            vec![
                leer(x, n, 0),
                llamar(puro, vec![p], vec![v(otro)], Some(z)),
                leer(y, n, 0),
            ],
            vec![],
        ),
        retornar(Some(k(0))),
    ]));
    f.p
}

/// N16: una llamada `puro(P)` dentro de `B` conserva el préstamo; no hay
/// lecturas de generación adicionales por acceso protegido.
#[test]
fn n16_revalidacion_conservada_durante_lectura_pura() {
    let p = revalidar_y_llamar_puro(Modo::View);
    let pv = ok(&p);
    assert_eq!(
        pv.efecto(FuncId(0), 0).nivel,
        nexo::verif::NivelEfecto::Puro
    );
    let mut m = maquina(&pv);
    let pool = m.crear_pool(FxClase::NODO).unwrap();
    // Un objeto y dos enlaces a él (`l` y `otro`).
    let mut ev = nexo::rt::pool::Eventos::default();
    let (s, g) = m.pool_mut(pool).unwrap().asignar(0, &mut ev).unwrap();
    let e = Valor::Enlace {
        pool,
        slot: s,
        gener: g,
    };
    m.llamar(FuncId(1), vec![pool], vec![e, e]).unwrap();
    let met = m.metricas();
    assert_eq!(
        met.lecturas_gen, 2,
        "una por revalidación (usa y lee), ninguna por acceso"
    );
    assert_eq!(met.accesos_comprobados, 3);
    // Con `edit`, una llamada que lee por enlaces del mismo pool podría
    // alcanzar el objeto editado: R7.
    rechaza(&revalidar_y_llamar_puro(Modo::Edit), Regla::R7);
}

/// Índices de clase de `fx()`.
struct FxClase;
impl FxClase {
    const NODO: ClaseId = ClaseId(0);
}

/// N17: `destruye(P)` dentro de `B` se rechaza aunque destruya otro objeto,
/// directamente o por una llamada.
#[test]
fn n17_destruccion_dentro_de_bloque_revalidado() {
    let mut f = fx();
    let mut g = Constructor::nueva("tira");
    let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
    let gx = g.param("x", ty_nodo(&f, gp));
    let tira = f.p.agregar(g.cuerpo(vec![destruir(gx)]));
    for por_llamada in [false, true] {
        let mut f2 = Fx {
            p: f.p.clone(),
            nodo: f.nodo,
            dato: f.dato,
        };
        let mut c = Constructor::nueva("main");
        let p = c.pool_local("P", f2.nodo);
        let a = c.var("a", ty_nodo(&f2, p));
        let otro = c.var("otro", ty_nodo(&f2, p));
        let l = c.var("l", Ty::Enlace(p));
        let n = c.var("n", view_nodo(&f2, p));
        let x = c.var("x", Ty::Int);
        let destr = if por_llamada {
            llamar(tira, vec![p], vec![v(otro)], None)
        } else {
            destruir(otro)
        };
        f2.p.agregar(c.cuerpo(vec![
            crear(a, f2.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
            crear(otro, f2.nodo, Ubic::Pool(p), vec![k(2), k(0)]),
            enlazar(l, a),
            revalidar(l, Modo::View, n, vec![destr, leer(x, n, 0)], vec![]),
        ]));
        rechaza(&f2.p, Regla::R6);
    }
}

/// N18: destrucción diferida. Dentro de `B` la referencia sigue válida aun
/// tras pedir la destrucción del propio objeto; la destrucción ocurre una
/// vez al salir (también en salida anticipada), actualiza la época y una
/// revalidación posterior da `Ausente`.
#[test]
fn n18_destruccion_diferida() {
    for anticipada in [false, true] {
        let mut f = fx();
        let lee = funcion_lee(&mut f);
        let mut c = Constructor::nueva("usa");
        let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
        let l = c.param("l", Ty::Enlace(p));
        let x = c.param("x", ty_nodo(&f, p));
        let n = c.var("n", view_nodo(&f, p));
        let y = c.var("y", Ty::Int);
        let tras = c.var("tras", Ty::Int);
        c.retorna(Ty::Int);
        let mut cuerpo = vec![destruir(x), leer(y, n, 0)];
        if anticipada {
            cuerpo.push(retornar(Some(v(y))));
        }
        let usa = f.p.agregar(c.cuerpo(vec![
            revalidar_diferido(l, Modo::View, n, cuerpo, vec![]),
            llamar(lee, vec![p], vec![v(l)], Some(tras)),
            retornar(Some(v(tras))),
        ]));
        let pv = ok(&f.p);
        let mut m = maquina(&pv);
        let pool = m.crear_pool(f.nodo).unwrap();
        let mut ev = nexo::rt::pool::Eventos::default();
        let (s, g) = m.pool_mut(pool).unwrap().asignar(0, &mut ev).unwrap();
        m.pool_mut(pool)
            .unwrap()
            .escribir(s, g, 0, nexo::rt::pool::Palabra::Int(5))
            .unwrap();
        let enl = Valor::Enlace {
            pool,
            slot: s,
            gener: g,
        };
        let obj = Valor::Obj(RefObj::Pool {
            pool,
            slot: s,
            gener: g,
        });
        let r = m.llamar(usa, vec![pool], vec![enl, obj]).unwrap();
        let met = m.metricas();
        assert_eq!(met.destrucciones_diferidas, 1);
        assert_eq!(
            met.slots_liberados, 1,
            "exactamente una destrucción, tras B"
        );
        assert_eq!(
            m.pool(pool).unwrap().epoca_destruccion,
            1,
            "la época se actualiza al aplicarla"
        );
        assert_eq!(m.pool(pool).unwrap().vivos, 0);
        // Sin salida anticipada, `lee` revalida después: Ausente (-1).
        assert_eq!(r, Some(Valor::Int(if anticipada { 5 } else { -1 })));
    }
}

fn firma_view(f: &Fx, opaca: bool, captura_mutable: bool, permiso: PermisoPool) -> Ty {
    Ty::Funcion(Box::new(Firma {
        pools: vec![(f.nodo, permiso)],
        params: vec![],
        ret: None,
        captura_mutable,
        opaca,
    }))
}

fn indirecta_en_revalidar(f: &mut Fx, cb_ty: Ty) {
    let mut c = Constructor::nueva("usa");
    let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let cb = c.param("cb", cb_ty);
    let l = c.param("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(f, p));
    let x = c.var("x", Ty::Int);
    f.p.agregar(c.cuerpo(vec![revalidar(
        l,
        Modo::View,
        n,
        vec![llamar_ind(cb, vec![p], vec![], None), leer(x, n, 0)],
        vec![],
    )]));
}

/// N19: llamada indirecta de efecto desconocido → `destruye(todos)` →
/// rechazo dentro de `B`. Las anotaciones de entrada no se creen.
#[test]
fn n19_llamada_de_efecto_desconocido() {
    let mut f = fx();
    let t = firma_view(&f, true, false, PermisoPool::View);
    indirecta_en_revalidar(&mut f, t);
    rechaza(&f.p, Regla::R6);

    // Una firma opaca no se "blanquea" copiándola a una firma no opaca.
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let _p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let a = c.param("a", firma_view(&f, true, false, PermisoPool::View));
    let b = c.var("b", firma_view(&f, false, false, PermisoPool::View));
    f.p.agregar(c.cuerpo(vec![copiar(b, a)]));
    rechaza(&f.p, Regla::R1);

    // Anotaciones falsas en la entrada: el verificador las recalcula.
    let mut f = fx();
    let mut c = Constructor::nueva("g");
    let p = c.pool_param("P", f.nodo, PermisoPool::Edit);
    let l = c.param("l", Ty::Enlace(p));
    let o = c.param("o", ty_nodo(&f, p));
    let n = c.var("n", view_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        Stmt::Revalidar {
            enlace: l,
            modo: Modo::View,
            ligado: n,
            cuerpo: vec![],
            ausente: vec![],
            diferir: false,
            nivel: Some(Nivel::Estatico),
        },
        Stmt::Escribir {
            obj: o,
            campo: 1,
            valor: v(l),
            invalida_epoca: Some(false),
        },
        destruir(o),
    ]));
    let pv = ok(&f.p);
    let cuerpo = &pv.programa.funciones[0].cuerpo;
    assert!(matches!(
        cuerpo[0],
        Stmt::Revalidar {
            nivel: Some(Nivel::Comprobado),
            ..
        }
    ));
    assert!(matches!(
        cuerpo[1],
        Stmt::Escribir {
            invalida_epoca: Some(true),
            ..
        }
    ));
}

/// N20: polimorfismo de efectos. Una indirecta sin edit ni capturas
/// mutables está acotada por `crece(P)` y se acepta; con captura mutable o
/// con edit sobre P no. El punto fijo propaga efectos transitivos.
#[test]
fn n20_polimorfismo_de_efectos() {
    let mut f = fx();
    let t = firma_view(&f, false, false, PermisoPool::View);
    indirecta_en_revalidar(&mut f, t);
    // Una implementación real que encaja en la firma, ejecutada de verdad.
    let lee_firma = {
        let mut g = Constructor::nueva("mira");
        let gp = g.pool_param("P", f.nodo, PermisoPool::View);
        let _ = gp;
        f.p.agregar(g.cuerpo(vec![]))
    };
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let cb = c.var("cb", firma_view(&f, false, false, PermisoPool::View));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        Stmt::RefFuncion {
            dst: cb,
            func: lee_firma,
        },
        llamar(FuncId(0), vec![p], vec![v(cb), v(l)], None),
    ]));
    let pv = ok(&f.p);
    assert_eq!(
        pv.efecto(FuncId(0), 0).nivel,
        nexo::verif::NivelEfecto::Crece
    );
    correr(&pv, "main");

    for (captura, permiso) in [(true, PermisoPool::View), (false, PermisoPool::Edit)] {
        let mut f = fx();
        let t = firma_view(&f, false, captura, permiso);
        indirecta_en_revalidar(&mut f, t);
        rechaza(&f.p, Regla::R6);
    }

    // Transitividad: a → b → c, solo c destruye; recursión en d.
    let mut f = fx();
    let ids: Vec<FuncId> = ["a", "b", "c", "d"]
        .iter()
        .map(|n| f.p.declarar(n))
        .collect();
    for (i, nombre) in ["a", "b", "c", "d"].iter().enumerate() {
        let mut g = Constructor::nueva(nombre);
        let gp = g.pool_param("P", f.nodo, PermisoPool::Edit);
        let x = g.var("x", ty_nodo(&f, gp));
        let cuerpo = match i {
            0 | 1 => vec![llamar(ids[i + 1], vec![gp], vec![], None)],
            2 => vec![
                crear(x, f.nodo, Ubic::Pool(gp), vec![k(1), k(0)]),
                destruir(x),
            ],
            _ => vec![
                crear(x, f.nodo, Ubic::Pool(gp), vec![k(1), k(0)]),
                destruir(x),
                si(k(0), vec![llamar(ids[3], vec![gp], vec![], None)], vec![]),
            ],
        };
        f.p.definir(ids[i], g.cuerpo(cuerpo));
    }
    let pv = ok(&f.p);
    for id in &ids {
        assert_eq!(pv.efecto(*id, 0).nivel, nexo::verif::NivelEfecto::Destruye);
    }
}

// ===================================================== E: concurrencia

/// N21: transferencia exclusiva del pool de A (origen) a B (hilo destino).
#[test]
fn n21_transferencia_exclusiva_de_pool() {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", edit_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        Stmt::TransferirPool {
            pool: p,
            cuerpo: vec![
                // B adquiere todas las capacidades: edita, crea y destruye.
                revalidar(l, Modo::Edit, n, vec![escribir(n, 0, k(2))], vec![]),
                crear(b, f.nodo, Ubic::Pool(p), vec![k(3), k(0)]),
            ],
        },
    ]));
    let pv = ok(&f.p);
    let (_, m) = correr(&pv, "main");
    assert_eq!((m.slots_asignados, m.slots_liberados), (2, 2));

    // A no puede usar el pool tras transferirlo (estático) …
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let b = c.var("b", ty_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        Stmt::TransferirPool {
            pool: p,
            cuerpo: vec![],
        },
        crear(b, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
    ]));
    rechaza(&f.p, Regla::C2);
    // … ni en IR manipulada (el pool ya no existe).
    assert_eq!(violacion_bruta(&f.p), Violacion::PoolInexistente);
}

fn congelado_mutado(caso: usize) -> Programa {
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let b = c.var("b", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let x = c.var("x", Ty::Int);
    let mutacion = match caso {
        0 => escribir(a, 0, k(9)),
        1 => destruir(a),
        2 => crear(b, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        _ => Stmt::Reestructurar { pool: p },
    };
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(1), k(0)]),
        enlazar(l, a),
        Stmt::Congelar {
            pool: p,
            cuerpo: vec![leer(x, a, 0), mutacion],
        },
    ]));
    f.p
}

/// N22: pool congelado compartido. Las mutaciones (escribir, liberar,
/// reutilizar slots, reestructurar) se rechazan; el nivel `Congelado` sin
/// congelación real lo detecta el oráculo.
#[test]
fn n22_pool_congelado_compartido() {
    for caso in 0..4 {
        rechaza(&congelado_mutado(caso), Regla::C3);
        assert_eq!(
            violacion_bruta(&congelado_mutado(caso)),
            Violacion::MutacionCongelado
        );
    }
    // Lectura compartida por varios hilos (positivo, ya cubierto en
    // verificador.rs con 2 hilos): aquí 3 hilos y sin lecturas de gen.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let hilos: Vec<Bloque> = (0..3)
        .map(|i| {
            let n = c.var(&format!("n{i}"), view_nodo(&f, p));
            let x = c.var(&format!("x{i}"), Ty::Int);
            vec![revalidar(l, Modo::View, n, vec![leer(x, n, 0)], vec![])]
        })
        .collect();
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(4), k(0)]),
        enlazar(l, a),
        Stmt::Congelar {
            pool: p,
            cuerpo: vec![Stmt::Paralelo { hilos }],
        },
    ]));
    let pv = ok(&f.p);
    for orden in [0, 1, 0x9E37] {
        let cfg = Config {
            orden_hilos: orden,
            ..Config::default()
        };
        let (_, m) = nexo::rt::ejecutar(&pv, "main", cfg).unwrap();
        assert_eq!((m.revalidaciones_congeladas, m.lecturas_gen), (3, 0));
    }
    // IR manipulada: nivel `Congelado` fuera de `congelar`.
    let mut f = fx();
    let mut c = Constructor::nueva("main");
    let p = c.pool_local("P", f.nodo);
    let a = c.var("a", ty_nodo(&f, p));
    let l = c.var("l", Ty::Enlace(p));
    let n = c.var("n", view_nodo(&f, p));
    f.p.agregar(c.cuerpo(vec![
        crear(a, f.nodo, Ubic::Pool(p), vec![k(4), k(0)]),
        enlazar(l, a),
        Stmt::Revalidar {
            enlace: l,
            modo: Modo::View,
            ligado: n,
            cuerpo: vec![],
            ausente: vec![],
            diferir: false,
            nivel: Some(Nivel::Congelado),
        },
        destruir(a),
    ]));
    assert_eq!(violacion_bruta(&f.p), Violacion::NivelIncorrecto);
}
