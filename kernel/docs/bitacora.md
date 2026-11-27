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

**Causa encontrada** (segunda foto: `marco de prueba: 0x0000000000000000`).
En la laptop, Limine marca como "recuperable del cargador" una región que
empieza en la dirección física 0. `memFisicaRecuperarCargador` liberaba
también el marco 0, y la primera reserva posterior devolvía la física 0,
que el asignador usa como "sin memoria". En la primera foto le tocó al
montón. En la segunda se lo llevó el marco de prueba, así que el montón
funcionó por casualidad. QEMU marca la memoria baja de otra forma.

Corrección: la recuperación nunca libera el marco 0 y
`memFisicaReservar` empieza a buscar en el marco 1. Se quita el marco de
prueba y se mantiene el informe de fallo del montón.

Números de la laptop con el hito 10 (foto 2):

| Medida | Valor |
|---|---|
| RAM | 3802 MiB (usable 3649, del cargador 152, kernel 176 KiB) |
| No RAM | reservada 380 MiB, ACPI 173464 KiB, framebuffer 4128 KiB |
| Libres | 3649 MiB -> 3801 MiB tras recuperar 151 MiB |
| Reloj | HPET 24 MHz, TSC 1801 MHz, LAPIC 1500 cuentas/ms; 500 ms = 499 ms |
| SMP | 1 de 1 AP |
| SGEMM 256 | 8587 MFLOPS en 1 núcleo; 4,76 FLOP/ciclo por núcleo = 59 % del núcleo, 29 % del chip; micronúcleo 5,45 = 68 % / 34 % |

## 2026-11-26 — Hito 11: SGEMM en 2 núcleos y matrices grandes

Plan: buzón de trabajos para el AP; SGEMM general (transpuestas, acumular)
en `lib/sgemm.l`; tres variantes del micronúcleo; verificación exacta;
tabla.

- `cpu/buzon.l`: una línea de caché de 64 bytes por núcleo (secuencia
  pedida, hecha, código, argumento, barrera). Sin instrucciones atómicas:
  cada campo tiene un solo escritor y x86 conserva el orden de las
  escrituras. `cpu/trabajos.l` despacha por código. El AP ya no hace HLT:
  atiende su buzón con interrupciones desactivadas.
- `lib/sgemm.l`: C (+)= op(A)·op(B), con op = identidad o transpuesta
  (las transpuestas solo cambian el empaquetado). N múltiplo de 16; M y K
  libres (K se rellena con ceros hasta múltiplo de 4).
- Bloqueo de caché (GotoBLAS): K en tramos de 256, así cada panel de B
  (16 KB) vive en L1. Filas en bloques de 96, con A empaquetada (96 KB) en
  L2. Para cada panel se recorren todos los bloques de filas. Sin esto, con
  N = 2048 cada bloque de filas releía los 16 MB de B: 3,3 F/c.
- Reparto: por tramo de K, cada núcleo empaqueta la mitad de los paneles,
  barrera, calcula su tramo de filas (múltiplo de 6) y barrera de nuevo.
  Las filas de C son líneas de caché enteras: no hay false sharing. Los
  búferes de A son por núcleo y van alineados a 64 bytes.
- Compilador: `xmmMulSumar4M` (MULPS con operando en memoria). Los
  intrínsecos xmm* aceptan XMM1..XMM15 (XMM0 es el temporal).
- Verificación: valores múltiplos de 1/8, así las sumas f32 son exactas.
  Se compara contra el producto ingenuo en enteros, en las filas 0, M/3,
  2M/3 y M-1, y se informa el error relativo máximo: 0 ppm en todos los
  casos.

Errores encontrados:
1. El montón se corrompía. `bufer()` alineaba con `(x + 63) / 64 * 64`,
   pero las direcciones del montón (0xFFFFC000...) son Int negativos y la
   división redondea hacia cero, o sea hacia arriba: la dirección alineada
   se pasaba del margen y pisaba la cabecera del bloque siguiente. Se
   arregló con `& ~63`. `montonVerificar()` queda como comprobación. Regla:
   nunca alinear direcciones de la mitad alta con división.
2. Las listas literales (`List[...]`) no existen con `--target kernel`
   (necesitan montón de usuario): código 75.

QEMU WHPX (i5-7300U, 2 vCPU, anfitrión con ~25 % de carga). F/c = FLOP por
ciclo de TSC; el pico es 8 por núcleo y 16 el chip:

| Variante (512, 1 núcleo) | F/c |
|---|---|
| a) 2x16 MOVUPS+MULPS | 4,73 |
| b) 2x16 MULPS con memoria | 5,03 |
| c) 3x16 MULPS con memoria | **5,65** (elegida) |

| Caso | 1 núcleo F/c | 2 núcleos F/c/núcleo | speedup | % chip | error |
|---|---|---|---|---|---|
| 256 A·B | 4,14 | 5,79 | 2,79 | 72 | 0 |
| 256 Aᵀ·B | 6,10 | 3,31 | 1,08 | 41 | 0 |
| 256 A·Bᵀ | 3,74 | 5,35 | 2,85 | 66 | 0 |
| 256 C+=A·B | 3,30 | 5,77 | 3,49 | 72 | 0 |
| 64x256 · 256x1024 | 4,59 | 4,20 | 1,82 | 52 | 0 |
| 64x1024 · 1024x256 | 5,39 | 4,83 | 1,79 | 60 | 0 |
| 64x256 · 256x768 | 5,66 | 5,12 | 1,80 | 64 | 0 |
| 512 | 5,40 | 4,77 | 1,76 | **59** | 0 |
| 1024 | 5,49 | 4,78 | 1,74 | **59** | 0 |
| 2048 | 5,37 | 5,01 | 1,86 | **62** | 0 |

Speedups por encima de 2 y las caídas en casos pequeños son ruido de WHPX:
el anfitrión reparte los vCPU con otros procesos y tiene turbo. Las cifras
buenas saldrán de la laptop. En TCG la prueba omite 1024 y 2048 y pasa
igual (hito 11 OK).

### Hito 11 en la laptop (Celeron 3865U, 2 núcleos, 1,8 GHz sin turbo) ✅

Con esta imagen también queda confirmado el arreglo del marco 0 (hito 10):
montón bien, 3649 -> 3801 MiB libres.

Variantes (512, 1 núcleo): a) 4,74 · b) 4,85 · **c) 5,10** FLOP/ciclo
(elegida c).

| Caso | 1 núcleo MFLOPS | F/c | 2 núcleos MFLOPS | F/c/núcleo | speedup | % chip | error |
|---|---|---|---|---|---|---|---|
| 256 A·B | 8504 | 4,72 | 16636 | 4,61 | 1,95 | 57 | 0 ppm |
| 256 Aᵀ·B | 8407 | 4,66 | 16465 | 4,57 | 1,95 | 57 | 0 ppm |
| 256 A·Bᵀ | 7450 | 4,13 | 14670 | 4,07 | 1,96 | 50 | 0 ppm |
| 256 C+=A·B | 8430 | 4,68 | 16527 | 4,58 | 1,96 | 57 | 0 ppm |
| 64x256 · 256x1024 | 7990 | 4,43 | 15467 | 4,29 | 1,93 | 53 | 0 ppm |
| 64x1024 · 1024x256 | 7636 | 4,23 | 14265 | 3,96 | 1,86 | 49 | 0 ppm |
| 64x256 · 256x768 | 8316 | 4,61 | 15375 | 4,26 | 1,84 | 53 | 0 ppm |
| **512** | 9060 | 5,03 | 17966 | 4,98 | 1,98 | **62** | 0 ppm |
| **1024** | 9421 | 5,23 | 18651 | 5,17 | 1,97 | **64** | 0 ppm |
| **2048** | 9654 | 5,36 | 19065 | 5,29 | 1,97 | **66** | 0 ppm |

Criterio de aceptación cumplido: exacto en todos los casos y por encima del
50 % del pico del chip completo (16 FLOP/ciclo) con N >= 512 (62-66 %). La
escala de 1 a 2 núcleos es casi lineal (x1,95-1,98) en hardware real.
Comparado con la Fase 1 (256, 1 núcleo, 29 % del chip), el chip completo
rinde ahora más del doble. Lo más débil son las formas planas del
transformer (M = 64): 49-53 %. El bloque de 96 filas queda a medio llenar y
el empaquetado de B pesa más. Se puede mejorar cuando lleguen los tensores.

## 2026-11-26 — Hito 12: PCI Express

Plan: base ECAM desde la tabla MCFG; recorrer todos los buses; mostrar
fabricante, dispositivo, clase y BAR; identificar el controlador de disco;
bus mastering y MSI.

- `acpi.l` lee la MCFG (segmento 0: base, primer y último bus).
- `dispositivos/pci.l`: configuración por ECAM, mapeada sin caché página a
  página. Enumeración bus/disp/fn (las multifunción por el bit 7 del tipo
  de cabecera), hasta 128 funciones. Los BAR se miden con el sondeo
  estándar (decodificación apagada, escribir ~0, restaurar), incluidos los
  de 64 bits. Capacidades: MSI, MSI-X y PCIe.
- `pciHabilitarDma` (memoria + bus master). `pciConfigurarMsi` (dirección
  0xFEE00000 | destino, dato = vector) queda escrita, pero sin activar: un
  vector sin manejador dejaría el LAPIC con el bit de servicio ocupado y
  bloquearía el temporizador y el teclado. Se activa con el driver de disco.
- Si el disco aparece como RAID (Intel RST) o IDE, el kernel se detiene con
  un aviso, como pide el plan.
- Paginación: `siguiente` ya no confunde una página de 2 MiB con una
  tabla. Si la zona ya está cubierta por el HHDM, pagMapear4k falla
  limpiamente y el acceso usa esa página.

QEMU (q35):
```
PCI: ECAM en 0xE0000000, buses 0-255, 6 funciones:
  00:00.0 8086:29c0 060000 puente anfitrión
  00:01.0 1234:1111 030000 pantalla BAR0m=0080000000/16384K BAR2m=0081085000/4K
  00:02.0 8086:10d3 020000 red BAR0m=... MSI MSI-X
  00:1f.0 8086:2918 060100 puente ISA/LPC
  00:1f.2 8086:2922 010601 SATA AHCI BAR4e=0000006040/32 BAR5m=0081084000/4K MSI
  00:1f.3 8086:2930 0c0500 SMBus BAR4e=0000006000/64
disco: AHCI en el bdf 0xFA (00:1f.2), con MSI
```

## 2026-11-26 — Hito 13: driver AHCI y escritura protegida

Plan: AHCI por sondeo; leer la GPT y mostrarla entera; escritura solo
dentro de la partición marcada (cualquier otra = pánico); medir MB/s;
escritura de prueba verificada con CRC32.

- `dispositivos/ahci.l`: ABAR (BAR5) sin caché y GHC.AE. Cada puerto con
  DET = 3 y firma 0x101 lleva un marco propio (lista de órdenes, FIS
  recibidos y tabla de la orden 0). READ/WRITE DMA EXT (LBA48), hasta 256
  KiB por orden. Cada página del búfer es una entrada de la PRDT, con su
  física vía `pagTraducir`. IDENTIFY da el tamaño. Espera por sondeo de CI
  con tiempo límite (reloj de referencia) y detección de TFES.
- `almacenamiento/disco.l`: GPT (cabecera en el LBA 1 y todas las
  entradas), con tipo, LBA, MiB y nombre. Partición permitida:
  - GUID de tipo propio `7F03465A-8D62-4902-B881-2A624BFA16B6`, o
  - partición de datos Microsoft con sector de arranque FAT32 y etiqueta
    `ELEDATOS`. Así se puede preparar desde Windows con diskpart y copiarle
    el dataset (hito 14). Cambié la idea de una firma en los primeros
    bytes, que chocaba con el sector de arranque FAT.
  - `discoEscribir` sin habilitar, o fuera de la partición, llama a
    `panico()`.
- `lib/crc32.l` (IEEE, tabla), `lib/panico.l`,
  `mem/paginacion.pagTraducir`.
- `herramientas/crear_disco_prueba.py`: disco GPT de 256 MiB con
  "Datos Windows" (0xAB, no se debe tocar), FAT32 `ELEDATOS` con texto.txt
  de 3 MiB y una partición cruda con el GUID propio.
  `construir.ps1 -DiscoDatos prueba` lo conecta al puerto 1 del AHCI.

QEMU:
```
AHCI versión 0x10000: 2 disco(s)
disco 1 (puerto 1): 256 MiB
       1  datos Microsoft  2048 - 67583  32 MiB  Datos Windows
       2  datos Microsoft  67584 - 329727  128 MiB  ELEDATOS
       3  DATOS ELE  329728 - 524254  94 MiB  ELE crudo
lectura secuencial: 64 MiB en 134 ms = 500 MB/s
partición ELE: LBA 67584 - 329727
regla: escritura fuera de la partición rechazada (LBA 0 y frontera)
escritura de prueba (LBA 329664, 32 KiB): patrón CRC32 0x22AD1964, leído
0x22AD1964; original 0x011FFCA6, restaurado 0x011FFCA6
hito 13 OK
```
Después de la prueba, desde el anfitrión: la partición "Datos Windows"
sigue intacta (todo 0xAB) y `fsck.fat` da la FAT32 por buena.

Error encontrado: un búfer de 256 KiB del montón no empieza en página y
ocupa 65 páginas. La PRDT pasó de 64 a 72 entradas.

## 2026-11-26 — Hito 14: FAT32 y checkpoints A/B

Plan: FAT32 de lectura (rutas, nombres largos) y escritura simple
(crear/sobrescribir en la raíz); checkpoints en dos ranuras alternas con
CRC y prueba de corte.

- `almacenamiento/fat32.l`: montaje desde el sector de arranque. Lectura por
  rutas con '/'; nombres largos VFAT comparados sin distinguir mayúsculas
  (ASCII), o 8.3. Lectura de clusters contiguos en una sola orden.
  Escritura: `fatCrear` (8.3, raíz; reutiliza los clusters si caben, si no
  libera y reserva) y `fatEscribir` (en el lugar, por sectores). La FAT se
  escribe en todas sus copias. La pista de libres de FSInfo se marca como
  desconocida (0xFFFFFFFF) al reservar.
- `ahciVaciar` (FLUSH CACHE EXT) y `discoVaciar`.
- `almacenamiento/checkpoint.l`: ranuras CKPT_A.BIN y CKPT_B.BIN de
  capacidad fija, creadas una sola vez (es la única operación que toca la
  FAT). Cabecera: magia, versión, paso, bytes, CRC32 de los datos y CRC32
  de la propia cabecera. Orden: datos, vaciar, cabecera, vaciar. Se
  escribe siempre la ranura que no tiene el último paso. Al cargar se
  prueba primero la más reciente; si sus datos no cuadran, la otra.

QEMU, primer arranque (disco de prueba nuevo):
```
FAT32 montada: 512 bytes por cluster
texto.txt: 3145736 bytes en 21 ms, CRC32 0xAD64C905   (anfitrión: 0xad64c905)
  primera línea: El compilador mide los datos del día con paciencia.
SALIDA.TXT escrito y leído de vuelta: idéntico
checkpoint: ninguno válido (primer arranque)
guardado el paso 1; corte simulado a mitad del paso 2
recarga inmediata: paso 1
hito 14 OK
```
Segundo arranque con el mismo disco:
```
checkpoint recuperado: paso 1 de la ranura A, datos verificados
guardado el paso 2; corte simulado a mitad del paso 3
```
`fsck.fat -n` sobre la partición después de las escrituras: sin errores
(solo indica que el contador de libres no está inicializado, como se
pretendía).

