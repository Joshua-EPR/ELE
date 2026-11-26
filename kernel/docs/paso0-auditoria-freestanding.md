# Paso 0 — Auditoría de ELE para modo freestanding

Fecha: 2026-11-25. Compilador auditado: driver ELE 0.3.0 (Gen3, `main` en
`5ee1286`, copia en `kernel/compilador/ele.exe`). Se revisó también Stage 0
(Rust) solo como referencia: no sirve para el kernel porque genera código
mediante rustc/Cranelift.

Leyenda: ✅ existe · 🟡 existe a medias · ❌ no existe.

## Resumen

El driver tiene lo más difícil ya hecho: codificador x86-64 propio, emisor
ELF64 propio sin enlazador, sin libc, y nunca emite AVX. Pero hoy produce
**programas de usuario Linux**: el punto de entrada, la salida, los errores en
tiempo de ejecución y el heap terminan en `syscall`. Además el lenguaje no
tiene **operadores de bits, literales hexadecimales, enteros sin signo,
acceso a memoria cruda ni estado global**, y sin eso no se puede escribir
una tabla de páginas ni una IDT.

La faena del Paso 0 es por tanto mayor que "agregar unas opciones": son
cambios al lenguaje. Los marcados con **[DECISIÓN]** necesitan tu visto
bueno antes de tocarlos (regla 5).

## Punto por punto

### 1. Sin runtime ni biblioteca estándar, entrada propia — ❌

- Hoy: el stub de entrada ELF es `call main; mov rdi,rax; mov eax,60;
  syscall` (`codegen/native_cfg_emit.l:462`). El runtime (`native_rt.l`,
  `native_rt_list.l`, `native_heap*.l`, `native_trap.l`,
  `native_rt_platform.l`) usa `write`, `mmap`, `mremap`, `munmap`, `exit`.
  `print`, `Text` dinámico y `List` lo arrastran automáticamente.
- Propuesta: `--target kernel` (nuevo, junto a `elf`/`pe`):
  - El símbolo de entrada es una `flow` elegida con `--entry kmain`; el stub
    no llama a `exit`, si `kmain` retorna ejecuta `cli; hlt` en bucle.
  - Sema rechaza (error claro, no ICE) todo lo que requiera runtime con
    syscalls: `print`, `Text` con dueño, `List` dinámica, `i platform`.
    `Text` literal (en `.rodata`) sí se permite.
  - Los fallos en tiempo de ejecución (desbordamiento 125, índice 127,
    variante 126) llaman a una `flow` del kernel `--panic kpanico(codigo:
    Int, linea: Int)` en vez de `exit`.
  - El heap (`List`) se conectará más adelante a un asignador del kernel
    (después NEXO). En Fase 1 no hace falta.

### 2. ELF64 higher-half, secciones, enlazado — 🟡

- Hoy: `elf64.l` produce `ET_EXEC` en `0x400000`, un `PT_LOAD` RX con todo el
  código y literales, y opcionalmente hasta 16 páginas RW **guardadas en el
  archivo** (no hay `.bss`). Sin tabla de secciones, sin reubicaciones.
- Limine acepta ELF64 con `PT_LOAD` sin secciones y encuentra las peticiones
  escaneando la imagen, así que no hace falta un enlazador ni un script de
  enlazado: el driver ya es "compilador + enlazador" de una sola unidad.
- Propuesta para `--target kernel`:
  - Base `0xffffffff80000000` (configurable `--base`).
  - Tres `PT_LOAD`: `.text` (R+X), `.rodata` (R), `.data`+`.bss` (R+W,
    `p_memsz > p_filesz` para que `.bss` no ocupe el archivo).
  - Tabla de secciones mínima con nombres (`.text`, `.rodata`, `.data`,
    `.bss`, `.symtab`) para que `objdump`/GDB funcionen al depurar.
  - `.symtab` con el nombre de cada `flow`: imprescindible para `-s -S` en QEMU.

### 3. Modelo de código "kernel" — ✅ de hecho

- Las direcciones de datos se cargan con `mov r64, imm64` (`x64MovImm64`) y
  los literales con `lea rip-relativo`; las llamadas son `call rel32`. Todo
  esto funciona en cualquier dirección, incluida la mitad alta. No hay que
  hacer nada más que el punto 2.

### 4. Sin red zone — ✅

