take x86_64
take pe64
take win64_rt
take native_rt_platform
take win64_window
take win64_clipboard

// Platform runtime of the ELE-written Windows x64 (PE32+) backend: the five
// `i platform` operations of ELE-LIR 1 (processArgCount, processArg,
// readText, printError, writeBytes) on KERNEL32 only. No CRT, no SHELL32,
// no Rust, no linker. The observable contract is the one native_rt_platform
// implements with Linux system calls, and Stage 0 with Rust std:
//   argcount           -> Int: arguments after the program name.
//   arg(i)             -> Result<Text,Int>: Err(1) out of range, Err(2) not
//                         well-formed UTF-16 (a lone surrogate), so not
//                         convertible to UTF-8.
//   readtext(path, n)  -> Result<Text,Int>: Err(1) bad limit (outside
//                         0..=64 MiB) or path, Err(2) not found, Err(3) other
//                         I/O failure or not a regular file, Err(4) not
//                         UTF-8, Err(5) larger than the limit.
//   printerror(text)   -> the text and a line feed on the standard error
//                         handle; errors ignored.
//   writebytes(path, l)-> Int: 0 ok, 1 bad path/byte/length (validated before
//                         the file is created), 2 cannot create, 3 write
//                         failed.
// Path validation (pfEmitPathZ) and strict UTF-8 validation (pfEmitUtf8)
// are the target-independent routines of native_rt_platform.
//
// Arguments: GetCommandLineW, split here with the rules of the Microsoft C
// runtime since 2008, which Rust std (and so Stage 0) also follows:
// - the program name ends at the first space or tab outside quotes; a quote
//   only toggles quoting there, backslashes are literal;
// - then arguments are separated by runs of spaces and tabs outside quotes;
// - 2n backslashes before a quote give n backslashes and the quote toggles
//   quoting; 2n+1 backslashes before a quote give n backslashes and a
//   literal quote; backslashes elsewhere are literal;
// - inside quotes, two quotes in a row give one literal quote.
// The command line is parsed again on every call (it is process-constant),
// so the runtime keeps no state and the image needs no data section. Each
// argument is decoded into UTF-16 and converted with WideCharToMultiByte
// (CP_UTF8, WC_ERR_INVALID_CHARS), which fails exactly on ill-formed UTF-16.
//
// Files: the UTF-8 path is converted with MultiByteToWideChar (CP_UTF8,
// MB_ERR_INVALID_CHARS) and opened with CreateFileW, sharing read, write and
// delete as Rust std does. Not found means ERROR_FILE_NOT_FOUND,
// ERROR_PATH_NOT_FOUND, ERROR_INVALID_DRIVE, ERROR_BAD_NETPATH or
// ERROR_BAD_NET_NAME (Rust's ErrorKind::NotFound). A directory cannot be
// opened without FILE_FLAG_BACKUP_SEMANTICS (Err(3)); anything that is not
// FILE_TYPE_DISK (a console, pipe or device such as NUL) is Err(3). Every
// handle from CreateFileW is closed and every temporary buffer released on
// every path; the handles of GetStdHandle are never closed.
//
// Internal convention, as in native_rt and win64_heap: arguments in RDI,
// RSI, RDX; results in RAX (RDX); RAX, RCX, RDX, RSI, RDI and R8-R11 are
// scratch, live values stay in frame slots. Every routine that calls
// KERNEL32 aligns RSP once after its frame (w64AlignStack) and reserves the
// 32-byte shadow space plus room for up to four stack arguments at
// [RSP+32]..[RSP+56]; RSP does not move again until the frame ends, so the
// alignment holds at every CALL. RBX, RSI, RDI, RBP and R12-R15 are
// preserved by Windows; RBX and R12-R15 are never touched here.

fixed WPF_CP_UTF8 = 65001
fixed WPF_WC_ERR_INVALID_CHARS = 128
fixed WPF_MB_ERR_INVALID_CHARS = 8
fixed WPF_GENERIC_READ = 2147483648
fixed WPF_GENERIC_WRITE = 1073741824
fixed WPF_SHARE_ALL = 7
fixed WPF_CREATE_ALWAYS = 2
fixed WPF_OPEN_EXISTING = 3
fixed WPF_ATTRIBUTE_NORMAL = 128
fixed WPF_FILE_TYPE_DISK = 1
fixed WPF_MAX_BYTES = 67108864
fixed WPF_DWORD_MASK = 4294967295
fixed WPF_CHUNK = 1073741824
// Shadow space plus four stack arguments, a multiple of 16.
fixed WPF_RESERVE = 64

flow wpfCall(code: edit X64Code, target: Int) {
    hold at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

flow wpfJumpTo(code: edit X64Code, target: Int) {
    hold at = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

flow wpfAdjust(code: edit X64Code, reg: Int, delta: Int) {
    x64MovImm64(edit code, 10, delta)
    x64AddReg(edit code, reg, 10)
}

// Jumps (placeholder returned) when `left` <cond> `right` holds, with the
// signed conditions of x64SetCondition (4 eq, 5 ne, 6 lt, 7 le, 8 gt, 9 ge).
// Clobbers RAX.
flow wpfIfReg(code: edit X64Code, left: Int, right: Int, cond: Int) => Int {
    x64CmpReg(edit code, left, right)
    x64SetCondition(edit code, cond)
    x64TestRax(edit code)
    give x64ConditionalPlaceholder(edit code, false)
}

// The same against a constant, held in R10. Clobbers RAX and R10.
flow wpfIf(code: edit X64Code, left: Int, value: Int, cond: Int) => Int {
    x64MovImm64(edit code, 10, value)
    give wpfIfReg(edit code, left, 10, cond)
}

flow wpfPatchAll(code: edit X64Code, at: view List of[Int]) {
    hold here = code.bytes.length
    each i among 0..at.length { x64PatchRelative(edit code, at[i], here) }
}

flow wpfPatchHere(code: edit X64Code, at: Int) {
    hold here = code.bytes.length
    x64PatchRelative(edit code, at, here)
}

// RAX = RAX & 0xFFFFFFFF: a DWORD or int result, zero-extended. Clobbers R10.
flow wpfDword(code: edit X64Code) {
    x64MovImm64(edit code, 10, WPF_DWORD_MASK)
    x64AndReg(edit code, 0, 10)
}

// Stack argument `n` (0 is the fifth argument) of the next API call.
flow wpfStackArg(code: edit X64Code, n: Int, reg: Int) {
    x64StoreMem64(edit code, 4, 32 + 8 * n, reg)
}

// Frame of a routine that calls KERNEL32: `slots` frame slots, then RSP
// aligned with the shadow space and four stack argument words below it.
flow wpfBegin(code: edit X64Code, slots: Int) {
    x64FrameBegin(edit code, slots)
    w64AlignStack(edit code, WPF_RESERVE)
}

// Writes Ok(text) from frame slots `address`, `length`, `capacity` into the
// Result<Text,Int> whose address is in frame slot `result`.
flow wpfStoreOk(code: edit X64Code, result: Int, address: Int, length: Int, capacity: Int) {
    x64LoadSlot(edit code, 11, result)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem64(edit code, 11, 0, 0)
    x64LoadSlot(edit code, 0, address)
    x64StoreMem64(edit code, 11, 8, 0)
    x64LoadSlot(edit code, 0, length)
    x64StoreMem64(edit code, 11, 16, 0)
    x64LoadSlot(edit code, 0, capacity)
    x64StoreMem64(edit code, 11, 24, 0)
}

// Writes Err(status) into the Result<Text,Int> of frame slot `result`.
flow wpfStoreErrSlot(code: edit X64Code, result: Int, status: Int) {
    x64MovImm64(edit code, 1, status)
    x64LoadSlot(edit code, 11, result)
    pfStoreErr(edit code)
}

// text_drop of the buffer in frame slots `address` and `capacity`.
flow wpfDrop(code: edit X64Code, rt: view PfRuntime, address: Int, capacity: Int) {
    x64LoadSlot(edit code, 7, address)
    x64LoadSlot(edit code, 6, capacity)
    wpfCall(edit code, rt.text_drop)
}

// write_handle(RDI = handle, RSI = bytes, RDX = count) -> RAX = 0, or -1
// when WriteFile fails or writes nothing. At most 1 GiB per call (the count
// is a DWORD). Slots: 0 handle, 1 next byte, 2 remaining, 3 bytes written (a
// DWORD, zero-extended through the whole slot).
flow wpfEmitWriteHandle(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 4)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    hold top = code.bytes.length
    x64LoadSlot(edit code, 0, 2)
    x64TestRax(edit code)
    hold finished = x64ConditionalPlaceholder(edit code, true)
    // R8 = min(remaining, 1 GiB).
    x64MovReg(edit code, 8, 0)
    x64MovImm64(edit code, 1, WPF_CHUNK)
    x64CmpReg(edit code, 1, 8)
    hold small = x64AboveEqualPlaceholder(edit code)
    x64MovReg(edit code, 8, 1)
    wpfPatchHere(edit code, small)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 3, 0)
    wpfStackArg(edit code, 0, 0)                // lpOverlapped = NULL
    x64LoadSlot(edit code, 1, 0)                // hFile
    x64LoadSlot(edit code, 2, 1)                // lpBuffer
    x64LeaMem(edit code, 9, 5, -32)             // lpNumberOfBytesWritten
    w64CallImport(edit code, edit imports, pe64ImportWriteFile())
    x64TestEax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 9, 3)
    x64MovReg(edit code, 0, 9)
    x64TestRax(edit code)
    hold stalled = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 6, 1)
    x64AddReg(edit code, 6, 9)
    x64StoreSlot(edit code, 1, 6)
    x64LoadSlot(edit code, 2, 2)
    x64SubReg(edit code, 2, 9)
    x64StoreSlot(edit code, 2, 2)
    wpfJumpTo(edit code, top)
    wpfPatchHere(edit code, finished)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, failed)
    wpfPatchHere(edit code, stalled)
    x64MovImm64(edit code, 0, -1)
    x64FrameEnd(edit code)
    give entry
}

// wide_z(RDI = NUL-terminated UTF-8) -> RAX = owned UTF-16 copy, NUL
// included, RDX = its capacity; RAX = 0 when it is not valid UTF-8.
// Slots: 0 source, 1 units (NUL included), 2 buffer, 3 capacity.
flow wpfEmitWideZ(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 4)
    x64StoreSlot(edit code, 0, 7)
    change failed: List of[Int] = List[]
    // Units needed: MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
    // source, -1, NULL, 0).
    x64MovImm64(edit code, 1, WPF_CP_UTF8)
    x64MovImm64(edit code, 2, WPF_MB_ERR_INVALID_CHARS)
    x64LoadSlot(edit code, 8, 0)
    x64MovImm64(edit code, 9, -1)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 0, 0)
    wpfStackArg(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportMultiByteToWideChar())
    wpfDword(edit code)
    x64StoreSlot(edit code, 1, 0)
    x64TestRax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))
    x64MovReg(edit code, 7, 0)
    x64AddReg(edit code, 7, 0)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovImm64(edit code, 1, WPF_CP_UTF8)
    x64MovImm64(edit code, 2, WPF_MB_ERR_INVALID_CHARS)
    x64LoadSlot(edit code, 8, 0)
    x64MovImm64(edit code, 9, -1)
    x64LoadSlot(edit code, 0, 2)
    wpfStackArg(edit code, 0, 0)
    x64LoadSlot(edit code, 0, 1)
    wpfStackArg(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportMultiByteToWideChar())
    wpfDword(edit code)
    x64MovReg(edit code, 9, 0)
    x64LoadSlot(edit code, 1, 1)
    hold converted = wpfIfReg(edit code, 9, 1, 4)
    wpfDrop(edit code, rt, 2, 3)
    failed@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, converted)
    x64LoadSlot(edit code, 0, 2)
    x64LoadSlot(edit code, 2, 3)
    x64FrameEnd(edit code)
    wpfPatchAll(edit code, view failed)
    x64MovImm64(edit code, 0, 0)
    x64MovImm64(edit code, 2, 0)
    x64FrameEnd(edit code)
    give entry
}

