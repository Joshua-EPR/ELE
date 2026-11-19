take x86_64

// Platform runtime of the ELE-written Linux x86-64 backend: the five
// `i platform` operations of ELE-LIR 1 (processArgCount, processArg,
// readText, printError, writeBytes), as raw system calls. No libc, no Rust.
//
// Contract (crates/l/src/backend/platform_runtime.inc.rs and
// platform_contract.inc.rs, which Stage 0 implements on every host):
//   argcount           -> Int: arguments after the program name.
//   arg(i)             -> Result<Text,Int>: Err(1) out of range, Err(2) not
//                         UTF-8.
//   readtext(path, n)  -> Result<Text,Int>: Err(1) bad limit (outside
//                         0..=64 MiB) or path, Err(2) not found, Err(3) other
//                         I/O failure or not a regular file, Err(4) not
//                         UTF-8, Err(5) larger than the limit.
//   printerror(text)   -> the text and a line feed on stderr; errors ignored.
//   writebytes(path, l)-> Int: 0 ok, 1 bad path/byte/length (validated before
//                         the file is created), 2 cannot create, 3 write
//                         failed.
// A valid path is non-empty, at most 131068 bytes, has no NUL byte and does
// not start with a `//./` or `//?/` device prefix (either slash).
//
// Convention, as in native_rt: arguments in RDI, RSI, RDX; result in RAX;
// RAX, RCX, RDX, RSI, RDI and R8-R11 are scratch. A Result<Text,Int> is the
// CFG enum layout: tag word (0 Ok, 1 Err), then the Text words (address,
// byte length, capacity) or the Int; every payload word is written.
//
// The initial stack pointer (argc, argv...) is read from the first word of
// the image's read-write data page, stored there by the entry stub. Each
// MOV of that page's address is recorded in `data_at` and patched by the
// caller once the final image size, hence the page address, is known.

expose flow pfArgCount() => Int { give 0 }
expose flow pfArg() => Int { give 1 }
expose flow pfReadText() => Int { give 2 }
expose flow pfPrintError() => Int { give 3 }
expose flow pfWriteBytes() => Int { give 4 }

// Addresses of the routines of native_rt that the platform runtime calls.
expose shape PfRuntime {
    text_new: Int
    text_drop: Int
}

