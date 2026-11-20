# ELE STAGE 3.3 — SEGURIDAD DEL COMPILADOR, OPTIMIZACIÓN DEL BACKEND Y EXPANSIÓN DEL SELF-HOSTING
## Informe Técnico de Ingeniería de Sistemas, Auditoría de Rendimiento y Verificación Generacional

**Repositorio:** https://github.com/Joshua-EPR/ELE  
**Base verificada:** `main` tras merge del PR #118 (`e441479280992db44fc707fdd15efb1eba348ae1`)  
**Rama de integración:** `test/ele-stage3-3-bootstrap-regression`  
**Ramas especializadas integradas:**
- `fix/ele-native-filesystem-safety` (commit `f4078af`)
- `perf/ele-driver-memory-pipeline` (commit `7f18e6c`)
- `perf/ele-native-codegen-capacity` (commit `5741025`)
- `feat/ele-native-self-coverage` (commit `8e70799`)
**Fecha:** 2026-11-20  
**Entorno de desarrollo y validación:** Windows x86-64 (PowerShell 5.1 / NT 10.0) y Linux x86-64 (WSL2 Ubuntu 24.04 LTS / Kernel 5.15)

---

## RESUMEN EJECUTIVO Y BITÁCORA GENERACIONAL

```text
BASE_SHA: e441479280992db44fc707fdd15efb1eba348ae1 (Merge PR #118)
INTEGRATION_BRANCH: test/ele-stage3-3-bootstrap-regression
FEATURE_BRANCHES:
  - fix/ele-native-filesystem-safety (f4078af)
  - perf/ele-driver-memory-pipeline (7f18e6c)
  - perf/ele-native-codegen-capacity (5741025)
  - feat/ele-native-self-coverage (8e70799)
GEN1_WINDOWS: COMPLETE (ele_gen1.exe, PE32+, 1,508,352 bytes)
GEN2_WINDOWS: COMPLETE (ele_gen2.exe, PE32+, 1,508,352 bytes)
GEN3_WINDOWS: COMPLETE (ele_gen3.exe, PE32+, 1,508,352 bytes)
GEN1_LINUX: COMPLETE (ele_gen1.elf, ELF64, 1,511,424 bytes)
GEN2_LINUX: COMPLETE (ele_gen2.elf, ELF64, 1,511,424 bytes)
GEN3_LINUX: COMPLETE (ele_gen3.elf, ELF64, 1,511,424 bytes)
GEN2_SHA256_WINDOWS: F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D
GEN3_SHA256_WINDOWS: F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D
GEN2_SHA256_LINUX: 4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9
GEN3_SHA256_LINUX: 4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9
BITWISE_EQUAL: YES (Gen 2 == Gen 3 en Windows PE32+; Gen 2 == Gen 3 en Linux ELF64)
FUNCTIONAL_EQUAL: YES (ambas generaciones ejecutan programas de forma idéntica)
DRIVER_COMPILATION_SPEEDUP: 13.3x (133.9 s -> 10.0 s, reducción del 92.5% de tiempo de CPU)
BACKEND_CAPACITY_EXPANSION: 16 MiB -> 32 MiB (código e IR), 64 MiB (PE64 Heap Reserve)
SELF_COVERAGE_BACKEND: 20/102 (100% de los ejecutables independientes de compiler-l/src)
TESTS_DRIVER: 23 passed; 0 failed (crates/l/tests/ele_build_driver_l.rs)
TESTS_CAPACITY: 12 passed; 0 failed (crates/l/tests/native_capacity_l.rs)
CI_QUALITY_GATES: 100% PASSED (fmt, clippy -D warnings, ratchet, self_coverage, driver, capacity)
```

---

## 1. TAREA ALPHA (P0): SEGURIDAD DEL SISTEMA DE ARCHIVOS Y PROTECCIÓN MULTIMÓDULO

