# ELE — Fase 8.7.4.4: invariantes nominales y de payload en `match`

## Base y alcance

Partida: `ELE-fase8.7.4.3-avance-proyecto-completo.zip`. Este incremento **no** implementa
`Option<T>` / `Result<T,E>` genéricos, ni la propagación `?`, ni completa el runtime.
Prioridad: corregir inconsistencias de validación que podrían permitir proyecciones
algebraicas incorrectas en la frontera Stage 1 ↔ ELE-LIR.

## Cambios de implementación

1. **Stage 1 — cobertura de enums.** `semaEnumMatchCovered` comprueba que el
   calificador de un patrón `Enum.Variante(...)` resuelva al mismo `decl_id`
   nominal del scrutinee. Comparar únicamente el nombre textual de una variante
   permitía confundir dos enums con variantes homónimas. Se exige un calificador
   para la ruta nativa de variantes de usuario. Los patrones de enlace de valor
   completo, subpatrones complejos y alias que el puente no puede resolver
   continúan fuera del subconjunto; no se reinterpretan como variantes.
2. **Aridad de patrones.** Se rechaza la forma de variante unitaria con
   paréntesis y la de variante con payload sin patrón del payload; se validan
   también las delimitaciones del patrón antes de permitir la caída al último
   brazo de `match`.
3. **Parser Rust ELE-LIR.** Un `variant` con id fuera de rango o aridad de
   payload incompatible se rechaza temprano; `payload` solo acepta un lugar
   raíz cuya variable sea `VarTy::Value(Type::Enum(...))`, **no** una referencia
   `VarTy::Ref`, tal como ya exige el subconjunto del lector ELE.
4. **Verificador Stage 1.** Una construcción `LIR_VARIANT` unitaria no puede
   contener un operando residual. `LIR_PAYLOAD` comprueba que su raíz no sea
   una variable `ref` antes de permitir la proyección Copy de Int/Bool.

## Pruebas

Se añadieron cinco pruebas de Rust (tres de fuente Stage 1 y dos del parser
LIR), integradas en:

- `crates/l/tests/native_enum_stage1_payload_l.rs`
- `crates/l/tests/lir_payload_protocol.rs`

Casos: variante de **otro enum nominal** en `match`, patrón con payload
faltante, payload ilegal en variante unitaria, lectura de payload desde una
referencia raíz y construcción de variante con aridad incorrecta.

### Verificación efectivamente ejecutada en este entorno

```sh
python3 -m unittest discover -s tests/native_backend -p 'test_*.py' -q
```

Las 39 pruebas locales existentes pasan (son pruebas Python de contratos y
herramientas; no compilan ELE). Auditoría de imports disponible separadamente.

**No se ejecutaron Cargo, rustc ni los `.l` nuevos**: esas herramientas no están
instaladas. Por tanto, este documento no certifica que la integración
Stage 1 → LIR → backend ELE → ELF64 compile o se ejecute. Los nuevos tests
Rust son pruebas **preparadas, no ejecutadas**.

### Verificación pendiente en Windows (desde la raíz ELE)

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo test -p project-l --test lir_payload_protocol --target x86_64-pc-windows-msvc
cargo test -p project-l --test native_enum_stage1_payload_l --target x86_64-pc-windows-msvc
.\bench\verify-native-enum-stage1-payload.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

La ejecución final del ELF se debe verificar en Linux x86-64/WSL. No es
suficiente observar que el archivo ELF se escribió o que las pruebas Python
pasaron. Ante errores de Stage 0, corregirlos y ejecutar nuevamente los tests.

## Trabajo todavía bloqueado

- Verificar todas las modificaciones de 8.7.4.3 y 8.7.4.4 con Stage 0.
- Completar bindings `match` sobre patrones complejos y la semántica de
  préstamos/movimientos propietarios.
- Generics y monomorfización de `Option` / `Result` desde `.l`.
- Drops y allocator de heap necesarios para payloads propietarios.
- Probar el backend nativo escrito en ELE hasta ELF64 usando LIR real.
- Stage 2; **no construido**.
