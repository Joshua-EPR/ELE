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
- Branch `feat/linear-resources-20261121` (`b7ea833`, **stacked on P0-B**) is step 1 of `docs/native-window-and-callbacks-design.md`: the File-specific linearity becomes general. It is a refactor with no behavior change.
  - Sema now has `semTypeIsLinear`, `semTypeLinearIds` and `semTypeCloser`.
  - Flow analysis tracks a list (`FlowGraph.linear_types`), and `FlowCheck.linear` names the leaked type.
  - Aggregate rule: `semaRejectLinearElem`.
  - LIR verifier: a table-driven `lirVerifyResourcePlatform`.
  - Evidence: File diagnostics are byte-identical; `file_streams_l` 4/4; ratchet and syntax green.
  - Full suite: 776 passed, 2 failed. One is the known ELF whitelist failure. The other, `stage1_import_exports_l`, hit Windows error 32 under parallel threads **even without clippy running**, so it is an intermittent contention inside the suite itself; 3/3 alone.
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
- On `main`: `compiler-l/src/codegen/win64_callback.l` has 1-word and 4-word adapters (Win64 register args → ELE stack args, RDI/RSI saved). Only the 1-word one was ever executed (`EnumSystemLocalesW`, PR #137). The `codex/ele-win32-*` branches are 0 commits ahead of `main`.
- Branch `feat/p0c-callbacks-20261121` (`1d18b5a`, from `f166cad`) executes the 4-word adapter three ways. Each target checks all four arguments:
  - a direct Win64 call with RDI/RSI/RBX sentinels;
  - `EnumResourceNamesW`;
  - `CallWindowProcW`: a WndProc-shaped dispatch, whose LRESULT comes back to the caller and whose lParam travels on the stack.
- Evidence (local): `tests/native_backend/win64_callback.ps1` passes. With the adapter's RSI or RDI restore removed, the probe exits 7; with a wrong expected argument, its marker disappears. A system caller hides lost nonvolatile registers, so only the direct call can catch them. That is why the direct check exists.
- Register audit: generated code doesn't use RBX, R12–R15 or XMM, so saving RDI/RSI is enough today.
- Status: 4-word callback ABI **IMPLEMENTADO, PENDIENTE DE VALIDACIÓN** (CI).
- Branch `feat/p0d-window-20261121` (`c9181f7`, **stacked on the P0-C branch**) adds a real Win32 window probe, `compiler-l/src/native_win_window_probe.l`:
  - it registers a class whose WndProc is the 4-word adapter, then creates, shows and paints the window (FillRect + TextOutW);
  - `GetPixel` reads the painted colour back;
  - posted keyboard and mouse messages arrive through GetMessageW/DispatchMessageW;
  - WM_CLOSE → DestroyWindow → PostQuitMessage, and the probe exits 0;
  - user32/gdi32 are loaded at run time, and the import table stays KERNEL32-only.
  - Evidence: `tests/native_backend/win64_window.ps1` passes locally, and a wrong-colour mutation is detected. A Windows CI step was added; CI hasn't run.
  - Details and limits: `docs/win32-window-probe.md`.
- Branch `feat/p0d-window-api-20261121` (`df2d811`, stacked on `feat/linear-resources-20261121`) implements step 2 of the design: the **linear `Window` language API**.
  - Builtins: `windowOpen/Status/Next/Fill/Text/Present/Send/Pixel/Close`.
  - Library: `std/ui/window.l`, with `WindowEvent` and the console's key codes.
  - Runtime: `compiler-l/src/codegen/win64_window.l`.
    - A per-window state block holds a DIB back buffer, a font, a resolved user32/gdi32 table and a 256-event ring.
    - The WndProc runs through the 4-word adapter and only enqueues events or BitBlts the back buffer.
    - WM_CLOSE is a request event, not a destroy.
  - Linux reports -7 (no graphical session).
  - Evidence (local):
    - `crates/l/tests/window_l.rs` 3/3:
      - a real window with pixel read-back and synthetic key/char/surrogate/mouse/wheel/close input through the real message loop;
      - the Linux -7 report under WSL;
      - six rejected programs.
    - `win64_window_resources.ps1`: 200 cycles end at 12 GDI objects; a DeleteObject-skipping mutant reaches 212 and fails.
    - Runtime mutations (fill tail, WM_CHAR kind) are caught with their exit codes.
  - Full suite: 778 passed, 3 failed.
    - The new module needed a self-coverage baseline line, now regenerated (`codegen/win64_window.l lir`).
    - The other two are the known ELF whitelist failure and the intermittent error 32.
  - Status: **IMPLEMENTADO, PENDIENTE DE VALIDACIÓN** (CI).
- **NO INICIADO**:
  - source-level FFI: extern declarations and ELE flows as callbacks;
  - callbacks with stack-passed parameters, floats or structs;
  - reentrancy;
  - real user input, resize and focus;
  - Linux X11/Wayland.

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
2. Open Draft PRs and let CI validate them (no `gh` here). Merge order:
   1. `fix/elf-syscall-whitelist-20261121` (independent, smallest);
   2. `feat/elepad-terminal-history-20261121` (independent);
   3. `feat/p0b-file-streams-20261121`, then `feat/linear-resources-20261121`, then `feat/p0d-window-api-20261121`, then `feat/elepad-gui-20261121`, then `feat/text-from-bytes-open-20261121` (stacked in that order; the GUI branch also merges the ELEPad history branch);
   4. `feat/p0c-callbacks-20261121`, then `feat/p0d-window-20261121` (probes and design doc; stacked).
3. When P0-B programs join the ELF structure tests, also allow `lseek` (fileSeek). `fsync` is already listed.
4. P0-B next: existence/metadata queries, rename/replace, then a `Text`-from-bytes primitive. That primitive also unblocks ELEPad Ctrl+O.
5. Design step 3 (graphical ELEPad) is done on `feat/elepad-gui-20261121` (`817b1a8`; it contains the ELEPad history branch and the Window API, plus fix `04e36a4`):
   - `apps/elepad/src/gui.l`, `gui_render.l` and `gui_dispatch.l`.
   - The shared key table `editor_commands.l` and the shared `document_io.l`.
   - Builtins `windowCell` (code 26) and `windowTextBytes` (code 27).
   - Evidence: `gui_test.l` and `tests/elepad/gui.ps1` pass, terminal tests are unchanged and green, a screenshot of the real window was inspected, and the full suite has only the 2 known failures.
   - A real bug was found and fixed: misaligned UTF-16 class name → `RegisterClassExW` ERROR_NOACCESS in larger images (commit `04e36a4`, also on the Window API branch).
   - Next for the window editor: several documents, system clipboard, mouse drag selection, dirty-region redraw.
6. `feat/text-from-bytes-open-20261121` (`bf419a3`, plus a CI commit; stacked on the window ELEPad branch) is done:
   - The language gets `textFromBytes(bytes, count) => Result<Text, Int>`: platform code 28, a strict UTF-8 check, shared by PE and ELF, emitted only when used.
   - ELEPad gets **Ctrl+O** in both frontends, via the shared prompt and `document_io.openDocument`; it refuses to open with unsaved changes.
   - Evidence:
     - `text_from_bytes_l` 3/3: PE, ELF via WSL, and bad arguments rejected.
     - Unit checks of the prompt and of `openDocument` against real files.
     - `terminal.ps1` 6/6, the Ctrl+O half of `terminal.sh` under WSL, `gui.ps1` 4/4.
     - Full suite: 782 passed, plus the 2 known failures.
   - Test-harness bug fixed: under PowerShell 5.1, `terminal.ps1` fed a UTF-8 BOM into ELEPad's stdin, and `File.ReadAllText` hid it. Its content checks are now byte-exact. This bug was latent in earlier `terminal.ps1` results; CI's pwsh 7 was never affected.
7. Design steps 4–6: a PE writable data section, `system flow`/`foreign flow`, and the X11 backend.
8. Re-run the self-coverage matrix on current `main` before any percentage is quoted.

## 5. Verification log

- `git fetch origin` completed; `origin/main` = `f166cad`.
- `git grep` on `origin/main` for undo/redo/clipboard/open/save: only save present in ELEPad.
- `terminal_dispatch.l` lines 10-13 read directly.
