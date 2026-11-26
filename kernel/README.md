# Kernel ELE — Fase 1

**Estado:** los nueve hitos pasan en QEMU y en el Celeron 3865U real
(SGEMM al 59 % del pico SSE; ver `docs/bitacora.md`).

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

## Probar en el equipo real (Celeron 3865U)

```powershell
.\kernel\herramientas\construir.ps1 -Prueba -Imagen    # crea y prueba kernel\construccion\ele.img
```

1. Grabar `kernel\construccion\ele.img` en un USB **en modo imagen/DD**
   (Rufus: "Escribir en modo Imagen DD"). Se borra todo el USB.
2. En el firmware del equipo: arranque UEFI, **Secure Boot desactivado**,
   y arrancar desde el USB (F12/F9/Esc según el fabricante) eligiendo la
   entrada **UEFI** del USB. "Selected boot device failed" (HP) significa
   que se eligió la entrada heredada (Legacy/CSM).
3. Los resultados salen en pantalla. Sin puerto serie físico, la salida
   serie simplemente se pierde.

Qué puede ser distinto del QEMU:
- Sin HPET, el reloj de referencia pasa al temporizador PM de ACPI
  (probado en QEMU con `-SinHpet`).
- El teclado del hito 7 es PS/2 (i8042). El teclado interno de un portátil
  suele serlo. Un teclado USB solo funciona si el firmware lo emula.
- La cifra del hito 9 es la que interesa: el 3865U no tiene turbo, así que
  los FLOP por ciclo de TSC son FLOP por ciclo de núcleo.

## Partición de datos (hitos 13 en adelante)

El kernel solo escribe en el disco dentro de UNA partición marcada para él;
cualquier otro intento es un pánico. Dos formas de marcarla:

- **Recomendada (se puede usar desde Windows):** partición de datos normal,
  formateada en FAT32 con la etiqueta de volumen `ELEDATOS`. En Windows,
  como administrador:

  ```
  diskpart
  list volume
  select volume C          (el volume de Windows, para hacerle sitio)
  shrink desired=4096      (4 GiB)
  create partition primary size=4096
  format fs=fat32 quick label=ELEDATOS
  assign
  exit
  ```

- **Desde Linux** (la laptop de pruebas tiene Linux en todo el disco):
  hay que hacer sitio reduciendo una partición ext4, lo que solo se puede
  hacer con ella desmontada, desde un USB de GParted Live. Con el espacio
  libre: crear una partición de 4-8 GiB y formatearla con
  `sudo mkfs.vfat -F 32 -n ELEDATOS /dev/sdaN`. **Copia de seguridad
  antes**: redimensionar particiones puede perder datos.

- **Cruda:** GUID de tipo `7F03465A-8D62-4902-B881-2A624BFA16B6`
  (`set id=...` en diskpart). Windows no la monta.

En QEMU, `construir.ps1 -DiscoDatos prueba` crea un disco de prueba con
una partición "de Windows" que no se debe tocar, una FAT32 `ELEDATOS` con
`texto.txt` y una cruda.

## Estructura

| Carpeta | Contenido |
|---|---|
| `kmain.l` | entrada `kmain` y la secuencia de hitos |
| `arranque/` | interfaz `arranque*` implementada con el protocolo Limine |
| `cpu/` | GDT+TSS, IDT, `kinterrupcion`, CPUID/SSE/FXSAVE, SMP |
| `mem/` | marcos físicos (mapa de bits), paginación propia, montón |
| `dispositivos/` | COM1, framebuffer, PIC, ACPI, LAPIC/IOAPIC, teclado PS/2 es-LA, PCI, AHCI |
| `almacenamiento/` | GPT y escritura protegida |
| `tiempo/` | HPET, reloj de referencia (HPET o temporizador PM) y temporizador del sistema |
| `lib/` | consola (`kprint`) y fuente 8x16 generada |
| `bench/` | SGEMM con SSE empaquetado |
| `herramientas/` | `construir.ps1`, `crear_imagen.py` (USB GPT+FAT32), `generar_fuente.py`, `ppm_a_png.py`, Limine |
| `docs/` | auditoría del Paso 0 y bitácora |

No hay carpeta `asm/`: todo lo que necesita una instrucción especial usa los
intrínsecos `take nucleo.cpu` / `take nucleo.mem` del compilador (ver
`docs/language-reference.md`). El trampolín SMP de 16/32 bits se escribe byte
a byte desde ELE (`cpu/smp.l`).
