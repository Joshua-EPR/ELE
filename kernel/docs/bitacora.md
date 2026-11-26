# Bitácora del kernel ELE

## 2026-11-25 — Preparación y Paso 0

- Creada la carpeta `kernel/`. Todo el trabajo del kernel vive aquí.
- Compilado el driver ELE 0.3.0 (Gen3) desde la semilla PE fijada, sin
  Stage 0: Gen2 == Gen3 bit a bit, smoke y rechazos OK. Copiado a
  `kernel/compilador/ele.exe` (sha256 `8f11ed74…b17f6`), con
  `provenance.json`.
- Auditoría freestanding: `docs/paso0-auditoria-freestanding.md`.
  Hallazgos principales: sin operadores de bits, sin literales hex, sin
  memoria cruda, sin globales, entrada/runtime basados en syscalls Linux,
  sin asm. Sí: codificador x86-64 propio, ELF propio, sin red zone, sin AVX
  posible, copias con `rep movsb`.
- Cambios al compilador: ninguno todavía; esperando decisiones.

## 2026-11-25 — Paso 0 aprobado; incremento 1: bits, hex y envolventes

Decisiones aprobadas (todas las propuestas del informe): operadores de bits
como símbolos, aritmética envolvente `+% -% *%`, memoria cruda por
intrínsecos sobre `Int`, intrínsecos de CPU generados por el compilador,
reservas en `.bss` y datos de bytes en `.rodata`.

Cambios al driver (rama `feat/driver-bitwise-hex`, fuera de `kernel/` porque
es el compilador):

- Literales `0x…` y `0b…` con `_`. Son patrones de 64 bits en complemento a
  dos: `0xFFFF_FFFF_8000_0000` = -2147483648. Más de 64 bits significativos
  es error de sintaxis.
- Operadores `& | ^ << >> ~` y `+% -% *%`, precedencia de Rust
  (`x & MASK == 0` es `(x & MASK) == 0`). `>>` es lógico.
- Desplazar fuera de 0..63 es fallo aritmético (estado 125), no el
  enmascaramiento silencioso de la CPU. Coste: `mov r10,64; cmp; jae`.
- Plegado en `fixed`: el compilador aún no puede usar estos operadores (la
  semilla no los tiene), así que los pliega con limbs de 16 bits.
- x86: nuevos `or`, `not`, `shl/shr r64,cl`; `+% -% *%` son `add/sub/imul`
  sin la comprobación `jo`.
- Stage 0: solo su lexer acepta `| ^ ~` (la prueba de CI lexea el corpus).

Verificación: semilla → Gen1 → Gen2 → Gen3 punto fijo; corpus nativo
151/151 en PE y 151/151 en ELF (WSL), con 6 casos nuevos
(`bitwise_ops`, `shift_out_of_range` y 4 rechazos); contratos Python OK;
`ele_v2_legacy_ratchet`, `native_corpus_l` y `self_coverage` OK; fmt y
clippy limpios.

Problemas encontrados:
- La auditoría de sintaxis v1 (`ele_v2_legacy_ratchet`) contaba todo `&`
  como préstamo legado `&x`. Ahora un `&` tras un operando (número,
  identificador, `)` o `]`) es el and de bits; se añadió su prueba.
- Un `.diag` de rechazo debe nombrar el código: los errores de sintaxis son
  `error[PARSER]`.

`kernel/compilador/ele.exe` actualizado (sha256 `ef22d798…916d3`).
Pendiente: commit y PR de la rama; luego el incremento 2
(`--target kernel`).

PR #186 abierto. El CI falló en Stage 1 (Linux y Windows): lexear `>>` como
un token rompía genéricos legados anidados `List<Option<Int>>`. Corrección:
el lexer vuelve a emitir `>` `>` y el parser une un par adyacente (sin
espacio) en desplazamiento. Suite completa de cargo en local: 98 binarios
OK. `ele.exe` actualizado (sha256 `e06e500d…77ca8`).

## 2026-11-26 — Incrementos 2 y 3: `--target kernel`, intrínsecos, hito 1 ✅

PR #186 fusionado (`main` `3d54d99`); `ele.exe` regenerado desde `main`
(mismo sha `e06e500d…`). Después, en la rama `feat/driver-target-kernel`
(worktree `ELE-wt/kernel-target`):

