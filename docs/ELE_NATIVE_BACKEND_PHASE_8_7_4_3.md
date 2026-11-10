# ELE — Fase 8.7.4.3: puente Stage 1 para variantes con payload primitivo

## Estado y alcance

Se partió del ZIP completo de la fase 8.7.4.2. Se modificó el **código fuente
real** del compilador Stage 1 escrito en ELE; **no** se ha podido compilar ni
ejecutar con Stage 0 porque en este entorno no están instalados `cargo` ni
`rustc`. No se afirma que la fase 8.7.4.3 esté completamente terminada.

## Implementado (sin certificación de compilación)

- `LirModule` conserva el tipo del primer payload de cada variante; únicamente
  se emiten construcciones con un `Int` o `Bool`, o variantes unitarias.
- Un `Enum.Variante(valor)` válido baja a `LIR_VARIANT` con operando tipado;
  se verifican identidad nominal, aridad y tipo exacto.
- `LIR_PAYLOAD` representa una lectura **Copy** guardada de la variante activa
  y el único payload primitivo; el serializer genera el formato compatible
  con el lector ELE y el lector de bootstrap Rust existentes.
- El verificador de Stage 1 valida variante, tipo nominal, tipo de destino,
  lugar directo, inicialización y prohibición de payload propietario.
- El lowering de `match` crea proyecciones `payload` dentro del brazo
  correspondiente y limita el binding a su propio scope.
- El verificador semántico comprueba exhaustividad y duplicados para enums
  antes de que un último brazo pueda interpretarse como la alternativa final.
- No se añadió un sistema paralelo de ownership ni se desactivó NLL.

## Contrato seguro

Soportado en el código fuente añadido: enums sin payload o con **un** payload
`Int` / `Bool`. La extracción es Copy, sin transferir ownership del agregado.
Los casos con `Text`, `List<T>`, structs propietarias, múltiples payloads,
préstamos, extracción por movimiento y drops reales continúan fuera del
subconjunto certificado. El backend comprueba dinámicamente el discriminante
antes del acceso para evitar leer una variante inactiva.

`Option`, `Result`, `?` y la construcción de Stage 2 **no están completados**.

## Pruebas ejecutadas aquí

`python -m unittest discover -s tests/native_backend -p 'test_*.py' -q`:
**39 pruebas aprobadas** (son pruebas Python, contratos y herramientas; NO
compilan el código ELE añadido).

## Pruebas de integración preparadas, NO ejecutadas

- `crates/l/tests/native_enum_stage1_payload_l.rs`: desde fuente real `.l`,
  invoca Stage 1, verifica y serializa LIR, invoca el backend escrito en ELE,
  inspecciona el ELF y, solo en Linux x86-64, comprueba código de salida 42.
- Pruebas negativas de tipo erróneo, argumento ausente, match incompleto y
  payload propietario no soportado.
- `bench/verify-native-enum-stage1-payload.ps1` para Windows/MSVC.

Para ejecutar desde PowerShell en el raíz de ELE:

```powershell
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
.\bench\verify-enum-lir-interop.ps1
.\bench\verify-native-enum-stage1-payload.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

**Importante:** ejecutar ELF Linux bajo WSL o Linux x86-64; la construcción
Windows/MSVC por sí sola no verifica código de salida 42.

## Siguiente bloqueo

1. Ejecutar Stage 0, corregir errores reales del frontend Stage 1 y confirmar
   que `examples/native_enum_payload_stage1.l` genera LIR válido.
2. Corregir cualquier fallo del backend ELE en construcción / proyección / CFG
   con una regresión nueva, y ejecutar el ELF.
3. Añadir movimiento de payloads y drops solo una vez demostrado el runtime.
4. Implementar `Option<T>`, `Result<T,E>` y genéricos de forma estructural,
   no como casos enteros hardcodeados.
5. Progresar a Stage 2 únicamente después del pipeline real validado.
