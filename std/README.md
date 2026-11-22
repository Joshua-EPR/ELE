# ELE standard library (`std/`)

Reusable ELE v2 modules for applications. Everything here is written in ELE
and compiled by the autonomous driver; the only native code involved is the
platform runtime that the compiler itself emits (KERNEL32 on Windows, Linux
system calls).

## Binary console output

The autonomous compiler provides `writeConsoleBytes(bytes)` for a borrowed
`List of[Int]`. It writes exactly those bytes to standard output, without a
trailing newline, and returns 0 on success, -1 for an OS write failure, or -2
for an invalid byte or a buffer above 16 MiB. Values must be in 0..255. The
operation does not depend on libc or a language runtime. It is suitable for
UTF-8 and terminal control sequences, but Windows terminals must have Virtual
Terminal Processing enabled to interpret ANSI sequences.

The native positive/negative test is `python tests/std/console_output.py
<driver> <pe|elf>`.

## File streams (`File`)

The autonomous compiler (Stage 1) provides an opaque, linear `File` and
block I/O on Windows x64 (KERNEL32 only) and Linux x86-64 (raw system
calls). No libc, CRT or Rust is involved at run time.

| Operation | Result |
|---|---|
| `fileOpen(path: Text, mode: Int) => File` | Always a `File`; check it with `fileStatus`. Modes: 1 read, 2 write (create or truncate), 3 append (create), 4 create new (fails if it exists), 5 read+write of an existing file. |
| `fileStatus(f) => Int` | 0 when the file is open, otherwise the open error. |
| `fileRead(f, buffer, max) => Int` | Stores up to `max` bytes into `buffer[0..]` and returns the count; **0 is end of file**. `buffer` must be a mutable `List of[Int]` with at least `max` elements; `max` is 1..16 MiB. |
| `fileWrite(f, bytes, count) => Int` | Writes `bytes[0..count]` completely (partial writes and interruptions are retried) and returns `count`. Every value must be 0..255; nothing is written otherwise. |
| `fileSeek(f, offset, whence) => Int` | New position; whence 0 start, 1 current, 2 end. |
| `fileSize(f) => Int` / `fileFlush(f) => Int` | Size in bytes / 0 after the data reached the device (`fsync`, `FlushFileBuffers`). |
| `fileClose(f) => Int` | Consumes the `File`. 0, or an error. Closing a failed open is 0. |

Errors are negative and identical on both systems: -1 invalid argument
(mode, count, limit, whence, path, byte value, negative position), -2 not
found, -3 permission denied or sharing violation, -4 already exists, -5 other
I/O failure (also: not a regular file, or a write the system refused), -6
the `File` is not open (its open failed).

Safety rules enforced by the compiler:

- A `File` comes only from `fileOpen`. An `Int` is never a `File`, and the
  LIR verifier checks every handle operand's type.
- `fileClose` moves the `File`: a second close or any later use is a
  use-after-move error (L0005).
- A `File` that may still be open when its scope ends is an error (L0005),
  on every path: return, `leave`, a branch that forgets to close, or a
  discarded `fileOpen(...)` result. Close it or move it to an owner.
- A `File` cannot be stored in a `List`, `Option`, `Result`, array, shape
  field or choice payload (L0016), because their drops would not close it.
- `fileRead` borrows its buffer exclusively; the file itself is borrowed
  shared, so `f: view File` parameters work.

Opening uses `O_CLOEXEC` and `O_NONBLOCK` on Linux (a FIFO never blocks the
open) and rejects anything but a regular file; on Windows anything but a
disk file is rejected. Write modes share read access only on Windows. The
runtime is linked only into programs that use these operations.

Tests: `cargo test -p project-l --test file_streams_l` builds
`tests/std/file_streams.l` for PE32+ and ELF64, runs it (ELF64 natively on
Linux, or with `ELE_TEST_WSL_DISTRO=<distro>` on Windows), verifies a 1 MiB
round trip from outside, and checks that each program in
`tests/std/file_streams_invalid/` is rejected with its diagnostic.

Not yet provided: existence and metadata queries, rename/replace through a
`File`, directory iteration, and safe publication through streams (use
`writeBytes` for atomic whole-file replacement).

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
