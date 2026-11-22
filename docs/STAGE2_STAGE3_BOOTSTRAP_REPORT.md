# Informe Técnico: Integración y Automatización del Bootstrap Stage 2 hacia Stage 3 en ELE

**Fecha:** 2026-11-18  
**Rama:** `feat/stage2-bootstrap-integration`  
**Autor:** Subagente Beta (Bootstrap Stage 2 / Stage 3)  
**Destinatario:** Director Técnico y Equipo de Arquitectura de ELE  

---

## 1. Resumen Ejecutivo

Se ha consolidado y verificado con éxito la integración del pipeline de bootstrap de **Stage 2** y establecido la base formal y automatizada para alcanzar **Stage 3** (self-hosting puro).

### Logros Principales:
1. **Compilación Limpia de los 4 Ejecutables Stage 1**:
   - `lexer-l` (`compiler-l/src/main.l` -> `main.exe`)
   - `parser-l` (`compiler-l/src/main_parser.l` -> `main_parser.exe`)
   - `sema-l` (`compiler-l/src/main_sema.l` -> `main_sema.exe`)
   - `native-cfg-demo` (`compiler-l/src/native_cfg_demo.l` -> `native_cfg_demo.exe`)
2. **Determinismo y Paridad Bit a Bit al 100% Demostrados**:
   - **Intra-fase (Stage 1 Run 1 vs Run 2)**: Al ejecutar `main_sema.exe compiler-l/src/main_sema.l --emit-lir` dos veces de forma independiente, la salida LIR de 1,039.8 KiB (1,064,790 bytes, 10,288 bloques, 16,571 instrucciones) es idéntica bit a bit.
     - Hash SHA-256: `721962FBA331347D9729D41FA420EA862810A5E8DE25F4D3EF9CDDEC3E223176`.
   - **Inter-fase (Stage 1 vs Stage 2)**: Se compiló el LIR emitido por Stage 1 utilizando `l build-lir` (backend provisional Cranelift, sin frontend Rust) produciendo el compilador ejecutable **Stage 2**. Dicho compilador Stage 2 recompiló a su vez `main_sema.l` emitiendo LIR con el **mismo hash SHA-256 idéntico bit a bit**, verificando la convergencia del ciclo de self-recompilación.
3. **Tubería Completa End-to-End Verificada**:
   - `main_parser.exe` procesa la fuente `.l` y valida el AST canónico (`AstSummary`).
   - `main_sema.exe --emit-lir` realiza el análisis de tipos, préstamos, ownership y drops, produciendo `ELE-LIR 1`.
   - `native_cfg_demo.exe` (backend ELF64 escrito 100% en ELE) consume el LIR y produce una imagen ejecutable **ELF64 little-endian funcional** de 19,179 bytes (con cabecera mágica `\x7fELF\x02\x01\x01`).
4. **Automatización Doble (Script y Test de Regresión)**:
   - Script de PowerShell: `scripts/bootstrap_stage2.ps1`
   - Test de integración en Rust: `crates/l/tests/stage2_bootstrap_l.rs`

---

## 2. Arquitectura de las Etapas de Bootstrap en ELE

| Etapa | Descripción | Frontend | Backend | Artefacto Resultante |
|---|---|---|---|---|
| **Stage 0** | Compilador inicial de referencia | Rust (`crates/l`) | Cranelift / rustc | `target/debug/l.exe` |
| **Stage 1** | Compilador escrito en ELE, compilado por Stage 0 | ELE (`compiler-l/src/*.l`) | Cranelift (vía Stage 0) | `main.exe`, `main_parser.exe`, `main_sema.exe`, `native_cfg_demo.exe` |
| **Stage 2** | Compilador producido al compilar las fuentes de ELE con Stage 1 | ELE (`main_sema.exe`) | Cranelift provisional (`l build-lir`) o Backend Nativo ELE | `sema_stage2.exe` |
| **Stage 3 (Objetivo Final)** | Self-hosting completo: Stage 2 compila el compilador completo usando únicamente el backend nativo de ELE | ELE (Stage 2) | ELE Nativo (`compiler-l/src/codegen/*.l`) | Compilador auto-hospedado autónomo |

---

## 3. Evidencia Experimental de Determinismo y Paridad

### 3.1. Métricas de la Compilación de `main_sema.l`

Al someter las ~246 líneas de `main_sema.l` y sus dependencias transitivas completas (`lexer`, `tokens`, `cursor`, `ast`, `parser`, `sema_types`, `symbols`, `scopes`, `ownership_l`, `sema_context`, `sema_expr`, `sema_stmt`, `sema`, `modules_l`, etc.):

- **Módulos analizados:** 16 módulos transitivos
- **Bloques LIR generados:** 10,288 bloques
- **Instrucciones LIR generadas:** 16,571 instrucciones
- **Operaciones de Drop elaboradas:** 1,084 drops
- **Banderas dinámicas de Drop requeridas:** 0
- **Tamaño del archivo serializado `ELE-LIR 1`:** 1,064,790 bytes (1,039.8 KiB)

### 3.2. Tabla de Hashes Criptográficos (SHA-256)

