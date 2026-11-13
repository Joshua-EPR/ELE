//! Oráculo de seguridad: aborta la ejecución ante cualquier violación de
//! memoria y detecta carreras de datos en regiones concurrentes.

use std::collections::{HashMap, HashSet};
use std::fmt;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Violacion {
    /// Acceso a un slot cuya generación no es la esperada (uso tras liberar).
    GeneracionObsoleta,
    /// Acceso a una subpágina de datos devuelta al SO o nunca confirmada.
    PaginaDevuelta,
    /// Liberación de un slot u objeto ya liberado.
    DobleLiberacion,
    /// Uso de un valor ya consumido.
    UsoTrasConsumo,
    /// Una revalidación anotada `Estatico`/`Congelado` encontró un enlace
    /// obsoleto: el verificador probó algo falso.
    NivelIncorrecto,
    /// Acceso por un préstamo de pool tras una reestructuración del pool.
    PrestamoInvalidado,
    /// Mutación de un pool congelado.
    MutacionCongelado,
    /// Dos hilos de una región concurrente acceden al mismo dato y al menos
    /// uno escribe.
    CarreraDeDatos,
    /// Un trabajador de `dividir` libera un slot de otra partición.
    ParticionAjena,
    /// Al destruir un pool quedan objetos o huecos vivos.
    Fuga,
    /// Uso de un pool ya transferido o destruido.
    PoolInexistente,
    /// Se agotó la reserva virtual del pool.
    AgotamientoVirtual,
    /// Recursión demasiado profunda.
    Desbordamiento,
    /// Valor de tipo inesperado (IR mal formada).
    ValorInvalido,
    /// Slot fuera de la reserva o campo fuera de la clase.
    FueraDeLimites,
    /// Operación sin el permiso necesario: escribir por un `view`, mutar un
    /// pool visto como `view`, usar un enlace como objeto, transferir un pool
    /// prestado.
    PermisoInventado,
    /// Una llamada ejecutó un efecto mayor que el inferido o asumido
    /// estáticamente para ese pool (P4).
    EfectoSubestimado,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Aborto {
    pub violacion: Violacion,
    pub mensaje: String,
}

impl fmt::Display for Aborto {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "aborto[{:?}]: {}", self.violacion, self.mensaje)
    }
}

pub fn abortar<T>(violacion: Violacion, mensaje: impl Into<String>) -> Result<T, Aborto> {
    Err(Aborto {
        violacion,
        mensaje: mensaje.into(),
    })
}

/// Unidad de memoria para la detección de carreras.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Granulo {
    /// Entrada `gen[s]` de la cabecera.
    Gen(usize, u32),
    /// Datos del slot.
    Dato(usize, u32),
    /// Estructuras del asignador (lista libre, buckets) de una partición.
    Meta(usize, usize),
    /// Contador de época de destrucción de una partición.
    Epoca(usize, usize),
    /// Estado de reestructuración del pool.
    Estructura(usize),
    /// Objeto de la pila de datos.
    Pila(u32),
}

#[derive(Default)]
struct Registro {
    lectores: HashSet<u32>,
    escritores: HashSet<u32>,
}

/// Región concurrente estructurada: todos sus hilos son concurrentes entre sí.
#[derive(Default)]
pub struct Region {
    pub hilo: u32,
    accesos: HashMap<Granulo, Registro>,
}

impl Region {
    pub fn registrar(&mut self, g: Granulo, escritura: bool) -> Result<(), Aborto> {
        let h = self.hilo;
        let r = self.accesos.entry(g).or_default();
        let otro_escritor = r.escritores.iter().any(|x| *x != h);
        let otro_lector = r.lectores.iter().any(|x| *x != h);
        if otro_escritor || (escritura && otro_lector) {
            return abortar(
                Violacion::CarreraDeDatos,
                format!(
                    "carrera de datos en {g:?}: el hilo {h} {} y otro hilo {} sin sincronización",
                    if escritura { "escribe" } else { "lee" },
                    if otro_escritor { "escribe" } else { "lee" }
                ),
            );
        }
        if escritura {
            r.escritores.insert(h);
        } else {
            r.lectores.insert(h);
        }
        Ok(())
    }
}