### Diagnóstico
En la versión base de Stage 3.2, la validación de sobreescritura destructiva en el driver (`compiler-l/src/main_driver.l`) se limitaba a comparar `output_path` con el `source_file` principal tras normalización léxica. Esto dejaba expuestas vulnerabilidades críticas:
1. **Sobreescritura de módulos importados:** En proyectos multimódulo (`import helper`), compilar con `--output helper.l` destruía el código fuente de los módulos secundarios antes o durante la compilación.
2. **Aliases y Hardlinks:** Si el destino apuntaba a un enlace duro o un alias del archivo de código fuente, la comparación por cadena de texto no detectaba la colisión.
3. **Escritura directa no atómica:** El compilador abría y truncaba directamente el archivo de salida final (`output_path`). Si la compilación fallaba a mitad de camino o los permisos eran denegados tardíamente, el archivo de salida previo quedaba corrupto o truncado.

### Evidencia
- Se diseñaron casos de prueba adversarios en `crates/l/tests/ele_build_driver_l.rs`:
  - `driver_cli_rejects_overwrite_of_imported_module`: verificó que intentar compilar `main.l` (que importa `helper.l`) con `--output helper.l` falle con código de error 2 y mensaje explícito de protección.
  - `driver_cli_source_intact_on_failed_compilation_and_overwrite`: verificó que si una compilación falla, el código fuente o el archivo preexistente permanezca intacto.
  - `driver_cli_rejects_overwrite_of_hardlink_source`: comprobó la detección de aliases mediante contenido de texto.
  - `driver_cli_rejects_overwrite_of_imported_module_hardlink`: comprobó la detección de aliases para submódulos importados.

### Cambio
En `compiler-l/src/main_driver.l`:
1. **Inspección de aliases de fuentes:**
   - Se añadió lectura y comparación de contenido (`textMatches`) entre el archivo de destino (si ya existe) y los archivos fuente. Como el builtin `readText` falla de forma segura cuando el archivo no es UTF-8 válido (ej. ejecutables binarios PE/ELF existentes), los binarios preexistentes no generan falsos positivos, mientras que cualquier alias de texto del fuente es detectado de inmediato.
2. **Protección exhaustiva de todo el grafo modular:**
   - En `compileProgram(...)`, antes de ensamblar o emitir el binario, se itera sobre todos los módulos descubiertos (`prog.module_paths`) comparando `output_path` mediante `pathsEquivalent(...)` y verificación de contenido.
   - Si colisiona con cualquier módulo del árbol de dependencias, aborta con código 2 y mensaje: `error: el archivo de salida no puede sobrescribir el modulo importado '{path}'`.
3. **Staging atómico (`.tmp.ele`):**
   - La emisión del ejecutable se realiza escribiendo primero a un archivo temporal intermedio `{output_path}.tmp.ele`.
   - Se verifica que la escritura retorne estado 0 (`writeBytes`).
   - Solo tras completar la emisión atómica se promueve al `output_path` final, eliminando el riesgo de dejar archivos truncados o binarios a medio escribir en compilaciones fallidas.

### Verificación
- Ejecución completa de `cargo test -p project-l --test ele_build_driver_l`: 23 pruebas pasadas satisfactoriamente (incluyendo las 4 nuevas pruebas de seguridad).
- Ningún archivo fuente es alterado ante compilaciones erróneas.

### Riesgos y Mitigaciones
- *Riesgo:* Falso positivo al sobrescribir un binario anterior que casualmente coincidiera con un archivo fuente.
- *Mitigación:* Los binarios ejecutables contienen encabezados binarios no UTF-8 (`\x7fELF` o `MZ`), los cuales provocan que `readText` retorne código de error cerrado (`Err(4)`), evitando comparaciones erróneas de texto sobre ejecutables válidos previos.

---

## 2. TAREA BETA (P1): OPTIMIZACIÓN DE MEMORIA Y TIEMPO DE COMPILACIÓN DEL DRIVER

### Diagnóstico
El driver `ele build` concatena las líneas emitidas por `main_sema` para generar el artefacto ELE-LIR antes de alimentar el backend nativo.
En la implementación base, esto se realizaba mediante concatenación lineal ingenua en un bucle:
```ele
each line among lines {
    lir = lir + line + "\n"
}
```
Dado que las cadenas en ELE son inmutables y asignadas por valor propietario en el heap, concatenar $N \approx 72,000$ líneas producía $O(N^2)$ reasignaciones y copias en memoria. Para compilar el propio driver (cuyo LIR supera los 72,000 renglones y 2.6 MB):
- Se asignaban y descartaban más de 50 GB acumulados en el heap.
- El tiempo de compilación del driver en Windows tomaba **133.9 segundos (2 minutos y 14 segundos)**.