// RCX = the UTF-16 code unit at [R8 + offset]. Clobbers RDX and R10.
flow wpfUnit(code: edit X64Code, offset: Int) {
    x64LoadMem8(edit code, 1, 8, offset)
    x64LoadMem8(edit code, 2, 8, offset + 1)
    x64MovImm64(edit code, 10, 256)
    x64MulReg(edit code, 2, 10)
    x64AddReg(edit code, 1, 2)
}

// In the scanner: appends one UTF-16 unit at RDI when the current argument
// is the requested one (slot 5) and counts it (slot 3). The unit is the one
// at [R8] when `value` is negative, else `value`. Clobbers RAX and R10.
flow wpfEmitUnit(code: edit X64Code, value: Int) {
    x64LoadSlot(edit code, 0, 5)
    x64TestRax(edit code)
    hold skip = x64ConditionalPlaceholder(edit code, true)
    when value < 0 {
        x64LoadMem8(edit code, 0, 8, 0)
        x64StoreMem8(edit code, 7, 0, 0)
        x64LoadMem8(edit code, 0, 8, 1)
        x64StoreMem8(edit code, 7, 1, 0)
    } otherwise {
        x64MovImm64(edit code, 0, value)
        x64StoreMem8(edit code, 7, 0, 0)
        x64MovImm64(edit code, 0, 0)
        x64StoreMem8(edit code, 7, 1, 0)
    }
    wpfAdjust(edit code, 7, 2)
    x64LoadSlot(edit code, 0, 3)
    wpfAdjust(edit code, 0, 1)
    x64StoreSlot(edit code, 3, 0)
    wpfPatchHere(edit code, skip)
}

// Advances R8 past spaces and tabs. Clobbers RAX, RCX, RDX and R10.
flow wpfSkipBlanks(code: edit X64Code) {
    hold top = code.bytes.length
    wpfUnit(edit code, 0)
    hold is_space = wpfIf(edit code, 1, 32, 4)
    hold is_tab = wpfIf(edit code, 1, 9, 4)
    hold done = x64JumpPlaceholder(edit code)
    wpfPatchHere(edit code, is_space)
    wpfPatchHere(edit code, is_tab)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, top)
    wpfPatchHere(edit code, done)
}

// scan(RDI = requested argument k, counted from 0 after the program name,
// or negative for none; RSI = UTF-16 output buffer, or 0) -> RAX = number of
// arguments after the program name, RDX = units of argument k written to
// RSI (0 when there is no such argument). The output never needs more
// units than the command line has. R8 walks the command line, RDI the
// output. Slots: 0 k, 1 output, 2 arguments so far, 3 units written,
// 4 inside quotes, 5 writing the current argument, 6 backslash run.
flow wpfEmitScan(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 7)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 0)
    w64CallImport(edit code, edit imports, pe64ImportGetCommandLineW())
    x64MovReg(edit code, 8, 0)
    x64LoadSlot(edit code, 7, 1)

    // Program name: a quote toggles quoting, an unquoted blank ends it.
    hold name = code.bytes.length
    wpfUnit(edit code, 0)
    hold name_nul = wpfIf(edit code, 1, 0, 4)
    hold name_quote = wpfIf(edit code, 1, 34, 4)
    x64LoadSlot(edit code, 0, 4)
    x64TestRax(edit code)
    hold name_quoted = x64ConditionalPlaceholder(edit code, false)
    hold name_space = wpfIf(edit code, 1, 32, 4)
    hold name_tab = wpfIf(edit code, 1, 9, 4)
    wpfPatchHere(edit code, name_quoted)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, name)
    wpfPatchHere(edit code, name_quote)
    x64MovImm64(edit code, 0, 1)
    x64LoadSlot(edit code, 1, 4)
    x64SubReg(edit code, 0, 1)
    x64StoreSlot(edit code, 4, 0)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, name)
    wpfPatchHere(edit code, name_nul)
    wpfPatchHere(edit code, name_space)
    wpfPatchHere(edit code, name_tab)
    wpfSkipBlanks(edit code)

    // Arguments. R8 is at a non-blank unit or at the terminating NUL.
    change done: List of[Int] = List[]
    change arg_end: List of[Int] = List[]
    hold arg_top = code.bytes.length
    wpfUnit(edit code, 0)
    done@push(wpfIf(edit code, 1, 0, 4))
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 0)
    // Writing = output given and this is argument k.
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold no_output = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 1, 2)
    x64LoadSlot(edit code, 2, 0)
    x64CmpReg(edit code, 1, 2)
    x64SetCondition(edit code, 4)
    x64StoreSlot(edit code, 5, 0)
    wpfPatchHere(edit code, no_output)

    hold next_unit = code.bytes.length
    wpfUnit(edit code, 0)
    arg_end@push(wpfIf(edit code, 1, 0, 4))
    hold backslash = wpfIf(edit code, 1, 92, 4)
    hold quote = wpfIf(edit code, 1, 34, 4)
    x64LoadSlot(edit code, 0, 4)
    x64TestRax(edit code)
    hold quoted = x64ConditionalPlaceholder(edit code, false)
    arg_end@push(wpfIf(edit code, 1, 32, 4))
    arg_end@push(wpfIf(edit code, 1, 9, 4))
    // Any other unit (or a blank inside quotes) is taken literally.
    wpfPatchHere(edit code, quoted)
    wpfEmitUnit(edit code, -1)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, next_unit)

    // A run of n backslashes.
    wpfPatchHere(edit code, backslash)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 6, 0)
    hold run = code.bytes.length
    wpfUnit(edit code, 0)
    hold run_end = wpfIf(edit code, 1, 92, 5)
    x64LoadSlot(edit code, 0, 6)
    wpfAdjust(edit code, 0, 1)
    x64StoreSlot(edit code, 6, 0)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, run)
    wpfPatchHere(edit code, run_end)
    hold before_quote = wpfIf(edit code, 1, 34, 4)
    // Not before a quote: n literal backslashes.
    hold literal = code.bytes.length
    x64LoadSlot(edit code, 0, 6)
    x64TestRax(edit code)
    hold literal_done = x64ConditionalPlaceholder(edit code, true)
    wpfEmitUnit(edit code, 92)
    x64LoadSlot(edit code, 0, 6)
    wpfAdjust(edit code, 0, -1)
    x64StoreSlot(edit code, 6, 0)
    wpfJumpTo(edit code, literal)
    hold literal_done_at = code.bytes.length
    x64PatchRelative(edit code, literal_done, literal_done_at)
    wpfJumpTo(edit code, next_unit)
    // Before a quote: one backslash per pair, then an odd one escapes it.
    wpfPatchHere(edit code, before_quote)
    hold pair = code.bytes.length
    x64LoadSlot(edit code, 1, 6)
    hold pairs_done = wpfIf(edit code, 1, 2, 6)
    wpfEmitUnit(edit code, 92)
    x64LoadSlot(edit code, 0, 6)
    wpfAdjust(edit code, 0, -2)
    x64StoreSlot(edit code, 6, 0)
    wpfJumpTo(edit code, pair)
    wpfPatchHere(edit code, pairs_done)
    x64LoadSlot(edit code, 0, 6)
    x64TestRax(edit code)
    hold even = x64ConditionalPlaceholder(edit code, true)
    x64PatchRelative(edit code, even, next_unit)
    wpfEmitUnit(edit code, 34)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, next_unit)

    // A quote not escaped by backslashes.
    wpfPatchHere(edit code, quote)
    x64LoadSlot(edit code, 0, 4)
    x64TestRax(edit code)
    hold opening = x64ConditionalPlaceholder(edit code, true)
    // Inside quotes: `""` is one literal quote, quoting goes on.
    wpfUnit(edit code, 2)
    hold closing = wpfIf(edit code, 1, 34, 5)
    wpfEmitUnit(edit code, 34)
    wpfAdjust(edit code, 8, 4)
    wpfJumpTo(edit code, next_unit)
    wpfPatchHere(edit code, closing)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 4, 0)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, next_unit)
    wpfPatchHere(edit code, opening)
    x64MovImm64(edit code, 0, 1)
    x64StoreSlot(edit code, 4, 0)
    wpfAdjust(edit code, 8, 2)
    wpfJumpTo(edit code, next_unit)

    // End of an argument: count it, skip the blanks after it.
    wpfPatchAll(edit code, view arg_end)
    x64LoadSlot(edit code, 0, 2)
    wpfAdjust(edit code, 0, 1)
    x64StoreSlot(edit code, 2, 0)
    wpfSkipBlanks(edit code)
    wpfJumpTo(edit code, arg_top)

    wpfPatchAll(edit code, view done)
    x64LoadSlot(edit code, 0, 2)
    x64LoadSlot(edit code, 2, 3)
    x64FrameEnd(edit code)
    give entry
}

// argcount() -> RAX = arguments after the program name.
flow wpfEmitArgCount(code: edit X64Code, scan: Int) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    x64MovImm64(edit code, 7, -1)
    x64MovImm64(edit code, 6, 0)
    wpfCall(edit code, scan)
    x64FrameEnd(edit code)
    give entry
}

