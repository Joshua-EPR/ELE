# ELE — 8.7.4.2 (incremento verificable de interoperabilidad)

## Alcance implementado

1. El lector Rust de ELE-LIR 1 admite `i payload vD pN eE V` en el mismo formato
   que el backend ELE experimental. Valida lugar directo, tipo nominal,
   variante y campo primitivo Copy con tipo exacto.
2. El backend Cranelift provisional comprueba el discriminante antes de
   calcular la dirección de un payload; la variante inactiva provoca un panic
   localizado en lugar de leer memoria no correspondiente al tipo activo.
3. Stage 1 conserva la identidad nominal de enums **unitarios** como `eN`.
   Serializa declaraciones, variantes unitarias y el discriminante de un
   `match` unitario. Los constructores unitarios ahora emiten `i variant`.
4. Stage 1 rechaza con `L0016` el LIR de match sobre Option/Result o enums
   con payload, en vez de generar código incorrecto que compara enteros
   directamente con agregados. No se han relajado ownership ni drops.
5. Se añadieron pruebas de protocolo negativas, una prueba de `match`
   unitario y una prueba que intenta compilar un archivo `.l` de enum
   unitario a ELF64 usando ambos componentes escritos en ELE. Esta última requiere el bootstrap Stage 0 y un host
   compatible (Rust/MSVC); por ahora no se ha ejecutado en este entorno.

## Garantías y límites

- El nuevo `payload` es solo lectura Copy de `Int` y `Bool`; no permite mover
  valores propietarios ni tomar referencias.
- La comprobación dinámica no implica soporte completo de match o
  seguridad de todos los accesos a payloads desde código fuente.
- No se ha construido Stage 2, no hay Option/Result completos, ni se ha
  completado la autocobertura del frontend.
- El código nuevo requiere validación real mediante Cargo y MSVC. No
  equiparar análisis estático o tests Python con compilación del `.l`.

## Pruebas reproducibles en Windows

```powershell
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
cargo test -p project-l --test lir_payload_protocol --target x86_64-pc-windows-msvc
cargo test -p project-l --test native_enum_stage1_l --target x86_64-pc-windows-msvc
.\bench\verify-native-enum-payload.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

`native_enum_stage1_l` verifica generación ELF64 con Stage 1 y el backend
ELE compilados inicialmente por Stage 0. Bajo Windows no ejecuta ese ELF:
para verificar el resultado (42), usar WSL/Linux x86-64, con permisos de
archivo compatibles y rutas adaptadas al sistema.

## Próxima prioridad

1. Ejecutar los tests Rust y ELE y corregir el primer error real.
2. Validar `match` unitario desde `.l` hasta ELF64 con flujo de control.
3. Completar construcción de variantes con payload en Stage 1 y su
   verificador, proyección de payload bajo CFG y move paths.
4. Implementar Option/Result y `?` únicamente después de verificar drops
   propietarios y el runtime necesario.
