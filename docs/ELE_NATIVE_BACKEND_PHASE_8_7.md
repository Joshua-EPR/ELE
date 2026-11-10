# ELE — avance real de las fases 8.5 y 8.7 (backend nativo en ELE)

**Estado de entrega: incremento parcial; NO hay Stage 2, Stage 3 ni compilador
completamente autónomo.** Fuente final `.l`; el backend Python/C11 y Rust son
herramientas de bootstrap y referencia, no la arquitectura final.

## Corrección de módulos (8.5)

En `compiler-l/src/modules_l.l`, el retorno de `loadProgram` construía un
`LoadedProgram` con `module_paths: module_starts` y omitía `module_starts`.
Se corrigió a `module_paths: module_paths, module_starts: module_starts`.
Esto reparaba un error tipado de construcción que impedía compilar Stage 1 con
el cargador actualizado. **Pendiente**: validación MSVC, compatibilidad con
Stage 0, eliminar el buffer de fuentes concatenadas y rutas UTF-8.

## Backend nativo ELE (8.7): código real incorporado

- `compiler-l/src/codegen/x86_64.l`: encoder puro en ELE. Produce
  `List<Int>` de bytes [0,255]. Implementa:
  `MOV r64,imm64`, `MOV r64,r64`, `ADD`, `SUB`, `CMP`, `IMUL` entre registros,
  `RET`, `SYSCALL`, `JMP rel32`, `JE/JNE rel32` y *patch* de rel32.
  Registros 0-15, prefijos REX.W/R/B, bytes little-endian. Detecta registros
  inválidos, desplazamientos fuera de rango y parches fuera de límites.
- `compiler-l/src/codegen/elf64.l`: emite en una `List<Int>` la estructura
  completa de un **ELF64 ET_EXEC mínimo x86-64 Linux** con segmento PT_LOAD
  ejecutable, encabezado de 64 bytes, program header de 56 bytes, offset
  de código 0x1000 y entrypoint 0x401000. No utiliza C, Python, Rust ni
  enlazador para generar sus bytes **una vez que se ejecuta esta fuente ELE**.
  No implementa relocations, múltiples secciones, símbolos, dinámico, PIE,
  ASLR, Windows PE o ABI de llamadas de aplicaciones generales.
- `compiler-l/src/native_elf_demo.l`: ejemplo en ELE que construye código
  máquina que ejecuta `exit(42)` en Linux mediante syscall y lo encapsula
  dentro de ELF64. Muestra el resultado como hex en stdout.
- `compiler-l/src/native_encoder_cases.l` y `native_encoder_branches.l`:
  fixtures de prueba de codificación, R8/R9, inmediatos negativos, saltos
  positivos/negativos y manejo de errores.
- `compiler-l/src/codegen/lir_tokens.l` y `codegen/lir_subset.l`: lector
  estricto de tokens y un **lowering ELE-LIR 1 → x86-64 escrito en ELE** para un
  subconjunto deliberadamente pequeño: `module structs 0 funcs 1 main f0`,
  una función `main(): Int`, un bloque, un máximo de ocho variables Int,
  instrucciones `i use`, `i binary add|sub|mul` y `t return`.
  Rechaza otros tipos e instrucciones, lecturas de variables no inicializadas
  y operaciones fuera del subconjunto. Las operaciones aritméticas emiten
  un salto JO a un manejador de overflow con código de salida 125.
- `compiler-l/src/native_lir_demo.l`: CLI ELE que lee un `.lir` a través de
  `readText`, invoca el lowering ELE y emite ELF64 hexadecimal. La escritura
  directa de archivos binarios sigue pendiente.
- `examples/native_int_subset.lir` y `native_int_subset_invalid*.lir`:
  fixtures de entrada del protocolo real, positivo y negativo.
- `crates/l/tests/native_encoder_l.rs`: **seis pruebas de integración aún
  pendientes de ejecutar** que compilan los fixtures ELE mediante Stage 0,
  verifican los bytes esperados, comprueban el lowering del LIR real y
  exigen rechazo de la instrucción `div` no soportada y de lecturas
  de variables sin inicializar. Rust es exclusivamente
  harness de desarrollo.