### Hitos 12-14 en la laptop

```
PCI: ECAM en 0xE0000000, buses 0-255, 17 funciones
  00:17.0 8086:9d03 010601 SATA AHCI ... BAR5m=0xd1333000/2K MSI
  02:00.0 10ec:8168 020000 red (Ethernet Realtek)
  03:00.0 168c:003e 028000 red (Wi-Fi Qualcomm Atheros) MSI MSI-X
  00:14.0 8086:9d2f 0c0330 USB xHCI ...
disco: AHCI en 00:17.0, con MSI                        -> hito 12 OK
AHCI versión 0x10301: 1 disco: 476940 MiB (puerto 0)
  GPT: 1 2048-4095 (1 MiB, arranque BIOS de GRUB)
       2 4096-4198399 (2 GiB, Linux)
       3 4198400-976771071 (474889 MiB, Linux)
lectura secuencial: 64 MiB en 588 ms = 114 MB/s    (disco duro)
sin partición marcada para ELE: SOLO LECTURA
```

El controlador está en modo AHCI, así que no hay que detenerse. El disco
es un HDD de 500 GB con Linux en todo el disco, sin Windows. Para los hitos
13 y 14 hace falta crear la partición FAT32 `ELEDATOS`, reduciendo la
partición 3 desde un USB de GParted. Lo decide el usuario. Se añadieron
nombres para los tipos de arranque BIOS, swap y LVM de Linux.

### Hitos 13 y 14 en la laptop, con la partición ELEDATOS ✅

El usuario creó la partición en el Ubuntu Server de la laptop, sin USB de
GParted y sin tocar ningún ext4. El grupo LVM tenía 63,76 GiB libres al
final del volumen físico:
`pvresize --setphysicalvolumesize 447G /dev/sda3`,
`parted resizepart 3 943216639`, `parted mkpart ELEDATOS fat32 943216640
976771071` y `mkfs.vfat -F 32 -n ELEDATOS /dev/sda4` (16 GiB, clústeres de
8 KiB, bandera msftdata). `/` y `/srv/postgres` quedaron intactos.

Primer arranque:
```
       4  datos Microsoft  943216640 - 976771071  16384 MiB  ELEDATOS
lectura secuencial: 64 MiB en 599 ms = 111 MB/s
partición ELE: LBA 943216640 - 976771071
regla: escritura fuera de la partición rechazada (LBA 0 y frontera)
escritura de prueba (LBA 976771008, 32 KiB): patrón 0x22AD1964, leído 0x22AD1964;
original 0x011FFCA6, restaurado 0x011FFCA6
hito 13 OK
FAT32 montada: 8192 bytes por cluster
SALIDA.TXT escrito y leído de vuelta: idéntico
guardado el paso 1; corte simulado a mitad del paso 2
hito 14 OK
```
Segundo arranque: `checkpoint recuperado: paso 1 de la ranura A, datos
verificados`.

El texto.txt de la laptop resultó ser una página HTML de 913 bytes: el
servidor de Gutenberg bloqueó la descarga por curl. El kernel lo leyó bien,
pero queda pendiente copiar un texto real de varios MB. La lectura de
varios MB con clústeres de 8 KiB se comprobó en QEMU, con una FAT32 creada
por mkfs.vfat -s 16 y un texto de 5 MiB: 5242914 bytes en 16 ms, CRC32
0xBEB090E9, igual que en el anfitrión.

## 2026-11-26 — Hito 15: tensores y operaciones

Plan: puente Float <-> f32 y más SSE en el compilador; matemática de
referencia en f64; tensores sobre una arena; PCG; exp/tanh SSE con su error
medido; forward/backward de cada operación, verificados con diferencias
finitas en f64.

Compilador (intrínsecos 85-109):
- `leerF32`/`escribirF32` (MOVSS + CVTSS2SD / CVTSD2SS) en nucleo.mem;
  `bitsDeFloat`, `floatDeBits`, `raizF` (SQRTSD). Los intrínsecos ya tienen
  tipos por argumento y por resultado (Int / Float / Unit) en sema, en el
  verificador LIR y en el backend.
- SSE empaquetado: SUBPS, DIVPS, MAXPS, MINPS, SQRTPS, ANDPS, ANDNPS, ORPS,
  XORPS, CVTPS2DQ, CVTTPS2DQ, CVTDQ2PS, PADDD, PSUBD, PSLLD/PSRLD (inmediato),
  CMPPS y SHUFPS (inmediato), MOVSS con memoria. Prueba de codificación en
  `driver_kernel_target_l`.

Kernel:
- `lib/matf64.l`: expF (reducción con ln2 partido + Taylor hasta r^14), logF
  (atanh en serie), expm1F, tanhF, raizF64, `kprintCientifico`.
- `lib/aleatorio.l`: PCG32 XSH-RR con semilla y secuencia (`*%` y `+%`).
- `lib/tensor.l`: tensores 2D f32/f64 con paso de fila (vistas), datos
  alineados a 64, gradiente opcional. Arena por bloques de 2 MiB del
  montón con marca/vuelta. Nota: son bloques virtuales de 2 MiB respaldados
  por páginas de 4 KiB; mapear páginas grandes de verdad queda para cuando
  la arena se conecte a NEXO.
- `lib/ops.l`: matmul (SGEMM en f32 con N % 16 == 0, si no escalar),
  suma con sesgo difundido, multiplicación, embedding, máscara causal,
  softmax estable, RMSNorm, GELU (aproximación tanh) y entropía cruzada,
  todas con backward que suma a los gradientes. Las reducciones se hacen
  en Float, en orden fijo: el resultado es determinista. Se escriben una vez
  sobre tLeer/tEscribir, así el mismo código corre en f32 y en f64.
- `lib/vexp.l`: exp (Cephes: acotar, n = redondeo(x·log2 e), ln2 = C1 + C2,
  polinomio de grado 5, 2^n por PADDD+PSLLD 23) y tanh
  (1 - 2/(exp(2|x|)+1), con serie para |x| < 1/16 y mezcla por máscara).
- `bench/gradientes.l`: L = Σ W⊙y con W aleatorios; diferencias centradas en
  f64 con h = 1e-6 sobre cada elemento de cada entrada.

QEMU (WHPX):
```
PCG32 (semilla 42, secuencia 54): 0xA15C02B7 0x7B47F409 0xBA1D3330 0x83D2F293
tensor 64x256 f32 alineado a 64: sí
exp SSE: 2097152 valores en [-87, 88], error relativo máximo 8,02e-08 (1,35 ulp)
tanh SSE: en [-10, 10], error absoluto máximo 1,03e-07, relativo 1,56e-06
  matmul            3,03e-09   matmul f32/SGEMM 1,35e-04 (umbral f32 1e-3)
  suma con sesgo    1,96e-09   multiplicación   1,02e-08
  embedding         1,28e-09   máscara+softmax  3,78e-10
  softmax           6,45e-09   RMSNorm          1,09e-09
  GELU              2,28e-07   entropía cruzada 6,55e-09
hito 15 OK
```
Los primeros valores de PCG32 coinciden con los del ejemplo de referencia
de pcg32 (semilla 42, secuencia 54): 0xa15c02b7 0x7b47f409 0xba1d3330
0x83d2f293.

Pendiente y anotado:
- La máscara causal sola no se puede verificar con diferencias finitas:
  L incluiría W·(-1e9) y la cancelación se come la precisión. Se verifica
  como se usa, softmax(máscara(x)).
- Lo elemento a elemento es escalar (Float por elemento); solo SGEMM y
  exp/tanh van vectorizados. exp SSE cuesta ~11 ciclos por valor, por el
  coste de cada intrínseco sin asignación de registros. Paralelizar y
  vectorizar el resto se decide en el hito 17, con el perfil real de
  dónde se va el tiempo, como pide el plan.

## Hito 16 — AdamW y primer aprendizaje (2026-11-26)

Escrito por un agente redactor (Sonnet) con encargo cerrado; revisado y
verificado en QEMU por el líder.

Kernel:
- `lib/optim.l`: AdamW sobre una lista de tensores parámetro. Estado m, v
  por parámetro; corrección de sesgo con 1 - beta^t; decaimiento de pesos
  desacoplado (`p·(1 - lr·decay)`) con bandera por parámetro (no se aplica a
  sesgos ni ganancias); warmup lineal y luego coseno hasta lr_min; recorte
  por norma L2 global (suma en Float, orden fijo). `optPaso` devuelve la
  norma antes del recorte; `optUltimoLr` el lr usado.
- `lib/matf64.l`: `cosF` (reducción a [-pi, pi] y seno de Taylor de x/2),
  `fmtEntero`, `fmtDecimal` y `kprintDecimal` (coma decimal).
- `bench/aprender.l`:
  - XOR con MLP 2-16-2 (Linear, GELU, Linear, entropía cruzada).
  - Dos círculos concéntricos (PCG, 256 + 256 puntos) con MLP 2-32-2.
  - Bigramas por bytes sobre `texto.txt` de la FAT32: tabla 256x256
    (embedding), lotes de 256 pares, 1500 pasos, lr 0,1 sin decay.
    Partición 90/10. La entropía H de bigramas sale de los conteos, y
    también la pérdida exacta de entrenamiento del modelo.
  - Si no hay texto.txt (o es < 4 KiB), la prueba se da por omitida.
  - Log en pantalla y en `ENTRENA.LOG`: paso, pérdida, lr, norma, ms por
    paso, pares por segundo. Se escribe por sectores con fatEscribir y al
    final se ajusta el tamaño con fatCrear y discoVaciar.

QEMU (WHPX, 2 CPU), salida resumida:
```
XOR: pérdida 0,00005, aciertos 4/4                (600 pasos, 0,084 ms/paso)
círculos: entrenamiento 256/256, prueba 256/256   (800 pasos, ~10 ms/paso)
-- Bigramas por bytes: texto 3145736 bytes, entrenamiento 2831157, validación 314579
   pares distintos 184, H(entrenamiento) = 1,8805 nats, H(validación) = 1,8790 nats
paso 0 pérdida exacta de entrenamiento 5,5452
paso 1500 ...                                     (~55 ms/paso, ~4600 pares/s)
bigramas: H = 1,8805 nats, pérdida de entrenamiento 1,8839 (exceso 0,0035),
          pérdida de validación 1,8827 (H validación 1,8790)
hito 16 OK
```
El texto del disco de prueba es sintético, con un vocabulario pequeño (solo
184 pares distintos), así que H es baja. La prueba de verdad es el
texto.txt del portátil.

Pendiente y anotado:
- El paso de bigramas (~55 ms) está dominado por lo escalar: AdamW sobre
  65536 parámetros y entropía cruzada elemento a elemento en Float.
  Vectorizar o paralelizar eso entra en el perfilado del hito 17.

## Cambio de rumbo: la IA del SO es ENCA (2026-11-26)

- Hito 15 queda como está. Ya cumplía el alcance recortado: arena, PCG,
  exp/ln/softmax con error medido y verificación de gradientes de todas las
  operaciones hechas. No quedó nada a medias.
