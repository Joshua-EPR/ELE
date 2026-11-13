//! Pool generacional Bi-Slab (modelo abstracto).
//!
//! * Reserva virtual fija: `base` no cambia nunca; las superpáginas se
//!   reservan dentro de `[base, base + max_superpaginas · 64 KiB)`.
//! * Superpágina de 64 KiB alineada a 64 KiB:
//!   - cabecera de 4 KiB: `gen[s]: u32` para cada slot (≤ 960 slots, 3840 B),
//!     seguida de los 15 bitmaps de slots libres (`u64`, 120 B) y los
//!     contadores de ocupación (15 B). La cabecera nunca se devuelve al SO.
//!   - 15 subpáginas físicas de datos de 4 KiB; ningún slot cruza subpáginas.
//! * `gen[s]`: bit bajo 1 = vivo, 0 = libre; `0xFFFF_FFFE` = retirado por
//!   agotamiento de generación (nunca se reutiliza; no hay *wraparound*).
//! * Lista libre intrusiva en la cabecera: bitmap por subpágina más un índice
//!   jerárquico por densidad (`buckets[k]` = subpáginas con `k` slots libres,
//!   resumen de 64 bits); se elige con `tzcnt` la subpágina más densa con
//!   hueco, para vaciar antes las casi vacías.
//! * Una subpágina con 0 slots ocupados se devuelve al SO (`MADV_DONTNEED` /
//!   `MEM_DECOMMIT`); la cabecera de generaciones permanece.
//!
//! Esto es una **simulación**: la "devolución al SO" descarta el vector de
//! datos y marca la subpágina `Devuelta`; no se llama a `madvise` ni a
//! `VirtualFree`. El allocator físico real es trabajo de la Etapa 4.

use std::collections::BTreeSet;

use super::oraculo::{Aborto, Violacion, abortar};

pub const SUPERPAGINA: u64 = 64 * 1024;
pub const CABECERA: u64 = 4096;
pub const SUBPAGINA: u64 = 4096;
pub const SUBPAGINAS_DATOS: usize = 15;
pub const GEN_RETIRADO: u32 = 0xFFFF_FFFE;
/// Máximo de generaciones que caben en la cabecera junto a los bitmaps.
pub const MAX_SLOTS_SUPERPAGINA: u32 = 960;
/// Bytes de cabecera: generaciones, bitmaps libres, bitmaps de huecos
/// reservados y contadores; incluso la clase de 64 B cabe en 4 KiB.
pub const CABECERA_USADA: u64 = MAX_SLOTS_SUPERPAGINA as u64 * 4
    + SUBPAGINAS_DATOS as u64 * 8 * 2
    + SUBPAGINAS_DATOS as u64;
/// Superpáginas máximas por pool (el índice por densidad usa 64 × 64 bits).
pub const MAX_SUPERPAGINAS: u32 = 64 * 64 / SUBPAGINAS_DATOS as u32;
/// Pools simultáneos direccionables en el espacio virtual simulado.
pub const MAX_POOLS: usize = 1 << 16;
/// Base del espacio virtual simulado.
const BASE_VIRTUAL: u64 = 0x1000_0000_0000;
/// Separación entre reservas de pools (4 GiB ≫ 273 × 64 KiB).
const ZANCADA_POOL: u64 = 1 << 32;

const _: () = assert!(CABECERA_USADA <= CABECERA);
const _: () = assert!(MAX_SUPERPAGINAS as u64 * SUPERPAGINA <= ZANCADA_POOL);

/// Palabra de 8 bytes almacenada en un campo.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Palabra {
    Int(i64),
    Enlace { slot: u32, gener: u32 },
}

/// Enlace empaquetado en 64 bits (`slot` bajo, generación alta). El enlace
/// nulo es `0`.
pub fn empaquetar(slot: u32, gener: u32) -> u64 {
    (slot as u64) | ((gener as u64) << 32)
}

