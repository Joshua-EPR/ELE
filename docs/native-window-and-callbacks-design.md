# Native windows and source-level callbacks: design (P0-C / P0-D)

Status: **design proposal, not implemented**. Nothing in this document is
supported ELE syntax or API until a branch implements it with tests. It
builds on verified pieces:

- the linear `File` of P0-B (`docs/native-file-streams-design.md`);
- the four-word Win64 callback adapter, executed for real in
  `feat/p0c-callbacks-20261121` (`docs/abi-win64-callback.md`);
- the hand-built window probe of `feat/p0d-window-20261121`
  (`docs/win32-window-probe.md`);
- the console's packed-event design (`std/io/console.l`, `readevent`).

## 1. Decisions

1. **Windows first, with no user callbacks.** ELE programs receive window
   events by asking for them, as they already do for console input
   (`consoleNext`). The runtime owns the WndProc. This handles the GUI needs
   of ELEPad without making ELE code reentrant from the OS, and without a
   function-value feature.
2. **A window is a linear resource**, like `File`: created only by
   `windowOpen`, released only by `windowClose`, never copied, stored or
   forged, and never dropped implicitly.
3. **General callbacks come second**, as `system flow`: a declaration
   modifier for flows with a fixed foreign signature, not a function value.
   They can be passed only to `foreign` declarations, which live only in
   `std/platform/`.
4. **No new unchecked path for user code.** Raw addresses never become
   `Int` values. The only foreign entry points are curated library
   declarations.

ELE has no closures, function values or mutable globals (`fixed` is
constant), and this design adds none. That is what makes the callback rules
below simple.

## 2. Part A: `Window` (P0-D)

### 2.1 API (proposed, `std/ui/window.l` plus compiler builtins)

```
take std.ui.window

flow main() => Int {
    hold title = "ELEPad"
    hold w = windowOpen(title, 960, 640)
    when windowStatus(w) != 0 {
        windowClose(w)
        give 1
    }
    change running = true
    during running {
        hold ev = windowNext(w)
        when ev.kind == WINDOW_CLOSE { running = false }
        otherwise when ev.kind == WINDOW_RESIZE {
            windowFill(w, 0, 0, ev.width, ev.height, 0x1E1E1E)
            windowPresent(w)
        } otherwise when ev.kind == WINDOW_KEY && ev.pressed {
            // editor_core handles the key, then redraws dirty rows
        }
    }
    give windowClose(w)
}
```

| Builtin | Result |
|---|---|
| `windowOpen(title: Text, width: Int, height: Int) => Window` | Always a `Window`; `windowStatus` is 0 or a negative error. |
| `windowStatus(w) => Int` | 0 when open. |
| `windowNext(w) => Int` (packed; `std.ui.window` decodes it as `WindowEvent`) | Blocks until an event exists. |
| `windowFill(w, x, y, width, height, rgb) => Int` | Draws into the back buffer. |
| `windowText(w, x, y, text: Text, rgb) => Int` | UTF-8 → UTF-16 text in a monospace font. |
| `windowCell(w) => Int` | Packed cell size of the font (width, height), for editors. |
| `windowPresent(w) => Int` | Invalidates the window. The next WM_PAINT copies the back buffer. |
| `windowSetTitle(w, title: Text) => Int` | |
| `windowClose(w) => Int` | Consumes the `Window`: destroys it, frees the back buffer and GDI objects. |

Every operation except `windowClose` borrows the `Window` shared. The window
changes only through the runtime, never through ELE-visible fields.
Coordinates and sizes are bounded (for example 1..16384) and checked in the
runtime. Error codes follow P0-B: -1 invalid argument, -5 system failure,
-6 not open, plus -7 for no graphical session.

`WindowEvent` (an ELE shape decoded from the packed Int, as with
`ConsoleEvent`):

