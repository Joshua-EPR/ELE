# ELE — Fase 8.7.3 (primer incremento): layout y direccionamiento nativo

**Estado: implementación inicial, pruebas de Stage 0 pendientes de ejecutar.**

## Propósito y alcance real

Este incremento inicia la Fase 8.7.3, pero **no la completa**. Se añadió
un planificador de layouts de agregados escrito en ELE y primitivas reales
de codificación de cargas/stores x86-64. No existe todavía lowering general
de `i struct` / `i read` / `i store`, asignación dinámica de heap, `List<T>`
nativa, ni drops de valores propietarios en este backend. No hay Stage 2.

## Archivos de código nuevos

- `compiler-l/src/codegen/native_layout.l`: `NativeLayout` calcula tamaño,
  alineación, padding, offsets por campo y orden de campos propietarios para
  futuros drops. Inserción y sellado tienen límites explícitos. Soporta
  layouts anidados y helpers primitivos Int, Bool y punteros para x86-64.
  Es un **plan interno provisional**, no el ABI de Stage 1 ni de Rust/C.
- `compiler-l/src/codegen/x86_64.l`: `x64LoadMem64`, `x64StoreMem64`,
  `x64LoadMem8`, `x64StoreMem8`, con ModRM, SIB para RSP/R12, REX para
  R8–R15 y registros de byte SIL/DIL, desplazamientos signed32, y
  validación antes de emitir bytes. `x64LoadSlot`/`x64StoreSlot` reutilizan
  estos helpers, preservando el formato de encodings existentes.
- `compiler-l/src/native_layout_cases.l`: fixture del layout, nested,
  orden de campos propietarios y rechazo de align inválido y overflow.
- `compiler-l/src/native_memory_cases.l`: fixture del codificador de memoria.
- `compiler-l/src/native_stack_aggregate_demo.l`: generador en ELE de un
  ELF64 Linux x86-64 que reserva un agregado en stack, coloca 39 y 2 en
  dos campos Int y 1 en un campo Bool, los carga y termina con `exit(42)`.
  No requiere un runtime de heap en el ejecutable generado.

## Pruebas nuevas (a ejecutar con Stage 0)

- `crates/l/tests/native_layout_l.rs`: invariantes de layout verificados
  por una función `main` escrita en ELE.
- `crates/l/tests/native_memory_l.rs`: comparación exacta de bytes x86-64
  producidos por ELE con un oráculo desensamblado independiente.
- `crates/l/tests/native_stack_layout_l.rs`: imagen ELF64 generada por
  código ELE, con ejecución real en Linux x86-64 (cuando la plataforma
  de prueba sea Linux y Stage 0 esté disponible).
- `bench/verify-native-memory.ps1`, `bench/build-native-stack.ps1`.
- `bench/verify-native-cfg.ps1` incluye también los nuevos tests.

## Verificación realizada en el entorno de trabajo

- `python3 -m unittest discover -s tests/native_backend -v`: **20/20**, sin
  regresiones en las herramientas anteriores. No compila los nuevos `.l`.
- `objdump` desensambló 46 bytes **de referencia** para direccionamiento
  R8/R12/R13, SIB y carga/escritura de bytes. Se validaron las instrucciones
  previstas, no el código emitido por ELE.
- Una imagen ELF64 **independiente**, construida como oráculo con la misma
  estrategia stack/ABI, ejecutó y salió con código **42** en Linux x86-64.
  No fue generada por el emisor ELE.
- Auditoría estática de imports de `native_stack_aggregate_demo.l`: 4 archivos
  alcanzables, 0 imports faltantes, 0 ciclos. No verifica semántica.
- **No hay Cargo/rustc ni un Stage 1/Stage 0 ejecutable** en este entorno;
  los tests de integración Rust y compilación real `.l` NO se ejecutaron.

## Comandos de verificación en Windows

Desde la raíz, sin descartar modificaciones de Git:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-encoder.ps1
.\bench\verify-native-cfg.ps1
.\bench\verify-native-memory.ps1
.\bench\build-native-stack.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

`build-native-stack.ps1` escribe
`target/native-ele/ele-stack.elf`. En Linux x86-64/WSL, ejecutar:

```bash
chmod +x target/native-ele/ele-stack.elf
./target/native-ele/ele-stack.elf
printf 'exit=%s\n' "$?"    # esperado: 42
```

Si Stage 0 falla compilando `native_layout.l`, corregir el error fuente
real y añadir una regresión. No tratar el resultado de un oráculo externo
como sustituto de esta prueba.

## Bloqueos hacia completar 8.7.3 → 8.8

1. Validar primero **todas** las pruebas MSVC anteriores (8.7.1 y 8.7.2)
   y las nuevas; reparar las fallas sin debilitar ownership.
2. Conectar los layouts al sistema de tipos nominales real de Stage 1:
   los `TypeId`, tamaños de agregados y drops deben provenir de la LIR
   tipada, no de descriptores manuales en los fixtures.
3. Ampliar el lector/verificador de `ELE-LIR 1` con `struct sN`,
   `i struct`, `i read` y `i store`; aplicar ownership y drops correctos.
4. Introducir asignación de heap y `List<T>` nativa, luego liberar exactamente
   una vez los recursos propietarios.
5. Incorporar enums/Option/Result/match y el runtime ELE, con pruebas E2E.
6. Avanzar hacia autocobertura de todos los módulos del compilador antes
   de intentar Stage 2. Mantener el bootstrap de Rust hasta confirmar Stage 2
   y Stage 3; todavía no existe una cadena de compilación autónoma.
