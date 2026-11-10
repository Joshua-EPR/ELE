# ELE — Phase 8.7.1: escritura binaria de ELF, integración de bootstrap

**Resultado: incremento implementado, pero aún no compilado con el bootstrap real**.
No se ha demostrado Stage 2, Stage 3 ni autonomía sin Rust/Python/C. 
El backend nativo continúa siendo un subconjunto experimental escrito en `.l`.

## Cambios implementados

- `writeBytes(path: Text, bytes: List<Int>) -> Int` en Stage 0, con préstamo
  compartido del path y del buffer. Códigos: **0** correcto, **1** argumentos/
  byte fuera de rango, **2** no se puede abrir/crear el destino, **3** error
  durante la escritura/cierre. Se validan todos los bytes **antes** de
  crear/truncar el archivo; límite de 64 MiB; se admiten NUL y valores 128–255.
  `writeBytes` **no transforma los bytes en UTF-8**. La ruta sí es UTF-8.
  La implementación inicial del servicio nativo Win64 reside en un objeto
  de bootstrap Rust `no_std` que invoca directamente las APIs Windows;
  también existe un fallback de Stage 0 `--backend rustc` basado en `std::fs`.
  **No es aún una primitiva implementada íntegramente en ELE.**
- Se integra el nuevo builtin en `lir.rs`, semántica Stage 0, CFG, efectos,
  serializador LIR Stage 1 (código provisional 4), parser de protocolo,
  backend rustc y Cranelift, con verificación de argumentos List<Int>.
  El frontend semántico completo de Stage 1 todavía debe implementar el nuevo
  builtin antes de usarlo como parte de su propia recompilación.
- `native_lir_demo.l` acepta `programa.lir [salida.elf]`. Con salida explícita,
  **el propio código ELE** llama a `writeBytes` para guardar exactamente
  los bytes producidos por `nativeCompileSubset`. Sin ruta de salida
  conserva el modo hex previo para las pruebas diferenciales.
- `native_elf_demo.l` acepta opcionalmente ruta de salida y conserva el modo
  hex histórico sin argumentos.
- `native_binary_io.l` prueba bytes `[0,127,128,255,10]` y rechazo de `256`.
- Cuatro pruebas Rust de integración nuevas requieren Windows/MSVC.
  Se mantienen las seis pruebas anteriores. Para el total de pruebas del
  workspace, ejecutar de nuevo la suite de Cargo; **no asumir su resultado**.
- `tools/verify_elf64.py` inspecciona un ELF64 sin generarlo y puede ejecutarlo
  opcionalmente en Linux x86-64. `bench/build-native-elf.ps1` facilita la
  construcción desde Stage 0 y la escritura por ELE en Windows.

## Qué se verificó efectivamente en este entorno

- `python -m unittest discover -s tests/native_backend -q`: **20 pruebas
  aprobadas**, incluidas cuatro pruebas nuevas de herramienta/contrato.
  Estas pruebas no compilan el nuevo código `.l`.
- `tools/verify_elf64.py --run` inspeccionó y ejecutó un ELF64 de **referencia**
  armado por una herramienta independiente y retornó **42** en Linux x86-64.
  **Ese ELF no procede del emisor ELE**; es una comprobación del verificador.
- Comprobación de estructura del repositorio y rutas de código modificado.
- No hay `cargo`/`rustc` ni `sema-l` precompilado en este entorno. Por tanto,
  no se verificó la compilación de los `.l` ni se ejecutaron las cuatro nuevas
  pruebas Rust; no se comprobó todavía la salida del emisor ELE en Windows.

## Reproducción requerida en Windows/MSVC

Desde la raíz, con VS Build Tools y Rust/MSVC instalados:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-encoder.ps1
.\bench\build-native-elf.ps1
.\bench\verify-stage1-modules.ps1 -FullSuite
```

El script `build-native-elf.ps1` debe producir `target/native-ele/ele-generated.elf`.
Tras obtenerlo, transferirlo a Linux x86-64/WSL y ejecutar:

```bash
python3 tools/verify_elf64.py target/native-ele/ele-generated.elf --run --expected-exit 42
```

**No ejecutar binarios generados a partir de LIR de fuentes no confiables.**

## Bloqueos restantes

1. Compilar y ejecutar las diez pruebas de `native_encoder_l.rs` en Windows;
   corregir cualquier fallo y repetir 398+ pruebas históricas.
2. Incluir `writeBytes` en el frontend **Stage 1 escrito en ELE**, y expresar
   préstamos/efectos/salida nativa a través del protocolo completo.
3. Implementar `readBytes` con un tipo de resultado que distinga error y
   archivo vacío, manteniendo límites, ownership y archivos binarios arbitrarios.
4. Extender el lowering desde el subconjunto entero lineal hacia CFG real,
   ABI, memoria, funciones y múltiples módulos; añadir verificador independiente.
5. Sustituir el puente Win64 de bootstrap por llamadas al SO desde el runtime
   escrito en ELE; desarrollar PE/COFF y objetos/enlazador propios.
6. Compilar todo Stage 1, construir Stage 2 y Stage 3; demostrar autonomía.