// arg(RDI = index, RSI = address of the Result<Text,Int>): argument
// index + 1 as a new owned Text. Slots: 0 result, 1 index, 2 UTF-16 buffer,
// 3 its capacity, 4 its units, 5 text, 6 text capacity, 7 byte length.
flow wpfEmitArg(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, scan: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 8)
    x64StoreSlot(edit code, 0, 6)
    x64StoreSlot(edit code, 1, 7)
    x64MovReg(edit code, 1, 7)
    hold negative = wpfIf(edit code, 1, 0, 6)
    // A buffer of 2 * (command line units + 1) bytes.
    w64CallImport(edit code, edit imports, pe64ImportGetCommandLineW())
    x64MovReg(edit code, 8, 0)
    x64MovImm64(edit code, 9, 0)
    hold measure = code.bytes.length
    wpfUnit(edit code, 0)
    hold measured = wpfIf(edit code, 1, 0, 4)
    wpfAdjust(edit code, 8, 2)
    wpfAdjust(edit code, 9, 1)
    wpfJumpTo(edit code, measure)
    wpfPatchHere(edit code, measured)
    x64MovReg(edit code, 7, 9)
    x64AddReg(edit code, 7, 9)
    wpfAdjust(edit code, 7, 2)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64LoadSlot(edit code, 7, 1)
    x64LoadSlot(edit code, 6, 2)
    wpfCall(edit code, scan)
    x64StoreSlot(edit code, 4, 2)
    x64MovReg(edit code, 9, 0)
    x64LoadSlot(edit code, 1, 1)
    hold missing = wpfIfReg(edit code, 1, 9, 9)
    change not_utf16: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 4)
    hold empty = wpfIf(edit code, 1, 0, 4)
    // Bytes needed: WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
    // units, count, NULL, 0, NULL, NULL); 0 when ill-formed.
    x64MovImm64(edit code, 1, WPF_CP_UTF8)
    x64MovImm64(edit code, 2, WPF_WC_ERR_INVALID_CHARS)
    x64LoadSlot(edit code, 8, 2)
    x64LoadSlot(edit code, 9, 4)
    x64MovImm64(edit code, 0, 0)
    each n among 0..4 { wpfStackArg(edit code, n, 0) }
    w64CallImport(edit code, edit imports, pe64ImportWideCharToMultiByte())
    wpfDword(edit code)
    x64StoreSlot(edit code, 7, 0)
    x64TestRax(edit code)
    not_utf16@push(x64ConditionalPlaceholder(edit code, true))
    x64MovReg(edit code, 7, 0)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 6, 2)
    x64MovImm64(edit code, 1, WPF_CP_UTF8)
    x64MovImm64(edit code, 2, WPF_WC_ERR_INVALID_CHARS)
    x64LoadSlot(edit code, 8, 2)
    x64LoadSlot(edit code, 9, 4)
    x64LoadSlot(edit code, 0, 5)
    wpfStackArg(edit code, 0, 0)
    x64LoadSlot(edit code, 0, 7)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    wpfStackArg(edit code, 3, 0)
    w64CallImport(edit code, edit imports, pe64ImportWideCharToMultiByte())
    wpfDword(edit code)
    x64MovReg(edit code, 9, 0)
    x64LoadSlot(edit code, 1, 7)
    hold converted = wpfIfReg(edit code, 9, 1, 4)
    wpfDrop(edit code, rt, 5, 6)
    not_utf16@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, converted)
    hold finish = code.bytes.length
    wpfDrop(edit code, rt, 2, 3)
    wpfStoreOk(edit code, 0, 5, 7, 6)
    x64FrameEnd(edit code)
    // An empty argument: an empty owned Text, as on Linux.
    wpfPatchHere(edit code, empty)
    x64MovImm64(edit code, 7, 0)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 6, 2)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 7, 0)
    wpfJumpTo(edit code, finish)
    wpfPatchHere(edit code, missing)
    wpfDrop(edit code, rt, 2, 3)
    hold missing_err = x64JumpPlaceholder(edit code)
    wpfPatchHere(edit code, negative)
    wpfPatchHere(edit code, missing_err)
    wpfStoreErrSlot(edit code, 0, 1)
    x64FrameEnd(edit code)
    wpfPatchAll(edit code, view not_utf16)
    wpfDrop(edit code, rt, 2, 3)
    wpfStoreErrSlot(edit code, 0, 2)
    x64FrameEnd(edit code)
    give entry
}

// printerror(RDI = bytes, RSI = count): the text and a line feed on the
// standard error handle. Slots: 0 bytes, 1 count, 2 handle, 3 line feed.
flow wpfEmitPrintError(code: edit X64Code, imports: edit Pe64Imports, write_handle: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 4)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64MovImm64(edit code, 1, -12)              // STD_ERROR_HANDLE
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64StoreSlot(edit code, 2, 0)
    x64LoadSlot(edit code, 7, 2)
    x64LoadSlot(edit code, 6, 0)
    x64LoadSlot(edit code, 2, 1)
    wpfCall(edit code, write_handle)
    x64MovImm64(edit code, 0, 10)
    x64StoreSlot(edit code, 3, 0)
    x64LoadSlot(edit code, 7, 2)
    x64LeaMem(edit code, 6, 5, -32)
    x64MovImm64(edit code, 2, 1)
    wpfCall(edit code, write_handle)
    x64FrameEnd(edit code)
    give entry
}

// Error exits of readtext: each sets the status (slot 8), runs its cleanup
// and stores Err(status). Cleanup bit 1 closes the file (slot 4), bit 2
// releases the buffer (slots 5, 6).
flow wpfReadFail(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, from: view List of[Int], status: Int, cleanup: Int) {
    wpfPatchAll(edit code, from)
    when cleanup == 1 || cleanup == 3 {
        x64LoadSlot(edit code, 1, 4)
        w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    }
    when cleanup >= 2 { wpfDrop(edit code, rt, 5, 6) }
    wpfStoreErrSlot(edit code, 0, status)
    x64FrameEnd(edit code)
}

// readtext(RDI = address of the path Text, RSI = limit, RDX = address of
// the Result<Text,Int>). Slots: 0 result, 1 limit, 2 UTF-8 path, 3 its
// capacity, 4 handle, 5 buffer, 6 capacity, 7 length, 8 error code,
// 9 UTF-16 path, 10 its capacity, 11 bytes read (DWORD), 12 path Text.
flow wpfEmitReadText(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, utf8: Int, path_z: Int, wide_z: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 13)
    x64StoreSlot(edit code, 0, 2)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 12, 7)
    change bad_input: List of[Int] = List[]
    change not_found: List of[Int] = List[]
    change io_error: List of[Int] = List[]
    change io_error_open: List of[Int] = List[]
    change io_error_read: List of[Int] = List[]
    change too_large: List of[Int] = List[]
    change not_utf8: List of[Int] = List[]
    x64MovReg(edit code, 1, 6)
    bad_input@push(wpfIf(edit code, 1, 0, 6))
    bad_input@push(wpfIf(edit code, 1, WPF_MAX_BYTES, 8))
    x64LoadSlot(edit code, 7, 12)
    wpfCall(edit code, path_z)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovReg(edit code, 1, 0)
    bad_input@push(wpfIf(edit code, 1, 0, 4))
    x64LoadSlot(edit code, 7, 2)
    wpfCall(edit code, wide_z)
    x64StoreSlot(edit code, 9, 0)
    x64StoreSlot(edit code, 10, 2)
    wpfDrop(edit code, rt, 2, 3)
    x64LoadSlot(edit code, 1, 9)
    bad_input@push(wpfIf(edit code, 1, 0, 4))
    // CreateFileW(path, GENERIC_READ, share all, NULL, OPEN_EXISTING,
    // FILE_ATTRIBUTE_NORMAL, NULL).
    x64LoadSlot(edit code, 1, 9)
    x64MovImm64(edit code, 2, WPF_GENERIC_READ)
    x64MovImm64(edit code, 8, WPF_SHARE_ALL)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, WPF_OPEN_EXISTING)
    wpfStackArg(edit code, 0, 0)
    x64MovImm64(edit code, 0, WPF_ATTRIBUTE_NORMAL)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    w64CallImport(edit code, edit imports, pe64ImportCreateFileW())
    x64StoreSlot(edit code, 4, 0)
    x64MovReg(edit code, 1, 0)
    hold opened = wpfIf(edit code, 1, -1, 5)
    // Not opened: read the error before anything else can change it.
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wpfDword(edit code)
    x64StoreSlot(edit code, 8, 0)
    wpfDrop(edit code, rt, 9, 10)
    x64LoadSlot(edit code, 1, 8)
    not_found@push(wpfIf(edit code, 1, 2, 4))
    not_found@push(wpfIf(edit code, 1, 3, 4))
    not_found@push(wpfIf(edit code, 1, 15, 4))
    not_found@push(wpfIf(edit code, 1, 53, 4))
    not_found@push(wpfIf(edit code, 1, 67, 4))
    io_error@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, opened)
    wpfDrop(edit code, rt, 9, 10)
    // A regular file: FILE_TYPE_DISK.
    x64LoadSlot(edit code, 1, 4)
    w64CallImport(edit code, edit imports, pe64ImportGetFileType())
    wpfDword(edit code)
    x64MovReg(edit code, 1, 0)
    io_error_open@push(wpfIf(edit code, 1, WPF_FILE_TYPE_DISK, 5))
    // A buffer of limit + 1 bytes: one more than allowed detects excess.
    x64LoadSlot(edit code, 7, 1)
    wpfAdjust(edit code, 7, 1)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 6, 2)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 7, 0)
    // ReadFile(handle, buffer + length, limit + 1 - length, &read, NULL).
    hold read_more = code.bytes.length
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 11, 0)
    wpfStackArg(edit code, 0, 0)
    x64LoadSlot(edit code, 1, 4)
    x64LoadSlot(edit code, 2, 5)
    x64LoadSlot(edit code, 0, 7)
    x64AddReg(edit code, 2, 0)
    x64LoadSlot(edit code, 8, 1)
    wpfAdjust(edit code, 8, 1)
    x64LoadSlot(edit code, 0, 7)
    x64SubReg(edit code, 8, 0)
    x64LeaMem(edit code, 9, 5, -96)
    w64CallImport(edit code, edit imports, pe64ImportReadFile())
    x64TestEax(edit code)
    io_error_read@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 9, 11)
    x64MovReg(edit code, 0, 9)
    x64TestRax(edit code)
    hold eof = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 1, 7)
    x64AddReg(edit code, 1, 9)
    x64StoreSlot(edit code, 7, 1)
    x64LoadSlot(edit code, 9, 1)
    too_large@push(wpfIfReg(edit code, 1, 9, 8))
    wpfJumpTo(edit code, read_more)
    wpfPatchHere(edit code, eof)
    x64LoadSlot(edit code, 1, 4)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    x64LoadSlot(edit code, 7, 5)
    x64LoadSlot(edit code, 6, 7)
    wpfCall(edit code, utf8)
    x64TestRax(edit code)
    not_utf8@push(x64ConditionalPlaceholder(edit code, true))
    wpfStoreOk(edit code, 0, 5, 7, 6)
    x64FrameEnd(edit code)
    wpfReadFail(edit code, edit imports, rt, view bad_input, 1, 0)
    wpfReadFail(edit code, edit imports, rt, view not_found, 2, 0)
    wpfReadFail(edit code, edit imports, rt, view io_error, 3, 0)
    wpfReadFail(edit code, edit imports, rt, view io_error_open, 3, 1)
    wpfReadFail(edit code, edit imports, rt, view io_error_read, 3, 3)
    wpfReadFail(edit code, edit imports, rt, view too_large, 5, 3)
    wpfReadFail(edit code, edit imports, rt, view not_utf8, 4, 2)
    give entry
}