### Evidencia
- Medición antes de la optimización (`target/debug/l.exe compiler-l/src/main_driver.l`):
  - **Tiempo base:** 133,925 ms.
- Medición tras la implementación del acumulador jerárquico radix-32:
  - **Tiempo optimizado:** 10,012 ms.
  - **Reducción neta:** 123,913 ms (92.5% más rápido).
  - **Factor de aceleración:** **13.3x**.
  - **Fijación determinista:** El LIR generado es exactamente idéntico carácter a carácter (`SHA256: 06DDD4ACB6177E40EE966598727E97645D044FD597F119A3379608198A36B005`).

### Cambio
En `compiler-l/src/main_driver.l`:
Se implementó el algoritmo `assembleLir(lines: view List of[Text]) => Text`:
1. Agrupación por lotes de 32 elementos (*radix-32 chunking*).
2. Cada bloque de hasta 32 líneas se concatena en una sola cadena intermedia (`b32`).
3. Si el lote supera 32 bloques, se consolida recursivamente a bloques de segundo nivel de 32 elementos (`b1024`).
4. Finalmente, los bloques de alto nivel se unen en la cadena final `out`.
5. La complejidad temporal y espacial se redujo de $O(N^2)$ a $O(N \log_{32} N) \approx O(N)$.

### Verificación
- Fixpoint generacional verificado bit a bit en Windows y Linux.
- Tiempos de prueba de autorreconstrucción reducidos de minutos a segundos en CI.

### Riesgos y Mitigaciones
- *Riesgo:* Alteración en delimitadores de línea o caracteres finales.
- *Mitigación:* Se verificó con hash SHA256 que el archivo LIR emitido es idéntico bit a bit al generado por la versión previa.

---

## 3. TAREA GAMMA (P1): EXPANSIÓN DE CAPACIDAD Y ROBUSTEZ DEL BACKEND

### Diagnóstico
El backend nativo mantenía constantes estáticas heredadas de las fases iniciales de Stage 3:
- `ELF64_MAX_CODE = 16777216` (16 MiB).
- `PE64_MAX_CODE = 16777216` (16 MiB).
- `cfgMaxSource() = 16777216` (16 MiB) y límite de 120,000 bloques básicos.
- `SizeOfHeapReserve = 33554432` (32 MiB) en encabezados PE32+.
- `NATIVE_HEAP_MAX = 16777216` (16 MiB).
- `heapDynSizeGuard` con techo de 16 MiB.

Aunque 16 MiB era suficiente para programas pequeños, el driver completo multimódulo y los futuros componentes del compilador self-hosted se acercaban peligrosamente a estos techos, impidiendo la compilación de programas monolíticos grandes.

### Evidencia
- Se ejecutó la suite `crates/l/tests/native_capacity_l.rs`.
- Se verificó que los límites de seguridad arquitectónicos (como `NATIVE_LAYOUT_MAX_BYTES = 1048576`, 1 MiB de límite de stack frame) se mantuvieran intactos (probado por `aggregates_beyond_the_layout_planner_are_rejected`).
- Se introdujo una prueba de regresión de capacidad a 32 MiB: `native_backend_source_capacity_at_32mib_boundary`.

### Cambio
1. `compiler-l/src/codegen/elf64.l`:
   - `ELF64_MAX_CODE = 33554432` (32 MiB).
2. `compiler-l/src/codegen/pe64.l`:
   - `PE64_MAX_CODE = 33554432` (32 MiB).
   - `SizeOfHeapReserve = 67108864` (64 MiB de reserva en encabezado opcional PE32+).
3. `compiler-l/src/codegen/native_cfg_ir.l`:
   - `cfgMaxSource() = 33554432` (32 MiB).
   - Límite de bloques básicos elevado a 250,000.
4. `compiler-l/src/codegen/lir_subset.l`:
   - Límite de tamaño de fuente LIR elevado a 33,554,432 (32 MiB).
5. `compiler-l/src/codegen/native_heap.l` y `native_heap_dynamic.l`:
   - `NATIVE_HEAP_MAX = 33554432` (32 MiB).
   - `heapDynSizeGuard` elevado a 33,554,432 (32 MiB).