- `kind`: one of `WINDOW_KEY`, `WINDOW_CHAR`, `WINDOW_MOUSE`,
  `WINDOW_WHEEL`, `WINDOW_RESIZE`, `WINDOW_FOCUS`, `WINDOW_CLOSE`,
  `WINDOW_ERROR`;
- `key` (the same key codes as `std.io.console`), `character` (a Unicode
  scalar; surrogate pairs are joined by the library);
- `modifiers`, `pressed`, `x`, `y`, `buttons`, `wheel`, `width`, `height`,
  `focused`.

`WINDOW_CLOSE` is a *request*: the program decides. ELEPad can ask to save
unsaved changes. The runtime never destroys a window on WM_CLOSE; only
`windowClose` does.

### 2.2 Runtime architecture (Windows)

- **State block.** `windowOpen` allocates a fixed-size block on the runtime
  heap (VirtualAlloc, as lists already do). It holds the HWND, the
  user32/gdi32 function table resolved once, a back-buffer DIB section and
  its memory DC, the font, a bounded event ring (256 packed events) and a
  dropped-events counter. The `Window` value below sema is the address of
  this block. ELE can never read it as an Int (see 2.3).
- **Class and WndProc.** There is one runtime WndProc, emitted with
  `w64EmitCallback4` around a runtime target, and the class is registered
  once per process. The block address travels in `CreateWindowExW`'s
  `lpParam`. The WndProc stores it with `SetWindowLongPtrW(GWLP_USERDATA)`
  on WM_NCCREATE and reads it back for every later message. Messages before
  WM_NCCREATE go to `DefWindowProcW`. This removes the probe's per-call
  `LoadLibraryExW`/`GetProcAddress`.
- **WndProc only enqueues.** It translates WM_KEYDOWN/UP, WM_CHAR,
  WM_MOUSEMOVE, WM_xBUTTONDOWN/UP, WM_MOUSEWHEEL, WM_SIZE (which also
  resizes the back buffer), WM_SETFOCUS/KILLFOCUS and WM_CLOSE into packed
  events in the ring. WM_PAINT does BeginPaint, BitBlt from the back buffer,
  EndPaint. Everything else goes to DefWindowProcW. No ELE code runs inside
  the WndProc, so DispatchMessageW reentrancy cannot reach ELE state.
- **`windowNext`.** It pops the ring when the ring is not empty. Otherwise
  it runs `GetMessageW`/`TranslateMessage`/`DispatchMessageW` until the
  WndProc enqueues something; GetMessageW returning -1 gives
  `WINDOW_ERROR`. When the ring is full, the oldest mouse-move event is
  merged. Key, char and close events are never dropped; if they cannot fit,
  the counter is set and a `WINDOW_ERROR` event reports it.
- **Drawing.** `windowFill` and `windowText` draw into the memory DC
  (FillRect, ExtTextOutW with a temporary UTF-16 copy). `windowPresent`
  calls `InvalidateRect`. Drawing never needs a paint-time DC, so ELE never
  holds a GDI handle.
- **Release.** `windowClose` does DestroyWindow, then frees the memory DC,
  bitmap, font and the block. A pending WM_DESTROY after that finds no user
  data and does nothing. Every failure path in `windowOpen` releases what it
  created (the P0-B rule).
- **Imports.** user32/gdi32 stay out of the PE import table: they are loaded
  from system32 at open, as the probe does. The runtime is emitted only for
  programs that use windows (`cfgUsesWindows`, like `cfgUsesFiles`).

### 2.3 Compiler rules

- `SemTypeKind.Window`, created on first use. It reuses the P0-B
  linearity: `FlowGraph.linear_type` becomes a list of linear type ids, and
  `flowDropsLinear` checks membership, so a `Window` and a `File` follow
  exactly the same leak, double-close and use-after-close rules (L0005).
- `semaRejectFileElem` generalizes to every linear type: a `Window` cannot
  live in a List, Option, Result, array, shape or choice (L0016).
