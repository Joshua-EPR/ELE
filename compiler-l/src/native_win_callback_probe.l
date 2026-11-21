take codegen.x86_64
take codegen.pe64
take codegen.win64_rt
take codegen.win64_callback

// Builds a PE image which resolves EnumSystemLocalesW from system32's
// KERNEL32 and receives one real Windows callback. The callback crosses into
// an ELE-internal function that prints a marker and stops enumeration.
shape Probe {
    code: X64Code
    entry: Int
}

flow sameText(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength { give false }
    each i among 0..a.byteLength {
        when a@byteAt(i) != b@byteAt(i) { give false }
    }
    give true
}

flow probeCode(imports: edit Pe64Imports) => Probe {
    change code = x64New()
    hold dll_at = code.bytes.length
    hold dll = "kernel32.dll"
    each i among 0..dll.byteLength {
        code.bytes@push(dll@byteAt(i))
        code.bytes@push(0)
    }
    code.bytes@push(0)
    code.bytes@push(0)
    hold proc_at = code.bytes.length
    hold proc = "EnumSystemLocalesW"
    each i among 0..proc.byteLength { code.bytes@push(proc@byteAt(i)) }
    code.bytes@push(0)
    hold marker_at = code.bytes.length
    hold marker = "callback-ok\n"
    each i among 0..marker.byteLength { code.bytes@push(marker@byteAt(i)) }

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
    // Exercise four-word trampoline emission too, but do not claim a
    // registered WndProc until the full window API exists.
    w64EmitCallback4(edit code, target)

    // PE entry. Keep RSP aligned and 32-byte shadow space reserved for each
    // imported or dynamically resolved Win64 call.
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 2)
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
    hold failed_proc = x64ConditionalPlaceholder(edit code, true)
    hold callback_fix = x64LeaRipPlaceholder(edit code, 1)
    x64PatchRelative(edit code, callback_fix, callback)
    x64MovImm64(edit code, 2, 0) // LCID_SUPPORTED
    x64LoadSlot(edit code, 11, 1)
    x64CallReg(edit code, 11)
    x64LoadSlot(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    x64MovImm64(edit code, 1, 0)
    w64EmitExitRcx(edit code, edit imports)

    hold proc_failed_at = code.bytes.length
    x64PatchRelative(edit code, failed_proc, proc_failed_at)
    x64LoadSlot(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    hold load_failed_at = code.bytes.length
    x64PatchRelative(edit code, failed_load, load_failed_at)
    x64MovImm64(edit code, 1, 2)
    w64EmitExitRcx(edit code, edit imports)
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
            // The marker is emitted in a real callback, not at image entry.
            hold image = pe64Executable(view probe.code.bytes, probe.entry, view imports)
            when image.error != 0 { give 3 }
            give writeBytes(path, image.bytes)
        }
        Err(code): { give 4 }
    }
}
