# ELE standard library (`std/`)

Reusable ELE v2 modules for applications. Everything here is written in ELE
and compiled by the autonomous driver; the only native code involved is the
platform runtime that the compiler itself emits (KERNEL32 on Windows, Linux
system calls).

## `std/io/console.l`: interactive console input

Status: implemented and tested on Windows x86-64 (real console) and Linux
x86-64 (real pseudo-terminal under WSL).

```ele
take console

flow main() => Int {
    change reader = consoleOpen()          // raw input, original state saved
    during true {
        hold ev = consoleNext(edit reader) // blocks; no polling
        when ev.kind == EVENT_END || ev.kind == EVENT_ERROR { leave }
        when ev.kind == EVENT_KEY && ev.key == KEY_ESCAPE { leave }
        when isCtrl(view ev, 115) { print("Ctrl+S") }
        when ev.key == KEY_CHAR { print("U+{ev.character}") }
    }
    give consoleClose(edit reader)         // restores the console state
}
```

`ConsoleEvent` fields: `kind` (`EVENT_KEY`, `EVENT_RESIZE`, `EVENT_MOUSE`,
`EVENT_END`, `EVENT_ERROR`), `key` (`KEY_CHAR`, `KEY_ENTER`, `KEY_BACKSPACE`,
`KEY_DELETE`, arrows, `KEY_HOME`/`KEY_END`, `KEY_PAGE_UP`/`KEY_PAGE_DOWN`,
`KEY_TAB`, `KEY_ESCAPE`, `KEY_INSERT`, `KEY_F1`..`KEY_F1 + 11`), `character`
(Unicode scalar), `modifiers` (`MOD_SHIFT`, `MOD_CTRL`, `MOD_ALT`), `pressed`,
`repeat`, `x`/`y` (resize size or mouse cell), `buttons`, `wheel`.

### Compiler platform operations underneath

| Operation | Windows | Linux |
|---|---|---|
| `consoleInputMode(request: Int) => Int` | `GetStdHandle`, `GetConsoleMode`, `SetConsoleMode` | `ioctl(0, TCGETS/TCSETS)` |
| `readConsoleEvent() => Int` | `ReadConsoleInputW` (console) or `ReadFile` (redirected) | `read(0, 1 byte)` |

`request`: `-1` query, `-2` raw input, `>= 0` restore a state returned
earlier. Results `< 0` are errors: `-1` not a console, `-2` mode rejected,
`-3` invalid request. `readConsoleEvent` packs one event into an `Int`
(documented in `compiler-l/src/codegen/win64_rt_platform.l`); `-2` means end
of input. The routines and their KERNEL32 imports are emitted only in images
that call these operations.

### Known limitations

- Byte input (Linux, or redirected input on Windows) cannot distinguish a
  lone Escape from the start of an escape sequence without a timed read:
  Escape is reported when the next byte arrives (Escape twice is immediate).
- Characters are Unicode scalar values, not grapheme clusters; dead keys and
  IME composition are delivered as the Windows console reports them.
- A program outside `std/io/` can now import `std.io.console` with
  `ele build <source.l> --lib <root-containing-std>`. The root is the
  directory **containing** `std/`, not `std/` itself.
- Imports still resolve locally first. `--lib` is an explicit, optional fallback
  used **only** when the local module is absent. Permission, invalid UTF-8 and
  oversized local-module errors are not masked by falling back to the library.
- The older `loadProgram(entry_path)` contract remains available to internal
  tools; no implicit global library path or environment lookup is introduced.

### Compile from another directory

From the ELE repository root with the autonomous compiler:

```powershell
.\ele.exe build .\apps\elepad\probes\console_import.l --lib . --target pe --output .\target\elepad-std-test.exe
.\target\elepad-std-test.exe
```

On Linux replace `--target pe` with `--target elf` and choose an ELF output path.

The probe imports `take std.io.console` while living in
`apps/elepad/probes/`; no source files are copied into the app.
The CLI also accepts an absolute library root. Running without `--lib`
continues to use the previous relative-only resolution behavior.

### Tests

```powershell
.\tests\std\console_input.ps1 -Ele <path to ele.exe or main_driver.exe>
```

The Linux half (`tests/std/console_input.sh`) runs ELF64 builds over a pipe
and inside `script(1)`, comparing `stty -g` before and after.
