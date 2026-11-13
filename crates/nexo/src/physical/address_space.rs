use std::ptr::NonNull;

use super::PhysicalError;
use super::platform::{self, Reservation};

const REQUIRED_PAGE_SIZE: usize = 4 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AddressSpaceMetrics {
    pub reserved_bytes: usize,
    pub committed_bytes: usize,
    pub accessible_bytes: usize,
    pub page_size: usize,
    pub allocation_granularity: usize,
}

/// Reserva de direcciones estable respaldada por memoria virtual del SO.
///
/// La API no expone referencias Rust a páginas revocables. Las lecturas y
/// escrituras comprueban primero el estado de las páginas y copian los bytes
/// mientras `&mut self` impide una revocación concurrente mediante esta API.
#[derive(Debug)]
pub struct AddressSpace {
    reservation: Reservation,
    page_size: usize,
    allocation_granularity: usize,
    committed: Vec<bool>,
    accessible: Vec<bool>,
    released: bool,
}

impl AddressSpace {
    pub fn reserve(len: usize, alignment: usize) -> Result<Self, PhysicalError> {
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
        let page_count = len / info.page_size;
        let reservation = platform::reserve(len, alignment)?;
        debug_assert_eq!(reservation.base.as_ptr() as usize % alignment, 0);
        Ok(Self {
            reservation,
            page_size: info.page_size,
            allocation_granularity: info.allocation_granularity,
            committed: vec![false; page_count],
            accessible: vec![false; page_count],
            released: false,
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

    pub fn metrics(&self) -> AddressSpaceMetrics {
        AddressSpaceMetrics {
            reserved_bytes: self.len(),
            committed_bytes: self.committed.iter().filter(|page| **page).count() * self.page_size,
            accessible_bytes: self.accessible.iter().filter(|page| **page).count() * self.page_size,
            page_size: self.page_size,
            allocation_granularity: self.allocation_granularity,
        }
    }

    pub fn commit(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        let base = self.range_base(offset)?;
        // SAFETY: page_range checked alignment and containment in the live reservation.
        unsafe { platform::commit(base, len)? };
        self.committed[pages.clone()].fill(true);
        self.accessible[pages].fill(true);
        Ok(())
    }

    pub fn protect_none(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        if self.committed[pages.clone()].iter().any(|page| !page) {
            return Err(PhysicalError::Uncommitted);
        }
        let base = self.range_base(offset)?;
        // SAFETY: range is committed, page-aligned, and belongs to the reservation.
        unsafe { platform::protect_none(base, len)? };
        self.accessible[pages].fill(false);
        Ok(())
    }

    pub fn decommit(&mut self, offset: usize, len: usize) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        let pages = self.page_range(offset, len)?;
        let base = self.range_base(offset)?;
        // SAFETY: page_range checked alignment and containment in the live reservation.
        unsafe { platform::decommit(base, len)? };
        self.committed[pages.clone()].fill(false);
        self.accessible[pages].fill(false);
        Ok(())
    }

    pub fn write(&mut self, offset: usize, bytes: &[u8]) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, bytes.len())?;
        let destination = self.range_base(offset)?;
        // SAFETY: the checked range is committed, accessible, and non-overlapping
        // with an immutable caller-owned byte slice while `&mut self` is held.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), destination.as_ptr(), bytes.len()) };
        Ok(())
    }

    pub fn read(&mut self, offset: usize, output: &mut [u8]) -> Result<(), PhysicalError> {
        self.ensure_live()?;
        self.check_accessible(offset, output.len())?;
        let source = self.range_base(offset)?;
        // SAFETY: the checked range is committed and accessible; output is a
        // distinct mutable slice supplied by the caller while `&mut self` is held.
        unsafe {
            std::ptr::copy_nonoverlapping(source.as_ptr(), output.as_mut_ptr(), output.len())
        };
        Ok(())
    }

