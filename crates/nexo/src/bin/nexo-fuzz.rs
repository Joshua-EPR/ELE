//! Campañas reproducibles del fuzzer de NEXO.
//!
//! ```text
//! cargo run -p ele-nexo --release --bin nexo-fuzz -- [opciones]
//!   --semilla N        semilla de la campaña aleatoria (por defecto 1)
//!   --casos N          programas aleatorios (por defecto 10000)
//!   --ops N            sentencias máximas por programa (por defecto 12)
//!   --prof N           profundidad máxima de bloques (por defecto 2)
//!   --malformados      a veces ignora la categoría de los operandos
//!   --segundos N       límite de tiempo de la campaña aleatoria
//!   --exhaustivo L     enumera todas las secuencias de L operaciones (24^L × 2)
//!   --pool N           casos del fuzz directo del pool (P3/P7)
//!   --efectos N        grafos de llamadas aleatorios (P8)
//!   --reproducir a,b,… reejecuta un caso a partir de sus elecciones
//! ```
//! Termina con código 1 si alguna propiedad falla.

use std::process::ExitCode;
use std::time::Duration;

use nexo::fuzz::{self, CfgCampana, CfgGen, Fuente, Veredicto};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let valor = |nombre: &str| -> Option<String> {
        args.iter()
            .position(|a| a == nombre)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let num = |nombre: &str, def: u64| -> u64 {
        valor(nombre)
            .map(|v| {
                let v = v.trim_start_matches("0x");
                u64::from_str_radix(
                    v,
                    if valor(nombre).is_some_and(|x| x.starts_with("0x")) {
                        16
                    } else {
                        10
                    },
                )
                .unwrap_or_else(|_| panic!("{nombre}: número inválido"))
            })
            .unwrap_or(def)
    };
    let generador = CfgGen {
        max_ops: num("--ops", 12) as u32,
        max_prof: num("--prof", 2) as u32,
        malformados: args.iter().any(|a| a == "--malformados"),
        ..CfgGen::default()
    };
    let mut fallo = false;

    if let Some(lista) = valor("--reproducir") {
        let eleccion: Vec<u32> = lista
            .split(',')
            .filter(|s| !s.is_empty())
            .map(|s| s.trim().parse().unwrap())
            .collect();
        let semilla = num("--semilla", 1);
        let c = fuzz::caso(Fuente::fija(eleccion), generador, semilla);
        println!("{}", nexo::pretty::programa(&c.programa));
        match c.veredicto {
            Veredicto::Seguro => println!("aceptado y seguro"),
            Veredicto::Rechazado { reglas, inseguro } => {
                println!("rechazado: {reglas:?}; ejecución sin verificar: {inseguro:?}")
            }
            Veredicto::Fallo(f) => {
                println!(
                    "FALLO P1: {}\ntraza:\n  {}\n{}",
                    f.aborto,
                    f.traza.join("\n  "),
                    f.estado
                );
                fallo = true;
            }
        }
        return if fallo {
            ExitCode::FAILURE
        } else {
            ExitCode::SUCCESS
        };
    }

    let semilla = num("--semilla", 1);
    let cfg = CfgCampana {
        semilla,
        casos: num("--casos", 10_000),
        generador,
        limite: valor("--segundos").map(|s| Duration::from_secs(s.parse().unwrap())),
        reducir: true,
    };
    if let Some(l) = valor("--exhaustivo") {
        let l: u32 = l.parse().unwrap();
        println!(
            "== exhaustiva: todas las secuencias de {l} operaciones ({} programas)",
            2 * 24u64.pow(l)
        );
        let inf = fuzz::exhaustiva(l, cfg);
        print!("{inf}");
        fallo |= !inf.fallos.is_empty();
    }
    if cfg.casos > 0 {
        println!(
            "== aleatoria: semilla {semilla:#x}, {} casos, ≤ {} sentencias, profundidad {}{}",
            cfg.casos,
            generador.max_ops,
            generador.max_prof,
            if generador.malformados {
                ", con IR mal tipada"
            } else {
                ""
            }
        );
        let inf = fuzz::campana(cfg);
        print!("{inf}");
        fallo |= !inf.fallos.is_empty();
    }
    let n_pool = num("--pool", 0);
    if n_pool > 0 {
        let mut total = fuzz::InformePool::default();
        for i in 0..n_pool {
            match fuzz::fuzz_pool(fuzz::semilla_caso(semilla, i), 2000) {
                Ok(r) => {
                    total.operaciones += r.operaciones;
                    total.asignaciones += r.asignaciones;
                    total.liberaciones += r.liberaciones;
                    total.huecos += r.huecos;
                    total.retirados += r.retirados;
                    total.devueltas += r.devueltas;
                    total.agotamientos += r.agotamientos;
                    total.sondeos_obsoletos += r.sondeos_obsoletos;
                }
                Err(e) => {
                    println!("FALLO pool: {e}");
                    fallo = true;
                }
            }
        }
        println!("== pool (P3/P7): {n_pool} casos: {total:?}");
    }
    let n_ef = num("--efectos", 0);
    if n_ef > 0 {
        let mut funciones = 0;
        for i in 0..n_ef {
            match fuzz::fuzz_efectos(fuzz::semilla_caso(semilla, i)) {
                Ok(n) => funciones += n,
                Err(e) => {
                    println!("FALLO efectos: {e}");
                    fallo = true;
                }
            }
        }
        println!(
            "== efectos (P8): {n_ef} grafos, {funciones} funciones; punto fijo = cierre transitivo en todos"
        );
    }
    if fallo {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