pub fn desempaquetar(e: u64) -> (u32, u32) {
    (e as u32, (e >> 32) as u32)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EstadoSub {
    /// Reservada (`PROT_NONE` / `MEM_RESERVE`) y nunca confirmada.
    Reservada,
    Confirmada,
    /// Devuelta al SO tras vaciarse.
    Devuelta,
}

struct Superpagina {
    gens: Vec<u32>,
    libres: [u64; SUBPAGINAS_DATOS],
    /// Reserva explícita de huecos lineales: distingue un slot realmente
    /// reservado de un slot simplemente libre (ambos tienen generación par).
    huecos_reservados: [u64; SUBPAGINAS_DATOS],
    /// Slots vivos + huecos pendientes por subpágina.
    ocupados: [u8; SUBPAGINAS_DATOS],
    estado: [EstadoSub; SUBPAGINAS_DATOS],
    datos: [Option<Vec<Palabra>>; SUBPAGINAS_DATOS],
    /// Asignador (0 = principal, k = partición k de `dividir`).
    asignador: usize,
}

/// Índice por densidad de un asignador.
struct Asignador {
    /// `buckets[k]`: bitset de subpáginas globales con exactamente `k` libres
    /// (1 ≤ k < slots_por_sub).
    buckets: Vec<Vec<u64>>,
    /// Bit `k` = `buckets[k]` no vacío.
    resumen: u64,
    /// Subpáginas con todos sus slots libres (confirmadas o no).
    vacias: BTreeSet<u32>,
    /// Superpáginas aún sin reservar disponibles para este asignador.
    sin_reservar: BTreeSet<u32>,
    /// Superpáginas reservadas por este asignador.
    reservadas: Vec<u32>,
    epoca: u64,
}

impl Asignador {
    fn nuevo(palabras: usize, sin_reservar: BTreeSet<u32>) -> Self {
        Asignador {
            buckets: (0..65).map(|_| vec![0u64; palabras]).collect(),
            resumen: 0,
            vacias: BTreeSet::new(),
            sin_reservar,
            reservadas: Vec::new(),
            epoca: 0,
        }
    }

    fn quitar(&mut self, g: u32, libres: u32, total: u32) {
        if libres == 0 {
            return;
        }
        if libres == total {
            self.vacias.remove(&g);
            return;
        }
        let k = libres as usize;
        self.buckets[k][(g / 64) as usize] &= !(1u64 << (g % 64));
        if self.buckets[k].iter().all(|w| *w == 0) {
            self.resumen &= !(1u64 << k);
        }
    }

    fn poner(&mut self, g: u32, libres: u32, total: u32) {
        if libres == 0 {
            return;
        }
        if libres == total {
            self.vacias.insert(g);
            return;
        }
        let k = libres as usize;
        self.buckets[k][(g / 64) as usize] |= 1u64 << (g % 64);
        self.resumen |= 1u64 << k;
    }

    fn contiene(&self, g: u32, libres: u32, total: u32) -> bool {
        if libres == 0 {
            return false;
        }
        if libres == total {
            return self.vacias.contains(&g);
        }
        self.buckets[libres as usize][(g / 64) as usize] & (1u64 << (g % 64)) != 0
    }

    /// Subpágina más densa con algún slot libre (`tzcnt` en dos niveles).
    fn mas_densa(&self) -> Option<u32> {
        if self.resumen == 0 {
            return None;
        }
        let k = self.resumen.trailing_zeros() as usize;
        for (i, w) in self.buckets[k].iter().enumerate() {
            if *w != 0 {
                return Some(i as u32 * 64 + w.trailing_zeros());
            }
        }
        None
    }
}

/// Resultado de destruir un slot.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Destruido {
    /// Slot devuelto a la lista libre (o retenido como hueco).
    Libre,
    /// La generación se agotó: slot retirado para siempre.
    Retirado,
}

/// Contadores de actividad del pool (oráculo de efectos, P4).
#[derive(Default, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Contadores {
    pub asignaciones: u64,
    pub destrucciones: u64,
    pub invalidaciones_epoca: u64,
    pub reestructuras: u64,
    pub revalidaciones_view: u64,
    pub revalidaciones_edit: u64,
}

pub struct Pool {
    pub id: usize,
    pub campos: usize,
    pub tam_slot: u32,
    pub slots_por_sub: u32,
    pub base: u64,
    pub max_superpaginas: u32,
    pub gen_inicial: u32,
    sps: Vec<Option<Superpagina>>,
    asignadores: Vec<Asignador>,
    /// Incrementa solo con `destruye(P)`.
    pub epoca_destruccion: u64,
    pub epoca_reestructura: u64,
    pub congelado: u32,
    pub vivos: u64,
    pub huecos: u64,
    pub cont: Contadores,
}

/// Contadores de memoria que el pool devuelve a la máquina.
#[derive(Default, Debug, Clone, Copy)]
pub struct Eventos {
    pub superpaginas_reservadas: u64,
    pub subpaginas_confirmadas: u64,
    pub subpaginas_reconfirmadas: u64,
    pub subpaginas_devueltas: u64,
    pub slots_retirados: u64,
}

