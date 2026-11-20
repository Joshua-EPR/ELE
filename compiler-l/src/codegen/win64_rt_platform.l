take x86_64
take pe64
take win64_rt
take native_rt_platform

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

// writebytes(RDI = address of the path Text, RSI = address of the
// List of[Int] header) -> RAX = status. Slots: 0 path Text, 1 length,
// 2 UTF-8 path, 3 its capacity, 4 byte buffer, 5 its capacity, 6 handle,
// 7 status, 8 elements, 9 UTF-16 dest path, 10 its capacity, 11 UTF-16 tmp path, 12 its capacity.
flow wpfEmitWriteBytes(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int, write_handle: Int) => Int {
    hold entry = code.bytes.length
    wpfBegin(edit code, 13)
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

    // Allocate tmp_wide: (R9 + 8) * 2 bytes
    x64MovReg(edit code, 7, 9)
    wpfAdjust(edit code, 7, 8)
    x64AddReg(edit code, 7, 7)
    wpfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 11, 0)
    x64StoreSlot(edit code, 12, 2)

    // Copy dest_wide into tmp_wide
    x64MovImm64(edit code, 1, 0)
    hold copy_loop = code.bytes.length
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

    // Append UTF-16 ".tmp.0\0" (14 bytes)
    x64LoadSlot(edit code, 8, 11)
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
    x64MovImm64(edit code, 0, 48)
    x64StoreMem8(edit code, 8, 10, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 11, 0)
    x64StoreMem8(edit code, 8, 12, 0)
    x64StoreMem8(edit code, 8, 13, 0)

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
    hold not_created = wpfIf(edit code, 1, -1, 4)

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

    wpfPatchHere(edit code, not_created)
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

// samefile(RDI = address of path_a Text, RSI = address of path_b Text) -> RAX = Bool (0 or 1).
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
    x64StoreSlot(edit code, 8, 0) // result = 0

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

    // Open handle A: CreateFileW(dest_a, GENERIC_READ, WPF_SHARE_ALL, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
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
    failed@push(wpfIf(edit code, 1, -1, 4))

    // Open handle B: CreateFileW(dest_b, GENERIC_READ, WPF_SHARE_ALL, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
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

    give entry
}

// Emits the Windows platform runtime; returns the entry of each operation,
// indexed by the ELE-LIR platform codes pfArgCount() .. pfWriteBytes(), like
// native_rt_platform's pfEmitAll. Its absolute addresses: none (tables are
// reached RIP-relative), so it adds no base relocation.
expose flow w64EmitPlatform(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime) => List of[Int] {
    hold utf8 = pfEmitUtf8(edit code)
    hold path_z = pfEmitPathZ(edit code, rt)
    hold write_handle = wpfEmitWriteHandle(edit code, edit imports)
    hold wide_z = wpfEmitWideZ(edit code, edit imports, rt)
    hold scan = wpfEmitScan(edit code, edit imports)
    change at: List of[Int] = List[]
    at@push(wpfEmitArgCount(edit code, scan))
    at@push(wpfEmitArg(edit code, edit imports, rt, scan))
    at@push(wpfEmitReadText(edit code, edit imports, rt, utf8, path_z, wide_z))
    at@push(wpfEmitPrintError(edit code, edit imports, write_handle))
    at@push(wpfEmitWriteBytes(edit code, edit imports, rt, path_z, wide_z, write_handle))
    at@push(wpfEmitSameFile(edit code, edit imports, rt, path_z, wide_z))
    give at
}