- `--target kernel`: ELF64 `ET_EXEC` en la mitad alta. `.text` R+X en
  `0xFFFFFFFF80001000`, literales en `.rodata` R aparte, `.symtab` con el
  nombre de cada flow (objdump/GDB/QEMU muestran `kmain`, `serieByte`…).
  Módulo nuevo `codegen/elf64_kernel.l`.
- `--entry <flow>` (por defecto `kmain` en kernel, `main` en el resto). El
  stub es `call kmain; cli; hlt; jmp` (FA F4 EB FD): si kmain vuelve, la
  CPU se detiene.
- Sin runtime: `print`, Text propio, List, choice con datos propios y E/S del
  sistema se rechazan con el código 75 y un mensaje claro.
- Fallos en tiempo de ejecución (overflow, índice, variante): la CPU se
  detiene con el estado (125/126/127) en RDI y línea/columna en RAX, visible
  con `info registers` en el monitor de QEMU. El `--panic kpanico` llega
  cuando haya `kprint` (hito 2).
- Intrínsecos `take nucleo.cpu`: `hlt cli sti pause in8/16/32 out8/16/32`;
  `take nucleo.mem`: `leer8/16/32/64`, `escribir8/16/32/64`. Una instrucción
  en línea cada uno. Solo existen en el módulo que hace el `take`.
- Sondeo de pila: se mantiene (es `or [rsp],0` en línea, inocuo con la pila
  mapeada); no hizo falta desactivarlo.
- `.bss`/globales: aplazado al incremento de globales (aún no hay sintaxis).

Herramientas (instaladas con tu permiso):
- QEMU 20260811 (qemu.weilnetz.de, sha512 verificado) en
  `C:\Program Files\qemu`, con OVMF `edk2-x86_64-code.fd`.
- Limine 12.11.1 (release oficial de GitHub): `herramientas/limine/BOOTX64.EFI`
  (sha256 `4ddecdc6…46592`) con su LICENSE.
- `herramientas/construir.ps1`: compila, arma la ESP como directorio (QEMU la
  monta como FAT con vvfat, sin imagen de disco) y arranca QEMU q35 + OVMF
  con CPU `qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt` (sin AVX/FMA, como el
  Celeron 3865U). `-Prueba` lo hace sin ventana y comprueba la salida serie.

Hito 1 — verificado en QEMU:

```
limine: Loading executable `boot():/boot/kernel.elf`...
ELE kernel OK
```

Problemas encontrados:
- `module` es palabra reservada en Stage 0: un parámetro con ese nombre
  rompía la compilación del driver por Stage 0 (no por la semilla).
- La flow de entrada con parámetros ya la rechazaba el backend (código 50);
  ahora el driver da un mensaje claro.
- **Literales de texto**: `hold s = "..."` crea un Text propio (textbuf +
  append + drop) y eso exige heap; pasar el literal directo a un parámetro
  `view Text` lo rechaza sema. Por eso el saludo va byte a byte. Para el
  hito 2 (`kprint`) hace falta decidir: literales estáticos prestables como
  `view Text` sin copia (recomendado) o heap del kernel antes de tiempo.
- Limine 12 arrancó sin etiqueta de revisión base. Las peticiones de Limine
  (framebuffer, mapa de memoria) necesitan datos estáticos escribibles:
  llegan con los globales/.data en el hito 2.

`ele.exe` actualizado (sha256 `75a07f21…30aa2`).

## 2026-11-26 — Hitos 2 a 9 (rama `feat/kernel-static-data-interrupts`)

PR #187 fusionado. A partir de aquí cada PR lleva a Joshua como coautor.

Compilador (en la misma rama, fuera de `kernel/`):
- Datos estáticos, solo con `--target kernel`: `reservar(bytes, alineación)`
  en `.bss`, `datos64(w...)` en `.data` (hasta 256 palabras) y
  `cadena("texto")` en `.rodata` como registro `[bytes u64][UTF-8]`. Cada
  llamada es un bloque fijo: `flow x() => Int { give datos64(...) }` devuelve
  siempre la misma dirección. Los argumentos se pliegan como en `fixed`.