impl Pool {
    /// Crea un pool. Falla (sin pánico) con tamaños de slot fuera de
    /// `[64, 4096]`, generación inicial impar o ≥ `GEN_RETIRADO`, o si se
    /// agota el espacio virtual de pools.
    pub fn nuevo(
        id: usize,
        campos: usize,
        tam_slot: u32,
        max_superpaginas: u32,
        gen_inicial: u32,
    ) -> Result<Pool, Aborto> {
        if !(crate::ir::TAM_SLOT_MIN..=SUBPAGINA as u32).contains(&tam_slot)
            || (campos as u64) * 8 > tam_slot as u64
        {
            return abortar(
                Violacion::ValorInvalido,
                format!("pool {id}: slot de {tam_slot} B para {campos} campos fuera de [64, 4096]"),
            );
        }
        if gen_inicial & 1 == 1 || gen_inicial >= GEN_RETIRADO {
            return abortar(
                Violacion::ValorInvalido,
                format!(
                    "generación inicial {gen_inicial:#x} inválida (debe ser par y < GEN_RETIRADO)"
                ),
            );
        }
        if id >= MAX_POOLS {
            return abortar(
                Violacion::AgotamientoVirtual,
                format!("espacio virtual de pools agotado ({MAX_POOLS})"),
            );
        }
        let max = max_superpaginas.clamp(1, MAX_SUPERPAGINAS);
        let slots_por_sub = (SUBPAGINA / tam_slot as u64) as u32;
        debug_assert!(slots_por_sub * SUBPAGINAS_DATOS as u32 <= MAX_SLOTS_SUPERPAGINA);
        let palabras = (max as usize * SUBPAGINAS_DATOS).div_ceil(64);
        Ok(Pool {
            id,
            campos,
            tam_slot,
            slots_por_sub,
            base: BASE_VIRTUAL + id as u64 * ZANCADA_POOL,
            max_superpaginas: max,
            gen_inicial,
            sps: (0..max).map(|_| None).collect(),
            asignadores: vec![Asignador::nuevo(palabras, (0..max).collect())],
            epoca_destruccion: 0,
            epoca_reestructura: 0,
            congelado: 0,
            vivos: 0,
            huecos: 0,
            cont: Contadores::default(),
        })
    }

    pub fn slots_por_superpagina(&self) -> u32 {
        self.slots_por_sub * SUBPAGINAS_DATOS as u32
    }

    /// Slots direccionables por la reserva completa.
    pub fn capacidad(&self) -> u64 {
        self.max_superpaginas as u64 * self.slots_por_superpagina() as u64
    }

    fn ubicar(&self, s: u32) -> (usize, usize, usize) {
        let sps = self.slots_por_superpagina();
        let sp = (s / sps) as usize;
        let resto = s % sps;
        (
            sp,
            (resto / self.slots_por_sub) as usize,
            (resto % self.slots_por_sub) as usize,
        )
    }

    /// Dirección virtual del slot: estable durante toda la vida del pool.
    /// `None` si el slot cae fuera de la reserva (sin desbordamiento).
    pub fn direccion(&self, s: u32) -> Option<u64> {
        if s as u64 >= self.capacidad() {
            return None;
        }
        let (sp, j, k) = self.ubicar(s);
        let off = (sp as u64)
            .checked_mul(SUPERPAGINA)?
            .checked_add(CABECERA)?
            .checked_add(j as u64 * SUBPAGINA)?
            .checked_add(k as u64 * self.tam_slot as u64)?;
        debug_assert!(k as u64 * self.tam_slot as u64 + self.tam_slot as u64 <= SUBPAGINA);
        self.base.checked_add(off)
    }

    fn sp(&self, s: u32) -> Result<&Superpagina, Aborto> {
        let (sp, _, _) = self.ubicar(s);
        match self.sps.get(sp).and_then(|x| x.as_ref()) {
            Some(x) => Ok(x),
            None => abortar(
                Violacion::PaginaDevuelta,
                format!(
                    "slot {s} del pool {} en una superpágina no reservada",
                    self.id
                ),
            ),
        }
    }

    /// Lee `gen[s]` de la cabecera (nunca toca la subpágina de datos).
    pub fn gen_de(&self, s: u32) -> Result<u32, Aborto> {
        let (_, j, k) = self.ubicar(s);
        Ok(self.sp(s)?.gens[j * self.slots_por_sub as usize + k])
    }

