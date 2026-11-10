# ELE — Continuación verificable de 8.7.3 hacia 8.8

**Fecha:** 2026-11-10. **Estado:** implementación parcial con pruebas de integración preparadas; sin compilación Stage 0/Stage 1 en el entorno de autoría.

## Avance de código (nuevo)

Se extendieron `compiler-l/src/codegen/native_cfg_ir.l`, `native_cfg_verify.l` y `native_cfg_emit.l` del backend x86-64 **escrito en ELE**. El subconjunto Int/Bool/CFG previo se conserva y admite, adicionalmente:

1. Declaraciones `struct sN <nombre> fields N` y `field <nombre> i|b` de **ELE-LIR 1**. Layout calculado con `native_layout.l`; es metadato extraído del programa LIR, no layout manual de un test.
2. Variables `var vN val sN` con asignación de slots de stack por tamaño de agregado (hasta 64 slots por función).
3. `i struct vN sN N <operandos...>` para construir structs de 1 a 4 campos primitivos.
4. `i read vN pM.K` y `i store pM.K <operando>` para acceder a un campo directo.
5. `i use vDst vSrc` para copia **exclusivamente** de structs Copy con campos Int/Bool; la copia preserva la representación de Bool de 1 byte.
6. Verificación de identidad nominal, tipos de campos, rangos, inicialización definitiva por CFG, límites de stack y rechazo explícito de tipos no soportados.

Los layouts admiten Int (8/8) y Bool (1/1); los structs se alinean y reciben padding según el plan de layout nativo provisional. No es una declaración de ABI definitiva para ELE ni cubre tipos genéricos.

### Límites deliberados

- **No** se aceptan campos `Text`, `List<T>`, referencias, payloads Enum, recursos propietarios ni tipos de struct anidados. Tampoco structs en parámetros o retornos, y no hay lowering de `loan`, `drop`, `dropfield`, `variant`, `disc` o operaciones sobre heap.
- Los lugares admiten solo una proyección numérica: `pN.K`. Las proyecciones anidadas, los índices y las referencias se rechazan.
- Para `store`, el verificador exige un agregado previamente inicializado por completo. No simula inicialización parcial ni omite drops.
- Las rutinas ELF64 actuales se dirigen a Linux x86-64; **PE64 Windows no está implementado** en esta ruta.
- Stage 2 **no existe**. No se puede certificar la autocobertura nativa sin resolver las capacidades de `Text`, `List<T>`, errores, memoria y el frontend real de Stage 1.

## Evidencia de pruebas

### Ejecutadas aquí

- `python3 -m unittest discover -s tests/native_backend -q`: **23/23 aprobadas**; estas pruebas validan herramientas Python y fixtures del protocolo, **no** compilan `.l` ni emiten un binario ELE.
- `python3 tools/ele_source_audit.py --root compiler-l/src --entry native_cfg_demo.l`: 8 módulos alcanzables, 0 imports faltantes, 0 ciclos. Es únicamente auditoría de grafo.
- `python3 tools/ele_source_audit.py --root compiler-l/src --entry main_sema.l`: 40 módulos alcanzables, 0 imports faltantes, 0 ciclos. No demuestra autocobertura semántica.

### Preparadas, NO ejecutadas

Nuevo `crates/l/tests/native_struct_cfg_l.rs`:
- Generación de ELF64 desde la implementación ELE usando una fixture LIR con struct nominal.
- Prueba de ELF ejecutable y salida 42 en Linux x86-64 (si el host del test es Linux).
- Rechazo de campo inexistente, tipo equivocado, struct no inicializada, store de tipo equivocado y campo propietario no soportado.
- Integración **fuente real `.l` → Stage 1 `--emit-lir` → backend ELE**; no se sustituye por LIR manuscrito.

En Windows/MSVC, desde raíz del proyecto:

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
.\bench\verify-native-encoder.ps1
.\bench\verify-native-cfg.ps1
.\bench\verify-native-memory.ps1
.\bench\verify-native-struct.ps1
.\bench\build-native-struct.ps1
cargo test --target x86_64-pc-windows-msvc
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
```

Luego, **en Linux x86-64 / WSL** (la imagen es ELF, no PE):

```bash
chmod +x target/native-ele/ele-struct.elf
./target/native-ele/ele-struct.elf
printf 'exit=%s\n' "$?"  # esperado 42
```

Si Stage 0 falla al compilar un módulo, corregir el error real en la fuente y volver a ejecutar la suite, sin desactivar ownership.

## Estado por fase

| Fase | Avance comprobable en fuente | Bloqueos |
|---|---|---|
| 8.7.3 | LIR structs Copy → layout nominal → stack → código máquina; scripts y tests | MSVC pendiente; heap, List<T>, drops reales, nested/owned structs, préstamos |
| 8.7.4 | No implementado en backend x86-64 | enums, Option, Result, match y `?` con ownership |
| 8.7.5 | Reutiliza ELF64/writeBytes provisional | runtime ELE completo, ABI Win64, PE64 y enlazador ELE |
| 8.8 | Auditoría de imports Stage 1 | 40 módulos solo alcanzables estáticamente; falta compilación completa, Stage 2 ejecutable |

## Próximo bloqueo decisivo

Una vez verificadas las pruebas MSVC, introducir un modelo tipado de valores propios con capacidad de drop en ELE-LIR/ Machine IR y un runtime de asignación/liberación nativo ELE, antes de aceptar `Text` o `List<T>` en el backend. Ningún test de layout en pila demuestra seguridad del heap.