flow pfCall(code: edit X64Code, target: Int) {
    hold at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

flow pfJumpTo(code: edit X64Code, target: Int) {
    hold at = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

flow pfAdjust(code: edit X64Code, reg: Int, delta: Int) {
    x64MovImm64(edit code, 10, delta)
    x64AddReg(edit code, reg, 10)
}

// Jumps (placeholder returned) when `left` <cond> `right` holds, with the
// signed conditions of x64SetCondition (4 eq, 5 ne, 6 lt, 7 le, 8 gt, 9 ge).
// Clobbers RAX; `left` and `right` must not be RAX.
flow pfIfReg(code: edit X64Code, left: Int, right: Int, cond: Int) => Int {
    x64CmpReg(edit code, left, right)
    x64SetCondition(edit code, cond)
    x64TestRax(edit code)
    give x64ConditionalPlaceholder(edit code, false)
}

// The same against a constant, held in R10. Clobbers RAX and R10.
flow pfIf(code: edit X64Code, left: Int, value: Int, cond: Int) => Int {
    x64MovImm64(edit code, 10, value)
    give pfIfReg(edit code, left, 10, cond)
}

flow pfPatchAll(code: edit X64Code, at: view List of[Int]) {
    hold here = code.bytes.length
    each i among 0..at.length { x64PatchRelative(edit code, at[i], here) }
}

// MOV reg, <address of the read-write data page>, patched later.
flow pfLoadData(code: edit X64Code, reg: Int, data_at: edit List of[Int]) {
    x64MovImm64(edit code, reg, 0)
    data_at@push(code.bytes.length - 8)
}

// Byte classes of the UTF-8 automaton (RFC 3629): 0 ASCII, 1 80..8F,
// 2 90..9F, 3 A0..BF, 4 C2..DF, 5 E0, 6 E1..EC and EE..EF, 7 ED, 8 F0,
// 9 F1..F3, 10 F4, 11 never valid (C0, C1, F5..FF).
flow pfUtf8Class(b: Int) => Int {
    when b < 128 { give 0 }
    when b < 144 { give 1 }
    when b < 160 { give 2 }
    when b < 192 { give 3 }
    when b < 194 { give 11 }
    when b < 224 { give 4 }
    when b == 224 { give 5 }
    when b == 237 { give 7 }
    when b < 240 { give 6 }
    when b == 240 { give 8 }
    when b < 244 { give 9 }
    when b == 244 { give 10 }
    give 11
}

// States: 0 accept, 1 reject (absorbing), 2 one continuation left, 3 two
// left, 4 after E0 (A0..BF next), 5 after ED (80..9F next, no surrogates),
// 6 three left, 7 after F0 (90..BF next), 8 after F4 (80..8F next).
// Overlong forms, surrogates and code points above U+10FFFF are rejected.
flow pfUtf8Next(state: Int, cls: Int) => Int {
    hold cont = cls >= 1 && cls <= 3
    when state == 0 {
        when cls == 0 { give 0 }
        when cls == 4 { give 2 }
        when cls == 5 { give 4 }
        when cls == 6 { give 3 }
        when cls == 7 { give 5 }
        when cls == 8 { give 7 }
        when cls == 9 { give 6 }
        when cls == 10 { give 8 }
        give 1
    }
    when state == 2 && cont { give 0 }
    when state == 3 && cont { give 2 }
    when state == 4 && cls == 3 { give 2 }
    when state == 5 && (cls == 1 || cls == 2) { give 2 }
    when state == 6 && cont { give 3 }
    when state == 7 && (cls == 2 || cls == 3) { give 3 }
    when state == 8 && cls == 1 { give 3 }
    give 1
}

// utf8_valid(RDI = bytes, RSI = count) -> RAX = 1 valid, 0 invalid.
// The class table (256 bytes) and the transition table (9 x 12 bytes) are
// emitted in front of the routine, after the `ret` of the previous one, and
// reached RIP-relative. Returns the entry address.
expose flow pfEmitUtf8(code: edit X64Code) => Int {
    hold classes = code.bytes.length
    each b among 0..256 { code.bytes@push(pfUtf8Class(b)) }
    hold next = code.bytes.length
    each s among 0..9 {
        each c among 0..12 { code.bytes@push(pfUtf8Next(s, c)) }
    }
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    hold class_at = x64LeaRipPlaceholder(edit code, 8)
    x64PatchRelative(edit code, class_at, classes)
    hold next_at = x64LeaRipPlaceholder(edit code, 9)
    x64PatchRelative(edit code, next_at, next)
    // RDX = state.
    x64MovImm64(edit code, 2, 0)
    hold top = code.bytes.length
    x64MovReg(edit code, 0, 6)
    x64TestRax(edit code)
    hold done = x64ConditionalPlaceholder(edit code, true)
    x64LoadMem8(edit code, 1, 7, 0)
    x64AddReg(edit code, 1, 8)
    x64LoadMem8(edit code, 1, 1, 0)
    x64MovImm64(edit code, 0, 12)
    x64MulReg(edit code, 0, 2)
    x64AddReg(edit code, 0, 1)
    x64AddReg(edit code, 0, 9)
    x64LoadMem8(edit code, 2, 0, 0)
    pfAdjust(edit code, 7, 1)
    pfAdjust(edit code, 6, -1)
    pfJumpTo(edit code, top)
    hold end_at = code.bytes.length
    x64PatchRelative(edit code, done, end_at)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 2, 1)
    x64SetCondition(edit code, 4)
    x64FrameEnd(edit code)
    give entry
}

// write_fd(RDI = fd, RSI = bytes, RDX = count) -> RAX = 0, or -1 when a
// write fails. EINTR is retried; a write of zero bytes counts as failure.
// RDI, RSI and RDX survive `syscall`, which clobbers RCX and R11 only.
flow pfEmitWriteFd(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    hold top = code.bytes.length
    x64MovReg(edit code, 0, 2)
    x64TestRax(edit code)
    hold finished = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 0, 1)
    x64Syscall(edit code)
    x64MovReg(edit code, 9, 0)
    hold failed = pfIf(edit code, 9, 0, 7)
    x64AddReg(edit code, 6, 9)
    x64SubReg(edit code, 2, 9)
    pfJumpTo(edit code, top)
    hold failed_at = code.bytes.length
    x64PatchRelative(edit code, failed, failed_at)
    hold interrupted = pfIf(edit code, 9, -4, 4)
    x64PatchRelative(edit code, interrupted, top)
    x64MovImm64(edit code, 0, -1)
    x64FrameEnd(edit code)
    hold ok_at = code.bytes.length
    x64PatchRelative(edit code, finished, ok_at)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    give entry
}