    pub fn estado_subpagina(&self, s: u32) -> Option<EstadoSub> {
        let (sp, j, _) = self.ubicar(s);
        self.sps.get(sp)?.as_ref().map(|x| x.estado[j])
    }

    fn total_sub(&self) -> u32 {
        self.slots_por_sub
    }

    fn reservar_superpagina(&mut self, a: usize, ev: &mut Eventos) -> Result<(), Aborto> {
        let Some(sp) = self.asignadores[a].sin_reservar.pop_first() else {
            return abortar(
                Violacion::AgotamientoVirtual,
                format!(
                    "pool {}: agotada la reserva virtual de {} superpáginas{}",
                    self.id,
                    self.max_superpaginas,
                    if a > 0 { " de la partición" } else { "" }
                ),
            );
        };
        let n = self.slots_por_superpagina() as usize;
        let total = self.total_sub();
        self.sps[sp as usize] = Some(Superpagina {
            gens: vec![self.gen_inicial; n],
            libres: [if total == 64 {
                u64::MAX
            } else {
                (1u64 << total) - 1
            }; SUBPAGINAS_DATOS],
            huecos_reservados: [0; SUBPAGINAS_DATOS],
            ocupados: [0; SUBPAGINAS_DATOS],
            estado: [EstadoSub::Reservada; SUBPAGINAS_DATOS],
            datos: std::array::from_fn(|_| None),
            asignador: a,
        });
        for j in 0..SUBPAGINAS_DATOS {
            self.asignadores[a]
                .vacias
                .insert(sp * SUBPAGINAS_DATOS as u32 + j as u32);
        }
        self.asignadores[a].reservadas.push(sp);
        ev.superpaginas_reservadas += 1;
        Ok(())
    }

    /// Aloja un slot desde el asignador `a`. Devuelve `(slot, gener)`.
    pub fn asignar(&mut self, a: usize, ev: &mut Eventos) -> Result<(u32, u32), Aborto> {
        if a >= self.asignadores.len() {
            return abortar(
                Violacion::ParticionAjena,
                format!("pool {}: la partición {a} ya no existe", self.id),
            );
        }
        let g = match self.asignadores[a].mas_densa() {
            Some(g) => g,
            None => {
                if self.asignadores[a].vacias.is_empty() {
                    self.reservar_superpagina(a, ev)?;
                }
                *self.asignadores[a]
                    .vacias
                    .first()
                    .expect("subpágina vacía disponible")
            }
        };
        let total = self.total_sub();
        let sp = (g / SUBPAGINAS_DATOS as u32) as usize;
        let j = (g % SUBPAGINAS_DATOS as u32) as usize;
        let spg = self.sps[sp].as_mut().expect("superpágina reservada");
        let libres_antes = spg.libres[j].count_ones();
        match spg.estado[j] {
            EstadoSub::Confirmada => {}
            antes => {
                spg.datos[j] = Some(vec![Palabra::Int(0); total as usize * self.campos]);
                spg.estado[j] = EstadoSub::Confirmada;
                if antes == EstadoSub::Devuelta {
                    ev.subpaginas_reconfirmadas += 1;
                } else {
                    ev.subpaginas_confirmadas += 1;
                }
            }
        }
        let k = spg.libres[j].trailing_zeros() as usize;
        let idx = j * total as usize + k;
        let actual = spg.gens[idx];
        if actual & 1 == 1 || actual >= GEN_RETIRADO {
            return abortar(
                Violacion::ValorInvalido,
                format!("bitmap corrupto: slot libre con generación {actual:#x}"),
            );
        }
        spg.libres[j] &= !(1u64 << k);
        spg.ocupados[j] += 1;
        spg.gens[idx] = actual + 1;
        let gener = actual + 1;
        let libres_despues = spg.libres[j].count_ones();
        self.asignadores[a].quitar(g, libres_antes, total);
        self.asignadores[a].poner(g, libres_despues, total);
        self.vivos += 1;
        self.cont.asignaciones += 1;
        let slot = sp as u32 * self.slots_por_superpagina() + idx as u32;
        Ok((slot, gener))
    }

