//! Revisión de la disposición Bi-Slab (modelo abstracto; no es el allocator
//! físico): alineación, capacidad de cabecera, correspondencia slot →
//! subpágina para cada tamaño de clase, bitmaps, agotamiento, devolución y
//! fallos de reserva.

use nexo::rt::Violacion;
use nexo::rt::pool::{
    CABECERA, CABECERA_USADA, Eventos, GEN_RETIRADO, MAX_SLOTS_SUPERPAGINA, MAX_SUPERPAGINAS, Pool,
    SUBPAGINA, SUBPAGINAS_DATOS, SUPERPAGINA,
};

const TAMS: [u32; 9] = [64, 72, 96, 128, 200, 1000, 2048, 3000, 4096];

#[test]
fn cabecera_cabe_en_4_kib() {
    // 960 gen × 4 B + dos grupos de 15 bitmaps × 8 B
    // (libres y huecos reservados) + 15 contadores × 1 B.
    assert_eq!(CABECERA_USADA, 3840 + 120 + 120 + 15);
    const { assert!(CABECERA_USADA <= CABECERA) };
    assert_eq!(SUPERPAGINA, CABECERA + SUBPAGINAS_DATOS as u64 * SUBPAGINA);
    // Con el slot mínimo (64 B) se usan exactamente las 960 generaciones.
    let p = Pool::nuevo(0, 1, 64, 1, 0).unwrap();
    assert_eq!(p.slots_por_superpagina(), MAX_SLOTS_SUPERPAGINA);
}

#[test]
fn correspondencia_slot_subpagina_por_tamano() {
    for tam in TAMS {
        let campos = (tam / 8).min(8) as usize;
        let p = Pool::nuevo(3, campos, tam, 4, 0).unwrap();
        assert_eq!(p.base % SUPERPAGINA, 0, "base alineada a 64 KiB");
        let por_sub = (SUBPAGINA / tam as u64) as u32;
        assert_eq!(p.slots_por_sub, por_sub);
        assert!(
            p.slots_por_superpagina() <= MAX_SLOTS_SUPERPAGINA,
            "tam {tam}"
        );
        let mut anterior_fin = 0u64;
        for s in 0..(p.slots_por_superpagina() * 2) {
            let d = p.direccion(s).unwrap();
            let off = d - p.base;
            let sp = off / SUPERPAGINA;
            let dentro = off % SUPERPAGINA;
            assert!(
                dentro >= CABECERA,
                "tam {tam}, slot {s}: invade la cabecera"
            );
            let sub = (dentro - CABECERA) / SUBPAGINA;
            let en_sub = (dentro - CABECERA) % SUBPAGINA;
            assert!(sub < SUBPAGINAS_DATOS as u64);
            assert!(
                en_sub + tam as u64 <= SUBPAGINA,
                "tam {tam}, slot {s}: cruza subpágina"
            );
            assert_eq!(d % 8, 0, "alineación de 8 B");
            assert_eq!(sp, (s / p.slots_por_superpagina()) as u64);
            assert!(d >= anterior_fin, "solapamiento en el slot {s}");
            anterior_fin = d + tam as u64;
        }
        // Fuera de la reserva: sin dirección (sin desbordamiento).
        assert_eq!(p.direccion(p.slots_por_superpagina() * 4), None);
        assert_eq!(p.direccion(u32::MAX), None);
    }
}

#[test]
fn tamanos_invalidos_y_generacion_inicial_invalida_no_entran_en_panico() {
    for (campos, tam) in [(1, 32), (1, 4097), (9, 64), (600, 4096)] {
        let e = Pool::nuevo(0, campos, tam, 1, 0).err().unwrap();
        assert_eq!(e.violacion, Violacion::ValorInvalido);
    }
    assert!(
        Pool::nuevo(0, 1, 64, 1, 3).is_err(),
        "generación inicial impar"
    );
    assert!(Pool::nuevo(0, 1, 64, 1, GEN_RETIRADO).is_err());
    assert!(
        Pool::nuevo(1 << 16, 1, 64, 1, 0).is_err(),
        "espacio de pools agotado"
    );
    // Reserva fuera de rango: se recorta a MAX_SUPERPAGINAS.
    assert_eq!(
        Pool::nuevo(0, 1, 64, u32::MAX, 0).unwrap().max_superpaginas,
        MAX_SUPERPAGINAS
    );
}

#[test]
fn reserva_agotada_aborta_y_deja_el_pool_consistente() {
    for tam in TAMS {
        let mut ev = Eventos::default();
        let mut p = Pool::nuevo(0, 1, tam, 1, 0).unwrap();
        let n = p.slots_por_superpagina();
        let mut vivos = Vec::new();
        for _ in 0..n {
            vivos.push(p.asignar(0, &mut ev).unwrap());
        }
        let e = p.asignar(0, &mut ev).unwrap_err();
        assert_eq!(e.violacion, Violacion::AgotamientoVirtual, "tam {tam}");
        p.comprobar_invariantes().unwrap();
        // Liberar uno permite volver a asignar en el mismo espacio.
        let (s, g) = vivos.pop().unwrap();
        p.destruir(s, g, false, &mut ev).unwrap();
        let (s2, g2) = p.asignar(0, &mut ev).unwrap();
        assert_eq!((s2, g2), (s, g + 2));
        p.comprobar_invariantes().unwrap();
    }
}

