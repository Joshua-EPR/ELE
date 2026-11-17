//! nexo_prototype_01.rs — Prototipo 0.1 de NEXO demostrando el ciclo de vida seguro de memoria.
//!
//! Utiliza el 100% de las APIs públicas de `nexo::physical`:
//! - Creación de pool físico con configuración tipada (`PhysicalPool::new`).
//! - Asignación lineal segura (`allocate`).
//! - Escritura y lectura tipada (`write_int`, `read_int`).
//! - Revalidación segura de enlaces (`revalidate`).
//! - Destrucción con retención de hueco lineal (`destroy`).
//! - Verificación fail-closed contra accesos obsoletos (`StaleGeneration`).
//! - Reutilización determinista de hueco con avance de generación (`reuse_hole`).
//! - Cierre ordenado y liberación de recursos virtuales del SO (`close`).

use nexo::physical::{DestroyOutcome, PhysicalPool, PoolConfig, PoolError};

fn main() {
    println!("=== NEXO Prototype 0.1: Demostración de Ciclo de Vida de Memoria Física ===");

    // 1. Inicialización del Pool con configuración estándar
    let config = PoolConfig {
        slot_size: 64,
        fields: 4,
        max_superpages: 4,
        ..PoolConfig::default()
    };
    let mut pool = PhysicalPool::new(config).expect("Fallo al crear PhysicalPool");
    let base_addr = pool.base_addr().expect("Fallo al obtener base_addr");
    println!(
        "[1] PhysicalPool inicializado: base={:#x}, capacidad={} slots",
        base_addr,
        pool.capacity()
    );

    // 2. Asignación de primer objeto
    let h1 = pool.allocate().expect("Fallo al asignar h1");
    let slot1 = h1.slot();
    let gen1 = h1.generation();
    let obj1 = h1.obj();
    let link1 = h1.link();
    println!(
        "[2] Asignado Objeto 1: slot={}, generación={}, link={:?}",
        slot1, gen1, link1
    );

    // 3. Escritura y lectura tipada
    pool.write_int(obj1, 0, 1337)
        .expect("Fallo en write_int[0]");
    pool.write_int(obj1, 1, 42).expect("Fallo en write_int[1]");
    let val0 = pool.read_int(obj1, 0).expect("Fallo en read_int[0]");
    let val1 = pool.read_int(obj1, 1).expect("Fallo en read_int[1]");
    println!(
        "[3] Valores escritos y leídos con éxito: campo[0]={}, campo[1]={}",
        val0, val1
    );
    assert_eq!(val0, 1337);
    assert_eq!(val1, 42);

    // 4. Revalidación de enlace no dueño
    let reval_obj = pool.revalidate(link1).expect("Fallo al revalidar link1");
    println!(
        "[4] Enlace revalidado con éxito: slot={}, generación={}",
        reval_obj.slot(),
        reval_obj.generation()
    );
    assert_eq!(reval_obj.slot(), slot1);
    assert_eq!(reval_obj.generation(), gen1);

    // 5. Destrucción con preservación de hueco lineal
    println!("[5] Destruyendo Objeto 1 solicitando retención de hueco...");
    let report = pool
        .destroy(h1, true)
        .unwrap_or_else(|_| panic!("Fallo al destruir h1"));
    let hole = match report.outcome {
        DestroyOutcome::Hole(h) => {
            println!("    Hueco lineal obtenido correctamente: slot={}", h.slot());
            h
        }
        _ => panic!("Se esperaba DestroyOutcome::Hole"),
    };

    // 6. Verificación fail-closed contra acceso obsoleto (stale check)
    println!("[6] Comprobando rechazo fail-closed de referencias obsoletas...");
    match pool.read_int(obj1, 0) {
        Err(PoolError::StaleGeneration) => {
            println!(
                "    Acceso a lectura rechazado correctamente con PoolError::StaleGeneration."
            );
        }
        other => panic!(
            "Se esperaba Err(PoolError::StaleGeneration), se obtuvo: {:?}",
            other
        ),
    }

    match pool.revalidate(link1) {
        Err(PoolError::StaleGeneration) => {
            println!("    Revalidación rechazada correctamente con PoolError::StaleGeneration.");
        }
        other => panic!(
            "Se esperaba Err(PoolError::StaleGeneration), se obtuvo: {:?}",
            other
        ),
    }

    // 7. Reutilización lineal del hueco
    println!("[7] Reutilizando hueco de forma lineal...");
    let h2 = pool
        .reuse_hole(hole)
        .unwrap_or_else(|_| panic!("Fallo al reutilizar hueco"));
    let slot2 = h2.slot();
    let gen2 = h2.generation();
    println!(
        "    Nuevo handle asignado en el mismo slot: slot={}, generación={}",
        slot2, gen2
    );
    assert_eq!(slot2, slot1);
    assert_eq!(gen2, gen1 + 2); // Invariante de avance de generación

    // 8. Uso del nuevo handle
    pool.write_int(h2.obj(), 0, 9999)
        .expect("Fallo en write_int en h2");
    assert_eq!(
        pool.read_int(h2.obj(), 0).expect("Fallo en read_int en h2"),
        9999
    );

    // 9. Liberación definitiva
    pool.destroy(h2, false)
        .unwrap_or_else(|_| panic!("Fallo al destruir h2"));
    println!("[8] Objeto final liberado sin hueco (completamente retirado).");
    assert_eq!(pool.live_count(), 0);

    // 10. Cierre ordenado de pool
    pool.close().expect("Fallo al cerrar pool");
    println!("[9] PhysicalPool cerrado limpiamente y memoria virtual devuelta al SO.");
    println!("=== NEXO Prototype 0.1 completado exitosamente ===");
}
