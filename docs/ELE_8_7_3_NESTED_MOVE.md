# ELE — Fase 8.7.3, incremento: structs anidadas con semántica Move

**Fecha:** 2026-11-10. **Estado:** código implementado; compilación Stage0/MSVC de estos cambios pendiente. **No** se ha construido Stage2.

## Alcance real

Se ha extendido el backend x86-64 escrito en ELE (`compiler-l/src/codegen/native_cfg_{ir,emit}.l`) para admitir **structs anidadas con campos primitivos y semántica Move** dentro del subconjunto `ELE-LIR 1`:

- Un campo `field <nombre> sN` es válido si `sN` es una estructura **previamente declarada** y completamente definida. Esto produce un grafo de tipos acíclico; las referencias hacia delante y la autorecursión por valor se rechazan.
- El layout de cada struct se calcula en ELE con `native_layout.l`. El offset, tamaño y alineación de un campo agregado proceden de ese layout, no de un número fijo.
- `i struct`, `i use` e `i store` admiten campos agregados movidos. `i read` solo admite campos primitivos Copy, incluso proyectados a `pN.M.K`. El generador recorre los campos del tipo anidado, emite cargas/escrituras de 8 bits para `Bool` y de 64 bits para `Int`, y **no copia padding no inicializado**.
- La identidad nominal se conserva (`s0` y `s1` son tipos distintos aunque sus campos tengan el mismo tamaño).
- El verificador aplica **KILL/GEN** a las variables en el CFG: los movimientos de struct invalidan el origen, y los usos posteriores se rechazan. La validez se calcula con intersección en las uniones y backedges. ELE **no** permite Copy implícito de structs incluso cuando todos sus campos son primitivos.
- Se rechazan las extracciones de un campo que contiene una struct: requieren análisis de movimientos parciales; para leer sus campos Copy se admite `pN.M.K`.
- Las lecturas desde lugares y los stores requieren agregados inicializados por completo; se mantienen los rechazos por tipos incompatibles, tipos propietarios y lugares malformados.
- Los tipos de retorno y parámetros de struct siguen rechazados: faltan convenciones ABI verificadas para agregados.

**Restricciones intactas:** máximo 16 structs, 4 campos por struct, 512 bytes por struct, 64 slots de 8 bytes por función. Solo campos `Int`, `Bool` y structs sin drop declaradas previamente. No se admiten `Text`, `List`, referencias, arrays, enums, préstamos, recursos propietarios ni drops. Se admiten `pN.M` y `pN.M.K` con tipo primitivo final; no se admiten movimientos parciales de campos struct.

## Pruebas

### Ejecutadas en este entorno

- `python3 -m unittest discover -s tests/native_backend -q`: **28/28** aprobadas; contratos y herramientas Python, **no** es compilación del código ELE.
- `python3 tools/ele_source_audit.py --root compiler-l/src --entry native_cfg_demo.l`: 0 imports faltantes, 0 ciclos; auditoría **estática**.
- `python3 tools/ele_source_audit.py --root compiler-l/src --entry main_sema.l`: 0 imports faltantes, 0 ciclos; auditoría **estática**.

### Nuevas pruebas de integración **NO ejecutadas** (necesitan Rust/MSVC)

`crates/l/tests/native_nested_struct_l.rs` construye `native_cfg_demo` desde el código `.l` real y comprueba:

1. `examples/native_cfg_nested_copy.lir`: construcción de `Inner`, composición de `Outer`, movimiento de `Inner` hacia `Outer`, movimiento de `Outer` hacia otra variable, acceso a `Int`/`Bool` mediante campos anidados y rama condicional; ELF64 esperado termina con **42** en Linux x86-64.
2. `examples/native_cfg_nested_inactive.lir`: mismo flujo pero `active=false`; ELF64 esperado termina con **0** en Linux.
3. Rechazo de `sN` adelantada, store de tipos nominales incompatibles, store sobre struct no inicializada, campo propietario no soportado, extracciones parciales de struct, doble movimiento, uso después de movimiento y movimiento válido solo en una rama seguido de uso tras la unión CFG.
4. `examples/native_cfg_real_nested.l` → **Stage1 real** `--emit-lir` → backend nativo escrito en ELE → ELF64. Su ejecución es parte de la validación pendiente, no una capacidad demostrada.

Desde Windows/MSVC:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-nested.ps1
.\bench\verify-native-struct.ps1
.\bench\verify-native-cfg.ps1
cargo test --target x86_64-pc-windows-msvc
```

Desde Linux x86-64 / WSL, los ejecutables ELF64 **realmente generados por ELE** deben ejecutarse para validar los códigos de salida (42 y 0 respectivamente). No usar como sustituto una imagen preparada por Python o C.

## Próximos bloqueos

1. Compilar este código `.l` y corregir cualquier fallo real de Stage0/borrow checking; repetir las pruebas de regresión.
2. Verificar fuente Stage1→LIR para structs anidadas; la emisión de lugares anidados puede requerir un lowering tipado adicional.
3. Introducir representación y verificación de recursos propietarios, runtime de asignación y drops antes de admitir `Text` o `List<T>` en el backend. No aceptar valores propietarios mediante el mecanismo de copia de structs.
4. Completar 8.7.3; solo después considerar enums/Option/Result (8.7.4), runtime/PE64 (8.7.5) y Stage2 (8.8).

**No afirmar self-hosting o ausencia de dependencias:** el generador ELE continúa construyéndose mediante Stage0; la cadena final, la ABI Win64/PE64 y Stage2 no están verificados ni terminados.
