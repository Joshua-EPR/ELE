take x86_64
take pe64
take native_rt

// Minimal Windows x64 runtime of the ELE-written backend: process exit and
// stdout output through KERNEL32 (GetStdHandle, WriteFile, ExitProcess),
// called through the IAT built by pe64. Machine code only; no CRT, no
// Rust, no linker.
//
// Windows x64 calling convention at every API call emitted here: arguments
// in RCX, RDX, R8, R9 then the stack from [RSP+32]; 32 bytes of shadow space
// reserved by the caller; RSP 16-byte aligned at the CALL. RAX, RCX, RDX and
// R8-R11 are volatile. The routines realign RSP themselves (AND RSP,-16)
// instead of trusting their caller, because the ELE-internal convention of
// the CFG lowering does not promise Windows stack alignment.
//
// Only output of Int and Bool is provided. Owned Text (allocation, growth,
// release) and lists are not ported yet: their runtime uses Linux mmap,
// and the CFG lowering rejects them for this target.

// Indexes into the address list returned by w64EmitRuntime; they match the
// first three entries of native_rt's rtEmitAll.
expose flow w64RuntimeCount() => Int { give 3 }

// CALL [RIP+disp32] to the IAT slot of import `slot`.
expose flow w64CallImport(code: edit X64Code, imports: edit Pe64Imports, slot: Int) {
    hold at = x64CallRipPlaceholder(edit code)
    imports.at@push(at)
    imports.index@push(slot)
}

// RSP = (RSP & -16) - `reserve`; `reserve` must be a multiple of 16 and
// include the 32 bytes of shadow space. Clobbers R10.
flow w64AlignStack(code: edit X64Code, reserve: Int) {
    x64MovImm64(edit code, 10, -16)
    x64AndReg(edit code, 4, 10)
    x64MovImm64(edit code, 10, reserve)
    x64SubReg(edit code, 4, 10)
}

// ExitProcess(RCX) from any stack state; never returns.
expose flow w64EmitExitRcx(code: edit X64Code, imports: edit Pe64Imports) {
    w64AlignStack(edit code, 32)
    w64CallImport(edit code, edit imports, pe64ImportExitProcess())
    x64Unreachable(edit code)
}

// ExitProcess(status) from any stack state; never returns.
expose flow w64EmitExit(code: edit X64Code, imports: edit Pe64Imports, status: Int) {
    x64MovImm64(edit code, 1, status)
    w64EmitExitRcx(edit code, edit imports)
}

// Process entry: the loader calls it with RSP = 8 (mod 16). Reserves the
// shadow space, calls the code at `main_at` (patched by the caller through
// the returned CALL rel32 position) and exits with the low 32 bits of RAX.
// The callee is entered with RSP = 8 (mod 16), as after any aligned CALL.
expose flow w64EmitEntry(code: edit X64Code, imports: edit Pe64Imports) => Int {
    x64MovImm64(edit code, 10, 40)
    x64SubReg(edit code, 4, 10)
    hold call_at = x64CallPlaceholder(edit code)
    x64MovReg(edit code, 1, 0)
    w64EmitExitRcx(edit code, edit imports)
    give call_at
}

// write_all(RSI = bytes, RDX = count): GetStdHandle(STD_OUTPUT_HANDLE) and
// WriteFile until every byte is out, at most 1 GiB per call (the count is a
// DWORD). A failed or empty write stops silently, as on Linux: `print` has
// no error channel. Frame slots: 0 next byte, 1 remaining, 2 handle,
// 3 bytes written (a DWORD, zero-extended through the whole slot).
flow w64EmitWriteAll(code: edit X64Code, imports: edit Pe64Imports) {
    x64FrameBegin(edit code, 4)
    x64StoreSlot(edit code, 0, 6)
    x64StoreSlot(edit code, 1, 2)
    // 32 shadow bytes + the fifth argument, rounded to 16.
    w64AlignStack(edit code, 48)
    x64MovImm64(edit code, 1, -11)
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64StoreSlot(edit code, 2, 0)
    hold top = code.bytes.length
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold finished = x64ConditionalPlaceholder(edit code, true)
    // R8 = min(remaining, 1 GiB).
    x64MovReg(edit code, 8, 0)
    x64MovImm64(edit code, 1, 1073741824)
    x64CmpReg(edit code, 1, 8)
    hold small = x64AboveEqualPlaceholder(edit code)
    x64MovReg(edit code, 8, 1)
    hold patch_small = code.bytes.length
    x64PatchRelative(edit code, small, patch_small)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 3, 0)
    x64StoreMem64(edit code, 4, 32, 0)          // lpOverlapped = NULL
    x64LoadSlot(edit code, 1, 2)                // hFile
    x64LoadSlot(edit code, 2, 0)                // lpBuffer
    x64LeaMem(edit code, 9, 5, -32)             // lpNumberOfBytesWritten
    w64CallImport(edit code, edit imports, pe64ImportWriteFile())
    x64TestEax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 9, 3)
    x64MovReg(edit code, 0, 9)
    x64TestRax(edit code)
    hold stalled = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 6, 0)
    x64AddReg(edit code, 6, 9)
    x64StoreSlot(edit code, 0, 6)
    x64LoadSlot(edit code, 2, 1)
    x64SubReg(edit code, 2, 9)
    x64StoreSlot(edit code, 1, 2)
    hold again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, again, top)
    hold done = code.bytes.length
    x64PatchRelative(edit code, finished, done)
    x64PatchRelative(edit code, failed, done)
    x64PatchRelative(edit code, stalled, done)
    x64FrameEnd(edit code)
}

// Emits write_all, print_int and print_bool. print_int and print_bool are
// the target-independent formatters of native_rt; only write_all differs.
expose flow w64EmitRuntime(code: edit X64Code, imports: edit Pe64Imports) => List of[Int] {
    change at: List of[Int] = List[]
    hold write_all = code.bytes.length
    at@push(write_all)
    w64EmitWriteAll(edit code, edit imports)
    at@push(code.bytes.length)
    rtEmitPrintInt(edit code, write_all)
    at@push(code.bytes.length)
    rtEmitPrintBool(edit code, write_all)
    give at
}