// Jumps to the returned placeholder unless the byte at [R8 + offset] is
// `/` or `\`. Clobbers RAX, RCX and R10.
flow pfNotSlash(code: edit X64Code, offset: Int) => Int {
    x64LoadMem8(edit code, 1, 8, offset)
    hold slash = pfIf(edit code, 1, 47, 4)
    hold backslash = pfIf(edit code, 1, 92, 4)
    hold other = x64JumpPlaceholder(edit code)
    hold yes = code.bytes.length
    x64PatchRelative(edit code, slash, yes)
    x64PatchRelative(edit code, backslash, yes)
    give other
}

// path_z(RDI = address of a Text) -> RAX = owned buffer holding the path
// and a NUL byte, RDX = its capacity; RAX = 0 when the path is invalid.
expose flow pfEmitPathZ(code: edit X64Code, rt: view PfRuntime) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 4)
    x64LoadMem64(edit code, 8, 7, 0)
    x64LoadMem64(edit code, 9, 7, 8)
    x64StoreSlot(edit code, 0, 8)
    x64StoreSlot(edit code, 1, 9)
    change invalid: List of[Int] = List[]
    x64MovReg(edit code, 1, 9)
    invalid@push(pfIf(edit code, 1, 0, 7))
    invalid@push(pfIf(edit code, 1, 131068, 8))
    // No NUL byte.
    x64MovImm64(edit code, 1, 0)
    hold scan = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold scanned = pfIfReg(edit code, 1, 2, 9)
    x64LoadSlot(edit code, 8, 0)
    x64AddReg(edit code, 8, 1)
    x64LoadMem8(edit code, 0, 8, 0)
    x64TestRax(edit code)
    invalid@push(x64ConditionalPlaceholder(edit code, true))
    pfAdjust(edit code, 1, 1)
    pfJumpTo(edit code, scan)
    hold scanned_at = code.bytes.length
    x64PatchRelative(edit code, scanned, scanned_at)
    // No `//./` or `//?/` device prefix.
    change prefix_ok: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 1)
    prefix_ok@push(pfIf(edit code, 1, 4, 6))
    x64LoadSlot(edit code, 8, 0)
    prefix_ok@push(pfNotSlash(edit code, 0))
    prefix_ok@push(pfNotSlash(edit code, 1))
    prefix_ok@push(pfNotSlash(edit code, 3))
    x64LoadMem8(edit code, 1, 8, 2)
    invalid@push(pfIf(edit code, 1, 46, 4))
    invalid@push(pfIf(edit code, 1, 63, 4))
    pfPatchAll(edit code, view prefix_ok)
    // Copy into a fresh buffer and terminate it.
    x64LoadSlot(edit code, 7, 1)
    pfAdjust(edit code, 7, 1)
    pfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovReg(edit code, 7, 0)
    x64LoadSlot(edit code, 6, 0)
    x64LoadSlot(edit code, 1, 1)
    x64RepMovsb(edit code)
    x64MovImm64(edit code, 1, 0)
    x64StoreMem8(edit code, 7, 0, 1)
    x64LoadSlot(edit code, 0, 2)
    x64LoadSlot(edit code, 2, 3)
    x64FrameEnd(edit code)
    pfPatchAll(edit code, view invalid)
    x64MovImm64(edit code, 0, 0)
    x64MovImm64(edit code, 2, 0)
    x64FrameEnd(edit code)
    give entry
}

// Writes Err(RCX) into the Result<Text,Int> whose address is in R11.
expose flow pfStoreErr(code: edit X64Code) {
    x64MovImm64(edit code, 0, 1)
    x64StoreMem64(edit code, 11, 0, 0)
    x64StoreMem64(edit code, 11, 8, 1)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem64(edit code, 11, 16, 0)
    x64StoreMem64(edit code, 11, 24, 0)
}