    /// Comprueba que `(s, gener)` sigue vivo. Al liberar, un slot ya liberado
    /// con esa misma generación es una doble liberación; en un acceso es un
    /// uso tras liberar.
    fn comprobar_vivo(&self, s: u32, gener: u32, liberando: bool) -> Result<(), Aborto> {
        let que = if liberando {
            "destruir"
        } else {
            "acceso a datos"
        };
        if s as u64 >= self.capacidad() {
            return abortar(
                Violacion::FueraDeLimites,
                format!("{que}: slot {s} fuera de la reserva del pool {}", self.id),
            );
        }
        let actual = self.gen_de(s)?;
        if actual == gener && gener & 1 == 1 {
            return Ok(());
        }
        if liberando && actual & 1 == 0 && actual.wrapping_sub(1) == gener {
            return abortar(
                Violacion::DobleLiberacion,
                format!(
                    "{que}: el slot {s} del pool {} ya está libre (gen {actual})",
                    self.id
                ),
            );
        }
        abortar(
            Violacion::GeneracionObsoleta,
            format!(
                "{que}: slot {s} del pool {} con gen {actual}, se esperaba {gener} (uso tras liberar)",
                self.id
            ),
        )
    }

    /// Asignador al que pertenece el slot.
    pub fn asignador_de(&self, s: u32) -> Result<usize, Aborto> {
        Ok(self.sp(s)?.asignador)
    }

    /// `gen[s] += 1` (par). Si `hueco`, el slot queda reservado para un
    /// `reusar_hueco`; si no, vuelve a la lista libre.
    pub fn destruir(
        &mut self,
        s: u32,
        gener: u32,
        hueco: bool,
        ev: &mut Eventos,
    ) -> Result<Destruido, Aborto> {
        self.comprobar_vivo(s, gener, true)?;
        let (sp, j, k) = self.ubicar(s);
        let total = self.total_sub();
        let spg = self.sps[sp].as_mut().expect("superpágina");
        let idx = j * total as usize + k;
        // gener es impar y < GEN_RETIRADO: +1 no desborda.
        let nueva = spg.gens[idx] + 1;
        spg.gens[idx] = nueva;
        self.vivos -= 1;
        self.cont.destrucciones += 1;
        if nueva == GEN_RETIRADO {
            ev.slots_retirados += 1;
            self.soltar_ocupado(sp, j, ev);
            return Ok(Destruido::Retirado);
        }
        if hueco {
            self.sps[sp]
                .as_mut()
                .expect("superpágina")
                .huecos_reservados[j] |= 1u64 << k;
            self.huecos += 1;
        } else {
            self.devolver_a_libres(sp, j, k, ev);
        }
        Ok(Destruido::Libre)
    }

    fn devolver_a_libres(&mut self, sp: usize, j: usize, k: usize, ev: &mut Eventos) {
        let total = self.total_sub();
        let g = sp as u32 * SUBPAGINAS_DATOS as u32 + j as u32;
        let spg = self.sps[sp].as_mut().expect("superpágina");
        let a = spg.asignador;
        let antes = spg.libres[j].count_ones();
        spg.libres[j] |= 1u64 << k;
        let despues = spg.libres[j].count_ones();
        self.asignadores[a].quitar(g, antes, total);
        self.asignadores[a].poner(g, despues, total);
        self.soltar_ocupado(sp, j, ev);
    }

    /// Resta un ocupado y devuelve la subpágina al SO si queda vacía.
    fn soltar_ocupado(&mut self, sp: usize, j: usize, ev: &mut Eventos) {
        let spg = self.sps[sp].as_mut().expect("superpágina");
        spg.ocupados[j] -= 1;
        if spg.ocupados[j] == 0 && spg.estado[j] == EstadoSub::Confirmada {
            spg.datos[j] = None;
            spg.estado[j] = EstadoSub::Devuelta;
            ev.subpaginas_devueltas += 1;
        }
    }