- AdamW, el MLP y los bigramas (el hito 16 anterior, PR #198) quedan en pausa
  como línea base opcional. Su código sigue en `bench/aprender.l` y se
  compila como `lineaBaseAdamW()` en kmain, pero no se llama al arrancar.
- Prueba en el portátil de esa línea base:
  - XOR: 4/4 a 0,168 ms por paso.
  - Círculos: 256/256 en prueba a unos 17 ms por paso.
  - Bigramas: omitidos, porque texto.txt en el portátil es una página HTML.

## Hito 16 (nuevo) — ENCA en el kernel, reproducción exacta (2026-11-26)

Escrito por un agente redactor (Sonnet) con encargo cerrado. Inventario de
ENCA hecho por un agente lector (Haiku). Referencia medida y verificación
en QEMU hechas por el líder.

Referencia en Windows: exp009 solo con C5 (`ENCA/experiments/enca_exp009_c5.l`),
backend Cranelift, 20 s. Imprime cada métrica también como mantisa entera
por 2^e, porque el print de Float redondea a 15 decimales y no es exacto.

Port (`kernel/enca/`):
- Archivos: `matematica.l`, `ventana.l`, `memoria_secuencial.l`,
  `corteza_bytes.l`, `mezclador_geometrico.l`, `modelo.l`, `exp009.l`.
- Matemática: f64 en todo, con las mismas funciones de `src/math` de ENCA
  (expFloat de Taylor elevada a 16, lnFloat, lnRapido, la constante
  0.69314718056 truncada), en el mismo orden de operaciones.
- Memoria: registros como bloques con desplazamientos de 8 bytes. Todo se
  reserva al iniciar con montonReservar: 72 086 706 B, de ellos 70 782 976 B
  de hipocampo. 0 reallocs.
- Corpus: los 18 archivos de ENCA se leen de la FAT32 ELEDATOS bajo
  `enca/<ruta>`, con tamaño y CRC32 verificados contra la tabla de Windows.
- Herramientas: `construir.ps1 -Enca <dir>` copia el corpus al disco de
  prueba y al ESP del USB (para pasarlo al disco del portátil desde Linux).

QEMU (WHPX, 2 CPU), extracto:
```
corpus ENCA verificado (18 archivos: tamaño y CRC32)
corteza: actualizaciones=180397 (vigilia cerradas=92407, consolidaciones en sueño=147743) | hipocampo: sobrescrituras=10799
PRUEBA A: bits/byte mezcla=1.307006210338917 hipocampo=1.580774745956898 corteza=3.136908783715093 | top-1=811 por mil
  exacto: mezcla 5886232681853270 * 2^-52, hipocampo 7119176556848176 * 2^-52, corteza 7063690614717264 * 2^-51
PRUEBA B: bits/byte mezcla=2.767418975801085 hipocampo=3.952569359328105 corteza=3.976527428229150 | top-1=637 por mil
  exacto: mezcla 6231673534097902 * 2^-51, hipocampo 8900394946913047 * 2^-51, corteza 8954343722000678 * 2^-51
entrenamiento: 125061 B; vigilia 3414 B/s; sueño (2 pasadas) 4425 B/s; total 1342 B/s de corpus
inferencia (evaluación sin autocompletado): 3838 B/s; autocompletado 1,2 s
RAM reservada por ENCA: 72086706 B (68 MiB); tiempo total ENCA 107 s
ENCA C5: idéntico a Windows
hito 16 OK
```

| | Windows (Cranelift) | kernel (QEMU WHPX) |
|---|---|---|
| bits/byte A | 5886232681853270·2^-52 | idéntico |
| bits/byte B | 6231673534097902·2^-51 | idéntico |
| tiempo C5 | 20 s | 107 s |

Resultado: idéntico bit a bit, no solo por debajo de 1e-9. Se compararon
las 6 métricas exactas, los contadores, los 12 pesos del mezclador, top-1
y autocompletado.

La diferencia de velocidad (unas 5 veces) viene del backend del kernel
(código ELE nativo sin asignación de registros, frente a Cranelift) y del
acceso a memoria por intrínsecos. Optimizar es el hito 17: SSE en exp/ln,
dos núcleos y registros.

Portátil (Celeron 3865U, 1,8 GHz). El corpus se copió del ESP del USB a
sda4 desde Ubuntu.
```
corpus ENCA verificado (18 archivos: tamaño y CRC32)
PRUEBA A ... exacto: mezcla 5886232681853270 * 2^-52 ... top-1=811 por mil
PRUEBA B ... exacto: mezcla 6231673534097902 * 2^-51 ... top-1=637 por mil
entrenamiento: 125061 B; vigilia 56640 ms = 2207 B/s; sueño (2 pasadas) 85762 ms = 2916 B/s; total 142403 ms = 878 B/s de corpus
inferencia (evaluación sin autocompletado): 46957 B en 20318 ms = 2311 B/s; autocompletado 2001 ms
RAM reservada por ENCA: 72086706 B (68 MiB); tiempo total ENCA 167 s
ENCA C5: idéntico a Windows
hito 16 OK
```

| | Windows (Cranelift) | QEMU WHPX | portátil |
|---|---|---|---|
| bits/byte A y B | referencia | idéntico | idéntico |
| entrenamiento (B/s de corpus) | — | 1342 | 878 |
| inferencia (B/s) | — | 3838 | 2311 |
| tiempo total C5 | 20 s | 107 s | 167 s |

Línea base para el hito 17: 878 B/s de entrenamiento y 2311 B/s de
inferencia en el portátil.

## Hito 17a — ENCA optimizada: perfil, modo exacto más rápido y modo rápido (2026-11-26)

Escrito por un agente redactor (Sonnet). Verificado por el líder en QEMU
con 2 CPU y con 1 CPU.

Perfil (`enca/perfil.l`, rdtsc por componente). Se apaga con la constante
PERFIL. Antes de optimizar, en vigilia (766k ciclos por byte) dominaban:
- logits + softmax de la corteza: 31 %
- predicción del mezclador: 27 % (exp/ln por cada uno de los 256 símbolos)
- sinapsis + k-WTA: 23 %

Optimizaciones exactas (el hito 16 sigue "idéntico a Windows"):
- tablas precalculadas de los tres términos del impulso y de 1 - fuga;
- punteros recorridos con `+%` en los bucles calientes, sin llamadas;
- pesos recorridos por filas, conservando el orden de suma de cada logit;
- expFloat y lnRapido en línea, con las mismas operaciones;
- k-WTA con el corte guardado en un local.

Resultado: el modo exacto pasa de 107 s a 52 s en QEMU (vigilia 766k → 432k
ciclos por byte).

Modo rápido (indicador en el modelo; `enca/rapido.l`):
- SSE f32:
  - Salida de la corteza y softmax con vexp, con tope inferior de x - máx
    en -16, como expFloat.
  - El mezclador geométrico, también en f32.
  - Nuevo `vln` (logf de Cephes con SSE): error absoluto máximo 9,73e-7,
    relativo 7,82e-8 en el barrido.
  - Predicción del hipocampo en una pasada densa más los símbolos vistos.
    El aprendizaje del hipocampo sigue en f64.
- 2 núcleos:
  - Los activos de la corteza dependen solo de los bytes, así que el
    avance (sinapsis + k-WTA, en f64) se reparte entre los dos núcleos.
  - El núcleo 1 hace un tramo de unidades y el 0 el resto más la
    predicción; después se fusionan las dos listas ordenadas.
  - Una sincronización por byte, que cuesta 5–6 % del paso.
  - Es determinista: mismos bits con 1 y 2 CPU.

QEMU WHPX, 2 CPU:
```
delta bits/byte (rápido - exacto) PRUEBA A: mezcla -0.000212265640437 hipocampo 0.000000001317018 corteza -0.004224731283444
delta bits/byte (rápido - exacto) PRUEBA B: mezcla -0.000410779630853 hipocampo 0.000000004094365 corteza -0.005386310526380
  vigilia       exacto 6442 B/s, rápido 33444 B/s, aceleración 5.19x
  sueño         exacto 10598 B/s, rápido 39581 B/s, aceleración 3.73x
  entrenamiento exacto 2907 B/s, rápido 12433 B/s, aceleración 4.27x
  inferencia    exacto 6269 B/s, rápido 21642 B/s, aceleración 3.45x
  tiempo total ENCA: exacto 52514 ms, rápido 13572 ms, aceleración 3.86x
hito 17 OK
```

Frente al hito 16 original (107 s), el modo rápido es unas 8 veces más
rápido.

Con 1 CPU el modo rápido da exactamente los mismos bits:
- mezcla A: 5885276722394095·2^-52
- mezcla B: 6230748540601682·2^-51

En ese caso la aceleración es de 2,41x.

En el rápido, top-1 y autocompletado no cambian (811 y 637 por mil;
3446 y 952 caracteres). El Δ de la corteza sola (-0,004 a -0,005) se debe
a que vexp es exacta y expFloat (polinomio elevado a 16) se aparta de e^x
hasta un 5 % en -16.

Memoria: el hipocampo exacto se libera al terminar el hito 16, y el rápido
reserva el suyo. ENCA ocupa unos 75 MiB por las tablas del impulso.

Pendiente:
- El avance de la corteza en f64 es el cuello de botella. Repartido entre
  los dos núcleos no escala perfecto: en total suma 103–113k ciclos frente
  a 79k con uno solo.
- 17b: modo interactivo y guardado del estado con los checkpoints A/B.

## Hito 17b — ENCA interactiva y estado en checkpoints A/B (2026-11-26)

- `checkpoint.l` tiene dos juegos de ranuras (CKPT_PRUEBA: CKPT_A/B.BIN del
  hito 14; CKPT_ENCA: ENCA_A/B.BIN), cada uno con capacidad y cabecera propias.
  Orden de escritura intacto (datos, vaciar, cabecera, vaciar).
- `fat32.l`: la FAT se escribe una vez por sector (modo diferido al reservar
  y liberar cadenas) y `fatEscribir` junta clusters contiguos; sin esto crear
  dos ranuras de 71 MB con clusters de 512 B tardaba mucho.
- `enca/estado.l`: formato del estado (cabecera de 256 B con configuración y
  16 métricas exactas, luego modelo, ventana, hipocampo, corteza, mezclador),
  71 315 216 bytes. Sin punteros; las tablas derivadas se recalculan.
- Arranque: si hay ranura válida y compatible se carga, no se entrena, se
  evalúa A y B y se exige igualdad bit a bit con la cabecera; luego se guarda
  paso + 1 en la otra ranura. Si no, entrena, evalúa y guarda el paso 1.
- `enca/interactivo.l` + hito 7: prompt `ENCA> `, prefijo a UTF-8, completado
  voraz (hasta 200 bytes o `\n`) con el modelo congelado.
- QEMU WHPX: guardar 1557 ms (45,7 MB/s), cargar 1656-1873 ms (38-43 MB/s),
  completado ~0,09 ms por byte. Disco de prueba de 512 MiB (FAT32 de 384 MiB).

Verificación del líder en QEMU (WHPX, 2 CPU, disco nuevo y después el mismo
disco):
```
arranque 1: estado ENCA: ninguna ranura válida (ENCA_A.BIN / ENCA_B.BIN): se entrena
            estado ENCA guardado: paso 1 en la ranura A, 71315216 bytes; ... 1524 ms = 46.7 MB/s
            hito 17 OK
arranque 2: estado ENCA: ranura A, paso 1, 71315216 bytes leídos y verificados (CRC32) en 1627 ms = 43.8 MB/s
            estado recuperado: evaluación idéntica a la guardada
            estado ENCA guardado: paso 2 en la ranura B, ... 1537 ms = 46.3 MB/s
            hito 17 OK
ENCA> hold x = 1; hold a = 1; hold a = 1; hold a = 1; ...
  [200 bytes generados en 84 ms, 0.420 ms por byte]
```

Revisión del cambio en fat32.l:
- Al cambiar de sector, el sector de FAT con cambios se escribe antes de
  leer el siguiente.
- `fatEscribir` puede juntar más de 512 sectores en un tramo, pero
  discoEscribir ya trocea en órdenes de 512 y comprueba la partición sobre
  todo el rango.

Observaciones:
- El completado voraz cae enseguida en bucles ("hold a = 1;" repetido). Es
  lo esperable con argmax en un modelo de contexto corto. Opciones para
  más adelante: muestreo con temperatura (PCG), penalizar la repetición o
  búsqueda en haz.
- El hito 11 a veces sale FALLÓ en QEMU: 2048x2048 queda en 49 % del pico
  (umbral 50 %), y Aᵀ con 2 núcleos va más lento que con 1 (x0,48). Es la
  CPU virtual del anfitrión compartida con Windows: el código del SGEMM no
  cambió, y en el portátil da 62–66 %.

Portátil, segundo arranque (carga el estado del primero):
```
RAM reservada por ENCA: 75251274 B (71 MiB); tiempo total ENCA 84 s      (exacto; era 167 s en el hito 16)
ENCA C5: idéntico a Windows
hito 16 OK
ENCA rápido: núcleos en línea (BSP incluido): 2
estado ENCA: ranura A, paso 1, 71315216 bytes leídos y verificados (CRC32) en 2965 ms = 24.0 MB/s
PRUEBA A ... exacto: mezcla 5885276722394095 * 2^-52 ... top-1=811 por mil
PRUEBA B ... exacto: mezcla 6230748540601682 * 2^-51 ... top-1=637 por mil
estado recuperado: evaluación idéntica a la guardada
estado ENCA guardado: paso 2 en la ranura B, 71315216 bytes; serializar 78 ms; escritura con CRC32 y vaciado 2761 ms = 25.8 MB/s
hito 17 OK
ENCA> hola + b + c", 1)                               [14 bytes, 0,084 ms por byte]
ENCA> 01 = this.nHid + 1] * this.nHid + 1] * ...      [200 bytes, 0,937 ms por byte]
```
- El modo rápido da en el portátil exactamente los mismos bits que en QEMU
  (mezcla A 5885276722394095·2^-52). Es determinista también entre máquinas.
- En el portátil, el modo exacto pasó de 167 s a 84 s con las
  optimizaciones que no cambian bits.
- Guardar y cargar van a unos 25 MB/s en el HDD, frente a 46 MB/s en QEMU;
  incluyen el CRC32 de 71 MB y el vaciado.

## Hito 18 — generación de ENCA sin bucles: muestreo y penalización de n-gramas (2026-11-26)

Problema: el completado voraz (argmax) caía en bucles ("hold a = 1; hold a = 1; ...").
`enca/muestreo.l` elige cada byte de la distribución de la mezcla del modelo
rápido (256 probabilidades f32), todo en orden fijo y sin depender del tiempo.

Diseño (por byte):
1. Penalización por continuación de n-grama. Para cada posición j de la
   ventana (últimos W bytes de prefijo + generado) donde el sufijo actual,
   de largo L >= m (m = 4), ya apareció terminando en j, el byte que siguió
   (hist[j+1]) es candidato a penalizar; cada byte candidato se penaliza una
   sola vez con el mayor L de sus emparejamientos: p <- p / pen^e, con
   e = min(1 + (L-m)/4, 8). Una penalización por presencia castigaría siempre
   a espacios y letras comunes; esta solo castiga repetir lo ya visto, y
   crece con la longitud del emparejamiento (un bucle largo se corta aunque
   el modelo esté muy seguro). Emparejamiento máximo contado: 64 bytes.
2. Temperatura: p ∝ p^(1/T); T = 0 equivale a argmax tras penalizar.
3. top-k (k = 0 desactiva) y top-p (p = 1 desactiva) sobre la distribución
   con temperatura; lista acotada a k, en orden de puntuación y, a igual
   puntuación, byte menor primero. Se descartan los pesos < e^-16 del máximo.
4. Inversión de la CDF con PCG32 (`lib/aleatorio.l`). Cada completado
   re-siembra con la semilla configurada: la semilla no avanza entre
   completados (mismo prefijo + misma configuración = mismo texto).
Los cálculos van en logaritmos de f64 (lnRapido/expFloat de enca/matematica).

Comandos de `ENCA> ` (línea que empieza por ':'): `:temp`, `:topk`, `:topp`,
`:pen`, `:ventana`, `:semilla`, `:linea si|no`, `:voraz`, `:muestreo`, `:ver`,
`:ayuda`. Decimales con punto o coma. Comando desconocido o valor inválido:
mensaje y no cambia nada. Rangos: temp 0..10, topk 0..256, topp (0,1],
pen 1..100, ventana 1..1024. ':' = Mayús+'.' en el mapa latinoamericano.

Valores por defecto: T 0,5, top-k 10, top-p 1 (apagado), pen 2, ventana 128,
m 4, exponente creciente, semilla 1, parar en '
' = sí.
Medición para elegirlos (QEMU WHPX, 3 semillas x 20 prompts = 60 generaciones
de 200 bytes; "bucle" = subcadena L 8..66 repetida 4+ veces seguidas):

| configuración                                   | con bucle | µs/byte |
|-------------------------------------------------|-----------|---------|
| T0,5 k10 pen 1 (sin penalización)                | 5/60      | 70      |
| T0,5 k10 pen 2 e=1 (una vez por byte)            | 4/60      | 76      |
| T0,5 k10 pen 1,5 e=1                             | 4/60      | 69      |
| T0 (argmax) pen 2 e=1                            | 60/60     | 91      |
| T0 (argmax) pen 2 e creciente                    | 0/60      | 63      |
| T0,5 k10 pen 2 e creciente (DEFECTO)             | 0/60      | 74      |
| T0,3 k10 pen 2 e creciente                       | 0/60      | 71      |
| T0,5 top-p 0,9 sin top-k, pen 2 e creciente      | 0/60      | 70      |
| T0,5 k10 pen 2 e creciente, ventana 32           | 0/60      | 68      |
| T1,0 sin top-k, pen 2 e creciente                | 0/60      | 267     |

(En una exploración previa de 20 prompts: T0,8 k20 e creciente 0/20, con
frases más desordenadas.) La temperatura baja y top-k pequeño dan texto con
estructura de código ELE de ENCA; sin penalización siguen 5/60 bucles, y la
penalización plana (e = 1) no basta cuando el modelo está muy seguro: lo que
corta los bucles es el exponente creciente, que además funciona con T = 0.
T alta y sin top-k es lenta (muchos candidatos) y ruidosa.

Hito automático (después del 17, antes del 7): 20 prompts, 200 bytes sin parar
en '
', configuración por defecto, semilla 20261126; bucle sí/no (voraz y
muestreo) y misma salida con la misma semilla. OK si 0/20 con bucles en
muestreo y 20/20 reproducibles.

| | voraz | muestreo |
|---|---|---|
| prompts con bucle (de 20) | 20 | 0 |
| reproducibles con la misma semilla | (determinista) | 20/20 |
| ms por byte (modelo + elección, sin pantalla) | 0,035 | 0,068 |

El sobrecoste del muestreo es de ~0,033 ms por byte. En el modo interactivo
sube a ~0,45 ms por byte por el dibujo en pantalla.

Ejemplos (muestreo, 80 bytes; ¶ = salto de línea):
- `flow main` -> `() => Int { ¶ this.wRec: wRecSnap[i] ¶ ¶ change bestMargin { ¶ wRe`
  (voraz: `() => Int { ` y luego espacios)
- `hold x = ` -> `0 ¶ hold redundante (espaldo[idxIn] - this.alphas: Int = 0 ¶ ¶ each i am`
  (voraz: `1; hold a = 1; hold a = 1; hold a = 1; ...`)
- `each i among ` -> `0..this.nFeat) ¶ hold b = conteoPrev += 1.0) ¶ wOutAncla[idxOut] = t`
  (voraz: `0..this.nHid + i] * deltaOut[o] * this.nHid + i] * this.nHid + i] ...`)
- `take ` -> `"../math/rng.l" ¶ ¶ // --- 1. NÚCLEO MATEMÁTICO PURO ENCA-EXP-002 (CORTEZA ESCA`