// BCryptGenRandom is resolved from the OS at runtime so the PE image keeps
// its existing single KERNEL32 import descriptor. Fail closed if unavailable.
flow wpfEmitRandom(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold dll_at = code.bytes.length
    hold dll = "bcrypt.dll"
    each i among 0..dll.byteLength {
        code.bytes@push(dll@byteAt(i))
        code.bytes@push(0)
    }
    code.bytes@push(0)
    code.bytes@push(0)
    hold proc_at = code.bytes.length
    hold proc = "BCryptGenRandom"
    each i among 0..proc.byteLength { code.bytes@push(proc@byteAt(i)) }
    code.bytes@push(0)

    hold entry = code.bytes.length
    // 0 output buffer, 1 byte count, 2 library, 3 function, 4 NTSTATUS.
    wpfBegin(edit code, 5)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    hold dll_fixup = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, dll_fixup, dll_at)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 2048) // LOAD_LIBRARY_SEARCH_SYSTEM32
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, 2, 0)
    x64TestRax(edit code)
    hold load_failed = x64ConditionalPlaceholder(edit code, true)

    x64LoadSlot(edit code, 1, 2)
    hold proc_fixup = x64LeaRipPlaceholder(edit code, 2)
    x64PatchRelative(edit code, proc_fixup, proc_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, 3, 0)
    x64TestRax(edit code)
    hold proc_failed = x64ConditionalPlaceholder(edit code, true)

    x64MovImm64(edit code, 1, 0)
    x64LoadSlot(edit code, 2, 0)
    x64LoadSlot(edit code, 8, 1)
    x64MovImm64(edit code, 9, 2) // BCRYPT_USE_SYSTEM_PREFERRED_RNG
    x64LoadSlot(edit code, 11, 3)
    x64CallReg(edit code, 11)
    x64StoreSlot(edit code, 4, 0)
    x64LoadSlot(edit code, 1, 2)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    x64LoadSlot(edit code, 0, 4)
    x64TestRax(edit code)
    hold random_failed = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    wpfPatchHere(edit code, proc_failed)
    x64LoadSlot(edit code, 1, 2)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    wpfPatchHere(edit code, load_failed)
    wpfPatchHere(edit code, random_failed)
    x64MovImm64(edit code, 0, -1)
    x64FrameEnd(edit code)
    give entry
}

flow wpfTempHexDigit(code: edit X64Code, digit: Int, offset: Int) {
    hold letter = wpfIf(edit code, digit, 9, 8)
    x64MovImm64(edit code, 10, 48)
    x64AddReg(edit code, digit, 10)
    hold done = x64JumpPlaceholder(edit code)
    wpfPatchHere(edit code, letter)
    x64MovImm64(edit code, 10, 87)
    x64AddReg(edit code, digit, 10)
    wpfPatchHere(edit code, done)
    x64LoadSlot(edit code, 8, 11)
    x64LoadSlot(edit code, 1, 13)
    x64AddReg(edit code, 1, 1)
    x64AddReg(edit code, 8, 1)
    x64StoreMem8(edit code, 8, offset * 2, digit)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, offset * 2 + 1, 0)
}

// writebytes(RDI = address of the path Text, RSI = address of the
// List of[Int] header) -> RAX = status. Slots: 0 path Text, 1 length,
// 2 UTF-8 path, 3 its capacity, 4 byte buffer, 5 its capacity, 6 handle,
// 7 status, 8 elements, 9 UTF-16 dest path, 10 its capacity, 11 UTF-16 tmp path,
// 12 its capacity, 13 destination path length in UTF-16 units,
// 14-15 random bytes, 16 collision count.
flow wpfEmitWriteBytes(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int, write_handle: Int, random: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 17)
    x64StoreSlot(edit code, 0, 7)
    x64LoadMem64(edit code, 8, 6, 0)
    x64LoadMem64(edit code, 9, 6, 8)
    x64StoreSlot(edit code, 8, 8)
    x64StoreSlot(edit code, 1, 9)
    change invalid: List of[Int] = List[]
    x64MovReg(edit code, 1, 9)
    invalid@push(wpfIf(edit code, 1, WPF_MAX_BYTES, 8))
    // Every element is a byte, checked before anything is created.
    x64MovImm64(edit code, 1, 0)
    hold check = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold checked = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 8)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 0, 0, 0)
    x64MovImm64(edit code, 10, 256)
    x64CmpReg(edit code, 0, 10)
    invalid@push(x64AboveEqualPlaceholder(edit code))
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, check)
    wpfPatchHere(edit code, checked)
    x64LoadSlot(edit code, 7, 0)
    wpfCall(edit code, path_z)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovReg(edit code, 1, 0)
    invalid@push(wpfIf(edit code, 1, 0, 4))
    x64LoadSlot(edit code, 7, 2)
    wpfCall(edit code, wide_z)
    x64StoreSlot(edit code, 9, 0)
    x64StoreSlot(edit code, 10, 2)
    wpfDrop(edit code, rt, 2, 3)
    x64LoadSlot(edit code, 1, 9)
    invalid@push(wpfIf(edit code, 1, 0, 4))

    // Measure dest_wide in WCHAR units
    x64LoadSlot(edit code, 8, 9)
    x64MovImm64(edit code, 9, 0)
    hold measure = code.bytes.length
    wpfUnit(edit code, 0)
    hold measured = wpfIf(edit code, 1, 0, 4)
    wpfAdjust(edit code, 8, 2)
    wpfAdjust(edit code, 9, 1)
    wpfJumpTo(edit code, measure)
    wpfPatchHere(edit code, measured)
    x64StoreSlot(edit code, 13, 9)

    // Destination + ".tmp." + 32 random hex digits + NUL.
    x64MovReg(edit code, 7, 9)
    wpfAdjust(edit code, 7, 38)
    x64AddReg(edit code, 7, 7)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 11, 0)
    x64StoreSlot(edit code, 12, 2)

    // Copy dest_wide into tmp_wide
    x64MovImm64(edit code, 1, 0)
    hold copy_loop = code.bytes.length
    x64LoadSlot(edit code, 9, 13)
    x64MovReg(edit code, 0, 9)
    x64AddReg(edit code, 0, 0)
    x64CmpReg(edit code, 1, 0)
    hold copy_done = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 8, 9)
    x64AddReg(edit code, 8, 1)
    x64LoadMem8(edit code, 0, 8, 0)
    x64LoadSlot(edit code, 8, 11)
    x64AddReg(edit code, 8, 1)
    x64StoreMem8(edit code, 8, 0, 0)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, copy_loop)
    wpfPatchHere(edit code, copy_done)

    // Append only the fixed prefix; the random suffix is filled before open.
    x64LoadSlot(edit code, 8, 11)
    x64LoadSlot(edit code, 9, 13)
    x64MovReg(edit code, 0, 9)
    x64AddReg(edit code, 0, 0)
    x64AddReg(edit code, 8, 0)
    x64MovImm64(edit code, 0, 46)
    x64StoreMem8(edit code, 8, 0, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 1, 0)
    x64MovImm64(edit code, 0, 116)
    x64StoreMem8(edit code, 8, 2, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 3, 0)
    x64MovImm64(edit code, 0, 109)
    x64StoreMem8(edit code, 8, 4, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 5, 0)
    x64MovImm64(edit code, 0, 112)
    x64StoreMem8(edit code, 8, 6, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 7, 0)
    x64MovImm64(edit code, 0, 46)
    x64StoreMem8(edit code, 8, 8, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 9, 0)

    // The bytes, packed.
    x64LoadSlot(edit code, 7, 1)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 2)
    x64MovImm64(edit code, 1, 0)
    hold pack = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold packed = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 8)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 2, 0, 0)
    x64LoadSlot(edit code, 0, 4)
    x64AddReg(edit code, 0, 1)
    x64StoreMem8(edit code, 0, 0, 2)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, pack)
    wpfPatchHere(edit code, packed)

    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 16, 0)
    change no_temp: List of[Int] = List[]
    hold create_retry = code.bytes.length
    x64LeaMem(edit code, 7, 5, -128)
    x64MovImm64(edit code, 6, 16)
    wpfCall(edit code, random)
    x64TestRax(edit code)
    hold random_ok = x64ConditionalPlaceholder(edit code, true)
    no_temp@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, random_ok)
    each i among 0..16 {
        x64LoadMem8(edit code, 0, 5, -128 + i)
        x64MovImm64(edit code, 2, 0)
        x64MovImm64(edit code, 10, 16)
        x64DivUnsignedReg(edit code, 10)
        x64MovReg(edit code, 11, 0)
        wpfTempHexDigit(edit code, 11, 5 + 2 * i)
        wpfTempHexDigit(edit code, 2, 6 + 2 * i)
    }
    x64LoadSlot(edit code, 8, 11)
    x64LoadSlot(edit code, 1, 13)
    x64AddReg(edit code, 1, 1)
    x64AddReg(edit code, 8, 1)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 74, 0)
    x64StoreMem8(edit code, 8, 75, 0)

    // Create exclusive temporary file:
    // CreateFileW(tmp_wide, GENERIC_WRITE, share all, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL)
    x64LoadSlot(edit code, 1, 11)
    x64MovImm64(edit code, 2, WPF_GENERIC_WRITE)
    x64MovImm64(edit code, 8, WPF_SHARE_ALL)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, 1) // CREATE_NEW = 1
    wpfStackArg(edit code, 0, 0)
    x64MovImm64(edit code, 0, WPF_ATTRIBUTE_NORMAL)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    w64CallImport(edit code, edit imports, pe64ImportCreateFileW())
    x64StoreSlot(edit code, 6, 0)
    x64LoadSlot(edit code, 1, 6)
    hold created = wpfIf(edit code, 1, -1, 5)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    x64MovReg(edit code, 1, 0)
    hold collision80 = wpfIf(edit code, 1, 80, 4)
    hold collision183 = wpfIf(edit code, 1, 183, 4)
    no_temp@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, collision80)
    wpfPatchHere(edit code, collision183)
    x64LoadSlot(edit code, 1, 16)
    wpfAdjust(edit code, 1, 1)
    x64StoreSlot(edit code, 16, 1)
    hold retry = wpfIf(edit code, 1, 16, 6)
    x64PatchRelative(edit code, retry, create_retry)
    no_temp@push(x64JumpPlaceholder(edit code))
    wpfPatchHere(edit code, created)

    // Write full byte buffer
    x64LoadSlot(edit code, 7, 6)
    x64LoadSlot(edit code, 6, 4)
    x64LoadSlot(edit code, 2, 1)
    wpfCall(edit code, write_handle)
    x64TestRax(edit code)
    hold write_failed = x64ConditionalPlaceholder(edit code, false)

    // Flush/sync: FlushFileBuffers(handle)
    x64LoadSlot(edit code, 1, 6)
    w64CallImport(edit code, edit imports, pe64ImportFlushFileBuffers())
    x64TestEax(edit code)
    hold flush_failed = x64ConditionalPlaceholder(edit code, true)

    // Close handle: CloseHandle(handle)
    x64LoadSlot(edit code, 1, 6)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    x64TestEax(edit code)
    hold close_failed = x64ConditionalPlaceholder(edit code, true)

    // Atomic Replace: MoveFileExW(tmp_wide, dest_wide, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)
    // 1 | 8 = 9
    x64LoadSlot(edit code, 1, 11)
    x64LoadSlot(edit code, 2, 9)
    x64MovImm64(edit code, 8, 9)
    w64CallImport(edit code, edit imports, pe64ImportMoveFileExW())
    x64TestEax(edit code)
    hold rename_failed = x64ConditionalPlaceholder(edit code, true)

    // Success! Destination published atomically.
    wpfDrop(edit code, rt, 4, 5)
    wpfDrop(edit code, rt, 9, 10)
    wpfDrop(edit code, rt, 11, 12)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // Failure cleanup:
    wpfPatchHere(edit code, write_failed)
    wpfPatchHere(edit code, flush_failed)
    x64LoadSlot(edit code, 1, 6)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())

    wpfPatchHere(edit code, close_failed)
    wpfPatchHere(edit code, rename_failed)
    x64LoadSlot(edit code, 1, 11)
    w64CallImport(edit code, edit imports, pe64ImportDeleteFileW())
    wpfDrop(edit code, rt, 4, 5)
    wpfDrop(edit code, rt, 9, 10)
    wpfDrop(edit code, rt, 11, 12)
    x64MovImm64(edit code, 0, 3)
    x64FrameEnd(edit code)

    wpfPatchAll(edit code, view no_temp)
    wpfDrop(edit code, rt, 4, 5)
    wpfDrop(edit code, rt, 9, 10)
    wpfDrop(edit code, rt, 11, 12)
    x64MovImm64(edit code, 0, 2)
    x64FrameEnd(edit code)

    wpfPatchAll(edit code, view invalid)
    x64MovImm64(edit code, 0, 1)
    x64FrameEnd(edit code)
    give entry
}