- Esto resolvió la decisión pendiente de los literales: `kprint` recibe un
  `cadena(...)`, sin heap ni copia.
- CPU: `cpuid`, `rdtsc`, `rdmsr`/`wrmsr`, `leerCr*`/`escribirCr*`,
  `lgdt`/`lidt`/`ltr`, `recargarSegmentos` (retorno lejano), `invlpg`,
  `fxsave`/`fxrstor`, `wbinvd`, `leerRflags`, `int3`.
- Interrupciones: `stubInterrupcion(v)` da la dirección de uno de 256 stubs
  que genera el compilador. Cada uno apila el código de error, el vector y
  los 15 registros, llama a `kinterrupcion(marco)` y termina en IRETQ.
- SSE empaquetado en XMM6..XMM15: `xmmCero`, `xmmCargar`, `xmmGuardar`,
  `xmmDifundir`, `xmmCopiar`, `xmmMultiplicar`, `xmmSumar`. Los acumuladores
  se quedan en registros entre sentencias.
- ELF del kernel: segmentos `.text` R+X, `.rodata` R y `.data`+`.bss` R+W.

Kernel (todo verificado en QEMU con Limine 12.11.1, OVMF, CPU sin AVX/FMA):

| Hito | Resultado en QEMU |
|---|---|
| 2 | framebuffer 1280x800x32, fuente 8x16 Lat15-Fixed16 (dominio público), `kprint` con tildes y ñ |
| 3 | GDT+TSS (IST1 para #DF), IDT de 256 puertas, PIC reprogramado y enmascarado, #BP atendido y reanudado |
| 4 | mapa de bits de marcos (459/510 MiB libres), PML4 propio (HHDM 2 MiB + kernel 4 KiB), montón con división y fusión |
| 5 | CPUID (fabricante, modelo, SSE..SSE4.2, AVX/FMA/XSAVE sin usar), CR0/CR4 para SSE, FXSAVE con MXCSR 0x1F80 |
| 6 | ACPI (XSDT, MADT, HPET), HPET 100 MHz, TSC ~2,8 GHz, LAPIC calibrado; 500 ms de temporizador = 513–521 ms de HPET |
| 7 | teclado PS/2 es-LA por IOAPIC: Mayús, AltGr, Bloq Mayús, teclas muertas ´ ¨ y retroceso (`hola áñ!@ü`) |
| 8 | INIT-SIPI-SIPI con trampolín propio 16→32→64 bits: 3 de 3 AP en línea (`-smp 4`) |
| 9 | SGEMM 128x128 f32 con MULPS/ADDPS: resultado exacto; ~40-48 MFLOPS en QEMU TCG |

Notas honestas:
- El rendimiento del hito 9 en QEMU (emulación TCG) no dice nada del 3865U.
  En hardware real, el código sin asignación de registros quedará lejos del
  50 % del pico. El micronúcleo sí mantiene los acumuladores en XMM. Falta
  medirlo en la máquina real.
- `construir.ps1 -Prueba` inyecta teclas con `sendkey` de QEMU, que usa
  nombres de teclas US (`bracket_left` es la tecla ´ en es-LA).
- Los manejadores de interrupción no guardan XMM: no deben usar Float.

Problema encontrado:
- PowerShell 5.1 `Get-Content`/`Set-Content` sobre un `.l` lo leyó como
  ANSI y lo reescribió como UTF-8 con BOM. Los mensajes de error del
  compilador salieron con mojibake (`nÃºmero`) y el corpus PE lo detectó.
  Lo arreglé y desde entonces solo edito con Python o con las herramientas
  de edición.

## 2026-11-26 — Rendimiento de SGEMM y pánico del kernel (rama `feat/kernel-sgemm-panic`)

PR #188 fusionado. La máquina de desarrollo tiene un i5-7300U (Kaby Lake,
la misma microarquitectura que el Celeron 3865U) y QEMU admite WHPX:
`construir.ps1 -Acelerar` ejecuta el kernel virtualizado, así que el hito 9
se mide en hardware real. Con WHPX los nueve hitos pasan igual, y el
temporizador queda más fino: 500 ms = 501 ms de HPET.

