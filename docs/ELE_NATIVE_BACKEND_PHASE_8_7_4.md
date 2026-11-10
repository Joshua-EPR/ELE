# ELE — Fase 8.7.4 (primer incremento: enums de payload primitivo)

**Estado: IMPLEMENTADO EN FUENTES, NO VERIFICADO CON STAGE 0.** No se ha completado la fase 8.7.4. Los scripts Rust/MSVC no se pudieron ejecutar en el entorno de esta entrega (faltan `cargo` y `rustc`).

## Auditoría

- El lector provisional de `ELE-LIR 1` en `crates/l/src/lir_protocol.rs` ya reconoce `module structs S enums E funcs F`, `enum eN`, `variant ... types N`, `i variant vN eN variante argumentos` e `i disc vN pN`.
- La ruta escrita en ELE de `codegen/native_cfg_ir.l` admitía inicialmente únicamente tipos `i`, `b` y `sN`, y rechazaba esas declaraciones e instrucciones.
- Stage 1 dispone de sintaxis y comprobaciones parciales de enums/Option/Result, pero `compiler-l/src/lir_write.l` aún no serializa todas las operaciones de variante/discriminante. No hay ruta verificada `.l → Stage 1 → enums LIR → backend ELE`.
- La Fase 8.7.3 todavía no tiene asignador, List<T> y drops nativos seguros; **no se admite ningún payload propietario**.

## Código implementado en ELE

`codegen/native_cfg_ir.l`, `native_cfg_verify.l` y `native_cfg_emit.l`:

- Cabecera opcional `enums N`, compatible con LIR anterior que no la incluya.
- Parseo y verificación de `enum eN` y `variant` hasta **16 enums**, **8 variantes por enum**.
- Únicamente variantes unitarias o con **un** payload `i` o `b`. Otros tipos y aridades se rechazan con error.
- IDs nominales, distintos de los IDs de structs: `Int=0`, `Bool=1`, `struct=2+s`, `enum=2+cantidad_structs+e`.
- Layout explícito inicial: discriminante `i64` en offset 0 y, si alguna variante lo necesita, un slot de payload de 8 bytes en offset 8. Tamaño total 8 o 16 bytes; alineación 8. No se utilizan niche optimizations.
- `i variant` inicializa discriminante y slot completo (incluye cero para la variante unitaria y el relleno de `Bool`). `i disc` lee solamente el discriminante de una variable propietaria ya inicializada.
- Los enums son **move-only** incluso con payload primitivo. Las asignaciones `i use` consumen el origen; el verificador comprueba uso después de movimiento, lecturas no inicializadas y movimiento en uniones de CFG.
- La emisión realiza cargas y stores x86-64 existentes, sin ensamblador ni generador C dentro de la ruta nativa.

El nuevo trabajo **no** introduce extracción de payload ni `match` de alto nivel. El lector del protocolo Rust todavía no describe proyecciones de payload en el formato textual de lugar para esta ruta, por lo que implementarlas solo en el backend ELE crearía un dialecto incompatible.

## Pruebas

Preparadas para Stage 0 (pendientes):

```powershell
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
.\bench\verify-native-enum.ps1
.\bench\verify-native-nested.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

`crates/l/tests/native_enum_l.rs` compila el CLI `native_cfg_demo.l`, escribe tres ELF64 (unitario, payload `Int`, payload `Bool`) y valida su cabecera. En Linux x86-64 también los ejecuta y comprueba códigos 1 y 42. Ocho casos negativos comprueban aridad, tipos, variante inexistente, enum inexistente, payload propietario, variables no inicializadas y movimientos en CFG.

Ejecutado **solo en este entorno**: `python -m unittest discover -s tests/native_backend -p 'test*.py'` (28 pruebas preexistentes) y `python -m unittest discover -s tools -p 'test_native_enum_contract.py'` (3 comprobaciones estáticas). Esas pruebas no compilan los cambios `.l`.

## Pendiente para finalizar 8.7.4

1. Compilar el backend ELE con Stage 0 y corregir problemas de semántica/ownership que revele MSVC.
2. Verificar los tres ELF64 **producidos por ELE** y ejecutar los casos negativos.
3. Diseñar las proyecciones de payload en la gramática LIR compartida, serialización Stage 1, parseo provisional, verificador y backend ELE, con pruebas de compatibilidad.
4. Permitir extracción segura de payload, pattern matching exhaustivo y uniones de flujo con ownership.
5. Integrar el lowering real de `Option<T>`, `Result<T,E>` y operador `?`, con propagación y drops de recursos propietarios cuando la Fase 8.7.3 complete el runtime.
6. Ejecutar pruebas diferenciales y un programa real `.l → Stage1 → ELE-LIR → backend ELE → ELF64`.

**No se han construido Stage 2 ni Stage 3.** Estas implementaciones no demuestran autonomía del toolchain ni un compilador completo de ADTs.