### Verificación
- Todas las 12 pruebas de `native_capacity_l` pasadas al 100%.
- El generador rechaza de forma determinista y segura (código de error 4 / fail-closed) entradas que superen los 32 MiB sin provocar desbordamientos de buffer ni fallos de segmentación.

### Riesgos y Mitigaciones
- *Riesgo:* Consumo excesivo de memoria virtual o colapso del linker.
- *Mitigación:* La reserva de heap PE32+ (`SizeOfHeapReserve`) no asigna memoria física en la carga, solo espacio de direcciones virtual. El commit inicial de stack (`SizeOfStackCommit = 65536`) y de heap se mantienen en valores seguros (4 KiB - 64 KiB).

---

## 4. TAREA DELTA (P1): EXPANSIÓN DEL BASELINE DE COBERTURA NATIVA (SELF-COVERAGE)

### Diagnóstico
La matriz de auto-cobertura (`docs/self_coverage_baseline.tsv`) registraba 19/102 archivos de `compiler-l/src/` con estatus `backend`. El único archivo ejecutable independiente que permanecía estancado en la fase `parser` era:
- `compiler-l/src/native_pe_demo.l`

El bloqueo se debía a proyecciones temporales propietarias en invocaciones encadenadas de funciones de PE64:
```ele
pe64Layout(image.sections, image.entry_point).error
```
El analizador semántico de Stage 1 rechazaba este patrón con el código `L0016: proyección de un valor temporal propietario fuera del subconjunto de Stage 1`.

### Evidencia
- Se ejecutó `cargo test -p project-l --test self_coverage`.
- Con `native_pe_demo.l` reparado, el archivo superó tanto el análisis semántico de Stage 1 como la generación LIR y la emisión del backend nativo.
- El baseline avanzó de 19/102 a **20/102 (100% de los ejecutables independientes de la toolchain)**.

### Cambio
1. `compiler-l/src/native_pe_demo.l`:
   - Se eliminaron las proyecciones de campos sobre llamadas temporales directas (`pe64Layout(...).error`, `pe64Executable(...).error`, `pe64ExecutableRelocatable(...).error`).
   - Se vincularon explícitamente a variables locales con `hold`:
     ```ele
     hold layout = pe64Layout(image.sections, image.entry_point)
     when layout.error != 0 { give layout.error }
     ```
2. `docs/self_coverage_baseline.tsv`:
   - Se actualizó la fila de `compiler-l/src/native_pe_demo.l` de `parser` a `backend`.

### Verificación
- Ejecución de `cargo test -p project-l --test self_coverage`:
  - 102/102 en fase Lexer/Parser (100%).
  - 102/102 en fase Semántica (100%).
  - 102/102 en fase LIR (100%).
  - 20/102 en fase Backend Nativo (100% de los ejecutables standalone).

### Riesgos y Mitigaciones
- *Riesgo:* Inconsistencia en la semántica de destrucción de variables locales temporales (`hold`).
- *Mitigación:* Se probó la compilación nativa directa del archivo produciendo un ejecutable funcional sin fugas de memoria.

---

## 5. EXPERIMENTO INTEGRADO Y VERIFICACIÓN MULTIPLATAFORMA (TAREA EPSILON)

### Cadena de Reconstrucción Generacional en Windows PE32+ (x86-64)
1. **Generación 0:** Compilador host Rust (`target/debug/l.exe`).
2. **Generación 1:** Compilado por Gen 0 -> `ele_gen1.exe` (PE32+, 1,508,352 bytes).
3. **Generación 2:** Compilado por Gen 1:
   ```powershell
   .\ele_gen1.exe build compiler-l/src/main_driver.l --target pe --output ele_gen2.exe
   ```
   - SHA256: `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`
4. **Generación 3:** Compilado por Gen 2:
   ```powershell
   .\ele_gen2.exe build compiler-l/src/main_driver.l --target pe --output ele_gen3.exe
   ```
   - SHA256: `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`
5. **Resultado:**
   - **Bit-for-bit Fixpoint:** `Gen 2 SHA256 == Gen 3 SHA256` idénticos byte a byte.
   - **Validación Funcional:** Gen 3 compiló `hello.l` a `hello_by_gen3.exe`; su ejecución imprimió `Autonomy Gen 3` con código de salida 0.

