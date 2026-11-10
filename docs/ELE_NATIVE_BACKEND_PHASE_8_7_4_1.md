# ELE — Fase 8.7.4.1 (incremento: lectura protegida de payloads primitivos)

**Estado:** implementación de fuentes y fixtures; **no compilada con Stage 0 ni ejecutada a partir de ELE** en este entorno. Este documento separa el subconjunto experimental de la cobertura completa de `Option`, `Result` y `match`.

## Cambios implementados

El backend de ELF64 escrito en ELE (`compiler-l/src/codegen/native_cfg_{ir,verify,emit}.l`) ahora admite una operación **experimental, local al backend nativo**:

```text
i payload v<dest> p<owner> e<enum> <variant>
```

- El destino debe ser `Int` o `Bool` según el tipo declarado del **único** payload de esa variante. Los enums siguen siendo nominales y `Move`.
- Se comprueban de forma estática la existencia del enum, su correspondencia con el tipo del owner, el índice de variante, la existencia del payload, el tipo de destino y la inicialización/vida del owner según el CFG. No se admiten structs, `Text`, listas, préstamos ni payloads propietarios en esta etapa.
- El emisor produce una comparación x86-64 del discriminante real contra la variante solicitada **antes** de leer el payload. Si no coincide, ejecuta `sys_exit(126)` en Linux x86-64 en lugar de leer un payload inactivo. El resultado se carga con el ancho correcto: 8 bits sin signo para `Bool`, 64 bits para `Int`.
- La operación **lee un payload Copy sin moverlo**. No implementa toma ni préstamo del payload; el owner continúa vivo. El movimiento del enum completo sigue invalidando el origen en el verificador anterior.
- Se añaden fixtures con flujo de tres bloques (análogo a un `match` sobre el discriminante) y ejemplos *estructuralmente equivalentes* a `Option<Int>` (Some/None) y `Result<Int,Int>` (Ok/Err), con trayectorias de éxito y error.

## Frontera del protocolo: trabajo pendiente

El protocolo oficial `ELE-LIR 1`, consumido por `crates/l/src/lir_protocol.rs`, **todavía no define `i payload`**. Tampoco lo serializa `compiler-l/src/lir_write.l`. El registro experimental anterior **NO es interoperable todavía** con Stage 1 o el backend Rust. No debe presentarse como extensión estable de ELE-LIR, ni como prueba de integración source `.l` → Stage 1 → backend ELE.

Para completar correctamente la integración se necesita acordar una proyección de payload oficial y actualizar **de forma conjunta**: la representación tipada de LIR y sus reglas de ownership; el emisor de Stage 1; el lector/verificador Rust; el lector/verificador ELE; y el lowering del backend, junto con pruebas reales de código `.l`. Si la representación introduce una incompatibilidad de formato, versionar explícitamente el protocolo. No incorporar la operación experimental como sinónimo silencioso de `i read` en Rust: una proyección sin guardia demostrada o comprobación dinámica podría leer una variante inactiva.

## Verificación disponible

- `python3 -m unittest discover -s tests/native_backend -q`: **30 pruebas** de herramientas, verificadores de fixtures y contratos de fuente aprobadas en este entorno. **No** ejecutan el compilador ELE.
- `python3 tools/ele_source_audit.py --root compiler-l/src --entry native_cfg_demo.l`: cero imports faltantes y cero ciclos en el **grafo estático**, no en el grafo semántico.
- Preparado `crates/l/tests/native_enum_payload_l.rs` con tests de integración reales que construyen el backend desde `.l` con Stage 0, producen ELF64 y, cuando corren sobre Linux x86-64, validan los códigos de salida `42`, `0`, `7` y `126`. **Sin ejecutar**: faltan Cargo y Rust en el entorno de implementación.

En Windows/MSVC, desde la raíz:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-enum.ps1
.\bench\verify-native-enum-payload.ps1
cargo test --target x86_64-pc-windows-msvc
```

En Windows los tests comprueban la generación de ELF; **la ejecución de ELF no se realiza en Windows**. Para comprobarla, generar el ELF usando `bench/build-native-cfg.ps1 -Lir examples/native_cfg_option_some.lir -Output target/native-ele/option.elf`, transferir el archivo a Linux/WSL x86-64, conceder permiso de ejecución y comprobar que `$?` es `42`. Para `native_cfg_enum_payload_wrong_active.lir` el código esperado es `126`.

## Invariantes y límites

- Enums con cero o un payload primitivo `Int`/`Bool`, sin heap ni drop.
- Solo se admite lectura Copy y solo después de un chequeo del discriminante ejecutado en cada lectura, incluso dentro de bucles y a través de ramas.
- No hay extracción de payload por movimiento, préstamos ni match exhaustivo nativo; los fixtures ilustran una estructura CFG equivalente, **no una compilación de sintaxis `match` por Stage 1**.
- `Option<T>`, `Result<T,E>` genéricos, propagación `?`, destrucción propietaria, ABI de agregados y Stage 2 permanecen pendientes.
- La compilación del código recién cambiado en ELE no está verificada. No declarar terminada la Fase 8.7.4.

## Siguiente incremento prioritario

1. Ejecutar las pruebas Rust/MSVC y corregir cualquier error real de semántica, borrow checking o codegen (sin suprimir comprobaciones).
2. Diseñar la proyección tipada interoperable en ELE-LIR, con seguridad de variante activa; añadirla al serializador Stage 1 y a ambos consumidores.
3. Crear un fixture **fuente `.l` real** que atraviese Stage 1 → ELE-LIR → backend ELE → ELF64 y comprobar su ejecución en Linux x86-64.
4. Integrar `Option` y `Result` monomorfizados y `match` exhaustivo con tratamiento de movimientos y drops; priorizar completar recursos propietarios de 8.7.3 antes de ampliar payloads.