    /// Consume exclusivamente un hueco reservado. Un slot libre ordinario
    /// tiene también generación par, pero NO concede permiso de reutilización.
    pub fn reusar_hueco(&mut self, s: u32) -> Result<u32, Aborto> {
        if s as u64 >= self.capacidad() {
            return abortar(Violacion::FueraDeLimites, format!("hueco {s} fuera de la reserva"));
        }
        let (sp, j, k) = self.ubicar(s);
        let total = self.total_sub();
        let campos = self.campos;
        let Some(spg) = self.sps.get_mut(sp).and_then(|x| x.as_mut()) else {
            return abortar(
                Violacion::PaginaDevuelta,
                format!("hueco {s} sin superpágina"),
            );
        };
        let marca = 1u64 << k;
        if spg.huecos_reservados[j] & marca == 0 {
            return abortar(
                Violacion::PermisoInventado,
                format!("slot {s} sin permiso de hueco reservado"),
            );
        }
        let idx = j * total as usize + k;
        if spg.gens[idx] & 1 == 1 || spg.gens[idx] >= GEN_RETIRADO {
            return abortar(
                Violacion::DobleLiberacion,
                format!("hueco {s} ya reutilizado o retirado"),
            );
        }
        // A valid hueco keeps the data subpage committed until consumed.
        if spg.estado[j] != EstadoSub::Confirmada || spg.datos[j].is_none() {
            return abortar(
                Violacion::PaginaDevuelta,
                format!("hueco {s} en subpágina no confirmada"),
            );
        }
        if self.huecos == 0 {
            return abortar(Violacion::ValorInvalido, "contador de huecos incoherente");
        }
        spg.huecos_reservados[j] &= !marca;
        spg.gens[idx] += 1;
        if let Some(d) = spg.datos[j].as_mut() {
            for w in &mut d[k * campos..(k + 1) * campos] {
                *w = Palabra::Int(0);
            }
        }
        self.huecos -= 1;
        self.vivos += 1;
        self.cont.asignaciones += 1;
        Ok(spg.gens[idx])
    }

    /// Libera un hueco reservado y lo devuelve a la lista libre.
    /// Debe fallar sin modificar el pool ante reutilización o doble liberación.
    pub fn liberar_hueco(&mut self, s: u32, ev: &mut Eventos) -> Result<(), Aborto> {
        if s as u64 >= self.capacidad() {
            return abortar(Violacion::FueraDeLimites, format!("hueco {s} fuera de la reserva"));
        }
        let (sp, j, k) = self.ubicar(s);
        let Some(spg) = self.sps.get_mut(sp).and_then(|x| x.as_mut()) else {
            return abortar(Violacion::PaginaDevuelta, format!("hueco {s} sin superpágina"));
        };
        let marca = 1u64 << k;
        if spg.huecos_reservados[j] & marca == 0 {
            return abortar(
                Violacion::PermisoInventado,
                format!("slot {s} sin permiso de hueco reservado"),
            );
        }
        if spg.gens[j * self.slots_por_sub as usize + k] & 1 == 1 || self.huecos == 0 {
            return abortar(Violacion::ValorInvalido, "estado de hueco incoherente");
        }
        spg.huecos_reservados[j] &= !marca;
        self.huecos -= 1;
        self.devolver_a_libres(sp, j, k, ev);
        Ok(())
    }

    /// Acceso a datos con todas las comprobaciones del oráculo.
    fn celda(&self, s: u32, gener: u32, campo: usize) -> Result<(usize, usize, usize), Aborto> {
        if campo >= self.campos {
            return abortar(
                Violacion::FueraDeLimites,
                format!("campo {campo} fuera de rango ({} campos)", self.campos),
            );
        }
        self.comprobar_vivo(s, gener, false)?;
        let (sp, j, k) = self.ubicar(s);
        let spg = self.sp(s)?;
        if spg.estado[j] != EstadoSub::Confirmada {
            return abortar(
                Violacion::PaginaDevuelta,
                format!(
                    "acceso al slot {s} del pool {}: su subpágina de datos está {:?}",
                    self.id, spg.estado[j]
                ),
            );
        }
        Ok((sp, j, k * self.campos + campo))
    }

    /// Acceso a datos: el estado de la subpágina se comprueba antes que la
    /// generación para distinguir "página devuelta" de "generación obsoleta".
    fn celda_ordenada(
        &self,
        s: u32,
        gener: u32,
        campo: usize,
    ) -> Result<(usize, usize, usize), Aborto> {
        if s as u64 >= self.capacidad() {
            return abortar(
                Violacion::FueraDeLimites,
                format!("slot {s} fuera de la reserva"),
            );
        }
        let (_, j, _) = self.ubicar(s);
        let spg = self.sp(s)?;
        if spg.estado[j] != EstadoSub::Confirmada {
            return abortar(
                Violacion::PaginaDevuelta,
                format!(
                    "acceso al slot {s} del pool {}: su subpágina de datos está {:?}",
                    self.id, spg.estado[j]
                ),
            );
        }
        self.celda(s, gener, campo)
    }