| Etapa / Ejecución | Operación | Salida | SHA-256 | Estado |
|---|---|---|---|---|
| Stage 1 (Run 1) | `main_sema.exe main_sema.l --emit-lir` | `main_sema_stage1_run1.lir` | `721962FBA331347D9729D41FA420EA862810A5E8DE25F4D3EF9CDDEC3E223176` | Base |
| Stage 1 (Run 2) | `main_sema.exe main_sema.l --emit-lir` | `main_sema_stage1_run2.lir` | `721962FBA331347D9729D41FA420EA862810A5E8DE25F4D3EF9CDDEC3E223176` | **100% IDÉNTICO** |
| Stage 2 | `main_sema_stage2.exe main_sema.l --emit-lir` | `main_sema_stage2_output.lir` | `721962FBA331347D9729D41FA420EA862810A5E8DE25F4D3EF9CDDEC3E223176` | **100% IDÉNTICO** |

Comparación de archivos con `fc.exe`:
```text
Comparing files main_sema_stage1_run1.lir and main_sema_stage2_output.lir
FC: no differences encountered
```

---

## 4. Análisis Detallado de Dependencias Externas Restantes para Stage 3 Puro

Para declarar **Stage 3 puro** (self-hosting donde ninguna herramienta Rust, cargo o biblioteca externa participe en la ruta normal de compilación), restan por desacoplar las siguientes dependencias:

### 4.1. Backend de Código Máquina (Cranelift)
- **Situación actual:** La emisión de código máquina del compilador completo (`main_sema.l`) todavía requiere `l build-lir`, el cual delega en los crates de Cranelift (`cranelift-codegen`, `cranelift-frontend`, `cranelift-object`, `cranelift-native`, `regalloc2`).
- **Qué falta:** El backend nativo escrito en ELE (`compiler-l/src/codegen/*.l`) actualmente soporta el subconjunto CFG de LIR (operaciones aritméticas, saltos, structs estáticos, heap/listas básicas, emitiendo ELF64). Debe expandirse para admitir:
  1. La totalidad de variantes de `match` sobre enums/uniones con payload propietario que utiliza `main_sema.l`.
  2. Indexación y desestructuración avanzada de agregados anidados.
  3. Límite de lectura de archivo en `native_cfg_demo.l`: elevar el tope de `readText(path, 1048576)` (1 MiB) a un valor acorde al compilador completo (ej. 16 MiB o 64 MiB), ya que `main_sema.lir` supera 1.01 MiB.

### 4.2. Enlazador del Sistema (System Linker) y Formato Ejecutable
- **Situación actual:**
  - En Windows x86_64, `build_cranelift` invoca `linker::find()` que busca `link.exe` de MSVC o `lld`/`gcc`, requiriendo las librerías `shell32.lib` y `mincore.lib`.
  - En Linux x86_64, `codegen/elf64.l` genera ejecutables ELF64 de forma autónoma sin enlazador externo para su subconjunto nativo.
- **Qué falta para Stage 3:**
  - Para Windows: Un emisor nativo de PE32+/COFF autónomo en ELE (`codegen/pe64.l`) o la capacidad de emitir scripts de enlace que invoquen `lld-link` sin intermediación del runtime de Rust.
  - Para Linux: Extender `codegen/elf64.l` para enlazar o emitir símbolos dinámicos si se requiere libc, o mantener la emisión estática autónoma basada en `sys_exit`, `sys_read`, `sys_write`.

### 4.3. Runtime de Plataforma (`platform.obj` / Win32 / Linux Syscalls)
- **Situación actual:** Primitivas como `readText`, `writeBytes`, `processArg` y `processArgCount` están vinculadas a través de `native::platform_object()` (`crates/l/src/native/platform_object.rs`), el cual incluye código máquina empaquetado para Win32.
- **Qué falta para Stage 3:** El runtime de plataforma debe escribirse en L o ensamblador puro ensamblado por el backend nativo de ELE, eliminando la dependencia de compilación cruzada desde Rust.

### 4.4. Parser y Validador de Protocolo LIR en Rust
- **Situación actual:** `crates/l/src/lir_protocol.rs` actúa como guardián defensivo entre Stage 1 y Cranelift.
- **Qué falta para Stage 3:** El backend nativo de ELE en `compiler-l/src/codegen/` debe convertirse en el consumidor nativo de la representación intermedia (ya sea en memoria compartida o parseando `ELE-LIR 1` directamente en ELE).

---

## 5. Instrucciones de Reproducción y Verificación

### 5.1. Vía PowerShell Harness
```powershell
powershell -ExecutionPolicy Bypass -File scripts/bootstrap_stage2.ps1
```
Salida esperada:
- Construcción de los 4 binarios en `target/bootstrap-stage2/build-*/`
- Doble corrida de determinismo comprobada
- Generación de `main_sema_stage1_run1.exe` vía `l build-lir`
- Recompilación por Stage 2 con paridad bit a bit verificada
- Pipeline completo con emisión de ELF64 de 19,179 bytes
- Código de salida: `0`.

### 5.2. Vía Cargo Integration Test
```powershell
cargo test -p project-l --test stage2_bootstrap_l
```
Salida esperada:
```text
running 3 tests
test test_all_four_stage2_executables_build_cleanly ... ok
test test_stage2_full_pipeline_end_to_end ... ok
test test_stage2_determinism_and_bit_for_bit_parity ... ok

test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 37.72s
```

---

## 6. Conclusión y Recomendación

La arquitectura de bootstrap de ELE ha superado con éxito la barrera más crítica: **el compilador escrito en ELE es capaz de analizarse, verificarse, generar su propia representación intermedia LIR y reproducirse a sí mismo de forma estrictamente determinista y bit a bit idéntica en Stage 2**.

El camino crítico para el siguiente hito (Stage 3) queda claramente acotado a la expansión del generador de código en `compiler-l/src/codegen/` y la eliminación de Cranelift y `platform_object.rs` como puentes provisionales.
