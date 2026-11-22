take codegen.x86_64
take codegen.pe64
take codegen.win64_rt
take codegen.win64_callback

// Builds a PE image that receives three real Windows callbacks through the
// ELE Win64 callback adapters:
//   1. EnumSystemLocalesW (kernel32): one-word callback (w64EmitCallback1).
//   2. EnumResourceNamesW (kernel32): four-word callback (hModule, type,
//      name, lParam) through w64EmitCallback4.
//   3. CallWindowProcW (user32): the system dispatches a WndProc-shaped call
//      (hWnd, msg, wParam, lParam) through w64EmitCallback4 and returns the
//      callback's LRESULT to the caller.
// Each four-word target checks all of its arguments, prints a marker only
// when they are exact, and clobbers RDI and RSI (ELE scratch registers,
// Win64 nonvolatile). The entry checks that RDI, RSI and RBX survive each
// call, which proves the adapter restores what Windows requires.
shape Probe {
    code: X64Code
    entry: Int
}

// lParam = first argument + CB4_KEY, so a callback can check the pairing.
fixed CB4_KEY = 81985529216486895            // 0x0123456789ABCDEF
fixed WND_MSG = 32769                        // WM_APP + 1
fixed WND_WPARAM = -2                        // all 64 bits set but bit 0
fixed WND_RESULT = 1311768467463790320       // 0x123456789ABCDEF0
fixed SENTINEL_RDI = 6148914691236517205     // 0x5555555555555555
fixed SENTINEL_RSI = 3689348814741910323     // 0x3333333333333333
fixed SENTINEL_RBX = 1229782938247303441     // 0x1111111111111111

flow sameText(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength { give false }
    each i among 0..a.byteLength {
        when a@byteAt(i) != b@byteAt(i) { give false }
    }
    give true
}

flow pushWide(code: edit X64Code, text: view Text) => Int {
    hold at = code.bytes.length
    each i among 0..text.byteLength {
        code.bytes@push(text@byteAt(i))
        code.bytes@push(0)
    }
    code.bytes@push(0)
    code.bytes@push(0)
    give at
}

flow pushAscii(code: edit X64Code, text: view Text, terminate: Bool) => Int {
    hold at = code.bytes.length
    each i among 0..text.byteLength { code.bytes@push(text@byteAt(i)) }
    when terminate { code.bytes@push(0) }
    give at
}

// Jumps to the returned placeholder when `left` != `right` (neither RAX).
flow jumpIfNotEqual(code: edit X64Code, left: Int, right: Int) => Int {
    x64CmpReg(edit code, left, right)
    x64SetCondition(edit code, 5)
    x64TestRax(edit code)
    give x64ConditionalPlaceholder(edit code, false)
}

// A four-word callback target. Arguments are at [RBP+16], +24, +32, +40.
// Expected: arg4 == arg1 + CB4_KEY, low 32 bits of arg2 == `second` (a UINT
// message in WndProc), arg3 == `third`. On success it prints `marker`,
// clobbers RDI and RSI, and returns `result`; on mismatch it returns 0
// without printing.
flow emitTarget4(code: edit X64Code, write_all: Int, marker_at: Int, marker_len: Int, second: Int, third: Int, result: Int) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 0)
    change bad: List of[Int] = List[]
    x64LoadMem64(edit code, 1, 5, 16)
    x64MovImm64(edit code, 10, CB4_KEY)
    x64AddReg(edit code, 1, 10)
    x64LoadMem64(edit code, 11, 5, 40)
    bad@push(jumpIfNotEqual(edit code, 1, 11))
    x64LoadMem64(edit code, 1, 5, 24)
    x64MovImm64(edit code, 10, 4294967295)
    x64AndReg(edit code, 1, 10)
    x64MovImm64(edit code, 11, second)
    bad@push(jumpIfNotEqual(edit code, 1, 11))
    x64LoadMem64(edit code, 1, 5, 32)
    x64MovImm64(edit code, 11, third)
    bad@push(jumpIfNotEqual(edit code, 1, 11))
    hold marker_fix = x64LeaRipPlaceholder(edit code, 6) // RSI
    x64PatchRelative(edit code, marker_fix, marker_at)
    x64MovImm64(edit code, 2, marker_len)
    hold print_call = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, print_call, write_all)
    x64MovImm64(edit code, 7, 0) // clobber RDI
    x64MovImm64(edit code, 6, 0) // clobber RSI
    x64MovImm64(edit code, 0, result)
    x64FrameEnd(edit code)
    hold bad_at = code.bytes.length
    each i among 0..bad.length { x64PatchRelative(edit code, bad[i], bad_at) }
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    give entry
}

flow setSentinels(code: edit X64Code) {
    x64MovImm64(edit code, 7, SENTINEL_RDI)
    x64MovImm64(edit code, 6, SENTINEL_RSI)
    x64MovImm64(edit code, 3, SENTINEL_RBX)
}

