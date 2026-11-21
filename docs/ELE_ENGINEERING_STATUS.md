# ELE Engineering Status (continuity report)

Verified: 2026-11-21, against `origin/main` = `f166cad` (Merge PR #140).
Status vocabulary: COMPLETADO Y VERIFICADO / IMPLEMENTADO, PENDIENTE DE VALIDACIÓN / EN DESARROLLO / BLOQUEADO / NO INICIADO.

This file is meant to let a new session resume without repeating investigations. Update it at each milestone.

## 1. Repository state at verification

| Item | Value | Status |
|---|---|---|
| `origin/main` head | `f166cad` | Verified via `git fetch` |
| Local checkout `main`/HEAD | `99c9eda` on a branch with 530 commits behind `origin/main` and an unfinished merge (`UU` in `.gitignore`, `crates/l/src/modules.rs`, `crates/l/src/parser.rs`) | Not touched; the user's working tree was left as is |
| Open PRs / issues / Actions runs | Not verified: `gh` is not installed in this environment | NOT VERIFIED |
| 2026-11 feature branches | `codex/native-file-streams`, `codex/elepad-terminal`, `codex/ele-win32-abi`, `codex/ele-console-output`, `codex/elepad-core`, `feat/ele-native-library-search-root`, `feat/ele-native-console-input`: **0 commits ahead of `origin/main`** (`git rev-list --count origin/main..<branch>`), so everything they contain is already merged. Local-only `codex/native-file-metadata-20261121` and `codex/ele-win32-window-probe-20261121`: 0 ahead, never pushed. | Verified |

## 2. Capability inventory on `origin/main` (grep-verified)

### 2.1 File I/O (P0-B)
- Available: whole-file `readText(path, max)` and `writeBytes(path, bytes)` (Win64 and Linux runtimes: `compiler-l/src/codegen/win64_rt_platform.l`, `native_rt_platform.l`). `writeBytes` publishes via temporary file and replace (`compiler-l/src/main_driver.l:467`).
- Design doc present: `docs/native-file-streams-design.md`.
- NOT present on `main`: opaque file-stream handle type, block read/write, seek/tell/size, flush, rename/replace API, EOF-vs-error distinction as language API.
- On `main`: design only. `codex/native-file-streams-20261121` (PR #140) contributed the contract and the Linux permission-preservation fix for `writeBytes`.
- Branch `feat/p0b-file-streams-20261121` (from `f166cad`, independent of the ELEPad branch) implements the first stream slice in Stage 1 and both native backends:
  - A linear, opaque `File` type (`SemTypeKind.File`), with `fileOpen`, `fileRead`, `fileWrite`, `fileSeek`, `fileSize`, `fileFlush`, `fileClose` and `fileStatus`.
  - Portable negative error codes; EOF (0) is distinct from errors.
  - Rejected at compile time: leaks (status 4 in `flowVerify` → L0005), double close and use after close (use-after-move), Int handles (sema type check plus the LIR verifier), and Files inside aggregates (L0016).
  - Linux: raw syscalls with EINTR handling. Windows: KERNEL32 only, plus two new imports, `SetFilePointerEx` and `GetFileSizeEx`.
  - The runtime is emitted only when a program uses files.
  - The contract is in `std/README.md` and `docs/native-file-streams-design.md`.
- Evidence (local, 2026-11-21):
  - `crates/l/tests/file_streams_l.rs`: 4/4. It covers PE32+ run on Windows, ELF64 run under WSL Ubuntu, 11 negative programs, and no new imports for programs that don't use files.
  - The 1 MiB file was verified byte by byte from outside, and a mutated expectation fails with its code.
  - `strace` on the ELF64 run: 11 opens and 11 closes, with `O_CLOEXEC|O_NONBLOCK` (and `O_EXCL` for create-new).
  - Full Windows suite: 775 passed, 3 failed. All three were then resolved or explained:
    - The legacy-syntax ratchet failed on my own legacy tokens; I rewrote them in v2 and it now passes.
    - `stage1_import_exports_l` hit Windows error 32 while clippy ran concurrently; 3/3 when rerun alone.
    - `native_image_structure_l::stage1_example_images_are_structurally_valid` reports `writeBytes` syscalls (stat/fsync/rename/getrandom). It fails identically on clean `main` `f166cad` with `ELE_TEST_WSL_DISTRO=Ubuntu`, so it predates this branch. The validator's syscall whitelist was not updated for the PR #140 `writeBytes`. It is invisible on Windows hosts that don't execute ELF64. Fixed separately on `fix/elf-syscall-whitelist-20261121` (`fccb3e0`, from `f166cad`): `ALLOWED_SYSCALLS` gains getrandom, stat, lstat, fchmod, fsync, rename and unlink. With `ELE_TEST_WSL_DISTRO=Ubuntu`: `native_image_structure_l` 4/4, `native_adversarial_lir_l` 9/9.
  - Commit: `8134728` on `feat/p0b-file-streams-20261121`, pushed; no PR opened (no `gh`).
  - Clippy `-D warnings` and `cargo fmt --check`: clean.
- Status: **IMPLEMENTADO, PENDIENTE DE VALIDACIÓN** (CI not run).
- Not yet done: existence/metadata queries, rename/replace through streams, directory iteration, permissions/attributes on stream-created files, concurrent-writer tests, and Stage 0 support for the builtins.

### 2.2 ELEPad terminal (P0 editor)
- Present on `main`: `apps/elepad/src/{buffer,cursor,editor_core,editor_test,main,search,terminal,terminal_dispatch,terminal_dispatch_test,terminal_render}.l`.
- On `main` (`f166cad`), key handling binds only Ctrl+S (save) and Ctrl+Q (quit).
- Branch `feat/elepad-terminal-history-20261121` adds, in the shared `editor_core.l`: an operation-log undo/redo with grouping and a saved-state marker, keyboard selection (Shift+movement, Ctrl+A, Escape), an in-process clipboard (Ctrl+C/X/V), and a find prompt (Ctrl+F, Enter, Escape). `buffer.l` gains `deleteRange` and `insertBytes`; `search.l` gains `findBytes` and moves from `import` to `take`. The renderer highlights the selection (SGR 7/27) and shows the find prompt in the status line. `terminal.l` uses `editorMarkSaved`, so undoing back to the saved text clears the unsaved marker.
- Evidence on that branch (local, 2026-11-21, driver built from `f166cad` sources):
  - `terminal_dispatch_test.l` (PE, native): passes; it has 30 new assertions. A mutation check (one inverted expectation) fails with the expected code 23.
  - `editor_test.l` (PE, native): passes.
  - `tests/elepad/terminal.ps1`: 4/4 PASS, including the 2 new redirected-input cases (undo/redo/cut/find/replace, undo-to-clean).
  - Same 4 cases on the ELF64 build under WSL Ubuntu: 4/4 PASS. `tests/elepad/terminal.sh` now contains the 2 new cases; the script itself was not run end to end, because it needs a Linux driver binary.
  - `tests/elepad/terminal_console.ps1` (real Windows console, mode restoration): PASS.
  - `cargo test --test ele_syntax_v2 --test ele_v2_legacy_ratchet --test examples_ele_v2`: 16/16 pass.
  - Test-script fix: `terminal.ps1` and `terminal_console.ps1` compared against a literal `é`, which Windows PowerShell 5.1 decodes as ANSI. They now use `[char]0xE9`; the assertions are unchanged.
  - CI: NOT run (no PR opened from this environment).
- Status: **IMPLEMENTADO, PENDIENTE DE VALIDACIÓN** (CI) for undo/redo, selection, clipboard and find.
- **BLOQUEADO**: Ctrl+O, because ELE has no primitive to build a `Text` path from runtime bytes (checked `docs/ELE_SYNTAX_V2.md` and the platform builtins).
- **NO INICIADO**: system clipboard, mouse selection, horizontal scroll, grapheme/East-Asian width, automatic VT enable on Windows, multiple documents.

### 2.3 Native FFI / callbacks / windows (P0-C, P0-D)
- `codex/ele-win32-abi-20261121` and `codex/ele-win32-window-probe-20261121` exist; merge state not verified.
- Status on `main`: **NO VERIFIADO** in this pass. Do not claim window support.

### 2.4 Self-hosting and coverage
- Historical matrix: `docs/SELF_COVERAGE_MATRIX_2026-11-11.md` (104 modules, 83 to LIR, 21 to backend). Historical, not re-measured.
- Status: **NO VERIFICADO** for the current `main`. Re-measure before quoting.

### 2.5 Standard library
- `std/io` exists; no `std.fs`, `std.path`, `std.text`, `std.collections`, `std.time`, `std.process`, `std.platform`, `std.net`, `std.sync` were checked in this pass.
- Status: **NO VERIFICADO**.

## 3. Items explicitly not done in this pass

- No compiler, runtime, or ELEPad code was changed. Work was limited to a verified audit.
- No CI result was confirmed (GitHub CLI absent; no authenticated API access used).
- No issues were opened, closed, or edited (requires verification of each issue's comments and criteria).
- No merges to `main` were made (requires explicit user authorization).
- ENCA and NEXO were not touched (paused by instruction).

## 4. Recommended next increments (dependency-ordered)

1. Reconcile the local checkout: resolve or abort the unfinished merge in the user's working copy (user decision; do not force).
2. Open Draft PRs for `feat/elepad-terminal-history-20261121`, `feat/p0b-file-streams-20261121` and `fix/elf-syscall-whitelist-20261121`, and let CI validate them (no `gh` here). The whitelist fix is independent and the smallest; merge it first.
3. When P0-B programs join the ELF structure tests, also allow `lseek` (fileSeek). `fsync` is already listed.
4. P0-B next: existence/metadata queries, rename/replace, then a `Text`-from-bytes primitive. That primitive also unblocks ELEPad Ctrl+O.
5. P0-C: audit `compiler-l/src/codegen/win64_callback.l` and build the four-argument callback test.
6. Re-run the self-coverage matrix on current `main` before any percentage is quoted.

## 5. Verification log

- `git fetch origin` completed; `origin/main` = `f166cad`.
- `git grep` on `origin/main` for undo/redo/clipboard/open/save: only save present in ELEPad.
- `terminal_dispatch.l` lines 10-13 read directly.
