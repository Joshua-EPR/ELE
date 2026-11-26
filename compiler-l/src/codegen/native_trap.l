take lir_tokens
take native_cfg_defs
take native_cfg_text
take x86_64
take pe64
take win64_rt

// Run-time trap diagnostics of the CFG backend (ELF64 and PE32+).
//
// A failed run-time check writes one line to standard error and then
// exits with the status of its kind, which this file does not change:
//
//   125  ": overflow entero o división/resto por cero"   (arithmetic)
//   126  ": acceso a variante enum inactiva"            (checked payload)
//   127  ": índice fuera de rango"                      (byteAt, list index)
//
// The line follows Stage 0 (crates/l/src/native/runtime.rs): "ELE l:c"
// followed by the message when the LIR record carried ` @line:col`, and
// "ELE" followed by the message otherwise, e.g.
// "ELE 2:10: overflow entero o división/resto por cero".
//
// Layout. Every check is a Jcc rel32 collected in CfgFix (overflow_at,
// bad_variant_at, bad_index_at). Each one is patched to a stub that loads
// the packed position into RAX and jumps to the entry of its kind; the
// entry loads the message and the status and jumps to one shared reporter.
// Consecutive checks of the same kind and position (one instruction) share
// a stub. Nothing is emitted for a program without checks.

// Positions are packed as line * 2^20 + col (both 1..1000000, as accepted
// by nativeEndLineSpan); 0 means "no position".
flow trapColumnBase() => Int { give 1048576 }

expose flow trapPack(line: Int, col: Int) => Int {
    when line < 1 || col < 1 || line > 1000000 || col > 1000000 { give 0 }
    give line * trapColumnBase() + col
}

// Reads the optional ` @line:col` suffix at the reader without consuming
// it: nativeEndLineSpan validates and consumes it right after.
expose flow cfgReadSpan(source: view Text, reader: view NativeReader, inst: edit CfgInst) {
    change p = reader.offset
    when p + 1 >= source.byteLength || source@byteAt(p) != 32 || source@byteAt(p + 1) != 64 { give }
    p += 2
    change line = 0
    during p < source.byteLength && source@byteAt(p) >= 48 && source@byteAt(p) <= 57 && line <= 1000000 {
        line = line * 10 + source@byteAt(p) - 48
        p += 1
    }
    when p >= source.byteLength || source@byteAt(p) != 58 { give }
    p += 1
    change col = 0
    during p < source.byteLength && source@byteAt(p) >= 48 && source@byteAt(p) <= 57 && col <= 1000000 {
        col = col * 10 + source@byteAt(p) - 48
        p += 1
    }
    when trapPack(line, col) == 0 { give }
    inst.line = line
    inst.col = col
}

// Packed position of every check, parallel to the CfgFix lists.
expose shape TrapSpans {
    overflow: List of[Int]
    variant: List of[Int]
    index: List of[Int]
}

expose flow trapNewSpans() => TrapSpans {
    give TrapSpans(overflow: List[], variant: List[], index: List[])
}

// Gives `packed` to every check emitted since the previous call.
expose flow trapTag(spans: edit TrapSpans, fix: view CfgFix, packed: Int) {
    during spans.overflow.length < fix.overflow_at.length { spans.overflow@push(packed) }
    during spans.variant.length < fix.bad_variant_at.length { spans.variant@push(packed) }
    during spans.index.length < fix.bad_index_at.length { spans.index@push(packed) }
}

// R8 -= 1; [R8] = `value` (one byte). Clobbers RCX and R10.
flow trapPutByte(code: edit X64Code, value: Int) {
    x64MovImm64(edit code, 10, -1)
    x64AddReg(edit code, 8, 10)
    x64MovImm32Zx(edit code, 1, value)
    x64StoreMem8(edit code, 8, 0, 1)
}

// Writes the decimal digits of the unsigned RAX downwards ending at R8,
// leaving R8 on the first digit. Clobbers RAX, RCX, RDX and R10.
flow trapPutDigits(code: edit X64Code) {
    hold top = code.bytes.length
    x64MovImm32Zx(edit code, 2, 0)
    x64MovImm32Zx(edit code, 1, 10)
    x64DivUnsignedReg(edit code, 1)
    x64MovImm32Zx(edit code, 10, 48)
    x64AddReg(edit code, 2, 10)
    x64MovImm64(edit code, 10, -1)
    x64AddReg(edit code, 8, 10)
    x64StoreMem8(edit code, 8, 0, 2)
    x64TestRax(edit code)
    hold more = x64ConditionalPlaceholder(edit code, false)
    x64PatchRelative(edit code, more, top)
}

// Frame of the reporter: slot 0 status, 1 packed position then line,
// 2 first byte, 3 byte count, 4 bytes written (WriteFile). The line is
// built downwards from RBP + trapBufferEnd() inside the remaining slots.
flow trapFrameSlots() => Int { give 32 }
flow trapBufferEnd() => Int { give -40 }

