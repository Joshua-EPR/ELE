# ELE STAGE 3.1 — ELE BUILD, DRIVER AUTÓNOMO Y TOOLCHAIN SELF-HOSTED
## Informe de Implementación, Verificación y Evidencia Generacional

**Repositorio:** https://github.com/Joshua-EPR/ELE  
**Rama:** `feat/ele-build-driver`  
**Commit base:** `4ae3d24132b45baac6ecf26250b55637ab91b710` (Merge pull request #116)  
**Fecha:** 2026-11-20  
**Entorno de verificación:** Windows x86-64 PowerShell 5.1 & WSL2 Ubuntu (Linux x86-64)

---

## 1. RESUMEN EJECUTIVO

En cumplimiento de las directivas de la **OPERACIÓN STAGE 3.1**, se implementó el driver autónomo y unificado del compilador ELE en sintaxis nativa ELE v2:

```bash
ele build <archivo.l> [--output <ruta>] [--target <elf|pe>] [--pe64] [--elf64]
```

El driver elimina la necesidad de coordinar manualmente el frontend semántico, la serialización de archivos `.lir` temporales y la invocación manual del backend. Conecta directamente en memoria el cargador recursivo de módulos, análisis léxico, análisis sintáctico, resolución de ámbitos y símbolos, borrow checking y ownership, descenso a ELE-LIR y la compilación directa a imágenes binarias ejecutables en formato **PE32+ (Windows x86-64)** y **ELF64 (Linux x86-64)**.

---

## 2. ARQUITECTURA DEL DRIVER UNIFICADO

El archivo fuente `compiler-l/src/main_driver.l` fue escrito íntegramente en la sintaxis canónica ELE v2:
- **Estructuras y funciones:** `shape`, `flow`, `expose`, `hold`, `change`, `choose`, `give`, `view`, `edit`, `when`, `otherwise`, `each ... among`, `take`.
- **Integración frontend en memoria:**
  - `loadProgram(entry_path)` (`modules_l.l`): resolución de rutas relativas, detección estricta de ciclos de importación (error `L0014`), control de profundidad de imports y fusión determinista de árboles AST.
  - `semaAnalyze(ctx, source, tree)` (`sema.l`): verificación de tipos, verificación estricta de ownership y borrow checking (`error[L0005]` por use-after-move, préstamos no solapados, drop flags), y emisión en memoria de líneas ELE-LIR (`semaCtx.lir_lines`).
- **Integración backend nativo:**
  - `cfgCompileFor(lir_text, target)` (`codegen/native_cfg_emit.l`): parseo y verificación de CFG en memoria, emisión de código máquina x86-64 sin dependencias externas, runtime de memoria y resolución de builtins.
  - `writeBytes(outpath, compiled.image)`: escritura directa a disco mediante primitivas de plataforma del kernel / KERNEL32.
- **Capacidad ampliada en ELF64:**
  - En `compiler-l/src/codegen/elf64.l`: se elevó el límite estático `ELF64_MAX_CODE` de 1 MiB (`1048576`) a 16 MiB (`16777216`), permitiendo que binarios monolíticos completos (como el propio driver unificado de 1.48 MiB) sean generados sin truncamiento ni error 72.

---

## 3. AUDITORÍA DE HITOS Y RESULTADOS

### Hito A — CLI y Comandos
- `ele --version` / `ele -v`: emite `ele 0.3.0 (Stage 3 self-hosted native driver)` y finaliza con código 0.
- `ele --help` / `ele -h`: emite el mensaje de uso detallando comandos y flags, finalizando con código 0.
- `ele` (sin argumentos): diagnostica `error[CLI]: falta el comando` con código 2.
- `ele build <inexistente.l>`: diagnostica `archivo inexistente` con código de fallo.
- `ele build <syntax_err.l>`: reporta errores léxicos/sintácticos con archivo, línea, columna y byte offset (ej. `error[PARSER]: se esperaba expresión`).

### Hito B — Backend y Ejecución Nativa
- **Windows PE32+ (x86-64):**
  - Comando: `ele build target/driver_test/hello.l --output target/driver_test/hello.exe`
  - Ejecución real en PowerShell: `.\target\driver_test\hello.exe`
  - Salida verificada: `Hola desde ELE`
  - Código de salida: `0`
- **Linux ELF64 (x86-64):**
  - Comando: `ele build target/driver_test/hello.l --target elf --output target/driver_test/hello.elf`
  - Cabecera verificada: `\x7fELF\x02\x01\x01`
  - Ejecución real en WSL Ubuntu: `/mnt/.../hello.elf`
  - Salida verificada: `Hola desde ELE`
  - Código de salida: `0`

### Hito C — Proyectos Multimódulo
- Se verificó la compilación de proyectos estructurados en varios archivos usando `take`:
  - `helper.l`: exporta `expose flow addNums(a: Int, b: Int) => Int` y `expose flow mulNums(a: Int, b: Int) => Int`.
  - `main.l`: importa `take helper` e invoca funciones calculando `(20 + 22) * 2`.
  - Ejecutable generado: `target/driver_test/multimodule/main_proj.exe` y `main_proj_elf`.
  - Salida verificada: `Resultado: 84` con código de salida `0` en Windows y WSL.

### Hito D — Seguridad, Invariantes y Ownership
- Prohibición de debilitar el borrow checker:
  - `ownership_err.l` (use-after-move de `Text`): el driver rechaza la compilación con `error[L0005]: uso de valor movido, parcialmente movido o sin inicialización segura` y no genera ejecutable.
  - `cycle_a.l` y `cycle_b.l` (dependencia circular): el driver rechaza la compilación con `error[L0014]: ciclo de dependencias detectado` y aborta limpiamente.

### Hito E — Autonomía Generacional (Bootstrap)
- **Generación 1 (Bootstrap Stage 0):** `main_driver.l` fue compilado a `main_driver.exe` mediante `l.exe`.
- **Generación 2 (Backend Nativo Autónomo):**
  - El backend nativo `native_cfg_demo.exe` compiló la LIR de `main_driver.l` (`main_driver_utf8.lir`, 1.94 MB) sin usar Stage 0, produciendo:
    - `main_driver_gen2.exe` (PE32+, 1,484,800 bytes).
    - `main_driver_gen2.elf` (ELF64, 1,486,848 bytes).
- **Generación 3 (Compilación Autónoma por el Driver Nativo):**
  - `main_driver_gen2.exe` compiló de manera 100% autónoma `hello.l` a `hello_gen3.exe`, el cual ejecutó con éxito imprimiendo `Hola desde ELE` (código 0).
  - `main_driver_gen2.elf` compiló de manera 100% autónoma `hello.l` a `hello_gen3_elf` en WSL Ubuntu, el cual ejecutó con éxito imprimiendo `Hola desde ELE` (código 0).
  - Invocaciones a compiladores externos en Generaciones 2 y 3: **0**.

---

## 4. ARCHIVOS MODIFICADOS Y CREADOS

1. `compiler-l/src/main_driver.l`: implementación completa del driver unificado en ELE v2.
2. `compiler-l/src/codegen/elf64.l`: incremento de capacidad estática `ELF64_MAX_CODE` a 16 MiB.
3. `crates/l/tests/ele_build_driver_l.rs`: suite de pruebas de integración con 11 casos end-to-end.
4. `docs/self_coverage_baseline.tsv`: actualización de la línea base oficial registrando `main_driver.l` en backend (19/102).
5. `docs/ELE_STAGE3_1_BUILD_DRIVER_PROGRESS.md`: este informe.

---

## 5. RESULTADOS DE GATES DE CALIDAD

```text
cargo fmt --all --check                                  -> PASS (código 0)
cargo clippy --workspace --all-targets -- -D warnings    -> PASS (0 warnings, código 0)
cargo test -p project-l --test ele_v2_legacy_ratchet     -> PASS (5 passed, 0 legacy tokens en fuentes nuevas)
cargo test -p project-l --test self_coverage             -> PASS (3 passed, 19/102 backend)
cargo test -p project-l --test ele_build_driver_l        -> PASS (11 passed; 0 failed)
```

---

## 6. SIGUIENTE FRONTIER TÉCNICA

- Soporte de optimizaciones de layout para agregados anidados en `main_driver.l`.
- Enlace opcional de emisor PE32+ que incorpore manifiestos embebidos en Windows.
- Sustitución progresiva de los wrappers de test en Rust por scripts de verificación orquestados mediante el propio `ele build`.
