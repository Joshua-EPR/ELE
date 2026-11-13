//! Campañas pequeñas y deterministas del fuzzer (las largas se ejecutan con
//! el binario `nexo-fuzz`).

use nexo::fuzz::{self, CfgCampana, CfgGen, Fuente, Veredicto};

fn cfg(semilla: u64, casos: u64, malformados: bool) -> CfgCampana {
    CfgCampana {
        semilla,
        casos,
        generador: CfgGen {
            malformados,
            ..CfgGen::default()
        },
        limite: None,
        reducir: true,
    }
}

#[test]
fn p1_campana_aleatoria_sin_fallos() {
    for semilla in [1u64, 0xC0FFEE] {
        let inf = fuzz::campana(cfg(semilla, 400, false));
        println!("{inf}");
        assert!(inf.fallos.is_empty(), "{inf}");
        assert!(
            inf.aceptados > 20,
            "el generador debe producir programas aceptados: {inf}"
        );
        assert!(inf.rechazados > 20, "y también rechazados: {inf}");
    }
}

#[test]
fn p1_campana_con_ir_mal_tipada() {
    let inf = fuzz::campana(cfg(7, 300, true));
    assert!(inf.fallos.is_empty(), "{inf}");
}

#[test]
fn p1_exhaustiva_dos_operaciones() {
    let inf = fuzz::exhaustiva(2, cfg(0, 0, false));
    println!("{inf}");
    assert_eq!(inf.casos, 2 * 24 * 24);
    assert!(inf.fallos.is_empty(), "{inf}");
}

#[test]
fn p3_p7_pool_directo() {
    for i in 0..40 {
        let r = fuzz::fuzz_pool(fuzz::semilla_caso(3, i), 1500).unwrap_or_else(|e| panic!("{e}"));
        assert!(r.asignaciones > 0);
    }
}

#[test]
fn p8_punto_fijo_igual_al_cierre_transitivo() {
    for i in 0..200 {
        fuzz::fuzz_efectos(fuzz::semilla_caso(8, i)).unwrap_or_else(|e| panic!("{e}"));
    }
}

#[test]
fn reproduccion_exacta_por_elecciones() {
    for i in 0..50 {
        let s = fuzz::semilla_caso(11, i);
        let a = fuzz::caso(Fuente::aleatoria(s), CfgGen::default(), s);
        let b = fuzz::caso(Fuente::fija(a.eleccion.clone()), CfgGen::default(), s);
        assert_eq!(
            nexo::pretty::programa(&a.programa),
            nexo::pretty::programa(&b.programa)
        );
        assert_eq!(a.eleccion, b.eleccion);
    }
}

/// El reductor conserva la propiedad y encoge el caso. Se usa una
/// propiedad artificial ("el programa tiene un `revalidar` dentro de un
/// `paralelo` y se rechaza") porque la campaña real no encontró fallos P1.
#[test]
fn reduccion_conserva_la_propiedad() {
    let tiene = |e: &[u32]| {
        let c = fuzz::caso(Fuente::fija(e.to_vec()), CfgGen::default(), 1);
        let texto = nexo::pretty::programa(&c.programa);
        texto.contains("hilo 0")
            && texto.contains("revalidar")
            && matches!(c.veredicto, Veredicto::Rechazado { .. })
    };
    let semilla = (0..5000)
        .map(|i| fuzz::semilla_caso(5, i))
        .find(|s| tiene(&fuzz::caso(Fuente::aleatoria(*s), CfgGen::default(), 1).eleccion))
        .expect("algún caso con la propiedad");
    let original = fuzz::caso(Fuente::aleatoria(semilla), CfgGen::default(), 1).eleccion;
    let (min, intentos) = fuzz::reducir(&original, tiene, 3000);
    println!(
        "{} → {} elecciones en {intentos} intentos",
        original.len(),
        min.len()
    );
    assert!(tiene(&min));
    assert!(min.len() <= original.len());
    let c = fuzz::caso(Fuente::fija(min), CfgGen::default(), 1);
    println!(
        "{}",
        nexo::pretty::funcion(&c.programa, c.programa.funciones.last().unwrap())
    );
}
