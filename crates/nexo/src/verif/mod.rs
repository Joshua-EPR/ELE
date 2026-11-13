//! Verificador estático de NEXO v0.2.
//!
//! Pases, en orden:
//! 1. [`tipos`]: R1–R5 (si falla, se detiene: los demás suponen tipos bien formados).
//! 2. [`huecos`]: forma `hueco<P, s>` para destruir+crear en un mismo bloque básico.
//! 3. [`lineal`]: R8/R9 y elaboración (destrucciones implícitas, drop flags,
//!    liberación de huecos no reutilizados).
//! 4. [`efectos`]: efectos por pool (punto fijo) y validez de enlaces; anota
//!    niveles de revalidación.
//! 5. [`prestamos`]: R6, R7 y C1–C6.

pub mod efectos;
pub mod huecos;
pub mod lineal;
pub mod prestamos;
pub mod tipos;

use crate::diag::{Diagnostico, Diags};
use crate::ir::{FuncId, Programa};

pub use efectos::{EfectoPool, NivelEfecto, Resumen};
pub use lineal::Elaboracion;

/// Programa aceptado: elaborado (drops, flags, huecos) y anotado (niveles).
#[derive(Clone, Debug)]
pub struct ProgramaVerificado {
    pub programa: Programa,
    /// Efectos inferidos por función y pool parámetro.
    pub efectos: Vec<Resumen>,
    pub elaboracion: Elaboracion,
    pub huecos_formados: usize,
}

impl ProgramaVerificado {
    /// Efecto inferido de `f` sobre su pool parámetro `i`.
    pub fn efecto(&self, f: FuncId, i: usize) -> EfectoPool {
        self.efectos[f.0 as usize][i]
    }

    /// Informe legible de los efectos inferidos.
    pub fn informe_efectos(&self) -> String {
        let mut s = String::new();
        for (f, res) in self.programa.funciones.iter().zip(&self.efectos) {
            let partes: Vec<String> = res
                .iter()
                .enumerate()
                .map(|(i, e)| format!("{}: {e}", f.pools[i].nombre))
                .collect();
            s.push_str(&format!("{}: {{{}}}\n", f.nombre, partes.join(", ")));
        }
        s
    }
}

/// Verifica un programa. Devuelve el programa elaborado o todos los
/// diagnósticos de la primera fase que falla.
pub fn verificar(p: &Programa) -> Result<ProgramaVerificado, Vec<Diagnostico>> {
    let mut d = Diags::default();
    tipos::verificar(p, &mut d);
    if !d.vacio() {
        return Err(d.lista);
    }
    let mut prog = p.clone();
    let huecos_formados = huecos::formar(&mut prog);
    let elaboracion = lineal::elaborar(&mut prog, &mut d);
    if !d.vacio() {
        return Err(d.lista);
    }
    let efectos = efectos::analizar(&mut prog);
    prestamos::verificar(&prog, &efectos, &mut d);
    if !d.vacio() {
        return Err(d.lista);
    }
    Ok(ProgramaVerificado {
        programa: prog,
        efectos,
        elaboracion,
        huecos_formados,
    })
}