// samefile(output, source) -> RAX: 0 different, 1 same, 2 identity error.
// Opens both handles, calls GetFileInformationByHandle on both, and compares
// dwVolumeSerialNumber, nFileIndexHigh, nFileIndexLow.
flow wpfEmitSameFile(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 30)
    x64StoreSlot(edit code, 0, 7) // slot 0 = path_a Text
    x64StoreSlot(edit code, 1, 6) // slot 1 = path_b Text
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 2, 0) // handle A = 0
    x64StoreSlot(edit code, 3, 0) // handle B = 0
    x64StoreSlot(edit code, 4, 0) // wide_a = 0
    x64StoreSlot(edit code, 5, 0) // wide_a cap = 0
    x64StoreSlot(edit code, 6, 0) // wide_b = 0
    x64StoreSlot(edit code, 7, 0) // wide_b cap = 0
    x64MovImm64(edit code, 0, 2)
    x64StoreSlot(edit code, 8, 0) // fail closed until both identities are known

    change failed: List of[Int] = List[]

    // Convert path_a to UTF-8 Z
    x64LoadSlot(edit code, 7, 0)
    wpfCall(edit code, path_z)
    x64StoreSlot(edit code, 9, 0)
    x64StoreSlot(edit code, 10, 2)
    x64MovReg(edit code, 1, 0)
    failed@push(wpfIf(edit code, 1, 0, 4))

    // Convert path_a UTF-8 Z to wide_z
    x64LoadSlot(edit code, 7, 9)
    wpfCall(edit code, wide_z)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 2)
    wpfDrop(edit code, rt, 9, 10)
    x64LoadSlot(edit code, 1, 4)
    failed@push(wpfIf(edit code, 1, 0, 4))

    // Convert path_b to UTF-8 Z
    x64LoadSlot(edit code, 7, 1)
    wpfCall(edit code, path_z)
    x64StoreSlot(edit code, 11, 0)
    x64StoreSlot(edit code, 12, 2)
    x64MovReg(edit code, 1, 0)
    failed@push(wpfIf(edit code, 1, 0, 4))

    // Convert path_b UTF-8 Z to wide_z
    x64LoadSlot(edit code, 7, 11)
    wpfCall(edit code, wide_z)
    x64StoreSlot(edit code, 6, 0)
    x64StoreSlot(edit code, 7, 2)
    wpfDrop(edit code, rt, 11, 12)
    x64LoadSlot(edit code, 1, 6)
    failed@push(wpfIf(edit code, 1, 0, 4))

    // Establish source identity before treating an absent output as different.
    x64LoadSlot(edit code, 1, 6)
    x64MovImm64(edit code, 2, -2147483648)
    x64MovImm64(edit code, 8, WPF_SHARE_ALL)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, 3) // OPEN_EXISTING = 3
    wpfStackArg(edit code, 0, 0)
    x64MovImm64(edit code, 0, WPF_ATTRIBUTE_NORMAL)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    w64CallImport(edit code, edit imports, pe64ImportCreateFileW())
    x64StoreSlot(edit code, 3, 0)
    x64MovReg(edit code, 1, 0)
    failed@push(wpfIf(edit code, 1, -1, 4))

    // Open the proposed output. Failure is inspected after the normal path.
    x64LoadSlot(edit code, 1, 4)
    x64MovImm64(edit code, 2, -2147483648)
    x64MovImm64(edit code, 8, WPF_SHARE_ALL)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, 3) // OPEN_EXISTING = 3
    wpfStackArg(edit code, 0, 0)
    x64MovImm64(edit code, 0, WPF_ATTRIBUTE_NORMAL)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    w64CallImport(edit code, edit imports, pe64ImportCreateFileW())
    x64StoreSlot(edit code, 2, 0)
    x64MovReg(edit code, 1, 0)
    hold output_unavailable = wpfIf(edit code, 1, -1, 4)

    // GetFileInformationByHandle(handle A, &infoA)
    // infoA is at RBP - 168
    x64LoadSlot(edit code, 1, 2)
    x64LeaMem(edit code, 2, 5, -168)
    w64CallImport(edit code, edit imports, pe64ImportGetFileInformationByHandle())
    x64TestEax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))

    // GetFileInformationByHandle(handle B, &infoB)
    // infoB is at RBP - 232
    x64LoadSlot(edit code, 1, 3)
    x64LeaMem(edit code, 2, 5, -232)
    w64CallImport(edit code, edit imports, pe64ImportGetFileInformationByHandle())
    x64TestEax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))

    // Both metadata queries succeeded; compare stable file identities.
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 8, 0)

    // Compare infoA and infoB:
    // dwVolumeSerialNumber at offset +28: [RBP - 140] vs [RBP - 204]
    x64LoadMem32(edit code, 0, 5, -140)
    x64LoadMem32(edit code, 1, 5, -204)
    x64CmpReg(edit code, 0, 1)
    hold vol_mismatch = x64ConditionalPlaceholder(edit code, false)

    // nFileIndexHigh at offset +44: [RBP - 124] vs [RBP - 188]
    x64LoadMem32(edit code, 0, 5, -124)
    x64LoadMem32(edit code, 1, 5, -188)
    x64CmpReg(edit code, 0, 1)
    hold idx_hi_mismatch = x64ConditionalPlaceholder(edit code, false)

    // nFileIndexLow at offset +48: [RBP - 120] vs [RBP - 184]
    x64LoadMem32(edit code, 0, 5, -120)
    x64LoadMem32(edit code, 1, 5, -184)
    x64CmpReg(edit code, 0, 1)
    hold idx_lo_mismatch = x64ConditionalPlaceholder(edit code, false)

    // All match: result = 1
    x64MovImm64(edit code, 0, 1)
    x64StoreSlot(edit code, 8, 0)

    wpfPatchHere(edit code, vol_mismatch)
    wpfPatchHere(edit code, idx_hi_mismatch)
    wpfPatchHere(edit code, idx_lo_mismatch)

    // Clean up
    hold clean_up = code.bytes.length
    x64LoadSlot(edit code, 1, 3)
    hold skip_hb = wpfIf(edit code, 1, 0, 4)
    hold skip_hb_neg = wpfIf(edit code, 1, -1, 4)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    wpfPatchHere(edit code, skip_hb)
    wpfPatchHere(edit code, skip_hb_neg)

    x64LoadSlot(edit code, 1, 2)
    hold skip_ha = wpfIf(edit code, 1, 0, 4)
    hold skip_ha_neg = wpfIf(edit code, 1, -1, 4)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    wpfPatchHere(edit code, skip_ha)
    wpfPatchHere(edit code, skip_ha_neg)

    wpfDrop(edit code, rt, 4, 5)
    wpfDrop(edit code, rt, 6, 7)

    x64LoadSlot(edit code, 0, 8)
    x64FrameEnd(edit code)

    wpfPatchAll(edit code, view failed)
    wpfJumpTo(edit code, clean_up)

    // ERROR_FILE_NOT_FOUND is safe only when the path itself has no reparse
    // point. ERROR_PATH_NOT_FOUND and every other failure remain errors.
    wpfPatchHere(edit code, output_unavailable)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    x64MovReg(edit code, 1, 0)
    hold not_absent = wpfIf(edit code, 1, 2, 5)
    x64LoadSlot(edit code, 1, 4)
    w64CallImport(edit code, edit imports, pe64ImportGetFileAttributesW())
    wpfDword(edit code)
    x64MovReg(edit code, 1, 0)
    hold has_entry = wpfIf(edit code, 1, WPF_DWORD_MASK, 5)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 8, 0)
    wpfPatchHere(edit code, not_absent)
    wpfPatchHere(edit code, has_entry)
    wpfJumpTo(edit code, clean_up)

    give entry
}

// Console input. Both routines use the standard input handle of
// GetStdHandle(STD_INPUT_HANDLE), which is never closed.
//
// consolemode(RDI = request) -> RAX: the previous input state, an opaque
// non-negative Int (here the DWORD console mode). Requests: -1 queries
// only; -2 switches to raw input; a value >= 0 restores a state that an
// earlier call returned. Raw input clears ENABLE_PROCESSED_INPUT (Ctrl+C
// arrives as a key), ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT and
// ENABLE_QUICK_EDIT_MODE, and sets ENABLE_WINDOW_INPUT, ENABLE_MOUSE_INPUT
// and ENABLE_EXTENDED_FLAGS (required to clear quick edit).
// Errors: -1 standard input is not a console (GetStdHandle or
// GetConsoleMode fails: a pipe, a file, NUL, no console); -2 the console
// rejects the new mode (the previous one stays in force); -3 a request
// below -2 or above a DWORD (nothing is changed).
// Slots: 0 request, 1 handle, 2 previous mode (a DWORD, zero-extended).
flow wpfEmitConsoleMode(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 3)
    x64StoreSlot(edit code, 0, 7)
    change no_console: List of[Int] = List[]
    change invalid: List of[Int] = List[]
    x64MovReg(edit code, 1, 7)
    invalid@push(wpfIf(edit code, 1, -2, 6))
    invalid@push(wpfIf(edit code, 1, WPF_DWORD_MASK, 8))
    x64MovImm64(edit code, 1, -10)              // STD_INPUT_HANDLE
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64StoreSlot(edit code, 1, 0)
    x64MovReg(edit code, 1, 0)
    no_console@push(wpfIf(edit code, 1, 0, 4))
    no_console@push(wpfIf(edit code, 1, -1, 4))
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 2, 0)
    x64LoadSlot(edit code, 1, 1)                // hConsoleHandle
    x64LeaMem(edit code, 2, 5, -24)             // lpMode = slot 2
    w64CallImport(edit code, edit imports, pe64ImportGetConsoleMode())
    x64TestEax(edit code)
    no_console@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 2, 0)
    hold query_only = wpfIf(edit code, 2, -1, 4)
    hold restore = wpfIf(edit code, 2, 0, 9)
    // Raw: (mode & ~0xDF) + 0x98.
    x64LoadMem32(edit code, 2, 5, -24)
    x64MovImm64(edit code, 10, 4294967072)
    x64AndReg(edit code, 2, 10)
    wpfAdjust(edit code, 2, 152)
    hold set_mode = x64JumpPlaceholder(edit code)
    wpfPatchHere(edit code, restore)
    x64LoadSlot(edit code, 2, 0)
    wpfPatchHere(edit code, set_mode)
    x64LoadSlot(edit code, 1, 1)                // hConsoleHandle, RDX = dwMode
    w64CallImport(edit code, edit imports, pe64ImportSetConsoleMode())
    x64TestEax(edit code)
    hold rejected = x64ConditionalPlaceholder(edit code, true)
    wpfPatchHere(edit code, query_only)
    x64LoadMem32(edit code, 0, 5, -24)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, rejected)
    x64MovImm64(edit code, 0, -2)
    x64FrameEnd(edit code)
    wpfPatchAll(edit code, view no_console)
    x64MovImm64(edit code, 0, -1)
    x64FrameEnd(edit code)
    wpfPatchAll(edit code, view invalid)
    x64MovImm64(edit code, 0, -3)
    x64FrameEnd(edit code)
    give entry
}