// Placeholders that jump when a sentinel register was not preserved.
// Clobbers RAX and R10.
flow checkSentinels(code: edit X64Code, failed: edit List of[Int]) {
    x64MovImm64(edit code, 10, SENTINEL_RDI)
    failed@push(jumpIfNotEqual(edit code, 7, 10))
    x64MovImm64(edit code, 10, SENTINEL_RSI)
    failed@push(jumpIfNotEqual(edit code, 6, 10))
    x64MovImm64(edit code, 10, SENTINEL_RBX)
    failed@push(jumpIfNotEqual(edit code, 3, 10))
}

// ExitProcess(`status`).
flow exitWith(code: edit X64Code, imports: edit Pe64Imports, status: Int) {
    x64MovImm64(edit code, 1, status)
    w64EmitExitRcx(edit code, edit imports)
}

flow probeCode(imports: edit Pe64Imports) => Probe {
    change code = x64New()
    hold kernel32 = "kernel32.dll"
    hold dll_at = pushWide(edit code, view kernel32)
    hold user32 = "user32.dll"
    hold user_at = pushWide(edit code, view user32)
    hold proc = "EnumSystemLocalesW"
    hold proc_at = pushAscii(edit code, view proc, true)
    hold enum_name = "EnumResourceNamesW"
    hold enum_at = pushAscii(edit code, view enum_name, true)
    hold wnd_name = "CallWindowProcW"
    hold wnd_at = pushAscii(edit code, view wnd_name, true)
    hold marker = "callback-ok\n"
    hold marker_at = pushAscii(edit code, view marker, false)
    hold enum_marker = "callback4-enum-ok\n"
    hold enum_marker_at = pushAscii(edit code, view enum_marker, false)
    hold wnd_marker = "callback4-wndproc-ok\n"
    hold wnd_marker_at = pushAscii(edit code, view wnd_marker, false)

    hold runtime = w64EmitRuntime(edit code, edit imports)
    hold target = code.bytes.length
    x64FrameBegin(edit code, 0)
    hold marker_fix = x64LeaRipPlaceholder(edit code, 6) // RSI
    x64PatchRelative(edit code, marker_fix, marker_at)
    x64MovImm64(edit code, 2, marker.byteLength) // RDX
    hold print_call = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, print_call, runtime[0])
    x64MovImm64(edit code, 0, 0) // FALSE: stop enumeration
    x64FrameEnd(edit code)
    hold callback = w64EmitCallback1(edit code, target)

    // RT_VERSION (16), resource name 1, FALSE: stop after the first name.
    hold enum_target = emitTarget4(edit code, runtime[0], enum_marker_at, enum_marker.byteLength, 16, 1, 0)
    hold enum_callback = w64EmitCallback4(edit code, enum_target)
    hold wnd_target = emitTarget4(edit code, runtime[0], wnd_marker_at, wnd_marker.byteLength, WND_MSG, WND_WPARAM, WND_RESULT)
    hold wnd_callback = w64EmitCallback4(edit code, wnd_target)

    // PE entry. Keep RSP aligned with 32-byte shadow space plus room for one
    // stack argument (CallWindowProcW's lParam) for every Win64 call.
    // Slots: 0 kernel32, 1 EnumSystemLocalesW, 2 EnumResourceNamesW,
    // 3 user32, 4 CallWindowProcW.
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 5)
    w64AlignStack(edit code, 48)
    hold dll_fix = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, dll_fix, dll_at)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 2048) // LOAD_LIBRARY_SEARCH_SYSTEM32
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, 0, 0)
    x64TestRax(edit code)
    hold failed_load = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 1, 0)
    hold proc_fix = x64LeaRipPlaceholder(edit code, 2)
    x64PatchRelative(edit code, proc_fix, proc_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, 1, 0)
    x64TestRax(edit code)
    change failed_kernel: List of[Int] = List[]
    failed_kernel@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 1, 0)
    hold enum_fix = x64LeaRipPlaceholder(edit code, 2)
    x64PatchRelative(edit code, enum_fix, enum_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, 2, 0)
    x64TestRax(edit code)
    failed_kernel@push(x64ConditionalPlaceholder(edit code, true))

    // 0. A direct Win64 call of the WndProc adapter, as the system would
    //    make it. No system function sits between caller and adapter, so a
    //    lost RDI/RSI/RBX is visible here (a system caller restores its own
    //    nonvolatile registers and would hide it). The marker is printed
    //    once more by this call, so the expected output names it.
    change bad_registers: List of[Int] = List[]
    setSentinels(edit code)
    x64MovImm64(edit code, 1, 0)
    x64MovImm64(edit code, 2, WND_MSG)
    x64MovImm64(edit code, 8, WND_WPARAM)
    x64MovImm64(edit code, 9, CB4_KEY)
    hold direct_call = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, direct_call, wnd_callback)
    x64MovReg(edit code, 1, 0)
    x64MovImm64(edit code, 10, WND_RESULT)
    hold bad_direct = jumpIfNotEqual(edit code, 1, 10)
    checkSentinels(edit code, edit bad_registers)

    // 1. EnumSystemLocalesW(callback, LCID_SUPPORTED).
    hold callback_fix = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, callback_fix, callback)
    x64MovImm64(edit code, 2, 0)
    x64LoadSlot(edit code, 11, 1)
    x64CallReg(edit code, 11)

    // 2. EnumResourceNamesW(kernel32, RT_VERSION, callback4, kernel32 + KEY).
    setSentinels(edit code)
    x64LoadSlot(edit code, 1, 0)
    x64MovImm64(edit code, 2, 16)
    hold enum_cb_fix = x64LeaRipPlaceholder(edit code, 8)
    x64PatchRelative(edit code, enum_cb_fix, enum_callback)
    x64LoadSlot(edit code, 9, 0)
    x64MovImm64(edit code, 10, CB4_KEY)
    x64AddReg(edit code, 9, 10)
    x64LoadSlot(edit code, 11, 2)
    x64CallReg(edit code, 11)
    checkSentinels(edit code, edit bad_registers)

    // 3. user32!CallWindowProcW(callback4, NULL, WM_APP+1, -2, KEY).
    hold user_fix = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, user_fix, user_at)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 2048)
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, 3, 0)
    x64TestRax(edit code)
    hold failed_user = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 1, 3)
    hold wnd_fix = x64LeaRipPlaceholder(edit code, 2)
    x64PatchRelative(edit code, wnd_fix, wnd_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, 4, 0)
    x64TestRax(edit code)
    hold failed_wnd_proc = x64ConditionalPlaceholder(edit code, true)
    setSentinels(edit code)
    hold wnd_cb_fix = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, wnd_cb_fix, wnd_callback)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, WND_MSG)
    x64MovImm64(edit code, 9, WND_WPARAM)
    x64MovImm64(edit code, 0, CB4_KEY)
    x64StoreMem64(edit code, 4, 32, 0) // fifth argument: lParam
    x64LoadSlot(edit code, 11, 4)
    x64CallReg(edit code, 11)
    x64MovReg(edit code, 1, 0)
    x64MovImm64(edit code, 10, WND_RESULT)
    hold bad_result = jumpIfNotEqual(edit code, 1, 10)
    checkSentinels(edit code, edit bad_registers)

    x64LoadSlot(edit code, 1, 3)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    x64LoadSlot(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    exitWith(edit code, edit imports, 0)

    // Failures, each with its own exit status.
    hold bad_result_at = code.bytes.length
    x64PatchRelative(edit code, bad_result, bad_result_at)
    x64PatchRelative(edit code, bad_direct, bad_result_at)
    exitWith(edit code, edit imports, 8)
    hold bad_registers_at = code.bytes.length
    each i among 0..bad_registers.length { x64PatchRelative(edit code, bad_registers[i], bad_registers_at) }
    exitWith(edit code, edit imports, 7)
    hold wnd_failed_at = code.bytes.length
    x64PatchRelative(edit code, failed_wnd_proc, wnd_failed_at)
    x64PatchRelative(edit code, failed_user, wnd_failed_at)
    exitWith(edit code, edit imports, 6)
    hold kernel_failed_at = code.bytes.length
    each i among 0..failed_kernel.length { x64PatchRelative(edit code, failed_kernel[i], kernel_failed_at) }
    x64LoadSlot(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    hold load_failed_at = code.bytes.length
    x64PatchRelative(edit code, failed_load, load_failed_at)
    exitWith(edit code, edit imports, 2)
    give Probe(code: code, entry: entry)
}

flow main() => Int {
    when processArgCount() != 1 { give 1 }
    choose processArg(0) {
        Ok(path): {
            hold self_check = "--self-check"
            when sameText(view path, view self_check) {
                change bad = x64New()
                when w64EmitCallback1(edit bad, -1) != -1 || bad.error != 4 { give 5 }
                change bad4 = x64New()
                when w64EmitCallback4(edit bad4, 0) != -1 || bad4.error != 4 { give 6 }
                print("callback-negative-ok")
                give 0
            }
            change imports = pe64NewImports()
            hold probe = probeCode(edit imports)
            when probe.code.error != 0 { give 2 }
            // Every marker is printed inside a real callback, not at entry.
            hold image = pe64Executable(view probe.code.bytes, probe.entry, view imports)
            when image.error != 0 { give 3 }
            give writeBytes(path, image.bytes)
        }
        Err(code): { give 4 }
    }
}
