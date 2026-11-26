# Kernel ELE — Fase 1

Kernel x86-64 escrito en ELE (sin C ni ensamblador aparte) para el Celeron
3865U: SSE hasta SSE4.2, nunca AVX/FMA. Arranca con Limine por UEFI y se
prueba en QEMU desde Windows.

## Construir y arrancar

```powershell
.\kernel\herramientas\construir.ps1            # ventana de QEMU, serie en la consola
.\kernel\herramientas\construir.ps1 -Prueba    # sin ventana; comprueba "ELE kernel OK"
```

Requisitos: `kernel\compilador\ele.exe` (ver `compilador/README.md`), QEMU en
`C:\Program Files\qemu` (con `share\edk2-x86_64-code.fd`) y Python para las
capturas. Limine 12.11.1 (`herramientas/limine/BOOTX64.EFI`, licencia BSD-2)
ya está en el repositorio. La partición EFI es el directorio
`construccion\esp`, que QEMU monta como disco FAT (vvfat).

Con `-Acelerar`, QEMU usa la virtualización por hardware de Windows (WHPX)
en lugar de emularlo todo: es lo que hay que usar para medir el hito 9.

Prueba completa de los nueve hitos (4 CPU, teclas inyectadas por el monitor):

```powershell
.\kernel\herramientas\construir.ps1 -Prueba -Segundos 180 -Cpus 4 -EsperarAntes "hito 7: escriba" -Teclas "h o l a spc bracket_left a semicolon shift-1 alt_r-q shift-bracket_left u ret" -Esperado "teclado: hola áñ!@ü" -Captura kernel\construccion\hitos.png
```

## Estructura

| Carpeta | Contenido |
|---|---|
| `kmain.l` | entrada `kmain` y la secuencia de hitos |
| `arranque/` | interfaz `arranque*` implementada con el protocolo Limine |
| `cpu/` | GDT+TSS, IDT, `kinterrupcion`, CPUID/SSE/FXSAVE, SMP |
| `mem/` | marcos físicos (mapa de bits), paginación propia, montón |
| `dispositivos/` | COM1, framebuffer, PIC, ACPI, LAPIC/IOAPIC, teclado PS/2 es-LA |
| `tiempo/` | HPET y temporizador del sistema |
| `lib/` | consola (`kprint`) y fuente 8x16 generada |
| `bench/` | SGEMM con SSE empaquetado |
| `herramientas/` | `construir.ps1`, `generar_fuente.py`, `ppm_a_png.py`, Limine |
| `docs/` | auditoría del Paso 0 y bitácora |

No hay carpeta `asm/`: todo lo que necesita una instrucción especial usa los
intrínsecos `take nucleo.cpu` / `take nucleo.mem` del compilador (ver
`docs/language-reference.md`). El trampolín SMP de 16/32 bits se escribe byte
a byte desde ELE (`cpu/smp.l`).