- LIR platform codes 17..25 (open, status, next, fill, text, cell, present,
  settitle, close). `lirVerifyFilePlatform` generalizes to
  `lirVerifyResourcePlatform`, with a per-op table of (kind, by_ref,
  mutable, type), so no Int reaches a Window operand.
- Below sema a `Window` serializes as `i`, like `File`.

### 2.4 Linux

The same API, with an X11 backend that speaks the **X11 wire protocol
directly over the `AF_UNIX` socket** (`/tmp/.X11-unix/X<n>` from
`DISPLAY`, MIT-MAGIC-COOKIE from `XAUTHORITY`). It needs no libX11 and no
libc, which matches the raw-syscall runtime. Requests needed: CreateWindow,
MapWindow, ChangeProperty (title, WM_DELETE_WINDOW), CreateGC, PutImage of
the back buffer, and the event reader. Text needs a bundled bitmap font
rendered into the back buffer, because core-font rendering differs per
server. Wayland, which needs shared memory plus xdg-shell, comes after X11.
Linux is not claimed until an ELF64 test opens a window under Xvfb in CI.

### 2.5 Tests (each needs to fail before the feature exists)

- `tests/std/window_events.l` (PE32+, Windows CI). It opens a window, uses
  a test-only hook to post key, char, mouse, resize and close messages, and
  checks the decoded events in order and the `WINDOW_CLOSE` handling. It
  then draws and reads back pixels through a test-only `windowPixel`
  builtin that is compiled only in test images, or through the probe's
  GetPixel route.
- `tests/std/window_invalid/`: leak, double close, use after close, Int as
  Window, Window in a List or shape, and `windowNext` on a closed window.
  Each must be rejected with its code.
- Resource audit: open/close 100 windows in a loop, then compare the process
  GDI and USER object counts (`GetGuiResources`) before and after.
- The existing probes stay, as low-level evidence for the adapter.

### 2.6 ELEPad (M3)

The graphical frontend reuses `apps/elepad/src/editor_core.l` unchanged.
A new `gui_render.l` maps buffer rows to `windowText` at `windowCell`
metrics, with dirty-row redraws as in `terminal_render.l`. A new
`gui_dispatch.l` maps `WindowEvent` to the same editor operations as
`terminal_dispatch.l`. The two dispatchers should share a key-to-command
table, so terminal and GUI cannot diverge.

## 3. Part B: source-level callbacks (P0-C)

Needed for Win32 APIs that call back synchronously (EnumWindows, timers,
sorting) and for future platform libraries. Not needed by Part A.

### 3.1 Syntax (proposed)

```
// Only in modules under std/platform/.
foreign flow enumWindows(callback: Entry, context: Int) => Int
    from "user32.dll" as "EnumWindows"

system flow countWindow(hwnd: Int, context: Int) => Int {
    give 1   // continue enumeration
}

hold n = enumWindows(entryOf(countWindow), 0)
```

- `system flow` declares a flow callable by the operating system. Its
  parameters and result must be `Int` (machine words), with at most four
  parameters in the first version. It cannot take `view` or `edit` (no
  borrows cross the boundary), and it cannot be `later` (async). It is an
  ordinary flow for type checking and ownership; the backend also emits a
  Win64 adapter entry for it (`w64EmitCallback1`/`4`, extended to N).
- `entryOf(name)` is valid only with the name of a `system flow`, and only
  directly as an argument of a `foreign` call. It produces the opaque type
  `Entry`. `Entry` has no operations, no conversions and no storage (the
  linear-aggregate rule applies), so an address can never become an Int or
  outlive the call expression.
- `foreign flow` declares a function exported by a system DLL. The
  `from`/`as` names are string literals. Parameters may be `Int`, `Entry`,
  or `view Text` (passed as a temporary NUL-terminated UTF-16 copy, released
  after the call). There are no `edit` parameters and no lists in the first
  version, so foreign code can never write ELE memory. Calls resolve the
  DLL from system32 once per call site, with LoadLibraryExW and a static
  cache, which needs a writable data section in PE images (also wanted by
  Part A).

