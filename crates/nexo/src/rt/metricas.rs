//! Métricas de acceso y de memoria de la máquina abstracta.

use std::fmt;

use crate::ir::Nivel;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Metricas {
    /// Accesos a datos de objetos (leer/escribir) por nivel del permiso.
    pub accesos_estaticos: u64,
    pub accesos_congelados: u64,
    pub accesos_comprobados: u64,
    /// Desreferencias de enlaces (`revalidar`, por enlace) por nivel.
    pub revalidaciones_estaticas: u64,
    pub revalidaciones_congeladas: u64,
    pub revalidaciones_comprobadas: u64,
    /// Lecturas de `gen[s]` hechas por el programa (no por el oráculo).
    pub lecturas_gen: u64,
    /// Lecturas de `gen[s]` hechas por `sellar`.
    pub lecturas_gen_sellado: u64,
    pub ausentes: u64,
    pub alias_en_lote: u64,
    pub reusos_hueco: u64,
    pub huecos_liberados: u64,
    pub slots_asignados: u64,
    pub slots_liberados: u64,
    pub slots_retirados: u64,
    pub superpaginas_reservadas: u64,
    pub subpaginas_confirmadas: u64,
    pub subpaginas_reconfirmadas: u64,
    pub subpaginas_devueltas: u64,
    pub destrucciones_diferidas: u64,
    pub drop_flags_saltados: u64,
}

impl Metricas {
    pub fn acceso(&mut self, n: Nivel) {
        match n {
            Nivel::Estatico => self.accesos_estaticos = self.accesos_estaticos.saturating_add(1),
            Nivel::Congelado => self.accesos_congelados = self.accesos_congelados.saturating_add(1),
            Nivel::Comprobado => {
                self.accesos_comprobados = self.accesos_comprobados.saturating_add(1)
            }
        }
    }

    pub fn revalidacion(&mut self, n: Nivel) {
        match n {
            Nivel::Estatico => {
                self.revalidaciones_estaticas = self.revalidaciones_estaticas.saturating_add(1)
            }
            Nivel::Congelado => {
                self.revalidaciones_congeladas = self.revalidaciones_congeladas.saturating_add(1)
            }
            Nivel::Comprobado => {
                self.revalidaciones_comprobadas = self.revalidaciones_comprobadas.saturating_add(1)
            }
        }
    }

    pub fn accesos_totales(&self) -> u64 {
        self.accesos_estaticos
            .saturating_add(self.accesos_congelados)
            .saturating_add(self.accesos_comprobados)
    }

    fn pct(x: u64, t: u64) -> f64 {
        if t == 0 {
            0.0
        } else {
            100.0 * x as f64 / t as f64
        }
    }

    pub fn pct_estatico(&self) -> f64 {
        Self::pct(self.accesos_estaticos, self.accesos_totales())
    }

    pub fn pct_congelado(&self) -> f64 {
        Self::pct(self.accesos_congelados, self.accesos_totales())
    }

    pub fn pct_comprobado(&self) -> f64 {
        Self::pct(self.accesos_comprobados, self.accesos_totales())
    }
}

impl fmt::Display for Metricas {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "accesos: {} ({:.1}% estático, {:.1}% congelado, {:.1}% comprobado)",
            self.accesos_totales(),
            self.pct_estatico(),
            self.pct_congelado(),
            self.pct_comprobado()
        )?;
        writeln!(
            f,
            "revalidaciones: {} estáticas, {} congeladas, {} comprobadas; lecturas gen: {} (+{} sellado); ausentes: {}",
            self.revalidaciones_estaticas,
            self.revalidaciones_congeladas,
            self.revalidaciones_comprobadas,
            self.lecturas_gen,
            self.lecturas_gen_sellado,
            self.ausentes
        )?;
        writeln!(
            f,
            "slots: {} asignados, {} liberados, {} retirados; reusos de hueco: {}, huecos liberados: {}",
            self.slots_asignados,
            self.slots_liberados,
            self.slots_retirados,
            self.reusos_hueco,
            self.huecos_liberados
        )?;
        write!(
            f,
            "páginas: {} superpáginas reservadas; subpáginas {} confirmadas, {} reconfirmadas, {} devueltas al SO",
            self.superpaginas_reservadas,
            self.subpaginas_confirmadas,
            self.subpaginas_reconfirmadas,
            self.subpaginas_devueltas
        )
    }
}
