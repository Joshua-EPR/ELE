# ELE — Fase 8.7.2: funciones, CFG y llamadas en el backend nativo

**Estado: implementación de código e integración preparada, validación del compilador ELE PENDIENTE.**
Esta revisión se hizo sobre el ZIP completo `ELE-fix-10-pruebas-proyecto-completo.zip`,
que contiene las correcciones previas de los 10 fallos de Stage 0. El entorno
usado aquí es Linux sin `cargo`, `rustc` ni el ejecutable `l` de ELE; por eso
**no hemos compilado ni ejecutado todavía las fuentes nuevas `.l`**. No hay
Stage 2 ni Stage 3, ni se ha probado una compilación autosuficiente.

## Implementación añadida

El nuevo punto de entrada `compiler-l/src/native_cfg_demo.l` usa un backend
escrito en ELE, separado del backend lineal anterior:

- `codegen/native_cfg_ir.l`: lector/representación *tipada y aplanada* de un
  subconjunto estricto del protocolo existente `ELE-LIR 1`. Admite hasta
  16 funciones, 32 bloques/función, 64 variables/función y 2 parámetros de
  tipo `Int` o `Bool`. Acepta `i use`, `i binary add/sub/mul/eq/ne/lt/le/gt/ge`,
  `i call` de 0–2 argumentos **por valor** y terminadores
  `t jump`, `t branch`, `t return`. Acepta sufijos `@línea:columna`
  como los que emite Stage 1. Exige nombres ASCII serializados con
  longitud correcta. Rechaza todas las variantes que faltan.
- `codegen/native_cfg_verify.l`: valida funciones, aridad y tipos de llamadas,
  saltos y tipos de condiciones, rechaza bloques inalcanzables y aplica
  análisis de inicialización definitiva por intersección de estados de
  predecesores hasta punto fijo, incluyendo backedges y uniones de ramas.
  No pretende reemplazar el verificador general de ownership/drops.
- `codegen/x86_64.l`: conserva las instrucciones anteriores y añade
  `CALL rel32` + parche, prólogo/epílogo con RBP, `mov` RBP-relativo,
  comparación `setcc`, `movzx` y `test`. Estrategia de variables en stack,
  sin asignador de registros general.
- `codegen/native_cfg_emit.l`: emite un stub ELF de entrada, llama a `main`,
  pasa hasta dos argumentos (`RDI`, `RSI`) con ABI **interna restringida**,
  recibe resultados en `RAX`, emite saltos y llamadas con fixups `rel32`,
  reserva stack alineado a 16 bytes y conserva `RBP`. Overflow aritmético
  usa JO a un manejador global que finaliza el proceso con 125.
- `native_cfg_demo.l`: lee LIR desde archivo y emite el ELF64 hexadecimal o
  lo escribe directamente con `writeBytes` del bootstrap de Stage 0.

No hay C, Python, Rust, ensamblador o linker **dentro de este emisor ELE**.
Pero el ejecutable del emisor **sigue necesitando Stage 0** para su bootstrap;
`writeBytes` usa un servicio de archivo Win64 inicialmente implementado en
Rust `no_std`; el ELF resultante necesita Linux x86-64 para ejecutarse.
La arquitectura final de ELE deberá reemplazar también esos apoyos temporales.

### Límites explícitos

- Solo `Int` y `Bool` por valor; sin `Text`, `List`, `struct`, Float, referencias,
  recursos propietarios, drops, async o llamadas a librerías externas.
- Solo funciones con 0–2 parámetros enteros/booleanos. La ABI es un
  contrato interno para este subconjunto, no la ABI Windows x64 completa.
- `main` no recibe argumentos y devuelve Int; el resultado se pasa a
  `sys_exit`, por lo que Linux observa solo el código de salida bajo 8 bits.
- Fuente LIR <= 1 MiB; 1–16 funciones; 1–32 bloques/función; 0–64 variables;
  <= 10 000 instrucciones/bloque; literales enteros decimales hasta 2^31−1
  en este lector reducido.
- Los nombres de funciones serializados se restringen a ASCII imprimible.
- Bloques CFG inalcanzables se rechazan conservadoramente; un `unreachable`
  explícito no se acepta en este subconjunto.