### Cadena de Reconstrucción Generacional en Linux ELF64 (WSL2 Ubuntu)
1. **Generación 1:** Driver genera imagen ELF64 -> `ele_gen1.elf` (ELF64, 1,511,424 bytes).
2. **Generación 2:** Compilado por Gen 1 en entorno Linux:
   ```bash
   ./ele_gen1.elf build compiler-l/src/main_driver.l --target elf --output ele_gen2.elf
   ```
   - SHA256: `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9`
3. **Generación 3:** Compilado por Gen 2 en entorno Linux:
   ```bash
   ./ele_gen2.elf build compiler-l/src/main_driver.l --target elf --output ele_gen3.elf
   ```
   - SHA256: `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9`
4. **Resultado:**
   - **Bit-for-bit Fixpoint:** `Gen 2 SHA256 == Gen 3 SHA256` idénticos byte a byte.
   - **Validación Funcional:** Gen 3 compiló `hello.l` a `hello_by_gen3.elf`; su ejecución imprimió `Autonomy Gen 3 Linux` con código de salida 0.
   - **Invocaciones externas:** 0 (cero llamadas a compiladores o ensambladores externos).

---

## 6. MATRIZ DE PUERTAS DE CALIDAD (CI QUALITY GATES)

| Puerta de Calidad | Comando de Verificación | Resultado | Estado |
|---|---|---|---|
| **Formato de Código** | `cargo fmt --all --check` | 0 diferencias | **PASS** |
| **Linter Estricto** | `cargo clippy --workspace --all-targets -- -D warnings` | 0 advertencias / 0 errores | **PASS** |
| **Sintaxis ELE v2 Ratchet** | `cargo test -p project-l --test ele_v2_legacy_ratchet` | 5/5 pasadas | **PASS** |
| **Auto-cobertura Semántica/Backend** | `cargo test -p project-l --test self_coverage` | 3/3 pasadas (20/102 backend) | **PASS** |
| **Capacidad y Límites de Backend** | `cargo test -p project-l --test native_capacity_l` | 12/12 pasadas (32 MiB boundary) | **PASS** |
| **Suite Completa del Driver** | `cargo test -p project-l --test ele_build_driver_l` | 23/23 pasadas (Fixpoints Win + Linux) | **PASS** |

---

## 7. ORDEN RECOMENDADO DE MERGE Y ENLACES DE PULL REQUESTS

Para una integración atómica y sin regresiones en `main`, se recomienda el siguiente orden de fusión:

1. **PR 1: `feat/ele-native-self-coverage` (Commit `8e70799`)**
   - *Título:* `feat(coverage): advance native_pe_demo to native backend phase (20/102)`
   - *Impacto:* Eleva la cobertura del backend nativo a 20/102 sin alterar la lógica del driver ni del backend.
2. **PR 2: `perf/ele-driver-memory-pipeline` (Commit `7f18e6c`)**
   - *Título:* `perf(driver): radix-32 hierarchical LIR accumulator eliminating quadratic copies`
   - *Impacto:* Aceleración de 13.3x en tiempo de compilación del driver y eliminación de 50 GB de copias innecesarias.
3. **PR 3: `fix/ele-native-filesystem-safety` (Commit `f4078af`)**
   - *Título:* `fix(driver): strict multi-module source protection, alias detection, and atomic write staging`
   - *Impacto:* Blindaje contra sobreescritura de módulos importados, detección de hardlinks y escritura atómica `.tmp.ele`.
4. **PR 4: `perf/ele-native-codegen-capacity` (Commit `5741025`)**
   - *Título:* `perf(codegen): raise static backend capacity boundaries to 32 MiB and 64 MiB heap reserve`
   - *Impacto:* Expansión de capacidades máximas de código, IR y heap reserve de 16 MiB a 32/64 MiB.
5. **PR 5 (Integración Unificada & Documentación): `test/ele-stage3-3-bootstrap-regression`**
   - *Título:* `test(stage3-3): unified regression suite, generational fixpoint validation and engineering report`
   - *Impacto:* Integración final verificada y documentación técnica de Stage 3.3.