// RAX = the WORD at [RBP + displacement]. Clobbers R10.
flow wpfLoadWord(code: edit X64Code, displacement: Int) {
    x64LoadMem32(edit code, 0, 5, displacement)
    x64MovImm64(edit code, 10, 65535)
    x64AndReg(edit code, 0, 10)
}

// Frame slot `acc` += RAX * `scale`. Clobbers RAX, R10 and R11.
flow wpfAccumulate(code: edit X64Code, acc: Int, scale: Int) {
    x64MovImm64(edit code, 10, scale)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 11, acc)
    x64AddReg(edit code, 0, 11)
    x64StoreSlot(edit code, acc, 0)
}

// readevent() -> RAX: the next key, resize or mouse event of the console
// input buffer, packed into one non-negative Int; -1 when standard input is
// not a console or ReadConsoleInputW fails. ReadConsoleInputW blocks until
// an event exists (no polling); focus and menu events are skipped.
// Packing (bits; std/io/console.l decodes it), kind in bits 56..59:
//   1 key:    0..15 UTF-16 unit (0 for none; a surrogate pair arrives as two
//             events), 16..31 virtual-key code, 32..47 low word of
//             dwControlKeyState, 48 key down, 49..55 repeat count (<= 127).
//   2 resize: 0..15 columns, 16..31 rows of the screen buffer.
//   3 mouse:  0..15 column, 16..31 row, 32..39 low byte of dwButtonState,
//             40..47 dwEventFlags (low byte), 48..52 low bits of
//             dwControlKeyState (alt, ctrl, shift), 53 wheel forward,
//             54 wheel backward.
// INPUT_RECORD (20 bytes) lives in slots 2..4: EventType at RBP-40, the
// event union from RBP-36. Slots: 0 handle, 1 events read, 5 result.
flow wpfEmitReadEvent(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 6)
    change failed: List of[Int] = List[]
    x64MovImm64(edit code, 1, -10)              // STD_INPUT_HANDLE
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64StoreSlot(edit code, 0, 0)
    x64MovReg(edit code, 1, 0)
    failed@push(wpfIf(edit code, 1, 0, 4))
    failed@push(wpfIf(edit code, 1, -1, 4))
    // Not a console (a pipe or a file): one byte through ReadFile.
    x64LoadSlot(edit code, 1, 0)
    x64LeaMem(edit code, 2, 5, -16)
    w64CallImport(edit code, edit imports, pe64ImportGetConsoleMode())
    x64TestEax(edit code)
    hold not_console = x64ConditionalPlaceholder(edit code, true)
    hold top = code.bytes.length
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 1, 0)
    x64StoreSlot(edit code, 5, 0)
    x64LoadSlot(edit code, 1, 0)                // hConsoleInput
    x64LeaMem(edit code, 2, 5, -40)             // lpBuffer
    x64MovImm64(edit code, 8, 1)                // nLength
    x64LeaMem(edit code, 9, 5, -16)             // lpNumberOfEventsRead
    w64CallImport(edit code, edit imports, pe64ImportReadConsoleInputW())
    x64TestEax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold none = x64ConditionalPlaceholder(edit code, true)
    wpfLoadWord(edit code, -40)
    x64MovReg(edit code, 1, 0)
    hold is_key = wpfIf(edit code, 1, 1, 4)     // KEY_EVENT
    hold is_mouse = wpfIf(edit code, 1, 2, 4)   // MOUSE_EVENT
    hold is_resize = wpfIf(edit code, 1, 4, 4)  // WINDOW_BUFFER_SIZE_EVENT
    // Focus, menu or an unknown record: read the next one.
    wpfPatchHere(edit code, none)
    wpfJumpTo(edit code, top)

    // Key: UnicodeChar +14, wVirtualKeyCode +10, dwControlKeyState +16,
    // bKeyDown +4, wRepeatCount +8 of the record.
    wpfPatchHere(edit code, is_key)
    wpfLoadWord(edit code, -26)
    wpfAccumulate(edit code, 5, 1)
    wpfLoadWord(edit code, -30)
    wpfAccumulate(edit code, 5, 65536)
    wpfLoadWord(edit code, -24)
    wpfAccumulate(edit code, 5, 4294967296)
    x64LoadMem32(edit code, 1, 5, -36)
    hold key_up = wpfIf(edit code, 1, 0, 4)
    x64MovImm64(edit code, 0, 1)
    wpfAccumulate(edit code, 5, 281474976710656)
    wpfPatchHere(edit code, key_up)
    wpfLoadWord(edit code, -32)
    x64MovReg(edit code, 1, 0)
    hold repeat_fits = wpfIf(edit code, 1, 127, 7)
    x64MovImm64(edit code, 1, 127)
    wpfPatchHere(edit code, repeat_fits)
    x64MovReg(edit code, 0, 1)
    wpfAccumulate(edit code, 5, 562949953421312)
    x64MovImm64(edit code, 0, 1)
    wpfAccumulate(edit code, 5, 72057594037927936)
    hold key_done = x64JumpPlaceholder(edit code)

    // Resize: dwSize (COORD: X, Y) at +4.
    wpfPatchHere(edit code, is_resize)
    x64LoadMem32(edit code, 0, 5, -36)
    wpfAccumulate(edit code, 5, 1)
    x64MovImm64(edit code, 0, 2)
    wpfAccumulate(edit code, 5, 72057594037927936)
    hold resize_done = x64JumpPlaceholder(edit code)

    // Mouse: dwMousePosition +4, dwButtonState +8, dwControlKeyState +12,
    // dwEventFlags +16.
    wpfPatchHere(edit code, is_mouse)
    x64LoadMem32(edit code, 0, 5, -36)
    wpfAccumulate(edit code, 5, 1)
    x64LoadMem32(edit code, 0, 5, -32)
    x64MovImm64(edit code, 10, 255)
    x64AndReg(edit code, 0, 10)
    wpfAccumulate(edit code, 5, 4294967296)
    x64LoadMem32(edit code, 0, 5, -24)
    x64MovImm64(edit code, 10, 255)
    x64AndReg(edit code, 0, 10)
    wpfAccumulate(edit code, 5, 1099511627776)
    x64LoadMem32(edit code, 0, 5, -28)
    x64MovImm64(edit code, 10, 31)
    x64AndReg(edit code, 0, 10)
    wpfAccumulate(edit code, 5, 281474976710656)
    // Wheel direction: the signed high word of dwButtonState, meaningful
    // only with MOUSE_WHEELED (4) or MOUSE_HWHEELED (8).
    x64LoadMem32(edit code, 0, 5, -24)
    x64MovImm64(edit code, 10, 12)
    x64AndReg(edit code, 0, 10)
    x64MovReg(edit code, 1, 0)
    hold no_wheel = wpfIf(edit code, 1, 0, 4)
    x64LoadMem32(edit code, 1, 5, -32)
    hold no_delta = wpfIf(edit code, 1, 65536, 6)
    hold backward = wpfIf(edit code, 1, 2147483648, 9)
    x64MovImm64(edit code, 0, 1)
    wpfAccumulate(edit code, 5, 9007199254740992)
    hold forward_done = x64JumpPlaceholder(edit code)
    wpfPatchHere(edit code, backward)
    x64MovImm64(edit code, 0, 1)
    wpfAccumulate(edit code, 5, 18014398509481984)
    wpfPatchHere(edit code, forward_done)
    wpfPatchHere(edit code, no_wheel)
    wpfPatchHere(edit code, no_delta)
    x64MovImm64(edit code, 0, 3)
    wpfAccumulate(edit code, 5, 72057594037927936)

    wpfPatchHere(edit code, key_done)
    wpfPatchHere(edit code, resize_done)
    x64LoadSlot(edit code, 0, 5)
    x64FrameEnd(edit code)

    // Byte input: kind 4, the byte in bits 0..7; -2 at end of input (zero
    // bytes read, or ERROR_BROKEN_PIPE once the writer has closed a pipe).
    wpfPatchHere(edit code, not_console)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 1, 0)
    x64StoreSlot(edit code, 2, 0)
    wpfStackArg(edit code, 0, 0)                // lpOverlapped = NULL
    x64LoadSlot(edit code, 1, 0)                // hFile
    x64LeaMem(edit code, 2, 5, -24)             // lpBuffer = slot 2
    x64MovImm64(edit code, 8, 1)                // nNumberOfBytesToRead
    x64LeaMem(edit code, 9, 5, -16)             // lpNumberOfBytesRead
    w64CallImport(edit code, edit imports, pe64ImportReadFile())
    x64TestEax(edit code)
    hold read_failed = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold end_of_input = x64ConditionalPlaceholder(edit code, true)
    x64LoadMem8(edit code, 0, 5, -24)
    x64MovImm64(edit code, 10, 288230376151711744)
    x64AddReg(edit code, 0, 10)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, read_failed)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wpfDword(edit code)
    x64MovReg(edit code, 1, 0)
    failed@push(wpfIf(edit code, 1, 109, 5))
    wpfPatchHere(edit code, end_of_input)
    x64MovImm64(edit code, 0, -2)
    x64FrameEnd(edit code)

    wpfPatchAll(edit code, view failed)
    x64MovImm64(edit code, 0, -1)
    x64FrameEnd(edit code)
    give entry
}

// Binary-safe stdout write of a borrowed List<Int>, with no newline.
// 0 success, -1 OS failure, -2 invalid byte/length.
flow wpfEmitWriteConsole(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, write_handle: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 5)
    x64LoadMem64(edit code, 8, 7, 0)
    x64LoadMem64(edit code, 9, 7, 8)
    x64StoreSlot(edit code, 0, 8)
    x64StoreSlot(edit code, 1, 9)
    x64MovReg(edit code, 1, 9)
    hold invalid_size = wpfIf(edit code, 1, 16777216, 8)
    x64MovImm64(edit code, 1, 0)
    hold check = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold checked = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 0)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 0, 0, 0)
    x64MovImm64(edit code, 10, 256)
    x64CmpReg(edit code, 0, 10)
    hold invalid_byte = x64AboveEqualPlaceholder(edit code)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, check)
    wpfPatchHere(edit code, checked)
    x64LoadSlot(edit code, 7, 1)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovImm64(edit code, 1, 0)
    hold pack = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold packed = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 0)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 2, 0, 0)
    x64LoadSlot(edit code, 0, 2)
    x64AddReg(edit code, 0, 1)
    x64StoreMem8(edit code, 0, 0, 2)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, pack)
    wpfPatchHere(edit code, packed)
    x64MovImm64(edit code, 1, -11)             // STD_OUTPUT_HANDLE
    w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
    x64StoreSlot(edit code, 4, 0)
    x64LoadSlot(edit code, 7, 4)
    x64LoadSlot(edit code, 6, 2)
    x64LoadSlot(edit code, 2, 1)
    wpfCall(edit code, write_handle)
    x64StoreSlot(edit code, 1, 0)
    wpfDrop(edit code, rt, 2, 3)
    x64LoadSlot(edit code, 0, 1)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, invalid_size)
    wpfPatchHere(edit code, invalid_byte)
    x64MovImm64(edit code, 0, -2)
    x64FrameEnd(edit code)
    give entry
}

