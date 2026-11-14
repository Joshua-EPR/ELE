use std::ptr::NonNull;

use super::PhysicalError;
use super::platform::{self, Reservation};

const REQUIRED_PAGE_SIZE: usize = 4 * 1024;

/// Estado físico de una página de la reserva, tal como lo dejó la última
/// llamada al SO **que tuvo éxito**. Cada transición se registra solo después
/// de que el SO la confirma, así que el seguimiento nunca es más permisivo que
/// la realidad.
///
/// | Estado | Backing en el SO | Acceso físico |
/// | --- | --- | --- |
/// | `Reserved` | ninguno, nunca confirmada | no |
/// | `Accessible` | confirmada | lectura/escritura |
/// | `Protected` | confirmada (puede conservar bytes antiguos) | no |
/// | `Discarded` | descartado (Linux: `MADV_DONTNEED` + `PROT_NONE`; Windows: `MEM_DECOMMIT`) | no |
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PageAccess {
    Reserved,
    Accessible,
    Protected,
    Discarded,
}

/// Punto de fallo inyectable (pruebas de recuperación).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FaultOp {
    Reserve,
    /// Primera confirmación de una página nunca confirmada.
    Commit,
    /// Confirmación de una página protegida o descartada.
    Recommit,
    Protect,
    /// Descarte del backing (`madvise` / `VirtualFree(MEM_DECOMMIT)`).
    Decommit,
    Release,
    /// Escritura de metadatos en la cabecera física (la dispara el pool).
    HeaderWrite,
}

const N_FAULT_OPS: usize = 7;

impl FaultOp {
    fn index(self) -> usize {
        self as usize
    }
}

/// Plan determinista de fallos: la N-ésima ocurrencia de una operación
/// (base uno) o todas a partir de ahora. Un fallo inyectado se produce
/// **antes** de llamar al SO, así que no cambia el estado externo.
#[derive(Clone, Debug, Default)]
pub struct FaultPlan {
    nth: Vec<(FaultOp, u64)>,
    always: Vec<FaultOp>,
    counts: [u64; N_FAULT_OPS],
}

impl FaultPlan {
    pub fn new() -> Self {
        Self::default()
    }

    /// Falla la `n`-ésima ocurrencia (contando desde que se activa el plan).
    pub fn fail_nth(mut self, op: FaultOp, n: u64) -> Self {
        let base = self.counts[op.index()];
        self.nth.push((op, base + n));
        self
    }

    pub fn fail_always(mut self, op: FaultOp) -> Self {
        self.always.push(op);
        self
    }

    pub fn stop_failing(&mut self, op: FaultOp) {
        self.always.retain(|o| *o != op);
        self.nth.retain(|(o, _)| *o != op);
    }

    /// Ocurrencias observadas de `op` (incluidas las que fallaron).
    pub fn count(&self, op: FaultOp) -> u64 {
        self.counts[op.index()]
    }

    pub(super) fn check(&mut self, op: FaultOp) -> Result<(), PhysicalError> {
        self.counts[op.index()] += 1;
        let n = self.counts[op.index()];
        if self.always.contains(&op) || self.nth.iter().any(|(o, k)| *o == op && *k == n) {
            Err(PhysicalError::Injected(op))
        } else {
            Ok(())
        }
    }
}

/// Llamadas reales al SO realizadas por este espacio.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct OsCalls {
    pub reserve: u64,
    pub commit: u64,
    pub protect: u64,
    pub discard: u64,
    pub release: u64,
}