### 3.2 Why this is memory-safe

- A `system flow` cannot capture anything: ELE has no closures and no
  mutable globals. Its code is static, so its address is valid for the
  whole process. Lifetime and use-after-free of callbacks cannot happen.
- Reentrancy (the OS calling the flow again while it runs, or from another
  thread) can only reach the flow's own locals and its Int arguments. No
  shared mutable ELE state exists to corrupt. When ELE gains mutable shared
  state (P14 concurrency), `system flow` must be restricted to the
  `Send`-like subset defined there.
- Errors cannot unwind across the boundary, because ELE has no unwinding: a
  runtime trap terminates the process, as it does today.
- The adapter preserves RDI and RSI, which is enough because the generated
  code does not use RBX, R12–R15 or XMM6–15 (audit of 2026-11-21). The
  backend register allocator (P12) must keep that list in sync with the
  adapter, enforced by a test that greps the emitted encodings.
- The unchecked surface is the set of `foreign` declarations. Restricting
  them to `std/platform/` makes every one reviewable. Each needs a comment
  with its ABI and contract, and a test.

### 3.3 Compiler changes

- Parser: the `system` and `foreign` flow modifiers, and the
  `from "dll" as "name"` clause.
- Sema: signature checks (L0004), the `std/platform/` rule for `foreign`
  (L0016), the `entryOf` rules, and `SemTypeKind.Entry` (linear,
  non-storable, consumed by the call).
- LIR: `i foreigncall` with a module-level table of (dll, symbol, arity);
  `i entry vD <function>`; and `system` marked in the function header, so
  the backend emits the adapter.
- Backend: the Win64 call with shadow space and stack arguments beyond
  four; adapter emission per `system flow`; the per-call-site resolution
  cache. Linux has no foreign DLLs: `foreign` declarations are
  Windows-only, behind a per-target `std/platform/windows/` module, and a
  Linux build that uses them is rejected with a clear diagnostic.

### 3.4 Tests

- Positive (`std/platform/windows`):
  - EnumWindows counts more than zero top-level windows;
  - EnumResourceNamesW checks four arguments, mirroring the P0-C probe;
  - a fifth stack argument for a `foreign` call (CreateWindowExW).
- Negative:
  - `entryOf` on an ordinary flow;
  - `entryOf` stored in `hold`;
  - `Entry` in a List;
  - a `system flow` with `view` or `edit` parameters, or with five
    parameters;
  - a `foreign` declaration outside `std/platform/`;
  - `edit List` in a `foreign` declaration.

## 4. Order of work

1. Generalize linearity (`linear_type` → set) and the resource verifier.
   Refactor only: the P0-B tests must stay green.
2. Part A Windows runtime, builtins, `std.ui.window`, and the tests in 2.5.
3. ELEPad graphical frontend on Part A.
4. A writable data section in PE images (also used by the Part A runtime,
   if it chooses a process-wide class atom cache).
5. Part B `system flow` / `foreign flow` / `Entry`.
6. Linux X11 backend for Part A.

## 5. Open questions

- Should `windowNext` gain a timeout (needed for caret blinking and timers),
  or should a separate `WINDOW_TICK` event come from `SetTimer` inside the
  runtime? The proposal is `windowNext(w, timeout_ms)` with a
  `WINDOW_TIMEOUT` kind.
- Clipboard (`OpenClipboard`/`GetClipboardData`) for ELEPad: as window
  builtins (`windowClipboardRead/Write` with `Text`) rather than through
  `foreign`, so that copying and pasting never exposes raw memory.
- High-DPI: declare per-monitor awareness at open
  (`SetProcessDpiAwarenessContext`) and report DPI in the resize event, or
  defer it.
