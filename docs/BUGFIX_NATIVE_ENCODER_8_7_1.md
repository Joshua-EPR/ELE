# Corrección de los 10 fallos iniciales de native_encoder_l (Fase 8.7.1)

## Contexto

El usuario ejecutó `bench/verify-native-encoder.ps1` bajo Windows/MSVC. Las diez pruebas fallaron durante la compilación, antes de ejercitar el encoder. Se identificaron tres causas en los archivos existentes y se aplicaron correcciones localizadas.

1. **L0005** (`compiler-l/src/codegen/elf64.l`): `elf64Executable` intentaba `return out` dentro de `for`, moviendo un valor propietario exterior en un contexto que el comprobador de ownership actual rechaza. La validación de bytes ahora acumula un indicador `Bool` y devuelve el buffer vacío **después** del bucle. No se relaja el borrow checker.
2. **L0001** (`compiler-l/src/codegen/lir_tokens.l`): `nativeExpect`, `nativeNumber`, `nativeId` y `nativeOperand` llamaban a `nativeWord(source, reader)` cuando este requiere `&mut NativeReader`. Ahora pasan `&mut reader` explícitamente, coherente con el resto de la implementación.
3. **L0007** (`crates/l/src/cfg.rs`): el lowering de operaciones de plataforma reconocía `List<Int>` como referencia para `writeBytes`, pero construía siempre un préstamo `VarTy::Ref(Type::Text)` y `Rvalue::Loan(..., Type::Text)`. Ahora conserva `value.ty` tanto para la variable como para el préstamo, de modo que el verificador reciba `List<Int>`.

## Validación efectuada en esta entrega

- Revisión estática de las tres correcciones y los diez tests existentes.
- `python -m unittest discover -s tests/native_backend -q`: **20 pruebas aprobadas** en Linux.
- **NO** se pudo ejecutar Cargo, Stage 0 ni los diez tests de `native_encoder_l`: este entorno no cuenta con `cargo`/`rustc`. Las correcciones todavía **no están confirmadas** por el toolchain Windows/MSVC.

## Comprobación necesaria en Windows

Desde la raíz `ELE` del proyecto actualizado:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-encoder.ps1
.\bench\build-native-elf.ps1
cargo test -p project-l --test native_encoder_l --target x86_64-pc-windows-msvc -- --nocapture
```

Si se aprueba esa suite, verificar luego el resto del proyecto:

```powershell
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

Si surge una **nueva** falla, compartir el mensaje íntegro de la primera falla; puede tratarse de un problema previamente oculto por los errores de compilación anteriores.

## Alcance

Estas correcciones se limitan al bootstrap y al backend experimental. No demuestran self-hosting, Stage 2, Stage 3 ni independencia de Rust. No introducen cambios destructivos en la semántica de ownership.
