# ELE — Traspaso multiagente verificado (2026-11-19)

Base de todas las ramas: `origin/main` = `81de31ed20f65f45588c54274f72f35ba52a30a1`
(merge del PR #108). Ningún PR se ha fusionado en esta operación. ENCA y NEXO no se han tocado.

Política: el coordinador **re-ejecutó** las pruebas declaradas por cada agente sobre el commit
exacto de su rama y revisó el diff. "Verificado" significa eso, nada más. La suite completa
`cargo test --workspace` **no se ejecutó** (NOT RUN) por coste: 5 compilaciones paralelas en 4 núcleos.

Entorno: Windows 10 x64, `RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc`, WSL Ubuntu para ejecutar ELF64.
Sin `gh` y repositorio privado: el estado en vivo de GitHub Actions es **NOT ACCESSIBLE** y los PR
deben abrirse desde la web.

## Resumen por agente

| Agente | Cambios reales | Commit (rama) | Pruebas (re-ejecutadas por el coordinador) | Estado |
|---|---|---|---|---|
| ALPHA | Ninguno (solo lectura). Inventario de 37 worktrees y ramas locales | — | n/a | DONE (inventario) |
| BETA | Verificador LIR de Stage 1: estado de propiedad por bandera/lugar guardado en vez de por raíz. `lir_verify.l`, `lir_verify_core.l`, `lir_verify_helpers.l`, +3 tests | `b8abd4e` (`fix/beta-drop-flags-partial-moves`) | drops_l 6/6, stage1_adversarial_drops_l 10/10, stage1_b3_owned_union_drops_l 5/5, stage1_owned_union_lir_l 16/16, native_builtin_union_l 4/4, lir_l 14/14 — PASS | DONE (verificado; revisión del diff por el coordinador) |
| GAMMA | Backend ELF64 en ELE: builtins `i platform` (processArgCount, processArg, readText, printError, writeBytes) a Linux ELF64; página de datos RW W^X en `elf64.l`; nuevos `native_cfg_platform.l`, `native_rt_platform.l` | `219ac08` (`feat/gamma-native-elf64-next`) | native_platform_l 4/4 (ejecución real en WSL con `ELE_TEST_WSL_DISTRO=Ubuntu`), native_cfg_l 10/10, native_builtin_union_l 4/4 — PASS | DONE (verificado; `native_rt_platform.l` de 652 líneas sin revisión línea a línea) |
| DELTA | PE32+ reubicable: sección `.reloc` con DIR64, DYNAMIC_BASE + HIGH_ENTROPY_VA; validador estructural de `.reloc` | `0ec2457` (`feat/delta-pe64-next`) | native_pe64_l 12/12 PASS (ejecuta .exe reales; prueba de reubicación por el loader con control negativo) | DONE (verificado; flags PE revisados: 0x22, 0x160, sección 0x42000040) |
| EPSILON | Pruebas: negativos con diagnóstico exacto, 2 negativos nuevos (drop eliminado = fuga, drop duplicado = doble liberación), aviso `SKIP[native-exec]` + modo estricto `ELE_REQUIRE_NATIVE_EXEC=1`, `tests/adversarial_qa.py` reescrito | `693baf1` (`test/epsilon-test-integrity`) | drops_l 6/6, lir_payload_protocol 7/7, stage1_adversarial_drops_l 9/9 — PASS | PARTIAL (ver pendientes) |
| ETA | `build-clean.ps1` (fallaba siempre que existía `target/`), `tools/generate_hashes.ps1` (UTF-16/rutas absolutas), `tools/verify_hashes.py`, nuevo `scripts/tests/test_hash_tools.ps1` | `1f89baa` (`chore/eta-storage-repro-audit`) | test_hash_tools.ps1 11/11 PASS | DONE (verificado) |

## Avances recuperados (ALPHA, comprobados por el coordinador)

Copias de seguridad sin modificar ningún worktree en
`C:\Users\Usuario\Desktop\ELE-wt\_recovery-patches-2026-11-19\` (fuera del repositorio):

| Origen | Contenido | Estado |
|---|---|---|
| `ELE-wt/agent-beta`, commit `f1ac440` | `native_cfg_demo.l`: buffer readText 1 MiB → 16 MiB | LOCAL-ONLY, no publicado en ninguna rama remota |
| `ELE-wt/agent-beta`, sin commit | `tests/native_backend/test_stage1_enum_bridge_contract.py` (actualiza aserciones) | LOCAL-ONLY |
| `.claude/worktrees/agent-a582e948d165bff07` (sin commit) | préstamo two-phase de argumentos, 8 archivos +162/−16 | LOCAL-ONLY, PARTIAL, sin probar |
| `.claude/worktrees/agent-a211fa3c9eab69693` (sin commit) | tipo esperado de elementos de lista, 6 archivos +66/−5 | LOCAL-ONLY, PARTIAL, sin probar |
| `.claude/worktrees/agent-a47f84692f572f627` (sin commit) | resolución de tipos entre módulos, 2 archivos +29/−1 | LOCAL-ONLY, PARTIAL, sin probar |
| `ELE-wt/agent-gamma` (sin commit) | `native_cfg_text.l` y 3 más, +42/−7 | LOCAL-ONLY, sin revisar |
| rama local `feat/native-list-cfg` `2b8d595` (mensaje "a") | `native_cfg_loan.l`, `native_cfg_verify.l`, doc, gitlinks | LOCAL-ONLY, mezclado |
| `.claude/worktrees/agent-a1d76385424054ae7` (sin rastrear) | borrador PE64 antiguo (`x86_64_win.l`, `native_rt_win.l`, …) | probablemente superado por `pe64.l`/`win64_*.l` de main |
| `origin/fix/read-text-single-alloc` `a586ff2` | readText con una sola reserva (Stage 0) | publicado, no integrado, sin PR |

## Avances inexistentes o no publicados de la operación anterior

- `swarm-gamma` `bc5f105` "ELF64 backend: Add implementation artifacts…": **no contiene código de backend**;
  solo `limpiar-ramas-ele.ps1` y `temp_test.l`.
- `swarm-delta` `0fb0f63` "Add PE64 autonomy investigation plan": **commit vacío** (0 archivos).
- `swarm-beta` `24f727e`: solo un informe; sus dos hipótesis (limpieza de banderas en la entrada,
  drop de uniones MAYBE sin bandera) son **incorrectas** según BETA (drops_plan.l:66-67, :95-114, :133-138).
- PR #107 (`tests/adversarial_qa.py`): los literales `b"\\x7fELF"` estaban escapados, así que todos los
  negativos se rechazaban por la cabecera mágica y **no probaban truncamiento ni máquina**. Además el
  script no se ejecuta en CI (el workflow solo descubre `tests/native_backend/test_*.py`).
- PR #108 (`build-clean.ps1`): `TrimEnd('\\','/')` lanza excepción con `target/` presente; la comprobación
  de worktrees protegidos tampoco funcionaba (barras `/` de git). Corregido en `1f89baa`.
- `docs/STAGE2_STAGE3_BOOTSTRAP_REPORT.md` describe un ELF64 "funcional" de `native_cfg_demo` pero
  `scripts/bootstrap_stage2.ps1` solo comprueba la cabecera y el tamaño; no lo ejecuta (EPSILON).

## Regresiones corregidas

- **Stage 1 rechazaba LIR correcta** ("error[ICE] … regla 6") con movimientos parciales divergentes entre
  ramas (`if k { take(u.c) } else { take(u.n) }` y reasignación) y con campos con bandera liberados antes de
  un back-edge de bucle. Causa: un solo estado de propiedad por raíz para todas las banderas
  (`lir_verify.l:124,363` en main). Fallo cerrado (no era un agujero de memoria). Corregido en `b8abd4e`;
  las banderas forjadas (fallos 17, 18) siguen rechazándose.
- `build-clean.ps1` / `generate_hashes.ps1` / `verify_hashes.py` (ETA, `1f89baa`).

## Pruebas que fallan o no se ejecutaron

- Ninguna FAIL en los binarios ejecutados.
- NOT RUN: suite completa del workspace, `cargo clippy --workspace`, ejecución ELF de los demás binarios
  bajo WSL (los agentes ejecutaron 40 ELF de referencia de GAMMA manualmente; ver su informe).
- Gap de pruebas conocido: en Windows, la mitad de ejecución de 19 archivos `native_*`/`stage2_*`
  (45 sitios) está bajo `cfg(linux)` y pasa sin ejecutar. EPSILON lo hace visible; no lo corrige.
  `native_platform_l` (GAMMA) ejecuta en WSL solo si `ELE_TEST_WSL_DISTRO` está definido.
- Negativos con `is_err()` sin diagnóstico aún pendientes: `conformance.rs:45-46,81,118,120`,
  `ele_generics_v2.rs:131`, `cfg.rs:605`, `lir_l.rs:333,717`, `tests/native_backend/test_native_elf_verifier.py:17,42`.

## Estado real de Stage 1 / 2 / 3

- **Stage 1** (compilador en ELE compilado por Stage 0 con Cranelift): funciona para lexer, parser,
  sema y el backend demo.
- **Stage 2**: según `STAGE2_STAGE3_BOOTSTRAP_REPORT.md`, la LIR de `main_sema.l` es idéntica entre Stage 1 y
  Stage 2, pero Stage 2 se produce con `l build-lir` → **Cranelift (Rust)**. No re-verificado en esta operación.
- **Stage 3: NO alcanzado.** Bloqueadores medidos por GAMMA al pasar la LIR real de Stage 1 al backend nativo:
  1. ~~`i platform` (code 33/31)~~ — eliminado en `219ac08`.
  2. `native_elf_demo.l`: `i drop` de una unión propietaria completa (`Result<Text,Int>`) → code 92. Sin drop glue de unión completa. **Siguiente prioridad.**
  3. `main.l` (lexer): code 44 — `lexScan` tiene 275 variables (límite 256); funciones que devuelven referencias (`t returnref`).
  4. `native_cfg_demo.l` (el backend): code 48 — 21 structs (límite 16), 293 funciones (límite 256).

## Dependencias Rust / Cranelift / MSVC

- Stage 0 (Rust + Cranelift + linker MSVC) sigue siendo necesario para construir los ejecutables Stage 1 y Stage 2.
- PE32+ y ELF64 emitidos por el backend ELE **no necesitan** link.exe, COFF, MSVC ni Rust en la escritura de la imagen.
  PE solo importa KERNEL32 (GetStdHandle, WriteFile, ExitProcess, VirtualAlloc, VirtualFree): sin E/S de ficheros ni argumentos en PE todavía; sin `.pdata`/unwind.

## CI

Un único workflow `.github/workflows/native-selfhosting-validation.yml` (ETA): matriz ubuntu/windows,
ejecución de ~70 ELF en Linux, fmt y clippy `-D warnings` bloqueantes, sin `continue-on-error` ni `|| true`.
Debilidades: toolchain `stable` flotante (el repo fija 1.99.1), acciones no fijadas por SHA, `adversarial_qa.py`
y `scripts/tests/test_hash_tools.ps1` no integrados. Estado en vivo: NOT ACCESSIBLE.

## Almacenamiento (medido por ETA, solo lectura)

- Checkout principal: 3,33 GB (no 58,7 GB); `target/` principal 0,15 GB, con 6 worktrees registrados dentro (protegidos).
- 37 worktrees ≈ 35 GB; ≈ 31 GB son `target/` reconstruibles (ELE-baseline 9,25 GB; ELE-wt/* 18,8 GB; antigravity ≈ 3,5 GB).
- No se borró nada. Cualquier limpieza requiere autorización explícita del usuario.

## Ramas y orden de integración recomendado

Conflictos (git merge-tree): BETA × EPSILON chocan en `crates/l/tests/stage1_adversarial_drops_l.rs`.
GAMMA × DELTA, GAMMA × BETA, GAMMA × EPSILON, BETA × DELTA, DELTA × EPSILON, ETA × EPSILON: sin conflicto.

1. `chore/eta-storage-repro-audit` (scripts, independiente).
2. `fix/beta-drop-flags-partial-moves` (seguridad del verificador).
3. `test/epsilon-test-integrity` — conflicto ya resuelto: el merge `9902ff6` integra BETA (`b8abd4e`)
   y conserva las categorías 5 (EPSILON) y 6 (BETA); stage1_adversarial_drops_l 12/12, drops_l 6/6,
   lir_payload_protocol 7/7, stage1_b3 5/5, stage1_owned_union_lir_l 16/16, native_builtin_union_l 4/4,
   fmt y clippy PASS. Fusionar después de BETA (su PR incluirá el commit de BETA hasta entonces).
4. `feat/delta-pe64-next`.
5. `feat/gamma-native-elf64-next`.

Cada rama tiene exactamente un commit sobre `81de31e`, salvo `test/epsilon-test-integrity`
(`693baf1` + `b8abd4e` + merge `9902ff6`). Ninguna se ha fusionado.

## Próxima prioridad técnica

Drop glue nativo de una unión propietaria completa (bloqueador 2, code 92), después los límites del
backend (256 variables, 16 structs, 256 funciones) y funciones que devuelven referencias.
Recuperar en ramas propias `f1ac440` y, tras probarlo, el préstamo two-phase de `agent-a582e948d165bff07`.
