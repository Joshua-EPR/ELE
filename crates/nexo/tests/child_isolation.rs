//! Pruebas de protección real de memoria en proceso hijo aislado.
//!
//! Verifica que:
//! 1. Se reserve memoria virtual real.
//! 2. Se confirme y permita lectura/escritura física.
//! 3. Se desconfirme/proteja como inaccesible ante el sistema operativo.
//! 4. Un intento de acceso directo desprotegido desde un proceso hijo sea
//!    interceptado por la MMU/núcleo del SO y termine de forma controlada
//!    (Windows: STATUS_ACCESS_VIOLATION 0xC0000005; Linux: SIGSEGV señal 11).
//! 5. El proceso padre continúe sin sufrir fallos de protección.
//! 6. La reconfirmación restaure el acceso real.
//! 7. La API segura de `AddressSpace` y `PhysicalPool` rechace el acceso antes
//!    de cualquier intento de desreferenciación.

use nexo::physical::{AddressSpace, PageAccess, PhysicalError};

#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;

const SUPERPAGE: usize = 64 * 1024;
const PAGE: usize = 4096;

fn run_probe_child(mode: &str) -> std::process::Output {
    let exe = std::env::current_exe().expect("current test executable");
    std::process::Command::new(exe)
        .arg("--nocapture")
        .arg("child_probe_entrypoint")
        .arg("--exact")
        .env("NEXO_CHILD_PROBE_MODE", mode)
        .output()
        .expect("spawn child probe process")
}

#[test]
fn child_probe_entrypoint() {
    let mode = match std::env::var("NEXO_CHILD_PROBE_MODE") {
        Ok(m) => m,
        Err(_) => return, // Ejecutado como test normal del runner padre: no-op.
    };

    match mode.as_str() {
        "read_protected" => {
            let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
            space.commit(PAGE, PAGE).unwrap();
            space.write(PAGE, &[0x42; 64]).unwrap();
            let mut buf = [0u8; 64];
            space.read(PAGE, &mut buf).unwrap();
            assert_eq!(buf[0], 0x42);

            // Proteger como inaccesible
            space.decommit(PAGE, PAGE).unwrap();
            let ptr = (space.base_addr() + PAGE) as *const u8;
            // El acceso volátil debe provocar un fallo de protección de página en hardware
            let val = unsafe { std::ptr::read_volatile(ptr) };
            std::process::exit(if val == 0x42 { 101 } else { 102 });
        }
        "write_protected" => {
            let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
            space.commit(PAGE, PAGE).unwrap();
            space.write(PAGE, &[0x42; 64]).unwrap();

            // Proteger como inaccesible
            space.decommit(PAGE, PAGE).unwrap();
            let ptr = (space.base_addr() + PAGE) as *mut u8;
            // El intento de escritura debe provocar un fallo de protección de página en hardware
            unsafe { std::ptr::write_volatile(ptr, 0x99) };
            std::process::exit(103);
        }
        "recommit_lifecycle" => {
            let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
            space.commit(PAGE, PAGE).unwrap();
            space.write(PAGE, &[0x11; 64]).unwrap();
            let mut buf = [0u8; 64];
            space.read(PAGE, &mut buf).unwrap();
            assert_eq!(buf[0], 0x11);

            space.decommit(PAGE, PAGE).unwrap();
            // La API segura rechaza antes de desreferenciar
            assert!(space.read(PAGE, &mut buf).is_err());
            assert!(space.write(PAGE, &[0x33; 64]).is_err());

            // Reconfirmación restaura el acceso real
            space.commit(PAGE, PAGE).unwrap();
            space.write(PAGE, &[0x22; 64]).unwrap();
            space.read(PAGE, &mut buf).unwrap();
            assert_eq!(buf[0], 0x22);
            space.release().unwrap();
            std::process::exit(0);
        }
        other => {
            eprintln!("Modo de prueba de hijo desconocido: {other}");
            std::process::exit(200);
        }
    }
}

#[test]
fn p03_os_prevents_read_on_protected_page_in_child() {
    let output = run_probe_child("read_protected");
    let status = output.status;

    assert!(
        !status.success(),
        "El proceso hijo debió ser terminado por el SO al intentar leer memoria protegida"
    );

    #[cfg(windows)]
    {
        let code = status.code().unwrap_or(0) as u32;
        const STATUS_ACCESS_VIOLATION: u32 = 0xC000_0005;
        assert_eq!(
            code, STATUS_ACCESS_VIOLATION,
            "En Windows el código de terminación debe ser STATUS_ACCESS_VIOLATION (0xC0000005), recibido: {code:#x}"
        );
    }

    #[cfg(unix)]
    {
        let signal = status.signal();
        assert_eq!(
            signal,
            Some(11),
            "En Linux/Unix el proceso hijo debe ser terminado por SIGSEGV (señal 11), recibido: {signal:?}"
        );
    }
}

#[test]
fn p03_os_prevents_write_on_protected_page_in_child() {
    let output = run_probe_child("write_protected");
    let status = output.status;

    assert!(
        !status.success(),
        "El proceso hijo debió ser terminado por el SO al intentar escribir en memoria protegida"
    );

    #[cfg(windows)]
    {
        let code = status.code().unwrap_or(0) as u32;
        const STATUS_ACCESS_VIOLATION: u32 = 0xC000_0005;
        assert_eq!(
            code, STATUS_ACCESS_VIOLATION,
            "En Windows el código de terminación debe ser STATUS_ACCESS_VIOLATION (0xC0000005), recibido: {code:#x}"
        );
    }

    #[cfg(unix)]
    {
        let signal = status.signal();
        assert_eq!(
            signal,
            Some(11),
            "En Linux/Unix el proceso hijo debe ser terminado por SIGSEGV (señal 11), recibido: {signal:?}"
        );
    }
}

#[test]
fn p03_recommit_lifecycle_in_child_succeeds() {
    let output = run_probe_child("recommit_lifecycle");
    assert!(
        output.status.success(),
        "El ciclo de confirmación, protección y reconfirmación debió completarse con éxito. Salida: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn p03_safe_api_rejects_without_dereferencing() {
    let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
    space.commit(PAGE, PAGE).unwrap();
    space.write(PAGE, &[0x55; 32]).unwrap();

    let mut buf = [0u8; 32];
    space.read(PAGE, &mut buf).unwrap();
    assert_eq!(buf[0], 0x55);

    // Tras decommit, el acceso se bloquea en la capa segura
    space.decommit(PAGE, PAGE).unwrap();
    assert_eq!(space.read(PAGE, &mut buf), Err(PhysicalError::Uncommitted));
    assert_eq!(
        space.write(PAGE, &[0x66; 32]),
        Err(PhysicalError::Uncommitted)
    );
    assert_eq!(space.page_access(PAGE), Ok(PageAccess::Discarded));

    // Reconfirmación restablece el estado accesible
    space.commit(PAGE, PAGE).unwrap();
    assert_eq!(space.page_access(PAGE), Ok(PageAccess::Accessible));
    space.write(PAGE, &[0x77; 32]).unwrap();
    space.read(PAGE, &mut buf).unwrap();
    assert_eq!(buf[0], 0x77);

    space.release().unwrap();
}