Límites: el modelo es un LM de bytes pequeño; el texto tiene estructura
(sangría, llaves, nombres del corpus) pero no es código válido. Las palabras
inventadas ("EpisodioTarea(mong") salen de mezclar contextos. El detector de
bucles también cuenta una racha larga de espacios (32+) como bucle.

Verificación del líder en QEMU (WHPX, 2 CPU, disco nuevo):
- Hitos 11–17 OK; el 16 sigue "idéntico a Windows".
- `prompts con bucle: voraz 20/20, muestreo 0/20`; `reproducibles con la misma semilla: 20/20`.
- ms por byte: voraz 0,035 y muestreo 0,066; `hito 18 OK`.
- El detector de bucles (mzTieneBucle) se revisó: hay 4 copias seguidas
  de largo L si buf[i] == buf[i+L] durante 3L bytes, con L de 8 a 66.

Portátil (Celeron 3865U):
```
prompts con bucle: voraz 20/20, muestreo 0/20
reproducibles con la misma semilla: 20/20
ms por byte: voraz 0.064, muestreo 0.116, sobrecoste del muestreo 0.052
hito 18 OK
ENCA> :ver      -> modo: muestreo  temp 0,500  topk 10  topp 1,000  pen 2.000  ventana 128  semilla 1  linea si
ENCA> :voraz ; flow main      -> flow main() => Int {   [12 bytes, 0.086 ms por byte]
ENCA> :muestreo ; :semilla 5 ; hold x =   -> hold x = -1   [4 bytes, 0.167 ms por byte]
```
Los textos generados son los mismos que en QEMU (por ejemplo el prompt
[20]): el muestreo es determinista también entre máquinas.

## Hito 19 — opción de arranque "ENCA desde cero" (2026-11-26)

Problema: con ENCA_A.BIN/ENCA_B.BIN válidos el hito 17 carga el estado y no
entrena, así que en el portátil no se podía medir la velocidad de entrenamiento
exacto frente a rápido.

Cómo se pasa la opción:
- Limine 12.11.1, petición "Executable Cmdline" (ID `4b161536e598651e b390ad4a2f1f303a`
  tras el prefijo común; respuesta: revisión + puntero a la cadena). El kernel la copia en
  `arranqueCopiar()` (hasta 255 bytes) y la expone con `arranqueLinea()`,
  `arranqueOpcion(clave)` (valor de "clave=valor", separadas por espacios, o 0) y
  `arranqueOpcionEs(clave, valor)`. Al inicio imprime `línea de órdenes: <texto>` o `(vacía)`.
- `kernel/herramientas/limine.conf`: `timeout: 3` y dos entradas: "/ELE kernel" (por
  defecto, sin opciones) y "/ELE kernel (ENCA desde cero: medir entrenamiento)" con
  `cmdline: enca=nuevo` (la clave en Limine 12 es `cmdline:`; `kernel_cmdline:` es la antigua).
- Timeout: `construir.ps1 -Prueba` genera su copia del conf con `timeout: 0` (no espera);
  sin -Prueba (ventana, -Imagen/USB) conserva el menú de 3 s.
- `construir.ps1 -Opciones "enca=nuevo"` pone ese texto como `cmdline:` de la entrada por
  defecto (para QEMU sin menú).

Qué hace `enca=nuevo` en el hito 17: no carga ninguna ranura (no las toca),
entrena en modo rápido desde cero, evalúa, imprime la tabla exacto/rápido y no guarda
("no se guarda: medición"). Comprueba que los bits/byte son los del rápido normal
(A 5885276722394095·2^-52, B 6230748540601682·2^-51) e imprime el resultado. Luego
sigue el hito 18 con el modelo recién entrenado.

QEMU (WHPX, 2 CPU, 2G, disco nuevo):
1. Normal: `línea de órdenes: (vacía)`; `estado ENCA: ninguna ranura válida ... se entrena`;
   `estado ENCA guardado: paso 1 en la ranura A`; hito 17 OK, hito 18 OK.
2. Mismo disco, `-Opciones "enca=nuevo"`: `línea de órdenes: enca=nuevo`;
   `estado ENCA: opción enca=nuevo, se ignoran ENCA_A.BIN/ENCA_B.BIN (no se tocan)`;
   mezcla A 5885276722394095 * 2^-52, B 6230748540601682 * 2^-51; aceleración total 3.74x
   (entrenamiento 2755 -> 10955 B/s); `enca=nuevo: bits/byte idénticos ...`;
   `no se guarda: medición`; hito 17 OK, hito 18 OK. (El hito 11 falló en esta
   corrida por ruido del anfitrión; pasó en las otras dos.)
3. Mismo disco, normal: `estado ENCA: ranura A, paso 1 ... verificados (CRC32)`;
   `estado recuperado: evaluación idéntica`; `estado ENCA guardado: paso 2 en la ranura B`.
   El paso cargado (1) es el mismo que dejó el arranque 1: el 2 no escribió nada, y el 3
   guarda paso+1 en la otra ranura.

### Hito 19: la "diferencia de compilador" en exp009 C5 es exacto frente a rápido

Se planteó que exp009 C5 daba en la prueba B, mezcla, 2,767418975801085 con
el compilador viejo y 2,767008196170232 con el actual. No es una diferencia
de compilador:
- 2,767418975801085 es el modo exacto. Lo dan el compilador actual en
  Windows (Cranelift, medido otra vez el 2026-11-26), QEMU y el portátil:
  mantisa 6231673534097902·2^-51.
- 2,767008196170232 es el modo rápido del hito 17: mantisa
  6230748540601682·2^-51.
- 2,767418975801085 - 0,000410779630853 (Δ rápido - exacto del hito 17)
  = 2,767008196170232.

Caso mínimo. El modo rápido cambia expFloat de ENCA (Taylor de grado 5
en x/16 elevado a la 16, con la entrada saturada a [-16, 16]) por exp en
f32 con SSE (vexp, error ~1e-8):

| x | expFloat | e^x | error relativo de expFloat |
|---|---|---|---|
| -16 | 1,0674385597e-7 | 1,1253517472e-7 | -5,15e-2 |
| -8 | 3,3528353494e-4 | 3,3546262790e-4 | -5,34e-4 |
| -4 | 1,8315515715e-2 | 1,8315638889e-2 | -6,73e-6 |
| -1 | 0,36787944066 | 0,36787944117 | -1,40e-9 |
| 4 | 54,597910838 | 54,598150033 | -4,38e-6 |

En los softmax de 256 símbolos (corteza y mezclador), los términos lejanos
del máximo (x ≈ -8 a -16) quedan subestimados hasta un 5 %. Con vexp la
corteza mejora 0,004–0,005 bits/byte y la mezcla 0,0002–0,0004.

### Hito 19: gzip y xz sobre la prueba B

Prueba B: memoria_secuencial.l y corteza_bytes.l, 15 781 B. Ejecutables
`gzip -9 -n` y `xz -9` de Git para Windows, cada archivo por separado:

| | memoria_secuencial.l (6428 B) | corteza_bytes.l (9353 B) | total B |
|---|---|---|---|
| gzip -9 | 1646 B = 2,049 bpb | 2520 B = 2,155 bpb | 2,112 bpb |
| xz -9 | 1672 B = 2,081 bpb | 2504 B = 2,142 bpb | 2,117 bpb |

Condicional al corpus de entrenamiento: tamaño(entrenamiento + B) -
tamaño(entrenamiento), con Python (gzip nivel 9, lzma preset 9):
- gzip: 1,800 bpb
- xz: 1,588 bpb

ENCA C5 evaluada congelada da 2,767 bpb: peor que gzip -9 incluso sin
corpus. gzip y xz se adaptan al propio archivo mientras lo comprimen;
ENCA congelada no aprende de B. La evaluación precuencial del hito 20
(predecir, medir y aprender) es la comparación justa.

Verificación del líder (QEMU, mismo disco):
- Arranque con `-Opciones "enca=nuevo"`: "se ignoran ENCA_A.BIN/ENCA_B.BIN",
  bits/byte idénticos al entrenamiento rápido normal, aceleración 3,75x,
  "no se guarda: medición".
- Arranque normal después: "estado ENCA: ranura B, paso 2 ... verificados
  (CRC32)" y "evaluación idéntica a la guardada". Las ranuras quedaron
  intactas.

## Hito 20 — exp010: recalibrar el mezclador (C6) y evaluación precuencial (2026-11-26)

Windows primero (`ENCA\experiments\enca_exp010.l`, salida completa en
`ENCA\target\enca_exp010_salida.txt`), luego el kernel.

### Diseño
- **C5**: exp009 C5 sin cambios (mezcla geométrica, vigilia + 2 sueños
  intercalados por archivo, 65536 ranuras). C5-O0 reproduce exp009 bit a bit
  (A 5886232681853270·2^-52, B 6231673534097902·2^-51).
- **C6** = C5 + tras los 2 replays de CADA archivo, una pasada sobre ese mismo
  archivo en la que solo aprende el mezclador: hipocampo y corteza predicen
  pero no aprenden ni consolidan; ventana y vMem avanzan como en evaluación
  (plástico = false). Alternativa no implementada: recalibrar solo una vez,
  tras el último archivo (el mezclador vería la corteza final, pero sobre un
  archivo que ya memorizó).
- **Precuencial**: byte a byte predice, mide (bits de la mezcla, del hipocampo
  y de la corteza, top-1) y aprende con el mismo paso de vigilia del
  entrenamiento (hipocampo, corteza con compuerta de sorpresa, mezclador). Sin
  replay ni autocompletado. A y B parten por separado del estado al terminar
  el entrenamiento; el modelo hospedado no se copia, así que B reentrena
  (determinista; en la salida el "reentrenado" repite las mismas
  estadísticas de corteza).
- **Órdenes** (índices del corpus 0..10): O0 = [0 1 2 3 4 5 6 7 8 9 10],
  O1 = [5 2 8 0 10 3 7 1 9 4 6], O2 = [9 6 1 4 10 0 8 3 5 2 7].

### Tabla de Windows (bits/byte de la mezcla; media y rango sobre O0..O2)
| | C5 media (mín–máx) | C6 media (mín–máx) | C6 − C5 por orden (O0, O1, O2) |
|---|---|---|---|
| A congelada | 1,3189 (1,3070–1,3422) | 1,4181 (1,3954–1,4355) | +0,116 +0,088 +0,093 |
| B congelada | 2,9090 (2,7674–3,0611) | 3,4084 (3,3004–3,4978) | +0,660 +0,402 +0,437 |
| A precuencial | 0,9849 (0,9768–0,9908) | 0,9878 (0,9804–0,9931) | +0,0036 +0,0023 +0,0028 |
| B precuencial | 1,6898 (1,6795–1,7077) | 1,6974 (1,6856–1,7150) | +0,0094 +0,0061 +0,0073 |

C6 empeora en las 4 pruebas y en los 3 órdenes (0/3 mejoras). En las
congeladas la pérdida (0,1 y 0,5) supera con holgura el ruido entre órdenes
(0,035 y 0,29 de rango de C5); en las precuenciales es pequeña (0,003 y 0,008)
pero consistente en signo. Causa probable: el mezclador se recalibra sobre un
archivo que el hipocampo (y la corteza) acaban de memorizar, así que sus
órdenes altos parecen casi perfectos y los pesos suben (orden 4: 0,52 -> 0,98,
orden 5: 0,51 -> 1,06 con O0), sobreconfianza que se paga en archivos nuevos.
Recalibrar sobre datos no vistos (un archivo apartado) sería la variante
honesta; no se probó.

**Mejor configuración: C5** (menor media de B precuencial, 1,6898 frente a
1,6974). Por eso el kernel no necesita la pasada de recalibración; solo la
evaluación precuencial (`modeloPrecuencial` = el paso de vigilia).

Ejemplo O0 (C5): A cong. 1,307 (top-1 811), B cong. 2,767 (637), A prec.
0,9768 (841), B prec. 1,6821 (740).

### Kernel: reproducción exacta (C5, O0)
- `kernel/enca/exp010.l` (nuevo), `modeloPrecuencial` en `modelo.l`, accesos
  `encaCorpusListo/encaTextoDe/...` en `exp009.l`, `hito20` en `kmain.l` y la
  entrada "/ELE kernel (exp010: reproducir mejoras de ENCA)"
  (`cmdline: enca=exp010`) en `limine.conf`.
- Se ejecuta solo con `enca=exp010`; sin ella imprime "hito 20: se ejecuta con
  la opción de arranque enca=exp010". Va justo tras el hito 16 (reutiliza el
  corpus verificado), antes de 17 y 18, de modo que `-Esperado "hito 18"` lo
  incluye.
- Modo exacto: entrena (48 s), evalúa A y B congeladas, A precuencial, libera
  el hipocampo y reentrena (51 s) para B precuencial.
- Salida clave (QEMU WHPX, 2 CPUs, 2 GiB): las cuatro evaluaciones coinciden
  en mezcla, hipocampo, corteza (mantisa y exponente), top-1 y autocompletado
  con Windows; "exp010 C5: idéntico a Windows" y "hito 20 OK". Tiempo total
  117,5 s; 844 280 B procesados = 7186 B/s (exacto). El arranque normal
  (sin opciones) sigue dando hitos 2-18 OK y la línea de aviso del hito 20.

### Comparación con gzip y xz (prueba B, 15 781 B, bpb)
| | bpb |
|---|---|
| gzip -9 (por archivo) | 2,112 |
| xz -9 (por archivo) | 2,117 |
| ENCA C5 congelada | 2,767 |
| gzip -9 condicional al corpus | 1,800 |
| xz -9 condicional al corpus | 1,588 |
| **ENCA C5 precuencial (media O0-O2)** | **1,690** (O0 1,682; 1,680–1,708) |

Precuencial, ENCA supera a gzip y xz por archivo (-20 %) y a gzip
condicional (1,800), pero no a xz condicional (1,588; +6 %).

Verificación del líder:
- Windows: volví a correr `enca_exp010.l`, 4 min 48 s; la salida es
  idéntica byte a byte a ENCA/target/enca_exp010_salida.txt.
- QEMU con `-Opciones "enca=exp010"`: "exp010 C5: idéntico a Windows" y
  "hito 20 OK", en 119 s (7068 B/s en modo exacto). Las mantisas
  precuenciales del kernel (A 8798484689747517·2^-53,
  B 7575402504172646·2^-52) están en la salida de Windows.
- `enca_exp010.l` vive en ENCA/experiments, que está fuera de git
  (/ENCA/ en .gitignore), como el resto de ENCA.

## Hito 21 — ENCA aprende de lo que escribe el usuario (2026-11-26)

Archivos: `enca/aprender.l` (nuevo: aprendizaje, `:guardar`, `:deshacer`, comandos),
`enca/hito21.l` (nuevo: prueba de aceptación), `almacenamiento/checkpoint.l`
(escritura/lectura de una ranura concreta), `enca/exp009.l` (evaluación silenciosa
y accesos), `enca/modelo.l` (`modeloMedirCongelado`), `enca/muestreo.l` (accesos),
`kmain.l` (hito 21 y bucle de ENCA>), `herramientas/limine.conf` (entrada
"/ELE kernel (ENCA: prueba de aprendizaje)", `cmdline: enca=prueba21`).