## Validación realizada / pendiente

**Realizado en Linux de este entorno:**

- Las 16 pruebas Python ya existentes (backend C experimental + auditoría)
  vuelven a pasar. No prueban los nuevos archivos ELE.
- La auditoría estática detecta 0 imports faltantes y 0 ciclos desde
  `native_elf_demo.l` y desde `main_sema.l`.
- Se verificaron de manera independiente las secuencias de instrucciones
  esperadas mediante GNU `as` + `objdump` y se ejecutó en Linux una imagen
  ELF de **referencia** con los mismos campos y bytes planificados:
  su código de salida es 42. Esto comprueba el diseño del formato y las
  instrucciones, **no prueba que el emisor ELE haya producido esa imagen**.

**No realizado:** no hay `cargo`, `rustc` ni ejecutable Stage 1 en el entorno.
Los seis tests en `native_encoder_l.rs` aún necesitan compilar y ejecutar
los `.l` reales. Tampoco se han ejecutado la suite MSVC histórica ni las
pruebas de imports agregadas en 8.5. No hay prueba de self-hosting.

### Validación adicional del diseño de lowering

El ensamblado de **referencia** para el caso `native_int_subset.lir`
contiene 69 bytes de instrucciones y, al encapsularlo en ELF64 con los mismos
campos previstos por ELE, **retorna 42 al ejecutarse en Linux**. La
comparación byte a byte con la salida del frontend nuevo en ELE está
preparada en la prueba Rust, pero no se ha ejecutado aquí. Esto no debe
presentarse como compilación LIR verificada por ELE.

### Verificación en Windows con MSVC

Desde la raíz del repositorio, con la toolchain de Rust y el SDK configurados:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo test -p project-l --test native_encoder_l --target x86_64-pc-windows-msvc -- --nocapture
.\bench\verify-stage1-modules.ps1 -FullSuite
```

El primero construye y ejecuta código escrito en ELE y verifica que los bytes
emitidos coinciden con los bytes x86-64/ELF de referencia. El ELF generado
es un ejecutable Linux, no un `.exe` Windows. Para ejecutarlo en Linux,
exportar la línea `ELE_ELF_HEX:` impresa por `native_elf_demo.l` a bytes
binarios, asignar permiso de ejecución y lanzar el archivo: debe salir con
código 42. La conversión hexadecimal es **solo un puente temporal**.

### Deuda técnica imprescindible para autonomía

1. Exponer `writeBytes(path: Text, bytes: List<Int>)` con semántica segura en
   el runtime y frontend ELE; sin escritura binaria no se puede guardar el
   ejecutable sin conversión auxiliar. El backend actual solo construye
   bytes en memoria.
2. Ampliar el lector y lowering ELE-LIR ya iniciados **en ELE** a todas las
   instrucciones y tipos necesarios para la autocompilación; añadir un Machine
   IR desacoplado y un verificador defensivo real. El lector actual es un
   subconjunto de una función y no sustituye al protocolo completo.
3. Resolver la cadena de toolchain del bootstrap y validar Stage 1 contra
   todos los módulos propios (incluyendo métodos, Option/Result y match).
4. Expandir x86-64 con stack frames, llamadas ABI, memoria, registros,
   símbolos, relocations y enlazado. Windows PE/COFF es la siguiente meta
   por prioridad de plataforma; este ELF mínimo demuestra solo el formato.
5. Migrar runtime a ELE; añadir Stage 2 y Stage 3 y pruebas diferenciales.
6. Finalmente eliminar Python/C11, Rust/Cranelift y los compiladores externos
   del camino **normal** de compilación. Pueden permanecer como referencias
   diferenciales de desarrollo.

**Invariante:** ninguna función se declara autónoma mientras una herramienta
externa sea necesaria para generar o escribir el ejecutable final.
