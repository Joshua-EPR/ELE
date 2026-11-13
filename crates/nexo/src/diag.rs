//! Diagnósticos del verificador estático: cada error nombra la regla violada.

use std::fmt;

/// Reglas estáticas de NEXO v0.2.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub enum Regla {
    /// Tipos, ámbitos, definición única y permisos de pool.
    R1,
    /// Enlazabilidad: solo clases `enlazar` viven en pools; tamaño de slot.
    R2,
    /// Un enlace solo se desreferencia mediante `revalidar`.
    R3,
    /// Un `Enlace<P>` no sobrevive a su pool `P`.
    R4,
    /// Ningún préstamo escapa a una raíz que viva más que él.
    R5,
    /// Ningún `revalidar l en B` (ni `si_sellado`) contiene `destruye(P)`,
    /// salvo destrucciones diferidas.
    R6,
    /// Exclusividad de `edit` y no-alias entre préstamos.
    R7,
    /// Linealidad de `dueño`: exactamente un consumo por camino.
    R8,
    /// `hueco<P, s>`: lineal, del mismo pool y confinado a su bloque básico.
    R9,
    /// Pools locales al hilo.
    C1,
    /// Transferencia de pool sin enlaces vivos en el hilo origen.
    C2,
    /// `congelar(P)`: solo lectura.
    C3,
    /// Capturas de hilos sin alias mutable.
    C4,
    /// `dividir`: cada trabajador muta solo su partición.
    C5,
    /// `dividir(edit P, N)`: permiso exclusivo y particiones válidas.
    C6,
}

impl Regla {
    pub fn descripcion(self) -> &'static str {
        match self {
            Regla::R1 => "tipos, ámbitos y permisos",
            Regla::R2 => "enlazabilidad",
            Regla::R3 => "acceso por enlace solo tras revalidar",
            Regla::R4 => "un enlace no sobrevive a su pool",
            Regla::R5 => "no-escape de préstamos",
            Regla::R6 => "sin destruye(P) dentro de revalidar/sellado",
            Regla::R7 => "exclusividad de edit",
            Regla::R8 => "linealidad de dueño",
            Regla::R9 => "hueco lineal confinado al bloque básico",
            Regla::C1 => "pools locales al hilo",
            Regla::C2 => "transferencia sin enlaces vivos",
            Regla::C3 => "congelar(P) es solo lectura",
            Regla::C4 => "capturas de hilos sin alias mutable",
            Regla::C5 => "dividir: mutación solo en la partición propia",
            Regla::C6 => "dividir requiere edit exclusivo de P",
        }
    }
}

impl fmt::Display for Regla {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

/// Error estático con la regla violada, la función y la ruta de la sentencia
/// (por ejemplo `cuerpo[2].entonces[0]`).
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct Diagnostico {
    pub regla: Regla,
    pub funcion: String,
    pub ruta: String,
    pub mensaje: String,
}

impl fmt::Display for Diagnostico {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "error[{}] ({}) en `{}` @ {}: {}",
            self.regla,
            self.regla.descripcion(),
            self.funcion,
            self.ruta,
            self.mensaje
        )
    }
}

/// Acumulador de diagnósticos sin duplicados, en orden de emisión.
#[derive(Default, Debug)]
pub struct Diags {
    pub lista: Vec<Diagnostico>,
}

impl Diags {
    pub fn emitir(&mut self, regla: Regla, funcion: &str, ruta: &str, mensaje: String) {
        let d = Diagnostico {
            regla,
            funcion: funcion.to_string(),
            ruta: ruta.to_string(),
            mensaje,
        };
        if !self.lista.contains(&d) {
            self.lista.push(d);
        }
    }

    pub fn vacio(&self) -> bool {
        self.lista.is_empty()
    }
}

/// Ruta jerárquica de una sentencia dentro de una función.
#[derive(Clone, Debug, Default)]
pub struct Ruta(Vec<(String, usize)>);

impl Ruta {
    pub fn raiz() -> Self {
        Ruta(Vec::new())
    }

    pub fn hijo(&self, bloque: &str, i: usize) -> Ruta {
        let mut r = self.clone();
        r.0.push((bloque.to_string(), i));
        r
    }

    pub fn texto(&self) -> String {
        if self.0.is_empty() {
            return "<función>".to_string();
        }
        self.0
            .iter()
            .map(|(b, i)| format!("{b}[{i}]"))
            .collect::<Vec<_>>()
            .join(".")
    }
}

/// Nombres de los bloques anidados de una sentencia, en el orden de
/// [`crate::ir::Stmt::bloques`].
pub fn nombres_bloques(s: &crate::ir::Stmt) -> Vec<String> {
    use crate::ir::Stmt;
    match s {
        Stmt::Revalidar { .. } | Stmt::RevalidarLote { .. } => {
            vec!["cuerpo".into(), "ausente".into()]
        }
        Stmt::SiSellado { .. } => vec!["cuerpo".into(), "sino".into()],
        Stmt::Si { .. } => vec!["entonces".into(), "sino".into()],
        Stmt::Paralelo { hilos } => (0..hilos.len()).map(|i| format!("hilo{i}")).collect(),
        _ => vec!["cuerpo".into()],
    }
}