// argcount() -> RAX = argc - 1, never negative.
flow pfEmitArgCount(code: edit X64Code, data_at: edit List of[Int]) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    pfLoadData(edit code, 0, edit data_at)
    x64LoadMem64(edit code, 0, 0, 0)
    x64LoadMem64(edit code, 1, 0, 0)
    pfAdjust(edit code, 1, -1)
    hold counted = pfIf(edit code, 1, 0, 9)
    x64MovImm64(edit code, 1, 0)
    hold counted_at = code.bytes.length
    x64PatchRelative(edit code, counted, counted_at)
    x64MovReg(edit code, 0, 1)
    x64FrameEnd(edit code)
    give entry
}

// arg(RDI = index, RSI = address of the Result<Text,Int>): copies
// argv[index + 1] into a new owned Text.
flow pfEmitArg(code: edit X64Code, rt: view PfRuntime, utf8: Int, data_at: edit List of[Int]) => Int {
    hold entry = code.bytes.length
    // Slots: 0 result, 1 index, 2 source bytes, 3 length, 4 buffer, 5 capacity.
    x64FrameBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 6)
    x64StoreSlot(edit code, 1, 7)
    change out_of_range: List of[Int] = List[]
    x64MovReg(edit code, 1, 7)
    out_of_range@push(pfIf(edit code, 1, 0, 6))
    pfLoadData(edit code, 0, edit data_at)
    x64LoadMem64(edit code, 8, 0, 0)
    x64LoadMem64(edit code, 9, 8, 0)
    pfAdjust(edit code, 9, -1)
    x64LoadSlot(edit code, 1, 1)
    out_of_range@push(pfIfReg(edit code, 1, 9, 9))
    // argv[index + 1] is at initial RSP + 16 + 8 * index.
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 0, 0, 16)
    x64StoreSlot(edit code, 2, 0)
    // Its byte length, up to the NUL terminator.
    x64MovImm64(edit code, 1, 0)
    hold scan = code.bytes.length
    x64LoadSlot(edit code, 2, 2)
    x64AddReg(edit code, 2, 1)
    x64LoadMem8(edit code, 0, 2, 0)
    x64TestRax(edit code)
    hold ended = x64ConditionalPlaceholder(edit code, true)
    pfAdjust(edit code, 1, 1)
    pfJumpTo(edit code, scan)
    hold ended_at = code.bytes.length
    x64PatchRelative(edit code, ended, ended_at)
    x64StoreSlot(edit code, 3, 1)
    x64LoadSlot(edit code, 7, 2)
    x64LoadSlot(edit code, 6, 3)
    pfCall(edit code, utf8)
    x64TestRax(edit code)
    hold not_utf8 = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 7, 3)
    pfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 2)
    x64MovReg(edit code, 7, 0)
    x64LoadSlot(edit code, 6, 2)
    x64LoadSlot(edit code, 1, 3)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 11, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem64(edit code, 11, 0, 0)
    x64LoadSlot(edit code, 0, 4)
    x64StoreMem64(edit code, 11, 8, 0)
    x64LoadSlot(edit code, 0, 3)
    x64StoreMem64(edit code, 11, 16, 0)
    x64LoadSlot(edit code, 0, 5)
    x64StoreMem64(edit code, 11, 24, 0)
    x64FrameEnd(edit code)
    pfPatchAll(edit code, view out_of_range)
    x64MovImm64(edit code, 1, 1)
    hold store_err = x64JumpPlaceholder(edit code)
    hold not_utf8_at = code.bytes.length
    x64PatchRelative(edit code, not_utf8, not_utf8_at)
    x64MovImm64(edit code, 1, 2)
    hold store_err_at = code.bytes.length
    x64PatchRelative(edit code, store_err, store_err_at)
    x64LoadSlot(edit code, 11, 0)
    pfStoreErr(edit code)
    x64FrameEnd(edit code)
    give entry
}