    /// Libera explícitamente la reserva. Es idempotente; `Drop` usa la misma
    /// operación. Tras liberarla, `len()` y `base_addr()` devuelven cero y las
    /// operaciones de memoria devuelven [`PhysicalError::Released`].
    pub fn release(&mut self) -> Result<(), PhysicalError> {
        if self.released {
            return Ok(());
        }
        // SAFETY: AddressSpace posee de forma exclusiva esta reserva viva.
        unsafe { platform::release(&self.reservation)? };
        self.released = true;
        self.committed.fill(false);
        self.accessible.fill(false);
        Ok(())
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
        if self.committed[first..=last].iter().any(|page| !page) {
            return Err(PhysicalError::Uncommitted);
        }
        if self.accessible[first..=last].iter().any(|page| !page) {
            return Err(PhysicalError::Inaccessible);
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
        // SAFETY: offset is within the allocated reservation and cannot wrap.
        Ok(unsafe { self.reservation.base.add(offset) })
    }
}

impl Drop for AddressSpace {
    fn drop(&mut self) {
        let _ = self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUPERPAGE: usize = 64 * 1024;

    #[test]
    fn reservation_is_aligned_stable_and_initially_inaccessible() {
        let mut space = AddressSpace::reserve(SUPERPAGE * 2, SUPERPAGE).unwrap();
        let base = space.base_addr();
        assert_eq!(base % SUPERPAGE, 0);
        assert_eq!(space.metrics().committed_bytes, 0);
        assert_eq!(space.write(0, &[1]), Err(PhysicalError::Uncommitted));
        space.commit(0, REQUIRED_PAGE_SIZE).unwrap();
        assert_eq!(space.base_addr(), base);
    }

    #[test]
    fn commit_protect_decommit_and_recommit_are_real() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, REQUIRED_PAGE_SIZE).unwrap();
        space.write(0, &[0xA5, 0x5A]).unwrap();
        let mut actual = [0; 2];
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [0xA5, 0x5A]);

        space.protect_none(0, REQUIRED_PAGE_SIZE).unwrap();
        assert_eq!(space.read(0, &mut actual), Err(PhysicalError::Inaccessible));
        space.commit(0, REQUIRED_PAGE_SIZE).unwrap();
        space.decommit(0, REQUIRED_PAGE_SIZE).unwrap();
        assert_eq!(space.read(0, &mut actual), Err(PhysicalError::Uncommitted));

        space.commit(0, REQUIRED_PAGE_SIZE).unwrap();
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [0, 0]);
    }

    #[test]
    fn rejects_unaligned_and_out_of_bounds_ranges() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        assert_eq!(
            space.commit(1, REQUIRED_PAGE_SIZE),
            Err(PhysicalError::InvalidRange)
        );
        assert_eq!(
            space.commit(0, REQUIRED_PAGE_SIZE - 1),
            Err(PhysicalError::InvalidRange)
        );
        assert_eq!(
            space.commit(SUPERPAGE, REQUIRED_PAGE_SIZE),
            Err(PhysicalError::InvalidRange)
        );
    }

    /// `commit` sobre páginas ya confirmadas pero protegidas debe devolverlas
    /// realmente a lectura/escritura en el SO, porque el seguimiento las
    /// marca accesibles: si no, la siguiente escritura sería una violación de
    /// acceso real (Windows: `VirtualAlloc(MEM_COMMIT)` sobre páginas
    /// confirmadas; Linux: `mprotect`).
    #[test]
    fn recommit_of_protected_pages_restores_real_access() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.commit(0, REQUIRED_PAGE_SIZE * 2).unwrap();
        space.write(0, &[7]).unwrap();
        space.protect_none(0, REQUIRED_PAGE_SIZE * 2).unwrap();
        space.commit(0, REQUIRED_PAGE_SIZE * 2).unwrap();
        let mut actual = [0; 1];
        space.read(0, &mut actual).unwrap();
        assert_eq!(actual, [7], "el contenido confirmado se conserva");
        space.write(REQUIRED_PAGE_SIZE, &[9]).unwrap();
        space.read(REQUIRED_PAGE_SIZE, &mut actual).unwrap();
        assert_eq!(actual, [9]);
    }

    #[test]
    fn explicit_release_is_idempotent_and_closes_the_space() {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        assert!(!space.is_empty());
        space.release().unwrap();
        assert!(space.is_empty());
        assert_eq!(space.base_addr(), 0);
        assert_eq!(space.len(), 0);
        assert_eq!(
            space.commit(0, REQUIRED_PAGE_SIZE),
            Err(PhysicalError::Released)
        );
        space.release().unwrap();
    }
}