Compilador:
- `xmmMulSumar4(acc, a, dir, desp)`: `acc+j += a * [dir+desp+16j]`, j = 0..3.
  Cuatro MOVUPS+MULPS+ADDPS con una sola carga de la dirección.
- `xmmDifundirEn(r, dir, desp)`: difusión con desplazamiento constante.
- Los argumentos constantes de los xmm* se pliegan como en `fixed`.
- `kpanico(codigo, posicion)`: si existe, la llama el compilador cuando
  falla una comprobación en tiempo de ejecución. El kernel la define en
  cpu/interrupciones.l e imprime causa, línea y columna.

SGEMM 256x256 f32 con WHPX, medido en ciclos de TSC (2,72 GHz):

| Versión | MFLOPS | FLOP/ciclo TSC |
|---|---|---|
| hito 9 original (1 fila x 16, una intrínseca por instrucción) | 1813 (128x128) | 0,67 |
| 2 x 16 con xmmMulSumar4 | 7974 | 2,92 |
| + empaquetado de A y B, k desenrollado x4 | 8232 | 3,02 (micronúcleo 6,35) |
| + empaquetado con copias SSE | 16540–17000 | 6,08–6,24 (micronúcleo 7,1) |

El pico SSE de un núcleo es 8 FLOP/ciclo (un MULPS y un ADDPS de 4 floats
por ciclo). Medido en ciclos de TSC, el total, con empaquetado, es el
76–78 % del pico. Ojo: el i5-7300U sube en turbo hasta ~3,5 GHz y el TSC va
fijo a 2,72 GHz. En ciclos reales de núcleo serían ~4,8 FLOP/ciclo, ~60 %:
sigue por encima del 50 % pedido. El Celeron 3865U no tiene turbo
(1,8 GHz), así que allí ciclo de TSC y ciclo de núcleo coinciden. Falta
medirlo en esa máquina.

## 2026-11-26 — Preparación para el equipo real (rama `feat/kernel-usb-image`)

PR #189 fusionado.

- `herramientas/crear_imagen.py`: imagen de disco GPT con una partición EFI
  FAT32 (nombres largos VFAT incluidos), escrita a mano en Python sin
  dependencias. `construir.ps1 -Imagen` la crea y arranca QEMU desde ella.
  `fsck.fat -n` sobre la partición: sin problemas. `sgdisk -v`: sin
  problemas. Los nueve hitos pasan arrancando desde la imagen.
- `tiempo/reloj.l`: reloj de referencia. Usa el HPET y, si no hay, el
  temporizador PM de ACPI (FADT: PM_TMR_BLK y TMR_VAL_EXT). Lo usan la
  calibración del LAPIC y el arranque SMP. Con `construir.ps1 -SinHpet`
  (q35,hpet=off): 500 ms del temporizador = 503 ms del temporizador PM.
- README: pasos para grabar el USB y arrancar en el 3865U (UEFI, Secure Boot
  desactivado) y qué puede cambiar respecto a QEMU.

## 2026-11-26 — Fase 1 en el equipo real: Celeron 3865U ✅

PR #190 fusionado. Imagen `ele.img` grabada con Rufus (modo DD) y arrancada
por UEFI, con Secure Boot desactivado. El primer intento falló con
"Selected boot device failed": el firmware había elegido el arranque
heredado (Legacy/CSM) del USB. Eligiendo la entrada UEFI arrancó.

Salida en pantalla (foto del 2026-11-26):

| Hito | Resultado en el 3865U |
|---|---|
| 1-2 | `ELE kernel OK`; framebuffer 1366x768x32; tildes y ñ correctas |
| 3 | GDT+TSS, IDT, #BP atendido y reanudado |
| 4 | 3649 MiB libres de 5368 MiB; PML4 propio (CR3 0x32000); montón OK |
| 5 | GenuineIntel, Intel Celeron CPU 3865U @ 1.80GHz; SSE..SSE4.2+, POPCNT+; AVX-, AVX2-, FMA-; XSAVE presente y sin usar; MXCSR 0x1F80 |
| 6 | HPET de 24 MHz (23999999 Hz); TSC 1801 MHz; LAPIC 1501 cuentas/ms; 500 ms = 500 ms |
| 8 | 1 de 1 procesadores secundarios en línea (2 núcleos, sin HT) |
| 9 | SGEMM 256x256: 3911 us, 8577 MFLOPS, **4,76 FLOP/ciclo = 59 % del pico SSE** con empaquetado; micronúcleo 5,44 FLOP/ciclo = 68 % |
| 7 | teclado interno PS/2 es-LA: `Hola`, `que tal?`, `¡?`, `¿?` |

