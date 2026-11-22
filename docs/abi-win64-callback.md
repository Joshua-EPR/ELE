# Win64 callback trampoline: verified narrow capability

The autonomous ELE driver compiles `compiler-l/src/native_win_callback_probe.l` to PE64. That ELE program emits a second PE64 image. The second image loads `KERNEL32.dll` with `LOAD_LIBRARY_SEARCH_SYSTEM32`, resolves `EnumSystemLocalesW`, passes a callback entry, and receives a real Windows callback. The callback enters an ELE-internal function that prints `callback-ok` and returns `FALSE` to stop enumeration. Run `tests/native_backend/win64_callback.ps1 -Ele <autonomous-driver.exe>` on Windows.

For this probe, `EnumSystemLocalesW` invokes a one-argument `LOCALE_ENUMPROCW`: a borrowed pointer to a UTF-16 locale identifier reaches RCX. The internal callback does not dereference or retain it and returns before enumeration ends. The adapter moves that pointer-sized word to the ELE stack argument position; it does not convert the pointed-to string to ELE `Text`.

`compiler-l/src/codegen/win64_callback.l` emits entries for one or four pointer-sized integer arguments with a one-word return in RAX. It copies Win64 register arguments to the ELE internal stack convention, saves/restores Win64 nonvolatile RDI and RSI, and preserves RBP through the normal frame prologue. It rejects targets outside already emitted code. The one-argument entry has been executed through `EnumSystemLocalesW`.

## Four-argument entry (verified 2026-11-21, branch `feat/p0c-callbacks-20261121`)

The probe now drives `w64EmitCallback4` three ways. Each four-word target checks all four arguments and prints its marker only when they are exact:

1. **Direct Win64 call** from the probe's entry: arguments in RCX, RDX, R8 and R9, 32-byte shadow space, RSP 16-byte aligned before the call, and sentinels in RDI, RSI and RBX. The target deliberately clobbers RDI and RSI. The caller then checks the sentinels and the returned word. This is the only check that isolates the adapter: a system function between caller and callback restores its own nonvolatile registers and would hide a broken adapter.
2. **`EnumResourceNamesW`** (kernel32) on kernel32 itself, with `RT_VERSION`. Windows calls `(hModule, 16, 1, hModule + 0x0123456789ABCDEF)`.
3. **`CallWindowProcW`** (user32), loaded with `LOAD_LIBRARY_SEARCH_SYSTEM32`. Windows dispatches a WndProc-shaped call `(NULL, WM_APP+1, -2, 0x0123456789ABCDEF)`, and the callback's LRESULT `0x123456789ABCDEF0` must come back as the return value of `CallWindowProcW`. Only the low 32 bits of `msg` are compared, because Win64 leaves the upper half of a `UINT` undefined. The fifth argument (lParam) travels on the stack at `[RSP+32]`.

Expected output: `callback4-wndproc-ok`, `callback-ok`, `callback4-enum-ok` and `callback4-wndproc-ok`, with exit status 0. Exit 7 means a sentinel register was lost; exit 8 means a wrong return word.

Mutations checked locally:
- With the adapter's RSI restore removed, the probe exits 7; with its RDI restore removed, it also exits 7.
- With the enum target expecting resource name 2, `callback4-enum-ok` is missing and the script fails.

Register audit: the native backend's generated code does not write RBX, R12–R15 or any XMM register (2026-11-21, `codegen/*.l`). So saving RDI and RSI is enough for an ELE-compiled target today. If the backend ever allocates those registers, the adapter must save them too.

Still not covered:
- A registered window class. `RegisterClassExW` and a message loop belong to P0-D.
- Stack-passed callback arguments (a fifth parameter received by the callback).
- Floating-point or structure arguments.
- Reentrancy while the target is still running.
- Source-level callbacks: ELE code cannot yet name an ELE flow as a callback.

Local Windows validation on this branch: the autonomous driver compiled the generator to PE64, the generated PE printed `callback-ok` through the real Kernel32 callback, and `--self-check` printed `callback-negative-ok` for invalid targets. A Gen 2 rebuild and Gen 3 rebuild of `main_driver.l` had identical SHA-256 `61701086663C5C4942BDAE5B22B34F80AA9E39E79E668F3E12C5F35F1DA6A9A9`; Gen 3 also compiled and executed this callback probe. CI and Linux validation are pending. This paragraph is the original one-argument record; the four-argument entry is covered by the section above. General FFI is still not proven.

This is a backend building block. ELE source cannot yet declare an external function, pass a function value as a callback, capture an environment, or manage callback lifetime. There is no public FFI API and no window library. A callback must remain valid for the duration of its OS registration; the current probe uses static code and synchronous enumeration. Errors cannot cross the ABI boundary. Only word-sized integer/pointer arguments and returns are in scope; floating point, structures, and stack-passed arguments require separate ABI work and explicit rejection before public exposure.

The current negative test rejects callback targets outside the emitted code buffer. It cannot test invalid source-level callback signatures because source-level FFI declarations do not exist yet; those compile-time rejections must be added with that feature.

Microsoft documents [the Win64 register and stack convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention) and [EnumSystemLocalesW's callback contract](https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-enumsystemlocalesw). This module follows the repository's existing `win64_rt.l` call alignment and shadow-space wrappers when the internal target calls Win32.