// Reporter: RAX = packed position, RSI = message, RDX = its length,
// RDI = exit status. Writes "ELE[ line:col]<message>" to standard error
// in a single write and exits with the status; never returns.
flow trapEmitReporter(code: edit X64Code, imports: edit Pe64Imports, target: Int) {
    x64FrameBegin(edit code, trapFrameSlots())
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 0)
    // RDI = R8 = RBP + end - length; copy the message there.
    x64MovReg(edit code, 7, 5)
    x64MovImm64(edit code, 10, trapBufferEnd())
    x64AddReg(edit code, 7, 10)
    x64SubReg(edit code, 7, 2)
    x64MovReg(edit code, 8, 7)
    x64MovReg(edit code, 1, 2)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold unlocated = x64ConditionalPlaceholder(edit code, true)
    // RAX = line, RDX = column.
    x64MovImm32Zx(edit code, 2, 0)
    x64MovImm32Zx(edit code, 1, trapColumnBase())
    x64DivUnsignedReg(edit code, 1)
    x64StoreSlot(edit code, 1, 0)
    x64MovReg(edit code, 0, 2)
    trapPutDigits(edit code)
    trapPutByte(edit code, 58)
    x64LoadSlot(edit code, 0, 1)
    trapPutDigits(edit code)
    trapPutByte(edit code, 32)
    hold prefix = code.bytes.length
    x64PatchRelative(edit code, unlocated, prefix)
    trapPutByte(edit code, 69)
    trapPutByte(edit code, 76)
    trapPutByte(edit code, 69)
    // RDX = RBP + end - R8.
    x64MovReg(edit code, 2, 5)
    x64MovImm64(edit code, 10, trapBufferEnd())
    x64AddReg(edit code, 2, 10)
    x64SubReg(edit code, 2, 8)
    when target == 1 {
        x64StoreSlot(edit code, 2, 8)
        x64StoreSlot(edit code, 3, 2)
        // 32 shadow bytes + the fifth argument, rounded to 16.
        w64AlignStack(edit code, 48)
        x64MovImm64(edit code, 1, -12)
        w64CallImport(edit code, edit imports, pe64ImportGetStdHandle())
        x64MovReg(edit code, 1, 0)                  // hFile
        x64MovImm32Zx(edit code, 0, 0)
        x64StoreSlot(edit code, 4, 0)
        x64StoreMem64(edit code, 4, 32, 0)          // lpOverlapped = NULL
        x64LoadSlot(edit code, 2, 2)                // lpBuffer
        x64LoadSlot(edit code, 8, 3)                // nNumberOfBytesToWrite
        x64LeaMem(edit code, 9, 5, -40)             // lpNumberOfBytesWritten
        w64CallImport(edit code, edit imports, pe64ImportWriteFile())
        x64LoadSlot(edit code, 1, 0)
        w64EmitExitRcx(edit code, edit imports)
        give
    }
    // write(2, R8, RDX), then exit(status).
    x64MovReg(edit code, 6, 8)
    x64MovImm32Zx(edit code, 7, 2)
    x64MovImm32Zx(edit code, 0, 1)
    x64Syscall(edit code)
    x64LoadSlot(edit code, 7, 0)
    x64MovImm32Zx(edit code, 0, 60)
    x64Syscall(edit code)
}

// Entry of one kind: message, status, jump to the reporter. The message
// bytes follow the jump inside the code.
flow trapEmitKind(code: edit X64Code, reporter: Int, message: view Text, status: Int) => Int {
    hold entry = code.bytes.length
    hold text_at = x64LeaRipPlaceholder(edit code, 6)
    x64MovImm32Zx(edit code, 2, message.byteLength)
    x64MovImm32Zx(edit code, 7, status)
    hold join = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, join, reporter)
    hold text = code.bytes.length
    each i among 0..message.byteLength { code.bytes@push(message@byteAt(i)) }
    x64PatchRelative(edit code, text_at, text)
    give entry
}

// One stub per run of equal positions; patches every check to its stub.
flow trapEmitStubs(code: edit X64Code, sites: view List of[Int], spans: view List of[Int], entry: Int) {
    change stub = -1
    change last = -1
    each i among 0..sites.length {
        change packed = 0
        when i < spans.length { packed = spans[i] }
        when stub < 0 || packed != last {
            stub = code.bytes.length
            last = packed
            when packed <= 4294967295 {
                x64MovImm32Zx(edit code, 0, packed)
            } otherwise {
                x64MovImm64(edit code, 0, packed)
            }
            hold join = x64JumpPlaceholder(edit code)
            x64PatchRelative(edit code, join, entry)
        }
        x64PatchRelative(edit code, sites[i], stub)
    }
}

// Emits the reporter, the entries of the kinds in use and their stubs, and
// patches every check of `fix`. Target 0 is ELF64 (Linux system calls),
// target 1 is PE32+ (KERNEL32 through the IAT).
expose flow trapEmitAll(code: edit X64Code, imports: edit Pe64Imports, target: Int, fix: view CfgFix, spans: view TrapSpans) {
    when fix.overflow_at.length + fix.bad_variant_at.length + fix.bad_index_at.length == 0 { give }
    hold reporter = code.bytes.length
    when target == 2 && fix.panic_entry >= 0 {
        // Kernel with `kpanico`: the block cfgBuildFor emitted just before.
        hold join = x64JumpPlaceholder(edit code)
        x64PatchRelative(edit code, join, fix.panic_entry)
    } otherwise when target == 2 {
        // Kernel: no output and nothing to exit to. The CPU stops with
        // RDI = status (125/126/127) and RAX = packed line/column, readable
        // with `info registers` in the QEMU monitor.
        x64HaltForever(edit code)
    } otherwise {
        trapEmitReporter(edit code, edit imports, target)
    }
    when fix.overflow_at.length > 0 {
        hold message = ": overflow entero o división/resto por cero\n"
        hold entry = trapEmitKind(edit code, reporter, view message, 125)
        trapEmitStubs(edit code, view fix.overflow_at, view spans.overflow, entry)
    }
    when fix.bad_variant_at.length > 0 {
        hold message = ": acceso a variante enum inactiva\n"
        hold entry = trapEmitKind(edit code, reporter, view message, 126)
        trapEmitStubs(edit code, view fix.bad_variant_at, view spans.variant, entry)
    }
    when fix.bad_index_at.length > 0 {
        hold message = ": índice fuera de rango\n"
        hold entry = trapEmitKind(edit code, reporter, view message, 127)
        trapEmitStubs(edit code, view fix.bad_index_at, view spans.index, entry)
    }
}