#[test]
fn agotamiento_de_generacion_sin_wraparound() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 4096, 1, GEN_RETIRADO - 4).unwrap();
    // Un slot por subpágina: el mismo slot recorre todas sus generaciones.
    let (s, g) = p.asignar(0, &mut ev).unwrap();
    assert_eq!(g, GEN_RETIRADO - 3);
    p.destruir(s, g, false, &mut ev).unwrap();
    let (s2, g2) = p.asignar(0, &mut ev).unwrap();
    assert_eq!((s2, g2), (s, GEN_RETIRADO - 1));
    // Al destruir llega a GEN_RETIRADO: retirado, nunca 0xFFFF_FFFF ni 0.
    p.destruir(s2, g2, false, &mut ev).unwrap();
    assert_eq!(p.gen_de(s).unwrap(), GEN_RETIRADO);
    assert_eq!(ev.slots_retirados, 1);
    for _ in 0..(SUBPAGINAS_DATOS - 1) {
        let (x, _) = p.asignar(0, &mut ev).unwrap();
        assert_ne!(x, s);
    }
    // Los 15 slots de la superpágina: 1 retirado + 14 vivos → reserva agotada.
    assert_eq!(
        p.asignar(0, &mut ev).unwrap_err().violacion,
        Violacion::AgotamientoVirtual
    );
    p.comprobar_invariantes().unwrap();
}

#[test]
fn bitmaps_y_devolucion_por_subpagina() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 128, 2, 0).unwrap();
    let todos: Vec<(u32, u32)> = (0..p.slots_por_superpagina())
        .map(|_| p.asignar(0, &mut ev).unwrap())
        .collect();
    assert_eq!(p.subpaginas_confirmadas(), SUBPAGINAS_DATOS);
    // Vaciar subpáginas alternas: cada una se devuelve al SO.
    let por_sub = p.slots_por_sub as usize;
    for (i, (s, g)) in todos.iter().enumerate() {
        if (i / por_sub).is_multiple_of(2) {
            p.destruir(*s, *g, false, &mut ev).unwrap();
        }
        p.comprobar_invariantes().unwrap();
    }
    assert_eq!(ev.subpaginas_devueltas, 8);
    assert_eq!(p.subpaginas_confirmadas(), 7);
    let base = p.base;
    // Reasignar reconfirma subpáginas sin mover la base.
    for _ in 0..por_sub {
        p.asignar(0, &mut ev).unwrap();
    }
    assert_eq!(ev.subpaginas_reconfirmadas, 1);
    assert_eq!(p.base, base);
    p.comprobar_invariantes().unwrap();
}

#[test]
fn un_slot_libre_no_otorga_permiso_de_hueco() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 1, 0).unwrap();
    let (s, g) = p.asignar(0, &mut ev).unwrap();

    // Un slot devuelto a la lista libre tiene generación par, pero no es
    // un hueco lineal. Reutilizarlo como hueco corrompería ambos contadores.
    p.destruir(s, g, false, &mut ev).unwrap();
    assert_eq!(
        p.reusar_hueco(s).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    assert_eq!(
        p.liberar_hueco(s, &mut ev).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    p.comprobar_invariantes().unwrap();
    assert_eq!(p.huecos, 0);
    assert_eq!(p.vivos, 0);

    // El camino ordinario continúa funcionando después de los rechazos.
    let (s2, g2) = p.asignar(0, &mut ev).unwrap();
    assert_eq!((s2, g2), (s, g + 2));
    p.comprobar_invariantes().unwrap();
}

#[test]
fn permisos_de_hueco_son_lineales_y_comprobados() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 1, 0).unwrap();
    let (s, g) = p.asignar(0, &mut ev).unwrap();

    p.destruir(s, g, true, &mut ev).unwrap();
    assert_eq!(p.huecos, 1);
    p.comprobar_invariantes().unwrap();

    // Solo el hueco reservado se puede reutilizar exactamente una vez.
    assert_eq!(p.reusar_hueco(s).unwrap(), g + 2);
    assert_eq!(
        p.reusar_hueco(s).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    assert_eq!(
        p.liberar_hueco(s, &mut ev).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    p.comprobar_invariantes().unwrap();

    // El siguiente hueco puede devolverse una sola vez a la lista libre.
    p.destruir(s, g + 2, true, &mut ev).unwrap();
    p.liberar_hueco(s, &mut ev).unwrap();
    assert_eq!(
        p.liberar_hueco(s, &mut ev).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    assert_eq!(
        p.reusar_hueco(u32::MAX).unwrap_err().violacion,
        Violacion::FueraDeLimites
    );
    assert_eq!(
        p.liberar_hueco(u32::MAX, &mut ev).unwrap_err().violacion,
        Violacion::FueraDeLimites
    );
    p.comprobar_invariantes().unwrap();
    assert_eq!(p.huecos, 0);
    assert_eq!(p.vivos, 0);
}

#[test]
fn dividir_rechaza_cantidades_extremas_sin_mutar_el_pool() {
    let mut ev = Eventos::default();
    let mut p = Pool::nuevo(0, 1, 64, 4, 0).unwrap();
    assert_eq!(
        p.dividir(0).unwrap_err().violacion,
        Violacion::ValorInvalido
    );
    assert_eq!(
        p.dividir(u32::MAX).unwrap_err().violacion,
        Violacion::ValorInvalido
    );
    assert_eq!(p.particiones(), 0);
    p.comprobar_invariantes().unwrap();

    p.dividir(2).unwrap();
    assert_eq!(p.particiones(), 2);
    assert_eq!(
        p.dividir(2).unwrap_err().violacion,
        Violacion::PermisoInventado
    );
    assert_eq!(p.particiones(), 2);
    p.unir_particiones();
    assert_eq!(p.particiones(), 0);
    let (_slot, _gen) = p.asignar(0, &mut ev).unwrap();
    p.comprobar_invariantes().unwrap();
}