// printerror(RDI = bytes, RSI = count): the text and a line feed on fd 2.
flow pfEmitPrintError(code: edit X64Code, write_fd: Int) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 2)
    x64MovReg(edit code, 2, 6)
    x64MovReg(edit code, 6, 7)
    x64MovImm64(edit code, 7, 2)
    pfCall(edit code, write_fd)
    x64MovImm64(edit code, 0, 10)
    x64StoreMem64(edit code, 5, -8, 0)
    x64MovReg(edit code, 6, 5)
    pfAdjust(edit code, 6, -8)
    x64MovImm64(edit code, 2, 1)
    x64MovImm64(edit code, 7, 2)
    pfCall(edit code, write_fd)
    x64FrameEnd(edit code)
    give entry
}

// Error exits of readtext: each sets the status (slot 8), runs its cleanup
// and stores Err(status). Cleanup bit 1 closes the file (slot 4), bit 2
// releases the buffer (slots 5, 6).
flow pfReadFail(code: edit X64Code, rt: view PfRuntime, from: view List of[Int], status: Int, cleanup: Int) {
    pfPatchAll(edit code, from)
    x64MovImm64(edit code, 0, status)
    x64StoreSlot(edit code, 8, 0)
    when cleanup == 1 || cleanup == 3 {
        x64LoadSlot(edit code, 7, 4)
        x64MovImm64(edit code, 0, 3)
        x64Syscall(edit code)
    }
    when cleanup >= 2 {
        x64LoadSlot(edit code, 7, 5)
        x64LoadSlot(edit code, 6, 6)
        pfCall(edit code, rt.text_drop)
    }
    x64LoadSlot(edit code, 1, 8)
    x64LoadSlot(edit code, 11, 0)
    pfStoreErr(edit code)
    x64FrameEnd(edit code)
}

