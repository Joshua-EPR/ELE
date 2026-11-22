# Native Win32 window probe (P0-D, first verified step)

Status (2026-11-21, branch `feat/p0d-window-20261121`, stacked on
`feat/p0c-callbacks-20261121`): **IMPLEMENTADO, PENDIENTE DE VALIDACIÓN**
(CI). This is a backend-level probe, not a window library: ELE programs
cannot open windows yet.

## What runs

The autonomous driver compiles `compiler-l/src/native_win_window_probe.l`,
an ELE program that emits a second PE32+ image. That image:

1. loads `user32.dll` and `gdi32.dll` from system32 (LoadLibraryExW with
   `LOAD_LIBRARY_SEARCH_SYSTEM32`) and keeps them loaded until exit. Its
   import table stays KERNEL32-only;
2. registers a window class whose `lpfnWndProc` is the ELE four-word
   callback adapter (`w64EmitCallback4`). `hInstance` is the image base,
   computed as `.text` minus one section alignment;
3. creates a 320×200 `WS_OVERLAPPEDWINDOW` window (WM_CREATE), shows it
   without activation, and calls `UpdateWindow`. This sends WM_PAINT, which
   does BeginPaint, `FillRect` with a solid brush, `TextOutW("ELE")`,
   `GetPixel` inside the rectangle, DeleteObject and EndPaint. The WndProc
   compares the pixel with the brush colour;
4. posts WM_KEYDOWN `'A'`, WM_LBUTTONDOWN at (30, 40) and WM_CLOSE. The
   `GetMessageW`/`TranslateMessage`/`DispatchMessageW` loop delivers them.
   WM_CLOSE calls DestroyWindow, and WM_DESTROY calls `PostQuitMessage(0)`;
5. leaves the loop on WM_QUIT and exits with its wParam.

Every other message goes to `DefWindowProcW`. The image has no writable
data section, so the WndProc resolves each user32/gdi32 function per call
with a temporary LoadLibraryExW/GetProcAddress/FreeLibrary. The entry's own
references keep the addresses valid.

Test: `tests/native_backend/win64_window.ps1 -Ele <driver.exe>` (also a CI
step). The expected output is `wm-create`, `wm-paint-pixel-ok`,
`wm-keydown-a`, `wm-lbuttondown-30-40`, `wm-close`, `wm-destroy` and
`message-loop-done`, with exit 0. A mutation that paints another colour
prints `wm-paint-pixel-bad`. Failure exits: 2 DLL, 3 RegisterClassExW,
4 CreateWindowExW, 5 missing export, 9 GetMessageW error.

## Limits (not claimed)

- Input is posted by the program itself; real user input and focus are not
  exercised. Resize, move, mouse wheel and window states are not handled.
- `GetPixel` needs a visible window region. A CI desktop that hides the
  window would report `wm-paint-pixel-bad`; that would be an environment
  limitation to investigate, not a reason to weaken the check.
- No ELE source-level API: no window type, no event type, no ownership of
  HWND/GDI resources in the type system. The probe deletes its brush and
  ends painting on every path, but nothing enforces that for user code.
- Linux (X11/Wayland): not started.