### Diseño
- **Qué se aprende.** Con `:aprender si` (por defecto) cada línea normal que se
  teclea, más su '\n', es un documento nuevo que se procesa con
  `modeloPrecuencial` (= el paso de vigilia del entrenamiento): predecir, medir
  los bits del byte real con la mezcla y aprender (hipocampo; corteza con la
  compuerta de sorpresa; mezclador), sin replay. Se imprime
  `aprendido: N bytes, X bits/byte` y se vuelve a mostrar lo tecleado para que el
  completado siga a continuación. La generación no aprende. `:aprender no` deja
  ENCA> como antes. `:ver` muestra aprender, umbral, bytes sin guardar, ranura y
  paso actuales y la mezcla B guardada.
- **Cuenta de bytes sin guardar**: sube con cada línea aprendida; vuelve a 0 con
  `:guardar` correcto o `:deshacer`.
- **`:guardar`.** Evalúa las pruebas A y B congeladas con la misma función que el
  hito 17 al cargar (`evaluarAB`, autocompletado incluido, que ya restaura la
  ventana y la corteza), compara la mezcla de B con la del último estado
  guardado o cargado y, si no empeora más que el umbral (`:umbral x`, bits/byte),
  serializa y guarda como paso + 1 en la OTRA ranura con las métricas nuevas en la
  cabecera (la comprobación del hito 17 al recargar sigue valiendo). Si empeora:
  `no se guarda: la prueba B empeora X bits/byte (umbral U); use :deshacer ...`.
  La comparación es contra la última versión guardada, no contra la original: pasos
  pequeños consecutivos podrían acumular degradación (cada uno bajo el umbral).
- **`:deshacer`** (difiere de "volver a la otra ranura" a secas por la
  persistencia; hay que ver que el arranque siguiente carga lo restaurado, y el
  hito 17 carga la ranura de paso MÁS ALTO):
  - con cambios sin guardar: recarga la ranura del último estado guardado o
    cargado (descarta lo aprendido); no escribe nada;
  - sin cambios: recarga la OTRA ranura (la versión anterior) y la reescribe como
    paso + 1 en la ranura de la que se viene (la actual), así sigue siendo la de
    paso más alto y el arranque siguiente la carga. Si las dos ranuras tienen el
    mismo CRC32 (p. ej. recién restaurado, o tras el guardado del hito 17 al
    arrancar, que copia el estado cargado en la otra ranura) o la otra no es válida,
    dice que no hay a dónde volver y no toca nada.
  - Tras recargar (CRC32 de la ranura incluido) se evalúa A y B y se exige igualdad
    bit a bit con la cabecera (como el hito 17); si no coincide, no se reescribe.
    Cuesta ~2 s de evaluación.
  - El estado se deserializa sobre el modelo vivo (los datos derivados, como la
    tabla del impulso, no cambian con el aprendizaje).
- **Umbral por defecto: 0,35 bits/byte** (13 % de la mezcla B, 2,767), con estos
  datos del propio hito (QEMU WHPX, partiendo del estado del hito 17):

  | aprendizaje | delta B (congelada) |
  |---|---|
  | F (284 B, 8 líneas) x1 | -0,149 (mejora) |
  | F x2 | +0,151 |
  | F x5 (prueba de aceptación, 1420 B) | +0,252 |
  | 1 línea `hold zeta = 12` x1 (sobre F x5) | -0,039 |
  | basura (3072 B, PCG) x1, sobre F x5 guardado | +1,514 |
  | basura x2 | +0,599 |
  | basura x3 (prueba de aceptación) | +0,449 |

  El buen aprendizaje (incluso repetido 5 veces) queda en 0,25 y la basura x3 en
  0,45; 0,35 deja ~0,10 de margen por cada lado. Una pasada de basura es muy
  nociva (+1,5) y repetirla la "memoriza" y baja el delta (el mezclador vuelve a
  fiarse de los órdenes altos, como pasaba con C6 en el hito 20): con muchas
  repeticiones la basura podría pasar el umbral, aunque la evaluación mide el daño
  real en B. Por eso la comparación es sobre una prueba congelada y no sobre los
  bits/byte del propio texto aprendido (que bajan siempre).

### Prueba de aceptación (`enca=prueba21`) y reinicio
`hito21()` va tras el 18 y antes del 7. Sin la opción imprime
`hito 21: prueba con enca=prueba21` y mide F congelado con el modelo cargado.
Con ella usa las mismas funciones que los comandos (`aprPasada` = lo que hace
cada línea tecleada, `aprGuardar`, `aprDeshacer`). F: 8 líneas de código ELE con
nombres inventados (zorvalMezclar, lumbre, hebra...; 284 B); basura: 3072 B
imprimibles de un PCG32 con '\n' cada 64.

Arranque 1 (disco nuevo, entrena y guarda el paso 1; luego la prueba):
```
hito 21: ... F = 284 bytes en 8 líneas; umbral de :guardar 0,3500 bits/byte; estado de partida: ranura B paso 2, B guardada 2,7670
a) F congelado antes: 4,2885 bits/byte; completado voraz ... desde 10 bytes: 4/205 bytes
b) pasada 1: 3,2598 bits/byte precuenciales (284 bytes); delta B congelado -0,1492
b) pasada 2: 0,8205 ...; delta B 0,1506   pasada 3: 0,5328   pasada 4: 0,4567
b) pasada 5: 0,4178 ...; delta B congelado 0,2522
b) F congelado después: 0,3791 bits/byte; completado voraz: 51/205 bytes; sin guardar 1420 bytes; aprender 0,053 ms por byte
c) prueba B congelada: 3,0192 (guardada 2,7670), delta B = 0,2522; prueba A: 1,3568 (delta A = 0,0500); evaluación 2087 ms
   guardado: paso 3 en la ranura A, 71315216 bytes; serializar 56 ms; escritura con CRC32 y vaciado 1552 ms = 45.9 MB/s
d) basura, pasada 1: 7,4058 bits/byte (delta B 1,5137)  pasada 2: 0,4480 (0,5992)  pasada 3: 0,3410 (0,4487)
   no se guarda: la prueba B empeora 0,4487 bits/byte (umbral 0,3500); use :deshacer para volver al último estado guardado
   deshacer: se descartan 9216 bytes aprendidos sin guardar; se recarga la ranura A, paso 3
   ranura A leída y verificada (CRC32) en 1622 ms; ... evaluación 2319 ms: idéntica a la cabecera
hito 21: delta B de F 0,2522 (guardado), de la basura 0,4487 (rechazado), umbral 0,3500
hito 21: F congelado 0,379136 bits/byte (bits 0x3FD843C1B61D457D)
hito 21 OK
```
(En el disco de prueba el primer arranque deja el paso 1 en la ranura A; la
prueba parte de la ranura B paso 2 porque el hito 17 copia el estado cargado en
la otra ranura. Hito 11 sale FALLÓ en este equipo por el ruido del anfitrión, como
en las corridas anteriores; el resto de los hitos 2-20 OK.)

Arranque 2 (mismo disco, normal): `estado ENCA: ranura A, paso 3 ... verificados
(CRC32)`, `estado recuperado: evaluación idéntica a la guardada`, guarda el paso 4
en B, `hito 21: prueba con enca=prueba21` y
`hito 21: F congelado 0,379136 bits/byte (bits 0x3FD843C1B61D457D)`: los mismos
bits que el estado guardado en c), no los de antes (4,2885): lo aprendido sobrevive
al reinicio. El arranque con `enca=exp010` también da `exp010 C5: idéntico a
Windows`, `hito 20 OK`, 17 OK, 18 OK.

Arranque 3 (mismo disco, teclas; las ranuras quedaron A paso 5, B paso 4):
```
ENCA> hold zeta = 12
  aprendido: 15 bytes, 6,090 bits/byte  [0.047 ms por byte; sin guardar 15 bytes]
  hold zeta = 12
  [0 bytes generados ...]       (la línea aprendida termina en '\n': el completado la da por cerrada)
ENCA> :ver  -> ... aprender si  umbral 0,3500 bits/byte  sin guardar 15 bytes  ranura A paso 5  B guardada 3,0192
ENCA> :guardar
  prueba B congelada: 2,9799 bits/byte (guardada 3,0192), delta B = -0,0394; prueba A: 1,3513 (delta A = -0,0055); evaluación 2108 ms
  guardado: paso 6 en la ranura B, 71315216 bytes; serializar 67 ms; escritura ... 1641 ms = 43.4 MB/s
ENCA> :deshacer          (sin cambios: versión anterior)
  deshacer: sin cambios pendientes; se vuelve a la versión anterior, ranura A, paso 5
  ranura A leída y verificada (CRC32) en 2626 ms; ...; evaluación 3004 ms: idéntica a la cabecera
  restaurada: reescrita como paso 7 en la ranura B (2329 ms); el próximo arranque la carga
ENCA> :deshacer
  deshacer: no hay a dónde volver (las dos ranuras guardan el mismo estado: B paso 7, A paso 5)
ENCA> hold zeta = 12 ; :deshacer      (con cambios: recarga lo guardado)
  deshacer: se descartan 15 bytes aprendidos sin guardar; se recarga la ranura B, paso 7
  ... evaluación 2431 ms: idéntica a la cabecera
```

### Tiempos (QEMU WHPX, 2 CPU)
- Aprender: 0,043-0,053 ms por byte (~20 KB/s; la vigilia del entrenamiento rápido
  hacía 19 KB/s); una línea tecleada de 15-60 B tarda menos de 3 ms.
- `:guardar`: evaluación A+B congelada 2,1 s (autocompletado incluido) + serializar
  0,06 s + escritura con CRC32 y vaciado 1,6 s (44-46 MB/s) = ~3,8 s en total;
  rechazado: solo los 2,1 s de evaluación.
- `:deshacer`: lectura y CRC32 1,6-2,8 s + evaluación 2,3-5 s (+ reescritura 2,3 s
  sin cambios pendientes).
- En el portátil (HDD, ~25 MB/s) la escritura/lectura de 71 MB sube a ~3 s; no
  probado en este hito.

Límites: ENCA> no tiene un `:guardar` automático; al apagar sin `:guardar` lo
aprendido se pierde. La comparación del umbral es contra la última versión guardada
(ver arriba). Una línea aprendida y vuelta a completar da el '\n' de inmediato: la
memorización es literal, no generalización.


### Hito 21, revisión: variantes del aprendizaje y umbral estrecho
El aprendizaje inicial (a: hipocampo + corteza + mezclador) dañaba B (+0,252 con
F x5, 9 %). Se midieron cuatro variantes con la opción `enca=estudio21` (cada una
desde el mismo estado guardado del hito 17; se restaura con `:deshacer` entre
medidas; F y la basura son los de la prueba de aceptación). `modeloPasoRapido`
elige la variante solo mientras aprende una línea tecleada (`modeloFijarVariante`);
el entrenamiento no cambia.

| variante | dB F x1 | dB F x5 | F congelado antes -> después | voraz F | dB basura x1 | dB basura x3 |
|---|---|---|---|---|---|---|
| a hipocampo + corteza + mezclador | -0,149 | +0,252 | 4,2885 -> 0,3791 | 4 -> 51/205 | +1,244 | +0,765 |
| b sin mezclador (hipocampo + corteza) | -0,024 | -0,031 | 4,2885 -> 0,5582 | 4 -> 51/205 | -0,017 | -0,012 |
| c solo hipocampo | -0,025 | -0,033 | 4,2885 -> 0,5980 | 4 -> 51/205 | -0,021 | -0,020 |
| d mezclador con tasa / 10 + hipocampo + corteza | -0,083 | +0,067 | 4,2885 -> 0,4488 | 4 -> 51/205 | +0,129 | +0,595 |

Lectura:
- Todo el daño sobre B viene del mezclador (y la corteza con él): b y c no dañan B
  ni con basura (la basura queda en el hipocampo/corteza sin tocar la prueba B), así
  que no hay nada que la protección pueda separar: la basura no se rechazaría, y
  la prueba de aceptación exige rechazarla. Además aprenden F algo peor (0,56-0,60
  frente a 0,38-0,45), aunque el completado voraz es igual (51/205) en las cuatro.
- a daña mucho con F x5 (0,252) y la basura x3 da +0,765, separación 3x.
- d conserva casi toda la mejora de F (0,449 frente a 0,379 de a), el voraz idéntico,
  F x5 apenas daña (+0,067, 2,4 %) y la basura x3 daña 9 veces más (+0,595).
  Es la que mejor separa.

**Decisión: variante d por defecto** (`:modoaprender a|b|c|d` elige; `:ver` muestra
la letra) y **umbral 0,20 bits/byte** (7 % de B): 3x por encima de F x5 (0,067) y
3x por debajo de la basura x3 (0,595). Una sola pasada de basura (+0,13) pasa el
umbral: es poco dañina en d. Prueba de aceptación con d (desde el disco nuevo):
F x1 -0,083, x2 -0,032, x5 +0,067 -> `:guardar` guarda (paso 3); basura sobre ese
estado: x1 +0,034, x2 +0,443, x3 +0,455 -> rechazada (umbral 0,2000); `:deshacer`
recarga el paso 3 con evaluación idéntica. F congelado 4,2885 -> 0,4488; voraz
4 -> 51/205. Arranque normal siguiente: `ranura A, paso 3`, `evaluación idéntica a
la guardada`, `hito 21: F congelado 0,448780 bits/byte (bits 0x3FDCB8D0AE580CF4)`
(mismos bits que antes de reiniciar). (Esta revisión sustituye las cifras del
umbral 0,35 y de la variante a que aparecen más arriba en la entrada original.)

Revisión y verificación del líder:
- Con la primera versión (variante a), aprender F cinco veces empeoraba B
  +0,252 bits/byte y el umbral era 0,35. Pedí medir variantes; la tabla de
  arriba muestra que el daño a B lo causa el mezclador.
- Variante b (sin mezclador): la basura tampoco daña B, así que la
  protección no tendría nada que rechazar.
- Variante d (mezclador con tasa/10): separa los dos casos. F×5 da
  +0,067 y la basura×3 da +0,455 a +0,595, con umbral 0,20.
- Limitación: una sola pasada de basura de 3 KB con la variante d daña
  poco (+0,03 a +0,13) y se guardaría. La protección mide el daño a B,
  no si el texto "es basura".
- QEMU, disco nuevo con enca=prueba21:
  - F: 4,2885 → 0,4488 bits/byte; completado voraz 4/205 → 51/205.
  - Guardar F: ΔB +0,0666, guardado (paso 2, ranura B).
  - Basura ×3: ΔB +0,4548, "no se guarda".
  - :deshacer: evaluación idéntica a la cabecera.
  - Resultado: "hito 21 OK".
- Arranques normales después sobre el mismo disco: "estado recuperado:
  evaluación idéntica a la guardada" e "hito 21: F congelado 0,448780
  bits/byte (bits 0x3FDCB8D0AE580CF4)", los mismos bits que al guardar.

## Hito 22 — velocidad de ENCA y del disco (2026-11-27)

Archivos: `dispositivos/ahci.l`, `almacenamiento/{disco,fat32,checkpoint}.l`,
`lib/crc32.l`, `enca/{corteza_bytes,rapido,estado,perfil,exp009,aprender}.l`,
`kmain.l` (prueba de disco crudo), `herramientas/construir.ps1`
(`-PuertoMonitor`, por defecto 45454).

### Parte A — disco
- Checkpoint formato 2: CRC32C (instrucción SSE4.2, `crc32cSse` desenrollada
  de 4 palabras) en cabecera y datos. El formato 1 (CRC32 por software) se
  sigue LEYENDO; se escribe siempre el 2. Compatibilidad probada con copia
  del disco del hito 21: 1er arranque `formato 1 (CRC32)`, se reescribe en
  formato 2 (ranura A, paso 5); 2º arranque `formato 2 (CRC32C)`, evaluación
  idéntica. Leer el formato 1 sigue costando ~1 s de CRC por software.