    pub fn leer(&self, s: u32, gener: u32, campo: usize) -> Result<Palabra, Aborto> {
        let (sp, j, i) = self.celda_ordenada(s, gener, campo)?;
        Ok(self.sps[sp].as_ref().expect("sp").datos[j]
            .as_ref()
            .expect("datos")[i])
    }

    pub fn escribir(&mut self, s: u32, gener: u32, campo: usize, w: Palabra) -> Result<(), Aborto> {
        let (sp, j, i) = self.celda_ordenada(s, gener, campo)?;
        self.sps[sp].as_mut().expect("sp").datos[j]
            .as_mut()
            .expect("datos")[i] = w;
        Ok(())
    }

    /// Slots vivos con su generación (para `sellar`).
    pub fn slots_vivos(&self) -> Vec<(u32, u32)> {
        let mut r = Vec::new();
        let n = self.slots_por_superpagina();
        for (sp, x) in self.sps.iter().enumerate() {
            let Some(x) = x else { continue };
            for (i, g) in x.gens.iter().enumerate() {
                if g & 1 == 1 {
                    r.push((sp as u32 * n + i as u32, *g));
                }
            }
        }
        r
    }

    pub fn subpaginas_confirmadas(&self) -> usize {
        self.sps
            .iter()
            .flatten()
            .map(|x| {
                x.estado
                    .iter()
                    .filter(|e| **e == EstadoSub::Confirmada)
                    .count()
            })
            .sum()
    }

    /// Incrementa la época de destrucción (en la partición `a` durante
    /// `dividir`; se suma al unir).
    pub fn destruye(&mut self, a: usize) {
        if a == 0 {
            self.epoca_destruccion += 1;
        } else {
            self.asignadores[a].epoca += 1;
        }
    }

    /// Particiona las superpáginas sin reservar en `n` rangos disjuntos.
    pub fn dividir(&mut self, n: u32) {
        let libres: Vec<u32> = std::mem::take(&mut self.asignadores[0].sin_reservar)
            .into_iter()
            .collect();
        let palabras = self.asignadores[0].buckets[1].len();
        let trozo = libres.len().div_ceil(n.max(1) as usize).max(1);
        for k in 0..n as usize {
            let rango: BTreeSet<u32> = libres.iter().skip(k * trozo).take(trozo).copied().collect();
            self.asignadores.push(Asignador::nuevo(palabras, rango));
        }
    }

    pub fn particiones(&self) -> usize {
        self.asignadores.len() - 1
    }

    /// Une las particiones en el asignador principal.
    pub fn unir_particiones(&mut self) {
        let total = self.total_sub();
        while self.asignadores.len() > 1 {
            let a = self.asignadores.pop().expect("partición");
            self.epoca_destruccion += a.epoca;
            self.asignadores[0].sin_reservar.extend(a.sin_reservar);
            for sp in a.reservadas {
                let spg = self.sps[sp as usize].as_mut().expect("superpágina");
                spg.asignador = 0;
                let libres: Vec<u32> = spg.libres.iter().map(|w| w.count_ones()).collect();
                for (j, l) in libres.into_iter().enumerate() {
                    self.asignadores[0].poner(sp * SUBPAGINAS_DATOS as u32 + j as u32, l, total);
                }
                self.asignadores[0].reservadas.push(sp);
            }
        }
    }

    /// Fuerza la generación de un slot (solo para pruebas de agotamiento).
    pub fn depuracion_fijar_generacion(&mut self, s: u32, gener: u32) {
        let (sp, j, k) = self.ubicar(s);
        let total = self.total_sub() as usize;
        if let Some(x) = self.sps[sp].as_mut() {
            x.gens[j * total + k] = gener;
        }
    }