Sin turbo en el 3865U, el ciclo de TSC es el ciclo de núcleo: el 59 % es
real. Supera el 50 % pedido para el hito 9. La Fase 1 queda completa en
hardware real.

# Fase 2

## 2026-11-26 — Hito 10: correcciones de la Fase 1

Plan: contar como RAM solo usable + recuperable del cargador + kernel;
copiar las respuestas de Limine a memoria del kernel y liberar la memoria
recuperable del cargador; informar SGEMM por núcleo y contra el pico del
chip.

- `arranqueCopiar()` (arranque/limine.l) copia, como primera acción de
  kmain, la revisión, el HHDM, la RSDP, las direcciones del kernel, el
  framebuffer y hasta 256 entradas del mapa de memoria. Desde ahí ninguna
  flow `arranque*` toca memoria de Limine.
- `memFisicaTotalBytes()` = usable + recuperable del cargador + kernel. El
  informe muestra aparte lo reservado, ACPI, framebuffer y defectuoso. El
  "5368 MiB" de la Fase 1 era el final de la RAM más alta (incluía el
  agujero PCI de 32 bits).
- `memFisicaRecuperarCargador(leerRsp())`: libera los marcos recuperables
  del cargador, tras el PML4 propio y la copia de Limine. Conserva los que
  están a menos de 64 KiB de la pila de arranque del BSP, que sigue en uso.
- Compilador: intrínseco `leerRsp()` (MOV RAX,RSP), para esa guarda.
- SGEMM informa los núcleos usados (1), los FLOP/ciclo por núcleo y el % del
  pico del chip (16 FLOP/ciclo con 2 núcleos). Confirmado: el SGEMM de la
  Fase 1 corría en un solo núcleo (los AP se quedan en HLT).

QEMU (q35, 4 GiB, WHPX): `RAM: 4089 MiB (usable 4047, del cargador 41,
kernel 176 KiB)`, `no RAM: reservada 259 MiB, ACPI 2160 KiB, framebuffer
4000 KiB`; `libres: 4047 MiB; tras recuperar ... (41 MiB): 4089 MiB`. Los
hitos 2-9 y 7 pasan.

Nota de medición: esta tarde el anfitrión estaba muy cargado (Chrome, CPU
al 80-100 %) y WHPX daba unas 10 veces menos rendimiento en SGEMM que por
la mañana. Con el kernel de `main` sin cambios ocurría lo mismo, así que
es el anfitrión, no una regresión. En TCG con esa carga, el hito 6 midió
733 ms (falla la tolerancia de 400-700 ms): la emulación pierde precisión
de tiempo. Las cifras que cuentan son las de la laptop.

### Hito 10 en la laptop

Primera prueba: memoria bien (`RAM: 3802 MiB (usable 3649, del cargador
152, kernel 176 KiB)`, `no RAM: reservada 380 MiB, ACPI 173464 KiB,
framebuffer 4128 KiB`, libres 3649 -> 3801 MiB tras recuperar 151 MiB).
Pero justo después, `montonReservar(100)` devolvió 0 y la escritura en esa
dirección dio un #PF (CR2 = 0, RIP en `hito4`, confirmado con objdump). No
se reprodujo en QEMU (3,8 / 4 / 6 GiB).

Se añadió diagnóstico: un marco de prueba reservado y liberado antes del
montón; si el montón no crece, `hito 4 FALLÓ` con el motivo (sin marco /
falló el mapeo), los marcos libres y el mapa de memoria completo. Con esa
imagen la laptop arrancó entera ("ya corre correctamente").

Causa sin confirmar. La única diferencia de comportamiento es el marco de
prueba: deja la pista de búsqueda del asignador en el primer marco libre
en vez de en 0. Se mantiene el código tal como se probó en la laptop. El
diagnóstico se queda: si vuelve a pasar, el informe dirá el motivo.