- AHCI: una orden mueve hasta 8 MiB (`AHCI_MAX_SECTORES` = 16384): las páginas
  contiguas en memoria física se funden en una entrada de PRDT (hasta 4 MiB,
  120 entradas); si la PRDT se llena la orden cubre menos y se encadena otra.
  `fatLeer/fatEscribir` ya no limitan a 512 sectores.
- Medición (`ckptImprimirDesglose`): serializar/copiar, CRC, E/S, vaciado,
  cabeceras y total, con MB/s. QEMU, 71 MB: antes guardar 1670 ms = 42,6 MB/s
  (CRC32 por software ~1,1 s); ahora ~360 ms = 199 MB/s (serializar 45 ms,
  CRC 35 ms = 2000 MB/s, E/S 203 ms, vaciado 119 ms); cargar ~410 ms =
  173 MB/s. En QEMU el límite es la caché del anfitrión, no el medio.
- No se solapó el CRC con la E/S: a 2 GB/s es ~10 % del tiempo en QEMU y <3 %
  a 25-100 MB/s. En el portátil no medido todavía (sin acceso): la lectura
  cruda (`hito disco`, solo lectura: 64 MiB al inicio y final de la partición
  y del disco, órdenes de 8 MiB y de 256 KiB) debe fijar el techo físico; en
  QEMU las órdenes de 8 MiB leen ~2 veces más rápido que las de 256 KiB.
  La meta de >= 100 MB/s en el HDD queda por verificar con esa prueba en el
  equipo real (las pistas interiores/finales de un HDD son más lentas).

### Parte B — modo rápido
Perfil de vigilia antes (ciclos/paso, 2 núcleos): total 128,7k; avance de la
corteza 143,8k sumando ambos núcleos (f64), espera 24k, hipocampo 17,5k,
logits+softmax 14,1k, mezclador 9,4k. Ahora: total 50,4k; avance 38,9k en el
núcleo 1 (etapa A SSE 4,9k, cota 2,4k, k-WTA 29,7k) escondido tras ~41k del
núcleo 0; espera 6,6k.

Cambios: en modo rápido vMem, umbral, decaimiento, 1-fuga y tablas R son f32
alineados; `cortezaAvanzarF32` (4 unidades por instrucción) en un solo núcleo
(sin tramos; 1 y 2 CPU = mismos bits). k-WTA: cota válida por conteo SSE
(k unidades la alcanzan) y filtro vectorial; claves enteras compuestas.
El exacto no cambia (hito 16 y hito 20 `idéntico a Windows`).

| QEMU 2 CPU | exacto | rápido antes | rápido ahora |
|---|---|---|---|
| entrenamiento B/s | 2971 | 12433 | 20282 (6,8x) |
| inferencia B/s | 6135 | 21642 | 28510 (4,6x) |
| total ENCA | 51,8 s | 13,6 s | 9,2 s (5,6x) |

Con 1 CPU: inferencia 3,17x. Δ bits/byte (rápido - exacto), mezcla: A
+0,000399, B +0,000415 (antes -0,00021 y -0,00041; |Δ| < 0,001). top-1 sin
cambio (811 y 637); autocompletado 3422 y 946 (antes 3446 y 952). Determinismo:
1 CPU y 2 CPU dan los mismos bits (mezcla A 5888031017282589·2^-52, B
6232608311089226·2^-51).

Estado de ENCA versión 2: vMem y umbral van como f32. Versión 1 se convierte
al cargar (f64 a f32; Δ mezcla A 2,6e-7, B 0) y se reescribe en v2; la
evaluación ya no puede ser idéntica bit a bit con una v1 (se exige |Δ| <
0,001).

Pendiente: el k-WTA (~30k ciclos) es lo más caro; el código escalar de ELE
cuesta ~250 ciclos por candidato. Hipocampo (11k) y mezclador sin tocar.

Verificación del líder (QEMU WHPX):
- Compatibilidad: generé un disco con el kernel del hito 21 (estado ENCA en
  formato 1) y arranqué con él el kernel del hito 22:
  - Primer arranque: "leídos y verificados (formato 1 (CRC32))".
    Conversión v1 → f32 con Δ mezcla A 2,2e-7. Se reescribe en formato 2
    a 198 MB/s. F congelado con los mismos bits (0x40112763DED1D1FB).
  - Segundo arranque: "formato 2 (CRC32C)", 148 MB/s, "evaluación
    idéntica a la guardada".
- Disco nuevo, 2 CPU: hitos 2–18 OK, el 16 "idéntico a Windows".

| | exacto | rápido | aceleración |
|---|---|---|---|
| entrenamiento | 2907 B/s | 20486 B/s | 7,04x |
| inferencia | 6411 B/s | 28694 B/s | 4,47x |
| tiempo total | 52,3 s | 9,0 s | 5,79x |

  Δ mezcla A +0,00040 y B +0,00042. Guardado a 195,5 MB/s.
- 1 CPU: mismos bits en el modo rápido (mezcla A 5888031017282589·2^-52,
  B 6232608311089226·2^-51); aceleración total 4,16x.
- Pendiente en el portátil: la meta de 100 MB/s se mide en el HDD real. La
  partición ELEDATOS está al final del disco; la lectura cruda al principio
  y al final de la partición dirá cuánto da el propio disco.

## ENCA: barrido de ranuras (2026-11-27)

Archivos: `enca/ranuras.l` (nuevo), `enca/{matematica,exp009}.l`, `mem/monton.l`,
`kmain.l` (`hitoRanuras`, tras el hito 20), `herramientas/{construir.ps1,
crear_corpus_ele.py,crear_imagen.py,crear_disco_prueba.py,limine.conf}`.

### Diseño
- Opción de arranque `enca=ranuras` (menú "ENCA: barrido de ranuras") o
  `enca=ranuras:262144,524288` (lista de S, para repartir el barrido en corridas
  de menos de 10 min). Sin la opción no cambia nada (una corrida normal da
  hito 16 idéntico a Windows y hito 17 OK).
- Modo rápido, C5, solo cambian las ranuras por orden S (65536 ... 4194304).
  Por S: modelo nuevo para el corpus ENCA (vigilia + 2 sueños por archivo,
  pruebas A y B congeladas, con autocompletado como el hito 17), se libera, y
  modelo nuevo para el corpus ELE (mismo esquema por documento; prueba C
  congelada sin autocompletado). No escribe al disco.
- Memoria: antes de cada S se calcula `5*S*(24+12*16)` B + 4 MiB y se compara con
  marcos libres + montón libre; con margen de 256 MiB. Si no cabe: "S no cabe
  (necesita X MiB, libres Y MiB)" y termina; si `montonReservar` da 0 también.
  Todo lo del modelo se devuelve con un rastro de reservas (`ncaRastrear`,
  `ncaLiberarRastreado`; hay reservas alineadas cuyo puntero original se
  perdía). Tras liberar se comprueba `montonEnUso` (volvió exacto en todas) y
  la lista libre (`montonVerificar`).
- `crecer` del montón: si el último bloque libre termina en el fin de la
  región, solo mapea lo que falta (antes mapeaba siempre el tamaño completo y
  desperdiciaba ~40 % al encadenar bloques enormes). Los marcos físicos no
  vuelven al asignador físico: tras liberar, el montón conserva lo mapeado
  (un único bloque libre de ~S x 1080 B, sin fragmentación: 5 bloques libres
  antes y después).
- Coste por ranura (por orden): 1080 B por S y 5 órdenes = 216 B por ranura
  (etiqueta, total y distintos 24 B + 12 sucesores x 16 B). RAM medida =
  1082 MiB para S=1048576.

### Corpus ELE
Código fuente del compilador: `compiler-l/src/**/*.l`, 113 archivos, 1 447 846 B.
Ordenados por ruta relativa (bytes UTF-8); el archivo i (desde 0) es de prueba
si `i % 10 == 9`, si no entrena: 102 documentos de entrenamiento = 1 287 947 B
(CRC32C 0xAAFAB8F7) y 11 de prueba = 159 899 B (CRC32C 0x9815E3D0). Se concatenan
en `ele/entrena.bin`, `ele/prueba.bin` con `ele/indice.bin` (cabecera de 128 B
con magia, versión, recuentos, tamaños y CRC32C de cada .bin, de la tabla y de
la propia cabecera; luego (desplazamiento, longitud) por documento). El kernel
verifica todo y lo imprime; `iniciarDocumento` por archivo. Se prepara con
`construir.ps1 -CorpusEle` (disco de datos y ESP de la imagen USB). Si falta, el
barrido hace solo la parte ENCA y lo dice.

### Resumen y RANURAS.LOG (portátil sin serie ni desplazamiento)
- El barrido guarda sus resultados en memoria (`sumi`/`meta`, búferes de 8 y 32 KiB) y al terminar escribe
  `RANURAS.LOG` en la raíz de la FAT32 (patrón de `ENTRENA.LOG`: `fatCrear` con 32 KiB, sectores de 512 B,
  `fatCrear` con el tamaño real y `discoVaciar`); sin FAT32 lo dice y sigue. Contiene el resumen y las dos tablas.
- `encaRanurasResumen()` (kmain, tras `hitoDiscoCrudo`, antes de `ENCA>`) reimprime el resumen compacto: título,
  memoria libre inicial, CRC32C del corpus ELE, una línea por S (RAM, B/s ELE, bits/byte A, B, C, sobrescrituras
  ELE; ~86 columnas) y la línea "S no cabe (necesita X MiB, libres Y MiB)". Sin `enca=ranuras` no hace nada.
- QEMU 2 GiB: `ranuras:65536,4194304` da la fila de 65536 y "no cabe (necesita 4324 MiB, libres 2027 MiB)";
  `ranuras:65536,131072` guarda 1261 B. Los números de la fila coinciden con la tabla de abajo.

### Resultados (QEMU WHPX, 2 CPU, 3 GiB; 1 corrida por S, mismo kernel)
Corpus ENCA, bits/byte (mezcla / hipocampo), top-1 por mil:

| S por orden | RAM MiB | A mezcla | A hip | B mezcla | B hip | sobrescr. | entren. B/s | eval. B/s |
|---|---|---|---|---|---|---|---|---|
| 65536 | 69 | 1,3074 | 1,5808 | 2,7678 | 3,9526 | 10799 | 20210 | 66129 |
| 131072 | 137 | 1,3070 | 1,5987 | 2,7664 | 3,9823 | 6719 | 20237 | 52009 |
| 262144 | 272 | 1,3014 | 1,5960 | 2,7646 | 3,9924 | 4791 | 19206 | 66068 |
| 524288 | 542 | 1,2940 | 1,5938 | 2,7388 | 3,9857 | 1552 | 20082 | 64519 |
| 1048576 | 1082 | 1,2909 | 1,5940 | 2,7335 | 3,9927 | 541 | 19971 | 64061 |
| 2097152 | 2162 | 1,2906 | 1,5947 | 2,7326 | 3,9926 | 215 | 19640 | 63786 |
| 4194304 | no cabe (necesita 4324 MiB, libres 3047 MiB) | | | | | | | |

Corpus ELE (prueba C, 159 899 B), entrenado con 1 287 947 B:

| S por orden | RAM MiB | C mezcla | C hip | C cor | top-1 | sobrescr. | ocupadas % | entren. B/s | eval. B/s |
|---|---|---|---|---|---|---|---|---|---|
| 65536 | 69 | 2,0958 | 2,4842 | 3,7967 | 670 | 286389 | 36 | 19526 | 55319 |
| 131072 | 137 | 1,9843 | 2,3181 | 3,7964 | 682 | 188585 | 25 | 19408 | 60520 |
| 262144 | 272 | 1,9549 | 2,2583 | 3,7987 | 687 | 125622 | 15 | 18844 | 60220 |
| 524288 | 542 | 1,9272 | 2,2385 | 3,7965 | 692 | 53203 | 8 | 19184 | 60182 |
| 1048576 | 1082 | 1,9248 | 2,2321 | 3,7970 | 693 | 26190 | 4 | 19311 | 58064 |
| 2097152 | 2162 | 1,9076 | 2,2387 | 3,7978 | 690 | 12203 | 2 | 19034 | 59104 |

S=65536 sale con 10799 sobrescrituras y bits como el estado de referencia.

### Conclusión
- Corpus ENCA (125 KB): el hipocampo ya cabe en 65536 ranuras; ocupa 11 % y la
  mezcla solo gana 0,017 bits/byte en A (1,307 a 1,291) y 0,035 en B; satura en
  ~S=524288. Subir S no mejora el hipocampo solo (su bits/byte sube un poco:
  menos desalojo de contextos raros hace la distribución más repartida).
- Corpus ELE (1,3 MB): mejora real y claramente mayor: mezcla 2,096 a 1,925
  (-8 %) de 65536 a 524288, con rendimientos decrecientes (-0,111, -0,029,
  -0,027, -0,003, -0,017 por duplicación); se satura hacia S=524288 a 1048576
  (la prueba C es de 160 KB y es ruidosa a partir de ahí). Hipocampo solo:
  2,484 a 2,232. La corteza no cambia (3,797).
- Velocidad: independiente de S (~19-20 kB/s entrenamiento, 55-65 kB/s
  evaluación): solo se tocan las ranuras que el contexto indica; la creación
  cuesta (1,1 GB en 5,5 s, 2,2 GB en 6,5 s en QEMU).
- Coste: 216 B por ranura de orden, o 1080 B por unidad de S; 542 MiB a 524288.
- Techo del portátil (4 GB, ~3,3 a 3,6 GiB usables, con el margen de 256 MiB):
  S=2097152 (2,2 GiB) debería caber; S=4194304 (4,3 GiB) no cabe en ninguna
  máquina de 4 GB; con 3 GiB en QEMU el límite fue S=2097152. Para estos
  corpus, S=524288 (542 MiB) a 1048576 (1,1 GiB) es el punto razonable.
- Limitaciones: una sola corrida por S; ELE y ENCA con ruido de prueba chica
  (un solo modelo, sin semillas); QEMU/WHPX con el anfitrión cargado (velocidades
  absolutas no son las del Celeron).

### Pendiente en el portátil
Medir con USB (`construir.ps1 -Imagen -CorpusEle -Enca ...`, entrada de menú
"barrido de ranuras", o `enca=ranuras:524288` etc.) todos los S, en especial
524288, 1048576 y 2097152 (si cabe) y los tiempos reales; comprobar que el
Celeron mantiene velocidad independiente de S (su caché es mucho menor que la
de QEMU/anfitrión). Nota: `hito 11` (SGEMM) falló en una corrida de QEMU por
carga del anfitrión (umbral de rendimiento, ajeno a este cambio).

Verificación del líder (QEMU WHPX, 2 CPU, 3 GiB, enca=ranuras:65536,524288 y
-CorpusEle):
- Coincide con la tabla:

| S | A | B | C |
|---|---|---|---|
| 65536 | 1,30741 | 2,76783 | 2,09584 |
| 524288 | 1,29398 | 2,73885 | 1,92722 |

- Corpus ELE verificado (CRC32C 0xAAFAB8F7 y 0x9815E3D0).
- Después del barrido el arranque sigue normal: hito 16 "idéntico a
  Windows", hito 17 guarda a 202 MB/s y los hitos 17 y 18 dan OK. El cambio
  de mem/monton.l no altera el camino normal.