- **No** se han validado CFI, relocations externas, PE64, calls indirectas,
  registers de plataforma especiales, unwind o excepciones.
- **No** se ha comprobado el backend con LIR fresco generado por Stage 1:
  los fixtures `.lir` se redactaron manualmente siguiendo el protocolo.

## Fixtures y pruebas preparadas

`crates/l/tests/native_cfg_l.rs` construye la CLI ELE mediante Stage 0 y
comprueba ELF64 y los casos negativos de:

- `examples/native_cfg_loop_call.lir`: funciones `main` y `double`, un bucle
  con salto hacia atrás, `lt`, llamada y retorno (esperado: salida **8**).
- `examples/native_cfg_branch.lir` y `native_cfg_branch_spans.lir`:
  comparaciones, bifurcaciones y spans de fuente estilo Stage 1.
- `examples/native_cfg_recursive.lir`: factorial recursivo 5! (**120**).
- `examples/native_cfg_uninit.lir`: lectura no inicializada entre bloques;
  debe rechazarse.
- `examples/native_cfg_branch_uninit.lir`: unión con inicialización parcial;
  debe rechazarse.
- `examples/native_cfg_bad_call.lir`: argumento Bool donde se exige Int;
  debe rechazarse.
- `examples/native_cfg_bad_branch.lir`: salto a bloque inexistente;
  debe rechazarse.

En una plataforma Linux x86-64 con bootstrap disponible, la prueba Rust
`ele_cfg_generated_elf_executes_with_last_loop_value` intenta ejecutar
realmente el ELF y exige código de salida 8.

### Ejecución de verificación en Windows/MSVC

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-encoder.ps1   # primero, las 10 pruebas corregidas de fase 8.7.1
.\bench\verify-native-cfg.ps1       # pruebas nuevas y antiguas
.\bench\build-native-cfg.ps1        # produce target/native-ele/ele-cfg.elf
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

En Linux x86-64/WSL, después de copiar el ELF generado desde Windows:

```bash
chmod +x target/native-ele/ele-cfg.elf
./target/native-ele/ele-cfg.elf
printf 'exit=%s\n' "$?"           # esperado: 8
```

**Nunca ejecutes LIR no confiable con este backend experimental.**

## Qué se verificó realmente en el entorno de esta revisión

- `python3 -m unittest discover -s tests/native_backend -v`: **20/20**;
  prueban herramientas previas y no compilan las nuevas fuentes ELE.
- Auditoría estática de imports desde `native_cfg_demo.l`: **7 módulos
  alcanzables, 0 imports perdidos y 0 ciclos**. Esto no valida semántica.
- Una secuencia representativa de instrucciones emitibles fue desensamblada
  mediante GNU `objdump` y reconocida como instrucciones x86-64 correctas.
- Un **programa de referencia en ensamblador externo**, con el mismo diseño
  de prólogos, llamadas y bucles, se ejecutó en Linux y devolvió **8**.
  No fue producido por el emisor ELE; no se confunde con una prueba E2E.
- No hay `cargo`, `rustc` ni Stage 1 preconstruido para ejecutar las pruebas
  Rust o compilar los nuevos módulos `.l`; **las nuevas pruebas no están
  aprobadas todavía**.

## Handoff y prioridad siguiente

1. Ejecutar primero `verify-native-encoder.ps1` sobre la versión con las
   correcciones de los 10 fallos. Si falla, detener la expansión y reparar.
2. Ejecutar `verify-native-cfg.ps1` y corregir errores reales de compilación
   o verificación, sin desactivar ownership.
3. Generar y ejecutar el ELF de `native_cfg_loop_call.lir` (8), y repetir
   con la recursión y las ramas (120 y 42).
4. Generar **LIR real de Stage 1** para casos de múltiples funciones y CFG;
   comparar con los fixtures y cubrir las formas faltantes (spans, etc.).
5. Ampliar la ABI, el control de memoria, drops y recursos propietarios solo
   cuando las pruebas anteriores pasen. Implementar el enlace PE/COFF
   para Windows en hitos posteriores.
6. La ruta Rust/Cranelift y el backend Python/C se conservan como referencias;
   el objetivo final permanece **compilar ELE con un backend, runtime y linker
   íntegramente en ELE**.