// ---- File streams (ELE-LIR platform codes 9..16) -------------------------
//
// Below sema a File is the HANDLE from CreateFileW (never -1, a positive
// kernel handle value) or, after a failed open, the negative error code.
// Results and error codes are those of native_rt_platform (Linux):
//   -1 invalid argument, -2 not found, -3 permission denied or sharing
//   violation, -4 already exists, -5 other I/O failure (also: not a disk
//   file), -6 file not open.
fixed WPF_FILE_BLOCK = 16777216
fixed WPF_GENERIC_RW = 3221225472
fixed WPF_WRITE_ATTRS = 1073741952      // GENERIC_WRITE | FILE_READ_ATTRIBUTES
fixed WPF_APPEND_ACCESS = 1048708       // FILE_APPEND_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE

// RAX = the ELE file error code for the GetLastError value in RCX.
// Clobbers R10.
flow wpfMapError(code: edit X64Code) {
    change missing: List of[Int] = List[]
    change denied: List of[Int] = List[]
    change exists: List of[Int] = List[]
    change invalid: List of[Int] = List[]
    change not_open: List of[Int] = List[]
    missing@push(wpfIf(edit code, 1, 2, 4))      // FILE_NOT_FOUND
    missing@push(wpfIf(edit code, 1, 3, 4))      // PATH_NOT_FOUND
    missing@push(wpfIf(edit code, 1, 15, 4))     // INVALID_DRIVE
    missing@push(wpfIf(edit code, 1, 53, 4))     // BAD_NETPATH
    missing@push(wpfIf(edit code, 1, 67, 4))     // BAD_NET_NAME
    missing@push(wpfIf(edit code, 1, 161, 4))    // BAD_PATHNAME
    denied@push(wpfIf(edit code, 1, 5, 4))       // ACCESS_DENIED
    denied@push(wpfIf(edit code, 1, 19, 4))      // WRITE_PROTECT
    denied@push(wpfIf(edit code, 1, 32, 4))      // SHARING_VIOLATION
    denied@push(wpfIf(edit code, 1, 33, 4))      // LOCK_VIOLATION
    exists@push(wpfIf(edit code, 1, 80, 4))      // FILE_EXISTS
    exists@push(wpfIf(edit code, 1, 183, 4))     // ALREADY_EXISTS
    invalid@push(wpfIf(edit code, 1, 87, 4))     // INVALID_PARAMETER
    invalid@push(wpfIf(edit code, 1, 123, 4))    // INVALID_NAME
    invalid@push(wpfIf(edit code, 1, 131, 4))    // NEGATIVE_SEEK
    invalid@push(wpfIf(edit code, 1, 206, 4))    // FILENAME_EXCED_RANGE
    not_open@push(wpfIf(edit code, 1, 6, 4))     // INVALID_HANDLE
    change done: List of[Int] = List[]
    x64MovImm64(edit code, 0, -5)
    done@push(x64JumpPlaceholder(edit code))
    wpfPatchAll(edit code, view missing)
    x64MovImm64(edit code, 0, -2)
    done@push(x64JumpPlaceholder(edit code))
    wpfPatchAll(edit code, view denied)
    x64MovImm64(edit code, 0, -3)
    done@push(x64JumpPlaceholder(edit code))
    wpfPatchAll(edit code, view exists)
    x64MovImm64(edit code, 0, -4)
    done@push(x64JumpPlaceholder(edit code))
    wpfPatchAll(edit code, view invalid)
    x64MovImm64(edit code, 0, -1)
    done@push(x64JumpPlaceholder(edit code))
    wpfPatchAll(edit code, view not_open)
    x64MovImm64(edit code, 0, -6)
    wpfPatchAll(edit code, view done)
}

flow wpfReturnConst(code: edit X64Code, value: Int) {
    x64MovImm64(edit code, 0, value)
    x64FrameEnd(edit code)
}

// RAX = mapped GetLastError(), then return from the frame.
flow wpfReturnLastError(code: edit X64Code, imports: edit Pe64Imports) {
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wpfDword(edit code)
    x64MovReg(edit code, 1, 0)
    wpfMapError(edit code)
    x64FrameEnd(edit code)
}

// RCX = RCX * 8 + [list header in RDX].elements. Clobbers R10.
flow wpfElementAddress(code: edit X64Code) {
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 1, 10)
    x64LoadMem64(edit code, 10, 2, 0)
    x64AddReg(edit code, 1, 10)
}

// Stores `value` in frame slot `slot` when RCX == `mode`. Clobbers RAX, R10.
flow wpfModeSlot(code: edit X64Code, mode: Int, slot: Int, value: Int) {
    hold other = wpfIf(edit code, 1, mode, 5)
    x64MovImm64(edit code, 0, value)
    x64StoreSlot(edit code, slot, 0)
    wpfPatchHere(edit code, other)
}

// open(RDI = address of the path Text, RSI = mode) -> RAX = HANDLE or an
// error. Modes as on Linux: 1 read (shares read, write and delete),
// 2 write (CREATE_ALWAYS), 3 append (FILE_APPEND_DATA, OPEN_ALWAYS),
// 4 create new (CREATE_NEW), 5 read+write (OPEN_EXISTING); write modes
// share read only. Anything but FILE_TYPE_DISK is closed and rejected (-5).
// Slots: 0 mode, 1 UTF-8 path, 2 its capacity, 3 UTF-16 path, 4 its
// capacity, 5 handle, 6 error, 7 path Text, 8 access, 9 share, 10 disposition.
flow wpfEmitFileOpen(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 11)
    x64StoreSlot(edit code, 0, 6)
    x64StoreSlot(edit code, 7, 7)
    change invalid: List of[Int] = List[]
    x64MovReg(edit code, 1, 6)
    invalid@push(wpfIf(edit code, 1, 1, 6))
    invalid@push(wpfIf(edit code, 1, 5, 8))
    x64LoadSlot(edit code, 7, 7)
    wpfCall(edit code, path_z)
    x64StoreSlot(edit code, 1, 0)
    x64StoreSlot(edit code, 2, 2)
    x64MovReg(edit code, 1, 0)
    invalid@push(wpfIf(edit code, 1, 0, 4))
    x64LoadSlot(edit code, 7, 1)
    wpfCall(edit code, wide_z)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 4, 2)
    wpfDrop(edit code, rt, 1, 2)
    x64LoadSlot(edit code, 1, 3)
    invalid@push(wpfIf(edit code, 1, 0, 4))
    // Mode 1 defaults, then the other modes.
    x64MovImm64(edit code, 0, WPF_GENERIC_READ)
    x64StoreSlot(edit code, 8, 0)
    x64MovImm64(edit code, 0, WPF_SHARE_ALL)
    x64StoreSlot(edit code, 9, 0)
    x64MovImm64(edit code, 0, WPF_OPEN_EXISTING)
    x64StoreSlot(edit code, 10, 0)
    x64LoadSlot(edit code, 1, 0)
    wpfModeSlot(edit code, 2, 8, WPF_WRITE_ATTRS)
    wpfModeSlot(edit code, 2, 9, 1)
    wpfModeSlot(edit code, 2, 10, WPF_CREATE_ALWAYS)
    wpfModeSlot(edit code, 3, 8, WPF_APPEND_ACCESS)
    wpfModeSlot(edit code, 3, 9, 1)
    wpfModeSlot(edit code, 3, 10, 4)
    wpfModeSlot(edit code, 4, 8, WPF_WRITE_ATTRS)
    wpfModeSlot(edit code, 4, 9, 1)
    wpfModeSlot(edit code, 4, 10, 1)
    wpfModeSlot(edit code, 5, 8, WPF_GENERIC_RW)
    wpfModeSlot(edit code, 5, 9, 1)
    // CreateFileW(path, access, share, NULL, disposition, NORMAL, NULL).
    x64LoadSlot(edit code, 1, 3)
    x64LoadSlot(edit code, 2, 8)
    x64LoadSlot(edit code, 8, 9)
    x64MovImm64(edit code, 9, 0)
    x64LoadSlot(edit code, 0, 10)
    wpfStackArg(edit code, 0, 0)
    x64MovImm64(edit code, 0, WPF_ATTRIBUTE_NORMAL)
    wpfStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wpfStackArg(edit code, 2, 0)
    w64CallImport(edit code, edit imports, pe64ImportCreateFileW())
    x64StoreSlot(edit code, 5, 0)
    x64MovReg(edit code, 1, 0)
    hold opened = wpfIf(edit code, 1, -1, 5)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wpfDword(edit code)
    x64StoreSlot(edit code, 6, 0)
    wpfDrop(edit code, rt, 3, 4)
    x64LoadSlot(edit code, 1, 6)
    wpfMapError(edit code)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, opened)
    wpfDrop(edit code, rt, 3, 4)
    x64LoadSlot(edit code, 1, 5)
    w64CallImport(edit code, edit imports, pe64ImportGetFileType())
    wpfDword(edit code)
    x64MovReg(edit code, 1, 0)
    hold not_disk = wpfIf(edit code, 1, WPF_FILE_TYPE_DISK, 5)
    x64LoadSlot(edit code, 0, 5)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, not_disk)
    x64LoadSlot(edit code, 1, 5)
    w64CallImport(edit code, edit imports, pe64ImportCloseHandle())
    wpfReturnConst(edit code, -5)
    wpfPatchAll(edit code, view invalid)
    wpfReturnConst(edit code, -1)
    give entry
}