impl OsCalls {
    pub fn total(&self) -> u64 {
        self.reserve + self.commit + self.protect + self.discard + self.release
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AddressSpaceMetrics {
    pub reserved_bytes: usize,
    /// Páginas con backing confirmado (`Accessible` o `Protected`).
    pub committed_bytes: usize,
    pub accessible_bytes: usize,
    pub page_size: usize,
    pub allocation_granularity: usize,
    pub os_calls: OsCalls,
}

/// Reserva de direcciones estable respaldada por memoria virtual del SO.
///
/// La API no expone referencias Rust a páginas revocables. Las lecturas y
/// escrituras comprueban primero que todas las páginas del rango estén
/// `Accessible` y copian los bytes mientras `&mut self` impide una revocación
/// concurrente mediante esta API.
#[derive(Debug)]
pub struct AddressSpace {
    reservation: Reservation,
    page_size: usize,
    allocation_granularity: usize,
    pages: Vec<PageAccess>,
    released: bool,
    /// Windows: proteger antes de `MEM_DECOMMIT` (redundante, solo para
    /// pruebas de fallo parcial y comparación de coste). Linux: siempre.
    protect_before_discard: bool,
    faults: FaultPlan,
    calls: OsCalls,
}

impl AddressSpace {
    pub fn reserve(len: usize, alignment: usize) -> Result<Self, PhysicalError> {
        Self::reserve_with_faults(len, alignment, FaultPlan::new())
    }

    pub fn reserve_with_faults(
        len: usize,
        alignment: usize,
        mut faults: FaultPlan,
    ) -> Result<Self, PhysicalError> {
        let info = platform::page_info()?;
        if info.page_size != REQUIRED_PAGE_SIZE {
            return Err(PhysicalError::UnsupportedPageSize {
                found: info.page_size,
                required: REQUIRED_PAGE_SIZE,
            });
        }
        if len == 0 || !len.is_multiple_of(info.page_size) {
            return Err(PhysicalError::InvalidRange);
        }
        if alignment < info.allocation_granularity
            || !alignment.is_power_of_two()
            || !alignment.is_multiple_of(info.allocation_granularity)
        {
            return Err(PhysicalError::InvalidAlignment {
                alignment,
                granularity: info.allocation_granularity,
            });
        }
        faults.check(FaultOp::Reserve)?;
        let page_count = len / info.page_size;
        let reservation = platform::reserve(len, alignment)?;
        debug_assert_eq!(reservation.base.as_ptr() as usize % alignment, 0);
        Ok(Self {
            reservation,
            page_size: info.page_size,
            allocation_granularity: info.allocation_granularity,
            pages: vec![PageAccess::Reserved; page_count],
            released: false,
            protect_before_discard: platform::PROTECT_BEFORE_DISCARD_REQUIRED,
            faults,
            calls: OsCalls {
                reserve: 1,
                ..OsCalls::default()
            },
        })
    }

    pub fn base_addr(&self) -> usize {
        if self.released {
            0
        } else {
            self.reservation.base.as_ptr() as usize
        }
    }

    pub fn len(&self) -> usize {
        if self.released {
            0
        } else {
            self.reservation.len
        }
    }

    /// Coherente con [`AddressSpace::len`]: una reserva liberada está vacía.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn page_size(&self) -> usize {
        self.page_size
    }

    pub fn metrics(&self) -> AddressSpaceMetrics {
        let count = |pred: fn(&PageAccess) -> bool| self.pages.iter().filter(|p| pred(p)).count();
        AddressSpaceMetrics {
            reserved_bytes: self.len(),
            committed_bytes: count(|p| matches!(p, PageAccess::Accessible | PageAccess::Protected))
                * self.page_size,
            accessible_bytes: count(|p| *p == PageAccess::Accessible) * self.page_size,
            page_size: self.page_size,
            allocation_granularity: self.allocation_granularity,
            os_calls: self.calls,
        }
    }

    pub fn faults(&self) -> &FaultPlan {
        &self.faults
    }

    pub fn faults_mut(&mut self) -> &mut FaultPlan {
        &mut self.faults
    }

    pub fn set_faults(&mut self, faults: FaultPlan) {
        self.faults = faults;
    }

    /// En Windows activa la protección redundante previa a `MEM_DECOMMIT`.
    /// En Linux la protección previa es obligatoria y no se puede desactivar.
    pub fn set_protect_before_discard(&mut self, on: bool) {
        self.protect_before_discard = on || platform::PROTECT_BEFORE_DISCARD_REQUIRED;
    }

    /// Estado físico de la página que contiene `offset`.
    pub fn page_access(&self, offset: usize) -> Result<PageAccess, PhysicalError> {
        self.ensure_live()?;
        if offset >= self.len() {
            return Err(PhysicalError::InvalidRange);
        }
        Ok(self.pages[offset / self.page_size])
    }

    /// Confirma lectura/escritura. Sobre páginas `Protected` o `Discarded`
    /// es una reconfirmación; el contenido de las `Discarded` vuelve a cero.
    pub fn commit(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        let op = if self.pages[pages.clone()]
            .iter()
            .all(|p| *p == PageAccess::Reserved)
        {
            FaultOp::Commit
        } else {
            FaultOp::Recommit
        };
        self.faults.check(op)?;
        let base = self.range_base(offset)?;
        // SAFETY: page_range comprobó alineación a página y contención en la
        // reserva viva.
        unsafe { platform::commit(base, len)? };
        self.calls.commit += 1;
        self.pages[pages].fill(PageAccess::Accessible);
        Ok(())
    }

    /// Quita todo acceso a páginas confirmadas (`Accessible` → `Protected`).
    pub fn protect_none(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        if self.pages[pages.clone()]
            .iter()
            .any(|p| !matches!(p, PageAccess::Accessible | PageAccess::Protected))
        {
            return Err(PhysicalError::Uncommitted);
        }
        self.faults.check(FaultOp::Protect)?;
        let base = self.range_base(offset)?;
        // SAFETY: el rango está confirmado, alineado y dentro de la reserva.
        unsafe { platform::protect_none(base, len)? };
        self.calls.protect += 1;
        self.pages[pages].fill(PageAccess::Protected);
        Ok(())
    }

    /// Reclamación por pasos, idempotente y reintentable:
    ///
    /// 1. si alguna página es `Accessible` y la plataforma (o la
    ///    configuración) lo exige, protegerla: éxito → `Protected`; fallo →
    ///    sin cambios;
    /// 2. descartar el backing: éxito → `Discarded`; fallo → el estado del
    ///    paso 1 se conserva.
    ///
    /// Tras un error, [`AddressSpace::page_access`] informa el estado real.
    /// Un rango ya `Discarded` o `Reserved` no hace ninguna llamada.
    pub fn decommit(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        if self.pages[pages.clone()]
            .iter()
            .all(|p| matches!(p, PageAccess::Discarded | PageAccess::Reserved))
        {
            return Ok(());
        }
        let base = self.range_base(offset)?;
        if self.protect_before_discard
            && self.pages[pages.clone()].contains(&PageAccess::Accessible)
        {
            self.faults.check(FaultOp::Protect)?;
            // SAFETY: rango alineado, confirmado y dentro de la reserva.
            unsafe { platform::protect_none(base, len)? };
            self.calls.protect += 1;
            for p in &mut self.pages[pages.clone()] {
                if *p == PageAccess::Accessible {
                    *p = PageAccess::Protected;
                }
            }
        }
        self.faults.check(FaultOp::Decommit)?;
        // SAFETY: rango alineado y dentro de la reserva viva; tras el paso 1
        // ningún acceso físico de esta API lo toca.
        unsafe { platform::discard(base, len)? };
        self.calls.discard += 1;
        self.pages[pages].fill(PageAccess::Discarded);
        Ok(())
    }

    pub fn write(&mut self, offset: usize, bytes: &[u8]) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, bytes.len())?;
        let destination = self.range_base(offset)?;
        // SAFETY: el rango comprobado está confirmado y accesible y no solapa
        // el slice inmutable del llamador mientras se mantiene `&mut self`.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), destination.as_ptr(), bytes.len()) };
        Ok(())
    }

    /// Rellena `len` bytes con `value` sin asignar memoria auxiliar.
    pub fn fill(&mut self, offset: usize, len: usize, value: u8) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, len)?;
        let destination = self.range_base(offset)?;
        // SAFETY: el rango comprobado está confirmado, accesible y dentro de la
        // reserva; `&mut self` impide revocarlo durante la escritura.
        unsafe { std::ptr::write_bytes(destination.as_ptr(), value, len) };
        Ok(())
    }

    /// Lectura con préstamo compartido. Es sólida porque toda mutación de
    /// la memoria o de su protección exige `&mut self`: mientras exista este
    /// préstamo nadie puede revocar ni escribir el rango mediante esta API.
    pub fn peek(&self, offset: usize, output: &mut [u8]) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, output.len())?;
        let source = self.range_base(offset)?;
        // SAFETY: rango comprobado accesible; ninguna escritura concurrente es
        // posible sin `&mut self`; `output` es memoria distinta del llamador.
        unsafe {
            std::ptr::copy_nonoverlapping(source.as_ptr(), output.as_mut_ptr(), output.len())
        };
        Ok(())
    }

    pub fn read(&mut self, offset: usize, output: &mut [u8]) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, output.len())?;
        let source = self.range_base(offset)?;
        // SAFETY: el rango comprobado está confirmado y accesible; `output` es
        // un slice mutable distinto del llamador mientras se mantiene `&mut self`.
        unsafe {
            std::ptr::copy_nonoverlapping(source.as_ptr(), output.as_mut_ptr(), output.len())
        };
        Ok(())
    }

    /// Libera la reserva. Es idempotente. Si el SO (o un fallo inyectado)
    /// rechaza la liberación, el espacio sigue vivo y puede reintentarse.
    /// `Drop` intenta una sola vez y, si falla, la reserva se pierde (fuga de
    /// direcciones, nunca un acceso indebido).
    pub fn release(&mut self) -> Result<(), PhysicalError> {
        if self.released {
            return Ok(());
        }
        self.faults.check(FaultOp::Release)?;
        // SAFETY: AddressSpace posee de forma exclusiva esta reserva viva y
        // `released` impide liberarla dos veces.
        unsafe { platform::release(&self.reservation)? };
        self.calls.release += 1;
        self.released = true;
        self.pages.fill(PageAccess::Reserved);
        Ok(())
    }

    /// Comprueba un fallo inyectado en una operación del llamador que no es
    /// una llamada al SO (por ejemplo, escritura de cabecera).
    pub fn inject(&mut self, op: FaultOp) -> Result<(), PhysicalError> {
        self.faults.check(op)
    }

    fn ensure_live(&self) -> Result<(), PhysicalError> {
        if self.released {
            Err(PhysicalError::Released)
        } else {
            Ok(())
        }
    }

    fn check_accessible(&self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        let end = offset.checked_add(len).ok_or(PhysicalError::Overflow)?;
        if end > self.len() {
            return Err(PhysicalError::InvalidRange);
        }
        if len == 0 {
            return Ok(());
        }
        let first = offset / self.page_size;
        let last = (end - 1) / self.page_size;
        for p in &self.pages[first..=last] {
            match p {
                PageAccess::Accessible => {}
                PageAccess::Protected => return Err(PhysicalError::Inaccessible),
                PageAccess::Reserved | PageAccess::Discarded => {
                    return Err(PhysicalError::Uncommitted);
                }
            }
        }
        Ok(())
    }

    fn page_range(
        &self,
        offset: usize,
        len: usize,
    ) -> Result<std::ops::Range<usize>, PhysicalError> {
        let end = offset.checked_add(len).ok_or(PhysicalError::Overflow)?;
        if len == 0
            || !offset.is_multiple_of(self.page_size)
            || !len.is_multiple_of(self.page_size)
            || end > self.len()
        {
            return Err(PhysicalError::InvalidRange);
        }
        Ok(offset / self.page_size..end / self.page_size)
    }

    fn range_base(&self, offset: usize) -> Result<NonNull<u8>, PhysicalError> {
        if offset > self.len() {
            return Err(PhysicalError::InvalidRange);
        }
        // SAFETY: offset ≤ len de la reserva viva: el resultado está dentro
        // de la asignación o es su final, y no desborda (la reserva existe).
        Ok(unsafe { self.reservation.base.add(offset) })
    }
}

