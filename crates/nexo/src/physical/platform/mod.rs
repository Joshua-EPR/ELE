use std::ptr::NonNull;

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
use super::PhysicalError;

#[derive(Clone, Copy, Debug)]
pub(super) struct PageInfo {
    pub page_size: usize,
    pub allocation_granularity: usize,
}

#[derive(Debug)]
pub(super) struct Reservation {
    pub base: NonNull<u8>,
    pub len: usize,
}

#[cfg(all(target_os = "windows", target_arch = "x86_64"))]
mod windows;
#[cfg(all(target_os = "windows", target_arch = "x86_64"))]
pub(super) use windows::*;

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
mod linux;
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
pub(super) use linux::*;

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) fn page_info() -> Result<PageInfo, PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) fn reserve(_len: usize, _alignment: usize) -> Result<Reservation, PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) unsafe fn commit(_base: NonNull<u8>, _len: usize) -> Result<(), PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) unsafe fn protect_none(_base: NonNull<u8>, _len: usize) -> Result<(), PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) unsafe fn decommit(_base: NonNull<u8>, _len: usize) -> Result<(), PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}

#[cfg(not(any(
    all(target_os = "windows", target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub(super) unsafe fn release(_reservation: &Reservation) -> Result<(), PhysicalError> {
    Err(PhysicalError::UnsupportedPlatform(std::env::consts::OS))
}