// read(RDI = HANDLE, RSI = address of a List of[Int] header, RDX = limit)
// -> RAX = bytes stored into elements 0.., 0 at end of file, or an error.
// Slots: 0 handle, 1 list header, 2 limit, 3 buffer, 4 capacity, 5 bytes
// read (DWORD, zeroed first), 6 error.
flow wpfEmitFileRead(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 7)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64MovReg(edit code, 1, 7)
    hold not_open = wpfIf(edit code, 1, 0, 6)
    change invalid: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 2)
    invalid@push(wpfIf(edit code, 1, 1, 6))
    invalid@push(wpfIf(edit code, 1, WPF_FILE_BLOCK, 8))
    x64LoadSlot(edit code, 2, 1)
    x64LoadMem64(edit code, 9, 2, 8)
    invalid@push(wpfIfReg(edit code, 1, 9, 8))
    x64LoadSlot(edit code, 7, 2)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 4, 2)
    // ReadFile(handle, buffer, limit, &read, NULL).
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 5, 0)
    wpfStackArg(edit code, 0, 0)
    x64LoadSlot(edit code, 1, 0)
    x64LoadSlot(edit code, 2, 3)
    x64LoadSlot(edit code, 8, 2)
    x64LeaMem(edit code, 9, 5, -48)
    w64CallImport(edit code, edit imports, pe64ImportReadFile())
    x64TestEax(edit code)
    hold read_ok = x64ConditionalPlaceholder(edit code, false)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wpfDword(edit code)
    x64StoreSlot(edit code, 6, 0)
    wpfDrop(edit code, rt, 3, 4)
    x64LoadSlot(edit code, 1, 6)
    // ERROR_HANDLE_EOF and ERROR_BROKEN_PIPE end the stream.
    change at_end: List of[Int] = List[]
    at_end@push(wpfIf(edit code, 1, 38, 4))
    at_end@push(wpfIf(edit code, 1, 109, 4))
    wpfMapError(edit code)
    x64FrameEnd(edit code)
    wpfPatchAll(edit code, view at_end)
    wpfReturnConst(edit code, 0)
    wpfPatchHere(edit code, read_ok)
    x64MovImm64(edit code, 1, 0)
    hold unpack = code.bytes.length
    x64LoadSlot(edit code, 2, 5)
    hold unpacked = wpfIfReg(edit code, 1, 2, 9)
    x64LoadSlot(edit code, 8, 3)
    x64AddReg(edit code, 8, 1)
    x64LoadMem8(edit code, 0, 8, 0)
    x64MovReg(edit code, 9, 1)
    x64LoadSlot(edit code, 2, 1)
    wpfElementAddress(edit code)
    x64StoreMem64(edit code, 1, 0, 0)
    x64MovReg(edit code, 1, 9)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, unpack)
    wpfPatchHere(edit code, unpacked)
    wpfDrop(edit code, rt, 3, 4)
    x64LoadSlot(edit code, 0, 5)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, not_open)
    wpfReturnConst(edit code, -6)
    wpfPatchAll(edit code, view invalid)
    wpfReturnConst(edit code, -1)
    give entry
}

// write(RDI = HANDLE, RSI = address of a List of[Int] header, RDX = count)
// -> RAX = count once every byte is written, or an error. Bytes are all
// validated (0..255) before the first WriteFile.
// Slots: 0 handle, 1 list header, 2 count, 3 buffer, 4 capacity, 5 status.
flow wpfEmitFileWrite(code: edit X64Code, rt: view PfRuntime, write_handle: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64MovReg(edit code, 1, 7)
    hold not_open = wpfIf(edit code, 1, 0, 6)
    change invalid: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 2)
    invalid@push(wpfIf(edit code, 1, 0, 6))
    invalid@push(wpfIf(edit code, 1, WPF_FILE_BLOCK, 8))
    x64LoadSlot(edit code, 2, 1)
    x64LoadMem64(edit code, 9, 2, 8)
    invalid@push(wpfIfReg(edit code, 1, 9, 8))
    hold empty = wpfIf(edit code, 1, 0, 4)
    x64MovImm64(edit code, 1, 0)
    hold check = code.bytes.length
    x64LoadSlot(edit code, 2, 2)
    hold checked = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 9, 1)
    x64LoadSlot(edit code, 2, 1)
    wpfElementAddress(edit code)
    x64LoadMem64(edit code, 0, 1, 0)
    x64MovReg(edit code, 1, 9)
    x64MovImm64(edit code, 10, 256)
    x64CmpReg(edit code, 0, 10)
    invalid@push(x64AboveEqualPlaceholder(edit code))
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, check)
    wpfPatchHere(edit code, checked)
    x64LoadSlot(edit code, 7, 2)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 4, 2)
    x64MovImm64(edit code, 1, 0)
    hold pack = code.bytes.length
    x64LoadSlot(edit code, 2, 2)
    hold packed = wpfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 9, 1)
    x64LoadSlot(edit code, 2, 1)
    wpfElementAddress(edit code)
    x64LoadMem64(edit code, 2, 1, 0)
    x64LoadSlot(edit code, 8, 3)
    x64AddReg(edit code, 8, 9)
    x64StoreMem8(edit code, 8, 0, 2)
    x64MovReg(edit code, 1, 9)
    wpfAdjust(edit code, 1, 1)
    wpfJumpTo(edit code, pack)
    wpfPatchHere(edit code, packed)
    x64LoadSlot(edit code, 7, 0)
    x64LoadSlot(edit code, 6, 3)
    x64LoadSlot(edit code, 2, 2)
    wpfCall(edit code, write_handle)
    x64StoreSlot(edit code, 5, 0)
    wpfDrop(edit code, rt, 3, 4)
    x64LoadSlot(edit code, 1, 5)
    hold failed = wpfIf(edit code, 1, 0, 5)
    x64LoadSlot(edit code, 0, 2)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, failed)
    wpfReturnConst(edit code, -5)
    wpfPatchHere(edit code, empty)
    wpfReturnConst(edit code, 0)
    wpfPatchHere(edit code, not_open)
    wpfReturnConst(edit code, -6)
    wpfPatchAll(edit code, view invalid)
    wpfReturnConst(edit code, -1)
    give entry
}

// seek(RDI = HANDLE, RSI = offset, RDX = whence 0..2) -> RAX = the new
// position or an error. Slots: 0 handle, 1 offset, 2 whence, 3 position.
flow wpfEmitFileSeek(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 4)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64MovReg(edit code, 1, 7)
    hold not_open = wpfIf(edit code, 1, 0, 6)
    change invalid: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 2)
    invalid@push(wpfIf(edit code, 1, 0, 6))
    invalid@push(wpfIf(edit code, 1, 2, 8))
    // SetFilePointerEx(handle, offset, &position, whence).
    x64LoadSlot(edit code, 1, 0)
    x64LoadSlot(edit code, 2, 1)
    x64LeaMem(edit code, 8, 5, -32)
    x64LoadSlot(edit code, 9, 2)
    w64CallImport(edit code, edit imports, pe64ImportSetFilePointerEx())
    x64TestEax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, false)
    wpfReturnLastError(edit code, edit imports)
    wpfPatchHere(edit code, ok)
    x64LoadSlot(edit code, 0, 3)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, not_open)
    wpfReturnConst(edit code, -6)
    wpfPatchAll(edit code, view invalid)
    wpfReturnConst(edit code, -1)
    give entry
}

// size(RDI = HANDLE) -> RAX = the file size or an error. Slots: 0 handle,
// 1 size.
flow wpfEmitFileSize(code: edit X64Code, imports: edit Pe64Imports) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 2)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 1, 7)
    hold not_open = wpfIf(edit code, 1, 0, 6)
    x64LoadSlot(edit code, 1, 0)
    x64LeaMem(edit code, 2, 5, -16)
    w64CallImport(edit code, edit imports, pe64ImportGetFileSizeEx())
    x64TestEax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, false)
    wpfReturnLastError(edit code, edit imports)
    wpfPatchHere(edit code, ok)
    x64LoadSlot(edit code, 0, 1)
    x64FrameEnd(edit code)
    wpfPatchHere(edit code, not_open)
    wpfReturnConst(edit code, -6)
    give entry
}

// flush (FlushFileBuffers) or close (CloseHandle) of RDI = HANDLE -> RAX
// = 0 or an error. A failed-open File closes as 0 and flushes as -6.
flow wpfEmitFileUnary(code: edit X64Code, imports: edit Pe64Imports, close: Bool) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 1)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 1, 7)
    hold not_open = wpfIf(edit code, 1, 0, 6)
    x64LoadSlot(edit code, 1, 0)
    when close { w64CallImport(edit code, edit imports, pe64ImportCloseHandle()) }
    otherwise { w64CallImport(edit code, edit imports, pe64ImportFlushFileBuffers()) }
    x64TestEax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, false)
    wpfReturnLastError(edit code, edit imports)
    wpfPatchHere(edit code, ok)
    wpfReturnConst(edit code, 0)
    wpfPatchHere(edit code, not_open)
    when close { wpfReturnConst(edit code, 0) }
    otherwise { wpfReturnConst(edit code, -6) }
    give entry
}

// Emits the Windows platform runtime; returns the entry of each operation,
// indexed by the ELE-LIR platform codes pfArgCount() .. pfWriteBytes(), like
// native_rt_platform's pfEmitAll. Its absolute addresses: none (tables are
// reached RIP-relative), so it adds no base relocation.
// The console input routines (codes 6, 7) are emitted only when `console`
// holds; otherwise their entries are -1 and their imports stay out.
// Window routines (codes 17..25, codegen/win64_window.l) likewise only
// when `windows` holds.
expose flow w64EmitPlatform(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, console: Bool, console_output: Bool, files: Bool, windows: Bool, clipboard: Bool, list_reserve: Int) => List of[Int] {
    hold utf8 = pfEmitUtf8(edit code)
    hold path_z = pfEmitPathZ(edit code, rt)
    hold write_handle = wpfEmitWriteHandle(edit code, edit imports)
    hold wide_z = wpfEmitWideZ(edit code, edit imports, rt)
    hold scan = wpfEmitScan(edit code, edit imports)
    hold random = wpfEmitRandom(edit code, edit imports)
    change at: List of[Int] = List[]
    at@push(wpfEmitArgCount(edit code, scan))
    at@push(wpfEmitArg(edit code, edit imports, rt, scan))
    at@push(wpfEmitReadText(edit code, edit imports, rt, utf8, path_z, wide_z))
    at@push(wpfEmitPrintError(edit code, edit imports, write_handle))
    at@push(wpfEmitWriteBytes(edit code, edit imports, rt, path_z, wide_z, write_handle, random))
    at@push(wpfEmitSameFile(edit code, edit imports, rt, path_z, wide_z))
    when console {
        at@push(wpfEmitConsoleMode(edit code, edit imports))
        at@push(wpfEmitReadEvent(edit code, edit imports))
    } otherwise {
        at@push(-1)
        at@push(-1)
    }
    when console_output { at@push(wpfEmitWriteConsole(edit code, edit imports, rt, write_handle)) }
    otherwise { at@push(-1) }
    when files {
        at@push(wpfEmitFileOpen(edit code, edit imports, rt, path_z, wide_z))
        at@push(wpfEmitFileRead(edit code, edit imports, rt))
        at@push(wpfEmitFileWrite(edit code, rt, write_handle))
        at@push(wpfEmitFileSeek(edit code, edit imports))
        at@push(wpfEmitFileSize(edit code, edit imports))
        at@push(wpfEmitFileUnary(edit code, edit imports, false))
        at@push(wpfEmitFileUnary(edit code, edit imports, true))
        at@push(pfEmitFileStatus(edit code))
    } otherwise {
        each k among 0..8 { at@push(-1) }
    }
    when windows {
        hold window_at = w64EmitWindows(edit code, edit imports, rt, path_z, wide_z)
        each k among 0..window_at.length { at@push(window_at[k]) }
    } otherwise {
        each k among 0..11 { at@push(-1) }
    }
    when clipboard {
        hold clip = wcEmitClipboard(edit code, edit imports, rt, list_reserve, utf8)
        at@push(clip[0])
        at@push(clip[1])
    } otherwise {
        at@push(-1)
        at@push(-1)
    }
    give at
}
