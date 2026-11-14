use std::ffi::c_void;
use std::ptr::NonNull;

use super::{PageInfo, Reservation};
use crate::physical::PhysicalError;

const SC_PAGESIZE: i32 = 30;
const PROT_NONE: i32 = 0;
const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const MAP_PRIVATE: i32 = 2;
const MAP_ANONYMOUS: i32 = 0x20;
const MADV_DONTNEED: i32 = 4;

unsafe extern "C" {
    fn sysconf(name: i32) -> isize;
    fn mmap(
        address: *mut c_void,
        len: usize,
        protection: i32,
        flags: i32,
        file_descriptor: i32,
        offset: isize,
    ) -> *mut c_void;
    fn mprotect(address: *mut c_void, len: usize, protection: i32) -> i32;
    fn madvise(address: *mut c_void, len: usize, advice: i32) -> i32;
    fn munmap(address: *mut c_void, len: usize) -> i32;
}

fn last_error(operation: &'static str) -> PhysicalError {
    PhysicalError::Os {
        operation,
        code: std::io::Error::last_os_error().raw_os_error().unwrap_or(-1),
    }
}

pub(in crate::physical) fn page_info() -> Result<PageInfo, PhysicalError> {
    // SAFETY: sysconf(_SC_PAGESIZE) has no pointer or lifetime preconditions.
    let page_size = unsafe { sysconf(SC_PAGESIZE) };
    let page_size = usize::try_from(page_size).map_err(|_| last_error("sysconf _SC_PAGESIZE"))?;
    Ok(PageInfo {
        page_size,
        allocation_granularity: page_size,
    })
}

pub(in crate::physical) fn reserve(
    len: usize,
    alignment: usize,
) -> Result<Reservation, PhysicalError> {
    let info = page_info()?;
    if alignment < info.allocation_granularity
        || !alignment.is_power_of_two()
        || !alignment.is_multiple_of(info.allocation_granularity)
    {
        return Err(PhysicalError::InvalidAlignment {
            alignment,
            granularity: info.allocation_granularity,
        });
    }
    let total = len.checked_add(alignment).ok_or(PhysicalError::Overflow)?;
    // SAFETY: anonymous mmap ignores fd/offset. A null hint lets Linux choose the
    // address; importantly this uses neither MAP_FIXED nor MAP_FIXED_NOREPLACE.
    let raw = unsafe {
        mmap(
            std::ptr::null_mut(),
            total,
            PROT_NONE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1,
            0,
        )
    };
    if raw as isize == -1 {
        return Err(last_error("mmap reserve"));
    }

    let start = raw as usize;
    let aligned = match start
        .checked_add(alignment - 1)
        .map(|value| value & !(alignment - 1))
    {
        Some(value) => value,
        None => {
            // SAFETY: raw,total are the exact mapping just returned by mmap.
            unsafe { munmap(raw, total) };
            return Err(PhysicalError::Overflow);
        }
    };
    let prefix = aligned - start;
    let suffix = total - prefix - len;

    if prefix != 0 {
        // SAFETY: prefix is a page-aligned prefix wholly inside the mapping.
        if unsafe { munmap(raw, prefix) } != 0 {
            let error = last_error("munmap alignment prefix");
            // SAFETY: the original mapping remains live after failed munmap.
            unsafe { munmap(raw, total) };
            return Err(error);
        }
    }
    if suffix != 0 {
        let suffix_address = (aligned + len) as *mut c_void;
        // SAFETY: suffix_address and suffix describe the page-aligned tail.
        if unsafe { munmap(suffix_address, suffix) } != 0 {
            let error = last_error("munmap alignment suffix");
            // SAFETY: after prefix trimming, this is the remaining live mapping.
            unsafe { munmap(aligned as *mut c_void, len + suffix) };
            return Err(error);
        }
    }

    let base = NonNull::new(aligned as *mut u8).ok_or(PhysicalError::Overflow)?;
    Ok(Reservation { base, len })
}

pub(in crate::physical) unsafe fn commit(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    // SAFETY: caller guarantees this is a page-aligned live reservation range.
    if unsafe { mprotect(base.as_ptr().cast(), len, PROT_READ | PROT_WRITE) } != 0 {
        Err(last_error("mprotect PROT_READ|PROT_WRITE"))
    } else {
        Ok(())
    }
}

pub(in crate::physical) unsafe fn protect_none(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    // SAFETY: caller guarantees this is a page-aligned live reservation range.
    if unsafe { mprotect(base.as_ptr().cast(), len, PROT_NONE) } != 0 {
        Err(last_error("mprotect PROT_NONE"))
    } else {
        Ok(())
    }
}

/// En Linux, `madvise(MADV_DONTNEED)` no quita la protección: sin un
/// `mprotect(PROT_NONE)` previo, la página descartada seguiría siendo
/// legible (como ceros). `AddressSpace` protege siempre antes de descartar,
/// de modo que un fallo de `madvise` deja la página `Protected`, nunca
/// accesible.
pub(in crate::physical) const PROTECT_BEFORE_DISCARD_REQUIRED: bool = true;

/// Descarta el backing de un rango ya protegido (`PROT_NONE`). Una
/// reconfirmación posterior (`mprotect(PROT_READ|PROT_WRITE)`) lo ve a cero.
///
/// # Safety
/// El rango está alineado a página y pertenece a una reserva viva.
pub(in crate::physical) unsafe fn discard(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    // SAFETY: el llamador garantiza un rango alineado de una reserva viva;
    // MADV_DONTNEED sobre un mapping anónimo privado PROT_NONE es válido.
    if unsafe { madvise(base.as_ptr().cast(), len, MADV_DONTNEED) } != 0 {
        Err(last_error("madvise MADV_DONTNEED"))
    } else {
        Ok(())
    }
}

pub(in crate::physical) unsafe fn release(reservation: &Reservation) -> Result<(), PhysicalError> {
    // SAFETY: reservation is the exact, still-live aligned mapping retained after trimming.
    if unsafe { munmap(reservation.base.as_ptr().cast(), reservation.len) } != 0 {
        Err(last_error("munmap release"))
    } else {
        Ok(())
    }
}
