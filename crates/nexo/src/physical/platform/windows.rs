use std::ffi::c_void;
use std::ptr::NonNull;

use super::{PageInfo, Reservation};
use crate::physical::PhysicalError;

const MEM_COMMIT: u32 = 0x0000_1000;
const MEM_RESERVE: u32 = 0x0000_2000;
const MEM_DECOMMIT: u32 = 0x0000_4000;
const MEM_RELEASE: u32 = 0x0000_8000;
const PAGE_NOACCESS: u32 = 0x01;
const PAGE_READWRITE: u32 = 0x04;

#[repr(C)]
#[allow(non_snake_case)]
struct SystemInfo {
    wProcessorArchitecture: u16,
    wReserved: u16,
    dwPageSize: u32,
    lpMinimumApplicationAddress: *mut c_void,
    lpMaximumApplicationAddress: *mut c_void,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: u32,
    dwProcessorType: u32,
    dwAllocationGranularity: u32,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetLastError() -> u32;
    fn GetSystemInfo(system_info: *mut SystemInfo);
    fn VirtualAlloc(address: *mut c_void, size: usize, kind: u32, protect: u32) -> *mut c_void;
    fn VirtualFree(address: *mut c_void, size: usize, kind: u32) -> i32;
    fn VirtualProtect(address: *mut c_void, size: usize, protect: u32, old: *mut u32) -> i32;
}

fn last_error(operation: &'static str) -> PhysicalError {
    // SAFETY: GetLastError has no preconditions and reads thread-local state.
    let code = unsafe { GetLastError() };
    PhysicalError::Os {
        operation,
        code: i32::try_from(code).unwrap_or(i32::MAX),
    }
}

pub(in crate::physical) fn page_info() -> Result<PageInfo, PhysicalError> {
    let mut info = std::mem::MaybeUninit::<SystemInfo>::uninit();
    // SAFETY: `info` points to writable storage large enough for SYSTEM_INFO.
    unsafe { GetSystemInfo(info.as_mut_ptr()) };
    // SAFETY: GetSystemInfo initializes the complete structure.
    let info = unsafe { info.assume_init() };
    Ok(PageInfo {
        page_size: info.dwPageSize as usize,
        allocation_granularity: info.dwAllocationGranularity as usize,
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

    // VirtualAlloc without a requested address chooses a base aligned to the
    // allocation granularity. NEXO currently requests exactly that 64 KiB
    // alignment, so no address hint or fixed mapping is needed.
    if alignment != info.allocation_granularity {
        return Err(PhysicalError::InvalidAlignment {
            alignment,
            granularity: info.allocation_granularity,
        });
    }
    // SAFETY: null requests an OS-selected address; len is validated by the caller.
    let raw = unsafe { VirtualAlloc(std::ptr::null_mut(), len, MEM_RESERVE, PAGE_NOACCESS) };
    let base = NonNull::new(raw.cast::<u8>()).ok_or_else(|| last_error("VirtualAlloc reserve"))?;
    Ok(Reservation { base, len })
}

pub(in crate::physical) unsafe fn commit(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    // SAFETY: caller guarantees this page-aligned range belongs to a live reservation.
    let result = unsafe { VirtualAlloc(base.as_ptr().cast(), len, MEM_COMMIT, PAGE_READWRITE) };
    if result.is_null() {
        Err(last_error("VirtualAlloc commit"))
    } else if result != base.as_ptr().cast() {
        Err(PhysicalError::Os {
            operation: "VirtualAlloc commit returned a different address",
            code: 0,
        })
    } else {
        Ok(())
    }
}

pub(in crate::physical) unsafe fn protect_none(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    let mut old = 0;
    // SAFETY: caller guarantees the range is committed and inside the reservation.
    if unsafe { VirtualProtect(base.as_ptr().cast(), len, PAGE_NOACCESS, &mut old) } == 0 {
        Err(last_error("VirtualProtect PAGE_NOACCESS"))
    } else {
        Ok(())
    }
}

/// `VirtualFree(MEM_DECOMMIT)` devuelve las páginas al estado reservado: tras
/// un éxito cualquier acceso produce una violación de acceso, así que la
/// protección previa es redundante. Si falla, las páginas conservan su estado
/// anterior. `AddressSpace` puede activar la protección previa solo para
/// pruebas de fallo parcial y comparación de coste.
pub(in crate::physical) const PROTECT_BEFORE_DISCARD_REQUIRED: bool = false;

/// Desconfirma un rango (`MEM_DECOMMIT`).
///
/// # Safety
/// El rango está alineado a página y pertenece a una reserva viva.
pub(in crate::physical) unsafe fn discard(
    base: NonNull<u8>,
    len: usize,
) -> Result<(), PhysicalError> {
    // SAFETY: caller guarantees the range is inside the live reservation.
    if unsafe { VirtualFree(base.as_ptr().cast(), len, MEM_DECOMMIT) } == 0 {
        Err(last_error("VirtualFree MEM_DECOMMIT"))
    } else {
        Ok(())
    }
}

pub(in crate::physical) unsafe fn release(reservation: &Reservation) -> Result<(), PhysicalError> {
    // SAFETY: caller transfers the one live reservation and releases the exact base.
    if unsafe { VirtualFree(reservation.base.as_ptr().cast(), 0, MEM_RELEASE) } == 0 {
        Err(last_error("VirtualFree MEM_RELEASE"))
    } else {
        Ok(())
    }
}