- El prólogo reserva el marco con `sub rsp` antes de usarlo
  (`x86_64.l:225`) y los slots están en `[rbp - 8·(k+1)]`, dentro del marco.
  Busqué accesos con desplazamiento negativo sobre RSP en todo `codegen/`:
  no hay. Una interrupción no puede pisar nada. Añadiré una prueba que lo
  asegure (escanear la imagen de `--target kernel`).

### 5. Stack probes y llamadas implícitas — 🟡

- Marcos > 4 KiB se sondean página a página **en línea** (`or qword
  [rsp],0`), no con una llamada a `__chkstk`. En el kernel es inocuo si la
  pila está mapeada; con `--target kernel` lo desactivo (las pilas del
  kernel son de tamaño fijo y conocido).
- Copias: `rep movsb` en línea; no hay llamadas a `memcpy`/`memset`. Bien.
- Lo implícito real son las rutinas del runtime (punto 1).

### 6. Memoria cruda, volatile, packed, casts — ❌

- No hay punteros, ni tipos de ancho fijo (`u8/u16/u32`), ni enteros sin
  signo, ni estado global mutable. Solo `Int` (i64 con chequeo de
  desbordamiento), `Float` (f64), `Bool`, `Text`, `List`, `shape`, `choice`.
- **No hay operadores de bits** (`& | ^ << >> ~`) ni **literales
  hexadecimales** en el driver (tampoco en Stage 0). Son imprescindibles.
- Ventaja: el backend nunca guarda valores en registros entre sentencias,
  así que todo acceso a memoria ya es, en la práctica, volatile.
- Propuesta **[DECISIÓN]**: un módulo de intrínsecos `take nucleo.mem` que
  el compilador reconoce y baja a una sola instrucción:
  `leer8/16/32/64(dir: Int) => Int`, `escribir8/16/32/64(dir: Int, v: Int)`
  (volatile garantizado, nunca se reordenan ni eliminan), `direccionDe(x)`
  para obtener la dirección de un global. Las estructuras `packed` de
  hardware (GDT, IDT, TSS, tablas ACPI) se describen como desplazamientos
  `fixed` sobre una dirección base: es lo que haría un `packed struct` y no
  obliga a añadir punteros tipados al lenguaje todavía.
- Propuesta **[DECISIÓN]**: operadores `&`, `|`, `^`, `<<`, `>>` (lógico),
  `~`, más literales `0x…` y `0b…` con `_` separador. Problema: `&` unario
  ya existe en el parser como referencia (`expr.l:424`), así que `&` binario
  es ambiguo solo a nivel léxico y se resuelve por posición (binario tras un
  operando). Alternativa sin conflicto: palabras (`a y_bit b`) o métodos
  (`a@and(b)`), más lentos de leer.
- Propuesta **[DECISIÓN]**: aritmética "envolvente" para direcciones. Hoy
  `0xffffffff80000000` no cabe como positivo en `Int` y `+` atrapa el
  desbordamiento. Opciones: (a) operadores `+%`, `-%`, `*%` que envuelven;
  (b) un tipo `Dir`/`U64` sin signo. La (a) es mucho menos trabajo.
- Propuesta **[DECISIÓN]**: globales: `global nombre: [Int; N]` o
  `reserva nombre = 4096` (bytes en `.bss`, alineación opcional
  `alineado 4096`), y `fixed` de bytes en `.rodata` para la fuente 8×16.

### 7. Asm en línea / objetos `.asm` / funciones naked — ❌

- No hay ensamblador ni enlazador; el driver no puede unir objetos `.asm`.
  Usar NASM + `ld` metería herramientas ajenas en el build.
- Propuesta **[DECISIÓN]** (recomendada): **intrínsecos de CPU** en
  `take nucleo.cpu`, cada uno emitido por el codificador propio: `hlt`,
  `cli`, `sti`, `pause`, `in8/16/32`, `out8/16/32`, `cpuid`, `rdtsc`,
  `rdmsr`, `wrmsr`, `leerCr0/2/3/4`, `escribirCr0/3/4`, `lgdt`, `lidt`,
  `ltr`, `invlpg`, `fxsave`, `fxrstor`, `swapgs`, `wbinvd`.
  Y dos formas especiales que el compilador genera completas:
  - `interrupcion flow manejador(marco: Int)` → stub "naked" que guarda los
    15 registros generales, alinea la pila, llama a la `flow` y hace
    `iretq` (con y sin código de error).
  - Trampolín SMP 16→32→64: bloque de bytes generado por una tabla de
    instrucciones en ELE (no por el lenguaje), copiado a < 1 MiB en
    ejecución.
  Alternativa: un pequeño ensamblador escrito en ELE dentro de `kernel/`.
  Es más flexible pero mucho más trabajo y aún necesitaría enlazado.