// readtext(RDI = address of the path Text, RSI = limit, RDX = address of
// the Result<Text,Int>).
flow pfEmitReadText(code: edit X64Code, rt: view PfRuntime, utf8: Int, path_z: Int) => Int {
    hold entry = code.bytes.length
    // Slots: 0 result, 1 limit, 2 path buffer, 3 its capacity, 4 fd,
    // 5 buffer, 6 capacity, 7 length, 8 status; 10..27 struct stat.
    x64FrameBegin(edit code, 28)
    x64StoreSlot(edit code, 0, 2)
    x64StoreSlot(edit code, 1, 6)
    change bad_input: List of[Int] = List[]
    change not_found: List of[Int] = List[]
    change io_error: List of[Int] = List[]
    change io_error_open: List of[Int] = List[]
    change io_error_read: List of[Int] = List[]
    change too_large: List of[Int] = List[]
    change not_utf8: List of[Int] = List[]
    x64MovReg(edit code, 1, 6)
    bad_input@push(pfIf(edit code, 1, 0, 6))
    bad_input@push(pfIf(edit code, 1, 67108864, 8))
    pfCall(edit code, path_z)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovReg(edit code, 1, 0)
    bad_input@push(pfIf(edit code, 1, 0, 4))
    // open(path, O_RDONLY | O_CLOEXEC), then release the path buffer.
    x64LoadSlot(edit code, 7, 2)
    x64MovImm64(edit code, 6, 524288)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 0, 2)
    x64Syscall(edit code)
    x64StoreSlot(edit code, 4, 0)
    x64LoadSlot(edit code, 7, 2)
    x64LoadSlot(edit code, 6, 3)
    pfCall(edit code, rt.text_drop)
    x64LoadSlot(edit code, 1, 4)
    hold opened = pfIf(edit code, 1, 0, 9)
    not_found@push(pfIf(edit code, 1, -2, 4))
    io_error@push(x64JumpPlaceholder(edit code))
    hold opened_at = code.bytes.length
    x64PatchRelative(edit code, opened, opened_at)
    // fstat(fd, stat): a regular file, (st_mode & S_IFMT) == S_IFREG.
    x64LoadSlot(edit code, 7, 4)
    x64MovReg(edit code, 6, 5)
    pfAdjust(edit code, 6, -224)
    x64MovImm64(edit code, 0, 5)
    x64Syscall(edit code)
    x64MovReg(edit code, 1, 0)
    io_error_open@push(pfIf(edit code, 1, 0, 5))
    x64LoadMem64(edit code, 1, 5, -200)
    x64MovImm64(edit code, 10, 61440)
    x64AndReg(edit code, 1, 10)
    io_error_open@push(pfIf(edit code, 1, 32768, 5))
    // A buffer of limit + 1 bytes: one more than allowed detects excess.
    x64LoadSlot(edit code, 7, 1)
    pfAdjust(edit code, 7, 1)
    pfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 6, 2)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 7, 0)
    hold read_more = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    pfAdjust(edit code, 2, 1)
    x64LoadSlot(edit code, 1, 7)
    x64SubReg(edit code, 2, 1)
    x64LoadSlot(edit code, 6, 5)
    x64AddReg(edit code, 6, 1)
    x64LoadSlot(edit code, 7, 4)
    x64MovImm64(edit code, 0, 0)
    x64Syscall(edit code)
    x64MovReg(edit code, 9, 0)
    hold eof = pfIf(edit code, 9, 0, 4)
    hold failed = pfIf(edit code, 9, 0, 6)
    x64LoadSlot(edit code, 1, 7)
    x64AddReg(edit code, 1, 9)
    x64StoreSlot(edit code, 7, 1)
    x64LoadSlot(edit code, 9, 1)
    too_large@push(pfIfReg(edit code, 1, 9, 8))
    pfJumpTo(edit code, read_more)
    hold failed_at = code.bytes.length
    x64PatchRelative(edit code, failed, failed_at)
    hold interrupted = pfIf(edit code, 9, -4, 4)
    x64PatchRelative(edit code, interrupted, read_more)
    io_error_read@push(x64JumpPlaceholder(edit code))
    hold eof_at = code.bytes.length
    x64PatchRelative(edit code, eof, eof_at)
    x64LoadSlot(edit code, 7, 4)
    x64MovImm64(edit code, 0, 3)
    x64Syscall(edit code)
    x64LoadSlot(edit code, 7, 5)
    x64LoadSlot(edit code, 6, 7)
    pfCall(edit code, utf8)
    x64TestRax(edit code)
    not_utf8@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 11, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem64(edit code, 11, 0, 0)
    x64LoadSlot(edit code, 0, 5)
    x64StoreMem64(edit code, 11, 8, 0)
    x64LoadSlot(edit code, 0, 7)
    x64StoreMem64(edit code, 11, 16, 0)
    x64LoadSlot(edit code, 0, 6)
    x64StoreMem64(edit code, 11, 24, 0)
    x64FrameEnd(edit code)
    pfReadFail(edit code, rt, view bad_input, 1, 0)
    pfReadFail(edit code, rt, view not_found, 2, 0)
    pfReadFail(edit code, rt, view io_error, 3, 0)
    pfReadFail(edit code, rt, view io_error_open, 3, 1)
    pfReadFail(edit code, rt, view io_error_read, 3, 3)
    pfReadFail(edit code, rt, view too_large, 5, 3)
    pfReadFail(edit code, rt, view not_utf8, 4, 2)
    give entry
}