### Hito 22 en el portátil (imagen del hito 22, arranque normal)
```
crc32c 64 MiB: software 1671 ms (38 MB/s), SSE4.2 60 ms (1066 MB/s)
lectura secuencial cruda (solo lectura):
  inicio de la partición: LBA 943216640, 64 MiB en órdenes de 8192 KiB: 871 ms = 76.9 MB/s
  inicio de la partición, tramo siguiente: LBA 943347712, 64 MiB en órdenes de 256 KiB: 864 ms = 77.5 MB/s
  final del disco: LBA 976642096, 64 MiB en órdenes de 8192 KiB: 942 ms = 71.1 MB/s
  final del disco: LBA 976640000, 64 MiB en órdenes de 8192 KiB: 937 ms = 71.5 MB/s
  final del disco, tramo anterior: LBA 976511024, 64 MiB en órdenes de 256 KiB: 917 ms = 73.1 MB/s
hito disco OK
hito 18: voraz 20/20 con bucle, muestreo 0/20; reproducibles 20/20; ms por byte voraz 0.034, muestreo 0.101
hito 21: F congelado 0,451807 bits/byte (bits 0x3FDCEA67E7666A96)
```
- La meta de 100 MB/s no se alcanza en ELEDATOS. El límite es el HDD: la
  partición está en las pistas interiores (de la LBA 943 M a la 977 M de
  un disco de 500 GB), donde el disco da 71–77 MB/s. Órdenes de 8 MiB y de
  256 KiB dan lo mismo, porque el cuello de botella es el medio. Al
  principio del disco (hito 13) daba 111–115 MB/s.
- El CRC32C por hardware (1066 MB/s, 28 veces el software) deja de limitar.
  Guardar y cargar el estado de 71 MB queda acotado por el disco, unos
  70 MB/s, frente a los 25 MB/s de antes del hito 22.
- Para pasar de 100 MB/s habría que mover ELEDATOS al principio del disco,
  reparticionando desde Linux.
- El 0,451807 de F tras reiniciar muestra que lo aprendido persiste. Es
  algo distinto del 0,448780 de QEMU porque la corteza del modo rápido
  pasó a f32 en el hito 22 y el estado del portátil viene de otra historia.

### Barrido de ranuras en el portátil (Celeron 3865U, 4 GB)
```
memoria libre inicial: 3788 MiB (marcos 3721 MiB); corpus ELE CRC32C entrena 0xAAFAB8F7 prueba 0x9815E3D0
medidas 6 de 7 en 723 s
S por orden | RAM MiB | ELE ent B/s | ELE eval B/s | bits/byte A | B | C | ELE sobrescr.
    65536 |      69 |       12745 |        39723 | 1,3074 | 2,7678 | 2,0958 |   286389
   131072 |     137 |       12744 |        39650 | 1,3070 | 2,7664 | 1,9843 |   188585
   262144 |     272 |       12734 |        39556 | 1,3014 | 2,7646 | 1,9549 |   125622
   524288 |     542 |       12718 |        39473 | 1,2940 | 2,7388 | 1,9272 |    53203
  1048576 |    1082 |       12704 |        39385 | 1,2909 | 2,7335 | 1,9248 |    26190
  2097152 |    2162 |       12698 |        39315 | 1,2906 | 2,7326 | 1,9076 |    12203
S=4194304 no cabe (necesita 4324 MiB, libres 3783 MiB)
```
- Bits/byte y sobrescrituras idénticos a QEMU en los 6 tamaños: el modo
  rápido es determinista entre máquinas también con hipocampos grandes.
- Techo de los 4 GB: 2097152 ranuras por orden (2162 MiB). 4194304 no cabe
  por unos 540 MiB.
- Velocidad independiente del tamaño: unos 12,7 KB/s entrenando y
  39,4 KB/s evaluando (0,65 de QEMU).
- Para este corpus (1,29 MB) el punto útil es 524288 ranuras por orden
  (542 MiB). De ahí a 2097152 la RAM se multiplica por 4 y C solo baja de
  1,927 a 1,908. Aprovechar hipocampos más grandes requiere más texto de
  entrenamiento.

## ENCA aprende español (2026-11-27)

Archivos: `enca/espanol.l` (nuevo: corpus, evaluación, entrenamiento, guardar y cargar),
`enca/hablar.l` (nuevo: arranque, conversación, comandos), `enca/aprender.l`,
`enca/exp009.l`, `enca/estado.l`, `enca/interactivo.l`, `almacenamiento/checkpoint.l`,
`kmain.l`, `herramientas/{construir.ps1,crear_imagen.py,crear_disco_prueba.py,limine.conf}`.
No se tocó el compilador ni el modelo de ENCA (`modelo.l`, `rapido.l`, ...).

### Corpus (paso A, `herramientas/crear_corpus_es.py`; no se versiona)
- Español: Wikisource (teatro con turnos, narrativa, poesía; dominio público) y Wikipedia en
  español (CC BY-SA 4.0), volcados de dumps.wikimedia.org del 1/2-nov-2026. Atribución:
  Wikipedia en español (CC BY-SA 4.0) y Wikisource en español.
- Mismo formato que el corpus ELE (`entrena.bin`, `prueba.bin`, `indice.bin` con cabecera
  `ELEIDX01` y CRC32C), en `es/` de la partición de datos. El kernel verifica cabecera, tabla
  y los dos CRC32C antes de usarlo.

| juego | entrena | documentos | prueba | documentos |
|---|---:|---:|---:|---:|
| completo | 30 617 629 B | 2041 | 1 092 883 B | 90 |
| desarrollo | 2 686 710 B | 182 | 1 092 883 B | 90 |

La prueba es la misma en los dos y por obra nunca se entrena. Referencia sobre `prueba.bin`
(bits/byte): gzip -9 3,080; xz -9 2,612; xz condicional al entrenamiento completo 2,238 (al de
desarrollo, 2,407).


### Diseño
- **Herramientas.** `construir.ps1 -CorpusEs <corpus_es\completo|desarrollo>` copia los tres
  archivos a `es/` de la FAT32 de datos de prueba y del ESP de la imagen USB. Con `-CorpusEs` el
  disco de prueba pasa de 512 MiB a **2 GiB** (FAT32 de 1,9 GiB; dos ranuras de 540 MiB más los
  corpus) y la imagen USB de 64 a **128 MiB**. `crear_disco_prueba.py` ya no arma el disco entero en
  memoria: `Fat32.volcar` escribe solo las zonas usadas en un archivo marcado como disperso en NTFS
  (crear el disco de 2 GiB con el corpus completo tarda ~5 s). Sin `-CorpusEs` todo queda como antes
  (512 MiB, 64 MiB).
- **Opción de arranque `enca=hablar`** (menú "/ELE kernel (ENCA: aprender español)"), tras todos
  los hitos y antes de ENCA>:
  1. carga y verifica `es/` (cabecera del índice, tabla de documentos y CRC32C de entrena y prueba);
     si falta lo dice y el arranque sigue normal;
  2. crea un modelo RÁPIDO aparte, el "hablante": C5 con **524288 ranuras por orden** (540 MiB; la
     memoria se comprueba antes: si no caben el modelo, un búfer del mismo tamaño para guardar y el
     corpus, se baja a la mayor potencia de 2 que quepa y se avisa); el modelo de código del hito 17
     (65536 ranuras, 70 MiB) sigue vivo al lado;
  3. entrena documento a documento (vigilia + 2 sueños, como siempre) con una línea de progreso cada
     ~1 MB (bytes, %, B/s, tiempo transcurrido y restante);
  4. evalúa la prueba congelada completa (`prueba.bin`, 1,09 MB) y la imprime por fuente
     (Wikipedia, teatro, narrativa y poesía) y en total, con gzip y xz al lado. El índice no lleva la
     fuente de cada documento: `espanol.l` lleva una tabla de 90 caracteres derivada fuera del kernel
     (teatro y Wikipedia suman exactamente 386 095 B y 451 845 B, las cifras de ESTADISTICAS.md;
     narrativa y poesía van juntas, 254 943 B) que solo se usa si el CRC32C de `prueba.bin` es el
     esperado;
  5. guarda el estado en sus propias ranuras `HABLA_A.BIN` / `HABLA_B.BIN` (`checkpoint.l`, juego
     `CKPT_HABLA`, formato 2 con CRC32C). Es el estado de ENCA de siempre con 524288 en la cabecera:
     `estado.l` ya no fija las ranuras en una constante, las lleva un valor que cambia con el perfil
     (`encaFijarRanurasEstado`); 566 763 280 bytes por ranura;
  6. muestra 10 ejemplos de conversación con prompts fijos.
  Sin la opción, si hay `HABLA_A/B.BIN` válidas el arranque normal **carga** el hablante (después del
  hito 17 y de los de disco): lee la ranura más reciente con su CRC32C, copia el estado al modelo e
  imprime `modelo hablante cargado: ranura X, paso N, 540 MB en T ms (MB/s)`. La prueba completa
  (1 MB, ~18 s) no se repite en cada arranque; solo las pruebas congeladas pequeñas de abajo (63 KB,
  ~1 s) contra las métricas de la cabecera. Si no hay ranuras no se imprime nada y no cambia nada.
  `enca=charla` carga y muestra los ejemplos; `charla=T,k,pen,ventana` cambia su muestreo (se usó
  para medir).
- **Pruebas congeladas del hablante.** La prueba completa tarda ~18 s; `:guardar`, `:deshacer` y la
  comprobación al cargar usan un subconjunto fijo de `prueba.bin`: los primeros 700 B de cada uno de
  los 90 documentos (63 000 B, ~1 s); los de índice par son la prueba "A" y los impares la "B". Sus
  métricas van en la cabecera del estado (mismo formato que A y B de ENCA) y así todo el código de
  `aprender.l` sirve sin cambios: `:guardar` mide el empeoramiento de B contra la última versión
  guardada (umbral 0,2 bits/byte, como siempre).
- **Perfiles.** `exp009.l` guarda dos modelos vivos (código y hablante) y un perfil activo (0 o 1)
  que decide el modelo, el juego de ranuras, las ranuras del formato del estado y el bloque de estado
  de `aprender.l` (ranura, paso, umbral, referencias). `:aprender`, `:modoaprender` valen para los dos.
- **Conversación (ENCA>).** Por defecto, con el hablante cargado, ENCA> conversa. En `entrena.bin` un
  turno de teatro es `NOMBRE:` + salto de línea + el parlamento (versos en líneas) y una línea en
  blanco entre turnos; así que la línea X del usuario se vuelve `TÚ:\nX\n\n`, el contexto es el
  historial de turnos + eso + `ENCA:\n` (no `TÚ: X`, que no se parece a nada del corpus), y se genera
  con el muestreo del hito 18 hasta `\n\n` o 300 bytes. Con `:aprender si` el turno del usuario (no
  lo que dice ENCA) se aprende antes como documento nuevo con el paso de vigilia del hito 21. El
  historial guarda los últimos ~1,5 KB (se descartan los turnos más viejos de dos en dos); cada
  respuesta reinicia el documento del modelo (`iniciarDocumento`) y vuelve a pasar el historial por
  la corteza (~60 ms), de modo que el estado del modelo entre líneas no es una corriente continua:
  la continuidad es el historial. Comandos: `:modelo codigo|espanol`, `:charla si|no`, `:nueva`;
  `:ver` muestra modelo, charla, historial, ranuras por orden y el estado de ranuras y paso del
  perfil activo; `:guardar`, `:deshacer` y `:umbral` actúan sobre el modelo activo (para el hablante,
  `HABLA_A/B.BIN` y las pruebas congeladas de arriba).


### Muestreo por defecto del español (medido)
ENCA> y los ejemplos usan el muestreo del hito 18 (penalización de n-gramas con exponente creciente,
detector de bucles). Para elegir los valores del español se corrió la misma tanda de los 10 prompts
fijos (300 bytes cada uno, semilla 1) con el hablante de desarrollo (`enca=charla charla=T,k,pen,ventana`)
y se midió: bucles (`mzTieneBucle`), palabras generadas que existen en el vocabulario del corpus
(la palabra aparece 3 veces o más en `entrena.bin` completo; mide qué tan "léxico" es el texto) y
diversidad (palabras distintas / palabras; trigramas de palabras repetidos entre respuestas):

| T | top-k | pen | ventana | bucles | palabras en vocabulario | diversidad | trigramas repetidos |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0,3 | 5 | 1,5 | 256 | 0/10 | 97,0 % | 0,28 | 35 |
| 0,4 | 8 | 1,5 | 256 | 0/10 | 95,7 % | 0,36 | 18 |
| 0,5 | 10 | 2 | 128 | 0/10 | 90,7 % | 0,43 | 4 |
| **0,5** | **10** | **3** | **256** | 0/10 | **91,8 %** | **0,48** | **3** |
| 0,6 | 15 | 2 | 128 | 0/10 | 86,7 % | 0,50 | 1 |
| 0,7 | 20 | 1,5 | 256 | 0/10 | 83,2 % | 0,55 | 0 |
| 0,8 | 30 | 2 | 128 | 0/10 | 78,1 % | 0,57 | 1 |