    /// Comprueba los invariantes de la cabecera y del índice por densidad.
    pub fn comprobar_invariantes(&self) -> Result<(), String> {
        let total = self.total_sub();
        let mascara = if total == 64 {
            u64::MAX
        } else {
            (1u64 << total) - 1
        };
        let (mut vivos, mut huecos) = (0u64, 0u64);
        for (sp, x) in self.sps.iter().enumerate() {
            let Some(x) = x else {
                if self
                    .asignadores
                    .iter()
                    .any(|a| a.reservadas.contains(&(sp as u32)))
                {
                    return Err(format!(
                        "superpágina {sp} anotada como reservada sin cabecera"
                    ));
                }
                continue;
            };
            for j in 0..SUBPAGINAS_DATOS {
                let g = sp as u32 * SUBPAGINAS_DATOS as u32 + j as u32;
                if x.libres[j] & !mascara != 0 || x.huecos_reservados[j] & !mascara != 0 {
                    return Err(format!("subpágina {g}: bits libres o de hueco fuera de rango"));
                }
                let mut v = 0u32;
                let mut retirados = 0u32;
                let mut pares_ocupados = 0u32;
                for k in 0..total as usize {
                    let g_s = x.gens[j * total as usize + k];
                    let libre = x.libres[j] & (1u64 << k) != 0;
                    let reservado = x.huecos_reservados[j] & (1u64 << k) != 0;
                    if libre && reservado {
                        return Err(format!("subpágina {g}: slot libre y hueco reservado a la vez"));
                    }
                    if g_s == GEN_RETIRADO {
                        retirados += 1;
                        if libre || reservado {
                            return Err(format!("subpágina {g}: slot retirado en lista libre o huecos"));
                        }
                    } else if g_s & 1 == 1 {
                        v += 1;
                        if libre || reservado {
                            return Err(format!("subpágina {g}: slot vivo marcado como libre o hueco"));
                        }
                    } else if reservado {
                        pares_ocupados += 1;
                    } else if !libre {
                        return Err(format!("subpágina {g}: slot par ocupado sin permiso de hueco"));
                    }
                }
                let libres = x.libres[j].count_ones();
                if v + pares_ocupados != x.ocupados[j] as u32 {
                    return Err(format!(
                        "subpágina {g}: {v} vivos + {pares_ocupados} huecos ≠ {} ocupados",
                        x.ocupados[j]
                    ));
                }
                if v + pares_ocupados + libres + retirados != total {
                    return Err(format!("subpágina {g}: el recuento de slots no cuadra"));
                }
                vivos += v as u64;
                huecos += pares_ocupados as u64;
                match x.estado[j] {
                    EstadoSub::Confirmada if x.datos[j].is_none() => {
                        return Err(format!("subpágina {g}: confirmada sin datos"));
                    }
                    EstadoSub::Reservada | EstadoSub::Devuelta if x.datos[j].is_some() => {
                        return Err(format!(
                            "subpágina {g}: datos en una subpágina no confirmada"
                        ));
                    }
                    EstadoSub::Confirmada if x.ocupados[j] == 0 => {
                        return Err(format!(
                            "subpágina {g}: confirmada y vacía (debió devolverse)"
                        ));
                    }
                    _ => {}
                }
                let a = &self.asignadores[x.asignador];
                if libres > 0 && !a.contiene(g, libres, total) {
                    return Err(format!(
                        "subpágina {g}: {libres} libres pero no está en su bucket"
                    ));
                }
                for (k, b) in a.buckets.iter().enumerate() {
                    let marcado = b[(g / 64) as usize] & (1u64 << (g % 64)) != 0;
                    if marcado && k as u32 != libres {
                        return Err(format!(
                            "subpágina {g}: en el bucket {k} con {libres} libres"
                        ));
                    }
                }
            }
        }
        if vivos != self.vivos || huecos != self.huecos {
            return Err(format!(
                "recuento global: {vivos} vivos / {huecos} huecos frente a {} / {}",
                self.vivos, self.huecos
            ));
        }
        Ok(())
    }

    /// Resumen legible del estado (para informes del fuzzer).
    pub fn resumen(&self) -> String {
        let mut s = format!(
            "pool {} (slot {} B, {} por subpágina): {} vivos, {} huecos, época {}, reestructuras {}",
            self.id,
            self.tam_slot,
            self.slots_por_sub,
            self.vivos,
            self.huecos,
            self.epoca_destruccion,
            self.epoca_reestructura
        );
        for (sp, x) in self.sps.iter().enumerate() {
            let Some(x) = x else { continue };
            let estados: String = x
                .estado
                .iter()
                .map(|e| match e {
                    EstadoSub::Reservada => '.',
                    EstadoSub::Confirmada => 'C',
                    EstadoSub::Devuelta => 'd',
                })
                .collect();
            let gens: Vec<String> = x
                .gens
                .iter()
                .enumerate()
                .filter(|(_, g)| **g != self.gen_inicial)
                .take(16)
                .map(|(i, g)| {
                    format!(
                        "{}:{g:#x}",
                        sp as u32 * self.slots_por_superpagina() + i as u32
                    )
                })
                .collect();
            s.push_str(&format!("\n  sp{sp} [{estados}] gens {}", gens.join(" ")));
        }
        s
    }
}