impl Drop for AddressSpace {
    fn drop(&mut self) {
        // Los fallos inyectados no deben impedir devolver la reserva al SO
        // en la destrucción del objeto.
        self.faults.stop_failing(FaultOp::Release);
        let _ = self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUPERPAGE: usize = 64 * 1024;
    const PAGE: usize = REQUIRED_PAGE_SIZE;

    #[test]
    fn reservation_is_aligned_stable_and_initially_inaccessible() {
        let mut space = AddressSpace::reserve(SUPERPAGE * 2, SUPERPAGE).unwrap();
        let base = space.base_addr();
        assert_eq!(base % SUPERPAGE, 0);
        assert_eq!(space.metrics().committed_bytes, 0);
        assert_eq!(space.write(0, &[1]), Err(PhysicalError::Uncommitted));
        space.commit(0, PAGE).unwrap();
        assert_eq!(space.base_addr(), base);
    }

    #[test]
    fn commit_protect_decommit_and_recommit_are_real() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, PAGE).unwrap();
        space.write(0, &[0xA5, 0x5A]).unwrap();
        let mut actual = [0; 2];
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [0xA5, 0x5A]);

        space.protect_none(0, PAGE).unwrap();
        assert_eq!(space.read(0, &mut actual), Err(PhysicalError::Inaccessible));
        space.commit(0, PAGE).unwrap();
        space.decommit(0, PAGE).unwrap();
        assert_eq!(space.page_access(0), Ok(PageAccess::Discarded));
        assert_eq!(space.read(0, &mut actual), Err(PhysicalError::Uncommitted));

        space.commit(0, PAGE).unwrap();
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [0, 0], "el backing descartado vuelve a cero");
    }

    /// `commit` sobre páginas ya confirmadas pero protegidas debe devolverlas
    /// realmente a lectura/escritura en el SO, porque el seguimiento las
    /// marca accesibles (Windows: `VirtualAlloc(MEM_COMMIT)` sobre páginas
    /// confirmadas; Linux: `mprotect`).
    #[test]
    fn recommit_of_protected_pages_restores_real_access() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, PAGE * 2).unwrap();
        space.write(0, &[7]).unwrap();
        space.protect_none(0, PAGE * 2).unwrap();
        space.commit(0, PAGE * 2).unwrap();
        let mut actual = [0; 1];
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [7], "el contenido confirmado se conserva");
        space.write(PAGE, &[9]).unwrap();
        space.read(PAGE, &mut actual).unwrap();
        assert_eq!(actual, [9]);
    }

    /// Secuencia de reclamación por pasos con fallos en cada punto: el
    /// estado registrado coincide con el último paso que tuvo éxito y el
    /// reintento completa la reclamación con contenido a cero.
    #[test]
    fn stepwise_reclaim_with_injected_faults() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.set_protect_before_discard(true);
        space.commit(0, PAGE).unwrap();
        space.write(0, &[0xEE]).unwrap();
        // Fallo antes de tocar la protección.
        space.set_faults(FaultPlan::new().fail_nth(FaultOp::Protect, 1));
        assert_eq!(
            space.decommit(0, PAGE),
            Err(PhysicalError::Injected(FaultOp::Protect))
        );
        assert_eq!(space.page_access(0), Ok(PageAccess::Accessible));
        // Protección correcta y fallo del descarte.
        space.set_faults(FaultPlan::new().fail_nth(FaultOp::Decommit, 1));
        assert_eq!(
            space.decommit(0, PAGE),
            Err(PhysicalError::Injected(FaultOp::Decommit))
        );
        assert_eq!(space.page_access(0), Ok(PageAccess::Protected));
        let mut b = [0; 1];
        assert_eq!(space.read(0, &mut b), Err(PhysicalError::Inaccessible));
        // Reintento: no vuelve a proteger, solo descarta.
        let antes = space.metrics().os_calls;
        space.decommit(0, PAGE).unwrap();
        let despues = space.metrics().os_calls;
        assert_eq!(
            (
                despues.protect - antes.protect,
                despues.discard - antes.discard
            ),
            (0, 1)
        );
        assert_eq!(space.page_access(0), Ok(PageAccess::Discarded));
        space.decommit(0, PAGE).unwrap();
        assert_eq!(
            space.metrics().os_calls.discard,
            despues.discard,
            "idempotente"
        );
        space.commit(0, PAGE).unwrap();
        space.read(0, &mut b).unwrap();
        assert_eq!(b, [0]);
    }

    /// Linux: la reclamación es siempre `mprotect(PROT_NONE)` seguido de
    /// `madvise(MADV_DONTNEED)`; desactivar la protección previa no tiene
    /// efecto, y tras reconfirmar (`mprotect` RW) la página se lee a cero.
    #[cfg(target_os = "linux")]
    #[test]
    fn linux_protege_siempre_antes_de_madvise() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.set_protect_before_discard(false);
        space.commit(0, PAGE).unwrap();
        space.write(0, &[0x5A; 64]).unwrap();
        let antes = space.metrics().os_calls;
        space.decommit(0, PAGE).unwrap();
        let despues = space.metrics().os_calls;
        assert_eq!(
            (
                despues.protect - antes.protect,
                despues.discard - antes.discard
            ),
            (1, 1)
        );
        assert_eq!(space.page_access(0), Ok(PageAccess::Discarded));
        space.commit(0, PAGE).unwrap();
        let mut b = [1u8; 64];
        space.read(0, &mut b).unwrap();
        assert_eq!(b, [0; 64]);
        assert_eq!(space.page_size(), 4096);
    }

    #[test]
    fn fill_zeroes_without_leaving_the_range() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, PAGE).unwrap();
        space.write(0, &[1; 16]).unwrap();
        space.fill(4, 8, 0).unwrap();
        let mut b = [9; 16];
        space.read(0, &mut b).unwrap();
        assert_eq!(b, [1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1]);
        assert_eq!(space.fill(PAGE - 4, 8, 0), Err(PhysicalError::Uncommitted));
        assert_eq!(space.fill(usize::MAX, 2, 0), Err(PhysicalError::Overflow));
    }

    #[test]
    fn rejects_unaligned_and_out_of_bounds_ranges() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        assert_eq!(space.commit(1, PAGE), Err(PhysicalError::InvalidRange));
        assert_eq!(space.commit(0, PAGE - 1), Err(PhysicalError::InvalidRange));
        assert_eq!(
            space.commit(SUPERPAGE, PAGE),
            Err(PhysicalError::InvalidRange)
        );
        assert_eq!(
            space.decommit(usize::MAX - PAGE + 1, PAGE),
            Err(PhysicalError::Overflow)
        );
    }

    #[test]
    fn explicit_release_is_idempotent_and_closes_the_space() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        assert!(!space.is_empty());
        space.release().unwrap();
        assert!(space.is_empty());
        assert_eq!(space.base_addr(), 0);
        assert_eq!(space.len(), 0);
        assert_eq!(space.commit(0, PAGE), Err(PhysicalError::Released));
        space.release().unwrap();
    }

    #[test]
    fn failed_release_keeps_the_space_alive_and_retryable() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, PAGE).unwrap();
        space.set_faults(FaultPlan::new().fail_nth(FaultOp::Release, 1));
        assert_eq!(
            space.release(),
            Err(PhysicalError::Injected(FaultOp::Release))
        );
        assert!(!space.is_empty());
        space.write(0, &[3]).unwrap();
        space.release().unwrap();
        assert!(space.is_empty());
    }

    #[test]
    fn injected_reserve_failure_reserves_nothing() {
        let r = AddressSpace::reserve_with_faults(
            SUPERPAGE,
            SUPERPAGE,
            FaultPlan::new().fail_nth(FaultOp::Reserve, 1),
        );
        assert_eq!(r.err(), Some(PhysicalError::Injected(FaultOp::Reserve)));
    }
}