Con temperatura baja el texto usa más palabras reales pero cae en el mismo molde ("de la ... de los
...") en todas las respuestas; con temperatura alta varía, pero inventa palabras. Se eligió
**T 0,5, top-k 10, penalización 3, ventana 256**, sin parar en `\n` (la respuesta termina en
`\n\n` o a los 300 bytes). Ninguna tanda tuvo bucles. Los valores son del hablante de desarrollo
(2,7 MB); no se repitió el barrido con el completo.


### Resultados: bits/byte sobre `prueba.bin` (1 092 883 B, congelada; QEMU WHPX, 2 CPU, 2 GiB)

| fuente (documentos, bytes) | desarrollo: mezcla | hipocampo | corteza | top-1 ‰ | completo: mezcla | hipocampo | corteza | top-1 ‰ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Wikipedia (31, 451 845) | 2,5308 | 3,0432 | 3,7309 | 540 | 2,3847 | 2,8194 | 3,5107 | 560 |
| teatro (28, 386 095) | 2,8682 | 3,4493 | 4,4392 | 453 | 2,6757 | 3,2648 | 4,2221 | 468 |
| narrativa y poesía (31, 254 943) | 2,6749 | 3,1085 | 3,9148 | 486 | 2,5133 | 2,9873 | 3,6516 | 504 |
| **total** | **2,6836** | 3,2019 | 4,0240 | 496 | **2,5175** | 3,0159 | 3,7949 | 514 |

| referencia (total, bits/byte) | |
|---|---:|
| gzip -9 | 3,080 |
| xz -9, solo | 2,612 |
| xz -9 condicional al entrenamiento de desarrollo | 2,407 |
| xz -9 condicional al entrenamiento completo | 2,238 |
| ENCA hablante, desarrollo (2,69 MB) | 2,684 |
| ENCA hablante, completo (30,6 MB) | 2,518 |

ENCA gana a gzip por 0,40 (desarrollo) y 0,56 (completo) bits/byte y, con el corpus completo, a
xz -9 solo por 0,09; no llega a xz condicional al mismo entrenamiento (2,238; +0,28). Con
desarrollo no alcanza ni a xz solo. La mezcla mejora al hipocampo solo en 0,5 bits/byte: la
corteza (3,79) aporta poco por sí sola. Pruebas congeladas pequeñas (63 000 B, para `:guardar`):
desarrollo A 2,7412 / B 2,7266; completo A 2,5465 / B 2,5771.

### Velocidad y tiempos (QEMU WHPX, 2 CPU)
| | desarrollo | completo |
|---|---:|---:|
| entrenar | 2 min 29 s, 17 948 B/s | 29 min 21 s, 17 376 B/s (vigilia 43 876 B/s, sueño 57 674 B/s) |
| crear el modelo (540 MiB) | 2,5 s | 2,8 s |
| prueba completa | 18,6 s (58 872 B/s) | 19,8 s (55 149 B/s) |
| crear HABLA_A/B.BIN (2 x 540 MiB) | 25,8 s | 25,3 s |
| guardar 566 763 280 B | 2,7 s = 209 MB/s (serializar 0,37 s, CRC32C 0,30 s, E/S 2,1 s) | 2,6 s = 214 MB/s (serializar 1,2 s) |
| cargar (lectura + CRC32C) | 3,8-5,9 s = 97-150 MB/s | 3,8 s = 150 MB/s |
| copiar al modelo | 0,4-0,6 s | 0,5 s |
| comprobar pruebas congeladas al cargar | 1,1-2,6 s, idéntica | 1,7 s, idéntica |
| tiempo total de `enca=hablar` | 3 min 24 s | 30 min 18 s |
Sobrescrituras del hipocampo: 386 877 (desarrollo) y 5 981 839 (completo); desalojos 0,86 M y 9,8 M.
Con 524288 ranuras por orden el hipocampo se satura con 30 MB (a diferencia de los 1,3 MB del barrido
de ranuras). `:guardar` (hablante): evaluación 1,4 s + serializar 0,4 s + escribir 2,7 s; `:deshacer`:
leer 4,4-4,9 s + evaluar 1,4 s (+ reescribir 2,9 s sin cambios pendientes). Generación: ~0,07 ms/byte
(300 bytes en ~20 ms); aprender una línea tecleada, ms.

### Ejemplos de conversación (los 10 prompts fijos; muestreo T 0,5, top-k 10, pen 3, ventana 256; contexto nuevo en cada uno, sin aprender; respuestas recortadas a ~300 bytes)
**Hablante completo** (`bucles 0/10`; 85 % de las palabras en vocabulario, diversidad 0,55):
```
[1] TÚ: Hola, ¿cómo estás?     ENCA: ¿Para de la a más alta estradas de antes preta el del compa el camino de un símites tareas a la editas...
[2] TÚ: ¿Quién eres?            ENCA: Las malidad de rodeos de la Seguridad.
[3] TÚ: ¿Qué hora es?           ENCA: ¿Ha del sus ateridioma estas ha cantidad de lástros vida eso, se conocido combargo, disidentra el filón y la invernaciones de mana cuerdo con ellos.
[4] TÚ: Cuéntame una historia.  ENCA: Las compasión explícita otras la destaca la tente en el cama con la estrellase a prevarmente de las recelancase maldición, por las tosistema en 1628...
[5] TÚ: ¿Dónde está el rey?     ENCA: ¿Para de la acción de mayo de palmera discurso del cual se mirar a mano describe que toca en el bach diamantes...
[6] TÚ: Te quiero.              ENCA: ¿Para ser una tintinados del tres meso de la inflexión de ejecutar de su mariscos.
[7] TÚ: ¿Qué es la memoria?     ENCA: Las compasión y a versión sur el presentan extravado en un trata de esta parando partir del discurio de los persistas precio a su han igual que lumias...
[8] TÚ: Háblame de España.      ENCA: Si la siguiente, entre los perio de la convertísica de los durante en el budistas y despirar por ener el contemplar tus bien de lo palmetantes condición...
[9] TÚ: ¿Por qué lloras?        ENCA: Las del mundo publicado en la alcanza y la cielo disimulara líritualizar a la con concreación de exportante es son incluyen el boddico principaletes...
[10] TÚ: Adiós.                 ENCA: Si la superficies sacrificio de comunidad de la es escala de cuenta de esta privada por lo que al poema de miraban entre con distintivo; no hay en 1759.7...
```
**Hablante de desarrollo** (`0/10`; 92 % en vocabulario, diversidad 0,48):
```
[1] TÚ: Hola, ¿cómo estás?     ENCA: Señor forma en que es el más de los elementos especie corporación de la consecuencias como de parecido a la elección no se le comercio de nodos...
[2] TÚ: ¿Quién eres?            ENCA: Elementos con cincorporación como el de los ejemplo, sin de El contrario de notipos de una complejaras del caso...
[3] TÚ: ¿Qué hora es?           ENCA: Señor Antonio,\nhonantheae
[4] TÚ: Cuéntame una historia.  ENCA: Escena al con lo que se puede ser un elementos, si el arconte; o con el conjunto de no a dicho, estrucción de un conocidos en los difícil...
[5] TÚ: ¿Dónde está el rey?     ENCA: Sientes en la estructura de los actual con el orden encontrarán como a los conocida dentenios. En los de nodos complejos...
[6] TÚ: Te quiero.              ENCA: Poco desarrollo hacia articulares y el conjuntar la del canto! (Siguientes a las propios y a dos comentar...
[7] TÚ: ¿Qué es la memoria?     ENCA: Ello antes contestir con el arcos como el proporción en el cloroplasta el de la extransmisión de enero de conductores...
[8] TÚ: Háblame de España.      ENCA: Elamente con el acto de no se le contexto del barre la propiera escriben considerar la sal pueblo de compara serie designios en la ciento.
[9] TÚ: ¿Por qué lloras?        ENCA: Ello ante el polite en el más arcanos como las propiedades cuando en tienen una cosa estrella partido de la comunican el carácter corte de los protomay ciero...
[10] TÚ: Adiós.                 ENCA: Seatrona de la necen a la productos como el completa el presignios en la considerarse parte del cartesiana de cuanto ha sostener un marco de elección.
```
(Los textos completos están en la salida serie de cada corrida; aquí se acortan.)

### Prueba con teclas (arranque sin opción, estado completo, `-EsperarAntes "ENCA> " -Teclas ...`)
```
modelo hablante cargado: ranura A, paso 1, 540 MB en 3770 ms = 150.3 MB/s (lectura y CRC32C); copia al modelo 508 ms; ...
  evaluación de las pruebas congeladas en 1687 ms: idéntica a la guardada en la cabecera
ENCA> hola, que tal
  aprendido: 20 bytes, 4,462 bits/byte  [sin guardar 20 bytes]
ENCA: Las de esta candelas condicionada a la con la guarto de la eso se despreciar las referio primer a la astrología...
ENCA> que es la memoria
  aprendido: 24 bytes, 2,576 bits/byte  [sin guardar 44 bytes]
ENCA: A se como consejeranzas de los son los con en 1954. Allen el Estado de esta conecta entonados...
ENCA> :ver
  modo: muestreo / temp 0,500  topk 10  topp 1,000  pen 3,000  ventana 256  semilla 1  linea no
  aprender si  modo d  umbral 0,2000 bits/byte  sin guardar 44 bytes  ranura A paso 1  B guardada 2,5771 bits/byte
  modelo español (hablante)  charla si  historial 660 bytes, 2 turnos dichos  ranuras por orden 524288
```
Con el estado de desarrollo se probó además `:guardar` (delta B +0,0014, guardado paso 2 en B a 210 MB/s),
`:deshacer` sin cambios (vuelve a A, reescribe como paso 3 en B), un segundo `:deshacer` ("no hay a dónde
volver"), `:deshacer` con cambios (recarga B paso 3, evaluación idéntica), `:modelo codigo` (completa
`flow main` con el modelo de código), `:modelo espanol`, `:charla no` (completa el prefijo con el
español) y `:nueva`. Hitos 2-21 sin la opción: OK (el 11 falló una vez por ruido del anfitrión y pasó
en otra corrida); `enca=prueba21` OK con los mismos bits de F que antes (0x3FDCAB7AA734D6A2); sin
`es/` ni `HABLA_*` el arranque no imprime nada nuevo.

### Valoración honesta: ¿habla?
**La forma sí; el sentido no.** El texto es castellano reconocible a nivel de caracteres y de
palabras: ortografía y acentos correctos, entre 85 % y 92 % de las palabras generadas existen en el
corpus, con artículos, preposiciones, comas y mayúsculas tras punto donde corresponde, y sin bucles
(0/10 en todas las tandas). Pero:
- ninguna respuesta tiene sintaxis de oración completa ni relación con la pregunta (a "¿Quién eres?"
  o "Te quiero." responde con el mismo tipo de pasta léxica); el aviso es que el prompt solo
  condiciona unos pocos bytes;
- el registro es el de Wikipedia (mitad del corpus): "conjunto", "nodos", "elemento", "budistas";
  del teatro solo salen restos ("Señor Antonio,");
- inventa palabras mezclando contextos ("comparacteriza", "estrellase", "líritualizar");
- el formato `TÚ:` / `ENCA:` no existe en el entrenamiento, así que casi nunca cierra el turno con
  `\n\n` (la mayoría de respuestas llega al corte de 300 bytes);
- el entrenamiento con 11 veces más texto bajó el total de 2,68 a 2,52 bits/byte (la diferencia
  entre palabras casi bien y palabras más largas y variadas), no cambió la falta de significado: un
  modelo de bytes con contextos de hasta 6 bytes y una corteza de 512 unidades no representa
  significado ni diálogo. Que supere a gzip y a xz solo en bits/byte lo dice como compresor, no como
  conversador.
- Aprender la línea del usuario (hito 21) no cambia las respuestas de forma visible: cuesta 3 ms, pero
  una frase entre 30 MB de texto no pesa.

### Lo que no se pudo hacer / pendiente
- No se midió en el portátil (la imagen USB con `-CorpusEs` completo se construye, 128 MiB; en el
  portátil hay que copiar `es/` a la partición ELEDATOS, que necesita ~1,4 GB libres, y la
  velocidad esperada es ~12,7 KB/s: ~40 min de entrenamiento y ~70 MB/s de disco).
- El muestreo se calibró solo con el hablante de desarrollo; no se repitió con el completo (cuyo
  vocabulario es más variado: 85 % frente a 92 %).
- La clasificación por fuente separa teatro y Wikipedia exactamente, pero narrativa y poesía van
  juntas (el índice no las distingue y la tabla no pudo ser única).
- Los ejemplos corren cada uno con contexto nuevo; las conversaciones largas con historial solo se
  probaron con dos turnos.

Verificación del líder (QEMU, disco con el estado completo, arranque normal y
tecleando "hola, que tal"):
```
modelo hablante cargado: ranura A, paso 1, 540 MB en 4298 ms = 131.8 MB/s (lectura y CRC32C); copia al modelo 416 ms; 524288 ranuras por orden, 30617629 B de corpus entrenados
  evaluación de las pruebas congeladas en 1323 ms: idéntica a la guardada en la cabecera
ENCA> hola, que tal
  aprendido: 20 bytes, 4,462 bits/byte  [sin guardar 20 bytes]
ENCA: Las de esta candelas condicionada a la con la guarto de la eso se despreciar las referio primer a la astrología sobre el cara de prueve indican dirigían a los poder de allí, ...
  [300 bytes, cortada a 300 en 20 ms]
```
Confirma la valoración: forma castellana (ortografía, palabras reales,
concordancias locales), sin sentido ni relación con la pregunta.

Un modelo de contextos de hasta 6 bytes no puede sostener una frase: ve
media palabra hacia atrás. Mejoras posibles, de menor a mayor alcance:
- contextos de palabra (órdenes por palabras, no por bytes);
- datos en formato de diálogo de dos voces;
- y para tener sentido, un modelo con memoria larga (la línea del
  transformer, en pausa).

## Teclado: sondeo de respaldo

En el portátil real (Dell, Celeron 3865U) el prompt `ENCA>` no recibía teclas aunque el kernel seguía vivo: el bucle de `hito7` dormía en `hlt()` y, si la IRQ1 no llega, nada lo despierta. Ahora el bucle no usa `hlt()`: llama a `tecladoSondear()` (lee el 8042 con `cli`/`sti`, descarta lo del ratón por el bit AUX) y avisa una vez si un byte llegó por sondeo sin ninguno por interrupción. `tecladoInterrupcion()` ya no lee el puerto 0x60 si el 8042 no tiene dato (evita repetir el byte anterior cuando el sondeo se adelantó). Diagnóstico: `teclado: estado 8042 0xNN` al entrar y, en `:ver`, `teclado: N por interrupción, M por sondeo, último estado 8042`. Pendiente de confirmar en el portátil.

Resultado en el portátil (imagen con sondeo, modelo hablante cargado):
- "teclado: estado 8042 0x...0C" (en QEMU 0x1C): solo difiere el bit 4,
  que en los 8042 modernos depende del fabricante. No es la causa.
- Se puede escribir. :ver dice "teclado: 22 por interrupción, 0 por
  sondeo": la IRQ1 sí llega.
- Conclusión: el fallo no estaba en la IRQ del teclado sino en el bucle
  antiguo, que dormía con hlt. Hipótesis principal: en el portátil,
  después de cargar el modelo hablante (540 MB), hito7 empieza con las
  interrupciones del procesador desactivadas (IF = 0). hlt con IF = 0 no
  despierta nunca. El bucle nuevo no duerme y su sondeo hace cli/sti, y
  ese sti las reactiva. En QEMU el mismo camino no deja IF = 0.
- Pendiente: imprimir RFLAGS.IF al entrar en hito7 (intrínseco de lectura
  de flags) para confirmarlo, y encontrar qué deja IF = 0 en la carga del
  hablante.

Diagnóstico de IF (cpu/ifdiag.l; para probar en el portátil): `ifActivo()` lee
RFLAGS.IF (intrínseco `leerRflags()`; en ELE se llama así, no `rdflags`).
`ifPunto(etiqueta)` guarda (etiqueta, IF) en una tabla estática tras cada hito
de kmain y dentro de `espCargarHablante` (hab0, habBuf, habLeer = lectura +
CRC32C, habMod, habCopia, habEval, habFin); `ifVigilar` anota solo el primer
IF = 0 en bucles (cada orden AHCI, cada fatLeer, ckCab/ckLee/ckCrc de
checkpoint.l, la evaluación). Tras el sti del hito 6 (`ifArmar`) un IF = 0 es
anómalo; antes (h4, h5) es lo esperado. `hito7` imprime la línea "IF: h6=1
h8=1 ..." (varias líneas de 12 puntos), "primer cero en X" y, si IF = 1, mide
los tics del temporizador en 35 ms (esperado ~3) y cuánto tarda un `hlt` en
despertar. Resultado en QEMU (WHPX, 2 CPU y modelo hablante cargado): IF = 1 en
todos los puntos, 3 tics, hlt despierta en ~2,6 ms. Lectura en el portátil:
si algún punto sale 0, ese es el culpable; si todos son 1 pero "tics" es 0, el
que falla es el temporizador LAPIC (hlt dormiría igual) y no IF; si todo es
normal, el fallo del bucle antiguo no era IF.
Revisión estática: nada en el kernel deja IF = 0 sin `cli`. El compilador solo
emite CLI/STI/HLT como intrínsecos (x86_64.l: x64Cli/x64Sti) y `leerRflags` es
PUSHFQ; POP RAX (sin POPF); no hay `popf`, `int n` ni escritura de RFLAGS. El
IRETQ de los stubs restaura el RFLAGS del marco (IF = 1 si se interrumpió con
IF = 1); `excepcion` solo continúa con #BP (hito 3, antes del sti). Los AP
ejecutan `smpEntradaAp` dentro de su propia interrupción (IF = 0 en ellos) y no
pasan por el BSP. Además, la hipótesis IF = 0 choca con el dato del portátil
(22 por interrupción, 0 por sondeo): con IF = 0 la primera tecla la habría
tomado el sondeo.