### 8. CPU objetivo: hasta SSE4.2, prohibido AVX — ✅

- El codificador no conoce prefijos VEX/EVEX: es **imposible** que emita AVX.
  Solo usa SSE2 escalar para `Float` (`movq`, `addsd/subsd/mulsd/divsd`,
  `ucomisd`, `cvtsi2sd`, `cvttsd2si`). Añadiré una prueba que escanee la
  imagen y falle si aparece `C4`/`C5`/`62` como prefijo de instrucción.

### 9. Uso de registros SSE en código general — 🟡

- Solo `Float` toca XMM. Las copias usan `rep movsb` (no XMM). Por tanto un
  kernel sin `Float` no toca XMM.
- Propuesta: `--sin-sse` hace que sema rechace `Float` (error claro).
  Se compila así el núcleo base; el código numérico (hito 5, hito 9) se
  compila con SSE permitido y las interrupciones que lo necesiten guardan
  estado con `fxsave` en el área de 512 B por contexto.

## Riesgos que conviene saber ya

1. **f32 y SIMD (hitos 5 y 9).** El driver solo tiene `Float` = f64 escalar.
   El hito 9 pide MULPS/ADDPS con acumuladores en XMM. Hará falta un tipo
   `f32` y un tipo vectorial (`F32x4`) con operaciones que bajen a
   `movaps/movups/mulps/addps/shufps/xorps`. **[DECISIÓN]** posterior,
   antes del hito 5.
2. **Rendimiento del código generado.** No hay asignador de registros: cada
   valor vive en la pila y cada operación hace load/op/store. Para el kernel
   base da igual; para SGEMM al 50 % del pico no alcanza. O bien el
   micro-kernel SSE se escribe como intrínseco que mantiene los acumuladores
   en XMM dentro de un bloque, o el backend necesita asignación de
   registros. Lo mediré en el hito 9.
3. **Convención de llamada interna.** Los argumentos van por la pila. Los
   stubs de interrupción generados por el compilador la conocen; si algún
   día hay `.asm` externo habrá que documentarla como ABI estable.
4. **Compilación de una sola unidad.** Todo el kernel se compila de una vez
   desde `kmain.l` con `take`. Con el driver actual (~4–13 s para el propio
   compilador) no es problema.

## Orden propuesto de implementación (tras tu visto bueno)

1. Literales `0x`/`0b` y operadores de bits + envolventes. Pruebas en
   `tests/native_corpus`.
2. `--target kernel` mínimo: base alta, 3 `PT_LOAD`, `.bss`, `.symtab`,
   `--entry`, `--panic`, rechazo de runtime con syscalls, sin sondeo de pila.
3. Intrínsecos `nucleo.cpu` básicos (`out8`, `in8`, `hlt`, `cli`) y
   `nucleo.mem` (`leer*/escribir*`), globales en `.bss`.
   → con esto se cierra el **hito 1** (COM1 + Limine).
4. `interrupcion flow`, `lgdt/lidt/ltr`, `cr*`, `fxsave` → hito 3.
5. `f32`/`F32x4` → hitos 5 y 9.

Cada cambio irá con su prueba en el repositorio del compilador, se
regenerará `kernel/compilador/ele.exe` con el bootstrap desde semilla y se
anotará en `kernel/docs/bitacora.md`.

## Decisiones que necesito de ti

1. Sintaxis de operadores de bits: ¿símbolos (`& | ^ << >> ~`) o palabras?
2. Direcciones de 64 bits: ¿operadores envolventes (`+%`) o tipo sin signo?
3. Memoria cruda: ¿intrínsecos `leer*/escribir*` sobre `Int` (propuesto) o
   punteros tipados en el lenguaje?
4. Asm: ¿intrínsecos de CPU generados por el compilador (propuesto) o un
   ensamblador propio en ELE?
5. Sintaxis de globales/reservas en `.bss` y de datos de bytes en `.rodata`.