// writebytes(RDI = address of the path Text, RSI = address of the
// List of[Int] header) -> RAX = status.
flow pfEmitWriteBytes(code: edit X64Code, rt: view PfRuntime, path_z: Int, write_fd: Int) => Int {
    hold entry = code.bytes.length
    // Slots: 0 path Text address, 1 length, 2 path buffer, 3 its capacity,
    // 4 byte buffer, 5 its capacity, 6 fd, 7 status, 8 elements.
    x64FrameBegin(edit code, 10)
    x64StoreSlot(edit code, 0, 7)
    x64LoadMem64(edit code, 8, 6, 0)
    x64LoadMem64(edit code, 9, 6, 8)
    x64StoreSlot(edit code, 8, 8)
    x64StoreSlot(edit code, 1, 9)
    change invalid: List of[Int] = List[]
    x64MovReg(edit code, 1, 9)
    invalid@push(pfIf(edit code, 1, 67108864, 8))
    // Every element is a byte, checked before anything is created.
    x64MovImm64(edit code, 1, 0)
    hold check = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold checked = pfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 8)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 0, 0, 0)
    x64MovImm64(edit code, 10, 256)
    x64CmpReg(edit code, 0, 10)
    invalid@push(x64AboveEqualPlaceholder(edit code))
    pfAdjust(edit code, 1, 1)
    pfJumpTo(edit code, check)
    hold checked_at = code.bytes.length
    x64PatchRelative(edit code, checked, checked_at)
    x64LoadSlot(edit code, 7, 0)
    pfCall(edit code, path_z)
    x64StoreSlot(edit code, 2, 0)
    x64StoreSlot(edit code, 3, 2)
    x64MovReg(edit code, 1, 0)
    invalid@push(pfIf(edit code, 1, 0, 4))
    // The bytes, packed.
    x64LoadSlot(edit code, 7, 1)
    pfCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 5, 2)
    x64MovImm64(edit code, 1, 0)
    hold pack = code.bytes.length
    x64LoadSlot(edit code, 2, 1)
    hold packed = pfIfReg(edit code, 1, 2, 9)
    x64MovReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 0, 10)
    x64LoadSlot(edit code, 8, 8)
    x64AddReg(edit code, 0, 8)
    x64LoadMem64(edit code, 2, 0, 0)
    x64LoadSlot(edit code, 0, 4)
    x64AddReg(edit code, 0, 1)
    x64StoreMem8(edit code, 0, 0, 2)
    pfAdjust(edit code, 1, 1)
    pfJumpTo(edit code, pack)
    hold packed_at = code.bytes.length
    x64PatchRelative(edit code, packed, packed_at)
    // open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644).
    x64LoadSlot(edit code, 7, 2)
    x64MovImm64(edit code, 6, 524865)
    x64MovImm64(edit code, 2, 420)
    x64MovImm64(edit code, 0, 2)
    x64Syscall(edit code)
    x64StoreSlot(edit code, 6, 0)
    x64LoadSlot(edit code, 7, 2)
    x64LoadSlot(edit code, 6, 3)
    pfCall(edit code, rt.text_drop)
    x64LoadSlot(edit code, 1, 6)
    hold not_created = pfIf(edit code, 1, 0, 6)
    x64LoadSlot(edit code, 7, 6)
    x64LoadSlot(edit code, 6, 4)
    x64LoadSlot(edit code, 2, 1)
    pfCall(edit code, write_fd)
    // Status 0, or 3 when write_fd reported -1.
    x64MovImm64(edit code, 10, -3)
    x64MulReg(edit code, 0, 10)
    x64StoreSlot(edit code, 7, 0)
    x64LoadSlot(edit code, 7, 6)
    x64MovImm64(edit code, 0, 3)
    x64Syscall(edit code)
    x64LoadSlot(edit code, 7, 4)
    x64LoadSlot(edit code, 6, 5)
    pfCall(edit code, rt.text_drop)
    x64LoadSlot(edit code, 0, 7)
    x64FrameEnd(edit code)
    hold not_created_at = code.bytes.length
    x64PatchRelative(edit code, not_created, not_created_at)
    x64LoadSlot(edit code, 7, 4)
    x64LoadSlot(edit code, 6, 5)
    pfCall(edit code, rt.text_drop)
    x64MovImm64(edit code, 0, 2)
    x64FrameEnd(edit code)
    pfPatchAll(edit code, view invalid)
    x64MovImm64(edit code, 0, 1)
    x64FrameEnd(edit code)
    give entry
}

// Emits the platform runtime; returns the entry of each operation, indexed
// by the ELE-LIR platform codes pfArgCount() .. pfWriteBytes().
expose flow pfEmitAll(code: edit X64Code, rt: view PfRuntime, data_at: edit List of[Int]) => List of[Int] {
    hold utf8 = pfEmitUtf8(edit code)
    hold write_fd = pfEmitWriteFd(edit code)
    hold path_z = pfEmitPathZ(edit code, rt)
    change at: List of[Int] = List[]
    at@push(pfEmitArgCount(edit code, edit data_at))
    at@push(pfEmitArg(edit code, rt, utf8, edit data_at))
    at@push(pfEmitReadText(edit code, rt, utf8, path_z))
    at@push(pfEmitPrintError(edit code, write_fd))
    at@push(pfEmitWriteBytes(edit code, rt, path_z, write_fd))
    give at
}
