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
