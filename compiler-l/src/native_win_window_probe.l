take codegen.x86_64
take codegen.pe64
take codegen.win64_rt
take codegen.win64_callback

// P0-D probe: builds a PE image that opens a real Win32 window whose WndProc
// is the ELE four-word callback adapter (w64EmitCallback4), runs a message
// loop, paints, and closes itself:
//   RegisterClassExW -> CreateWindowExW (WM_CREATE) -> ShowWindow ->
//   UpdateWindow (WM_PAINT: FillRect + TextOutW, then GetPixel checks the
//   painted colour) -> posted WM_KEYDOWN 'A', WM_LBUTTONDOWN (30, 40),
//   WM_CLOSE -> DestroyWindow (WM_DESTROY -> PostQuitMessage(0)) ->
//   GetMessageW returns 0 -> exit with the WM_QUIT wParam.
// Every other message goes to DefWindowProcW. Each handled message prints a
// marker, so the test checks the exact event sequence.
//
// The image keeps KERNEL32 as its only import table. user32 and gdi32 are
// loaded from system32 at run time; the entry keeps both loaded until exit,
// and the WndProc resolves each function it calls with a temporary
// LoadLibraryExW/GetProcAddress/FreeLibrary (the image has no writable data
// to cache addresses).
shape Probe {
    code: X64Code
    entry: Int
}

fixed SYSTEM32 = 2048                   // LOAD_LIBRARY_SEARCH_SYSTEM32
fixed PAINT_COLOR = 5649426             // RGB(0x12, 0x34, 0x56) = 0x00563412
fixed CLICK = 2621470                   // MAKELPARAM(30, 40)
fixed WM_CREATE = 1
fixed WM_DESTROY = 2
fixed WM_PAINT = 15
fixed WM_CLOSE = 16
fixed WM_KEYDOWN = 256
fixed WM_LBUTTONDOWN = 513
fixed DWORD_MASK = 4294967295

shape Names {
    user32: Int
    gdi32: Int
    def_proc: Int
    destroy: Int
    quit: Int
    begin_paint: Int
    end_paint: Int
    fill_rect: Int
    brush: Int
    text_out: Int
    get_pixel: Int
    delete_object: Int
    register: Int
    create: Int
    show: Int
    update: Int
    post: Int
    get_message: Int
    translate: Int
    dispatch: Int
    class_name: Int
    title: Int
    text: Int
}

shape Markers {
    write_all: Int
    create: Int
    paint_ok: Int
    paint_bad: Int
    key_ok: Int
    key_bad: Int
    click_ok: Int
    click_bad: Int
    close: Int
    destroy: Int
    done: Int
}

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

flow pushAscii(code: edit X64Code, text: view Text) => Int {
    hold at = code.bytes.length
    each i among 0..text.byteLength { code.bytes@push(text@byteAt(i)) }
    code.bytes@push(0)
    give at
}

// A marker line: its offset, followed by its byte length.
flow pushMarker(code: edit X64Code, text: view Text) => Int {
    hold at = code.bytes.length
    each i among 0..text.byteLength { code.bytes@push(text@byteAt(i)) }
    code.bytes@push(10)
    give at
}

flow markerLength(code: view X64Code, at: Int) => Int {
    change n = 0
    during code.bytes[at + n] != 10 { n += 1 }
    give n + 1
}

flow leaData(code: edit X64Code, reg: Int, at: Int) {
    hold fix = x64LeaRipPlaceholder(edit code, reg)
    x64PatchRelative(edit code, fix, at)
}

flow emitPrint(code: edit X64Code, m: view Markers, at: Int) {
    hold len = markerLength(view code, at)
    leaData(edit code, 6, at)
    x64MovImm64(edit code, 2, len)
    hold call_at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, call_at, m.write_all)
}

flow patchHere(code: edit X64Code, at: Int) {
    hold here = code.bytes.length
    x64PatchRelative(edit code, at, here)
}

// Jumps to the returned placeholder when `left` != `right` (neither RAX).
flow jumpIfNotEqual(code: edit X64Code, left: Int, right: Int) => Int {
    x64CmpReg(edit code, left, right)
    x64SetCondition(edit code, 5)
    x64TestRax(edit code)
    give x64ConditionalPlaceholder(edit code, false)
}

// Frame slot `slot` (RBP - 8 * (slot + 1)) as an address in `reg`.
flow leaSlot(code: edit X64Code, reg: Int, slot: Int) {
    x64LeaMem(edit code, reg, 5, -8 * (slot + 1))
}

// Frame slot `dest` = address of export `name_at` of the system32 DLL named
// at `dll_at`, through a temporary reference held in slot `scratch`. Exits
// the process with status 5 when the export cannot be found. The caller's
// frame must be aligned with Win64 shadow space.
flow emitResolve(code: edit X64Code, imports: edit Pe64Imports, dll_at: Int, name_at: Int, scratch: Int, dest: Int) {
    leaData(edit code, 1, dll_at)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, SYSTEM32)
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, scratch, 0)
    x64LoadSlot(edit code, 1, scratch)
    leaData(edit code, 2, name_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, dest, 0)
    x64LoadSlot(edit code, 1, scratch)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    x64LoadSlot(edit code, 0, dest)
    x64TestRax(edit code)
    hold found = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 1, 5)
    w64EmitExitRcx(edit code, edit imports)
    hold found_at = code.bytes.length
    x64PatchRelative(edit code, found, found_at)
}

// Calls the function whose address is in frame slot `slot` (arguments
// already in RCX, RDX, R8, R9 and the stack argument area).
flow callSlot(code: edit X64Code, slot: Int) {
    x64LoadSlot(edit code, 11, slot)
    x64CallReg(edit code, 11)
}

// Stack argument `n` (0 = fifth argument) of the next Win64 call.
flow stackArg(code: edit X64Code, n: Int, reg: Int) {
    x64StoreMem64(edit code, 4, 32 + 8 * n, reg)
}

// The WndProc target. Arguments: hWnd [RBP+16], msg [RBP+24], wParam
// [RBP+32], lParam [RBP+40]. Slots: 0 DLL scratch, 1 resolved function,
// 2 HDC, 3 brush, 4 GetPixel result, 10..18 PAINTSTRUCT (RBP-152),
// 20..21 RECT (RBP-176), 23 message.
flow emitWndProc(code: edit X64Code, imports: edit Pe64Imports, n: view Names, m: view Markers) => Int {
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 24)
    w64AlignStack(edit code, 48)
    x64LoadMem64(edit code, 1, 5, 24)
    x64MovImm64(edit code, 10, DWORD_MASK)
    x64AndReg(edit code, 1, 10)
    x64StoreSlot(edit code, 23, 1)
    change handlers: List of[Int] = List[]
    change kinds: List of[Int] = List[WM_CREATE, WM_PAINT, WM_KEYDOWN, WM_LBUTTONDOWN, WM_CLOSE, WM_DESTROY]
    each k among 0..kinds.length {
        x64LoadSlot(edit code, 1, 23)
        x64MovImm64(edit code, 10, kinds[k])
        x64CmpReg(edit code, 1, 10)
        x64SetCondition(edit code, 4)
        x64TestRax(edit code)
        handlers@push(x64ConditionalPlaceholder(edit code, false))
    }
    // Default: DefWindowProcW(hWnd, msg, wParam, lParam).
    emitResolve(edit code, edit imports, n.user32, n.def_proc, 0, 1)
    x64LoadMem64(edit code, 1, 5, 16)
    x64LoadMem64(edit code, 2, 5, 24)
    x64LoadMem64(edit code, 8, 5, 32)
    x64LoadMem64(edit code, 9, 5, 40)
    callSlot(edit code, 1)
    x64FrameEnd(edit code)

    // WM_CREATE.
    patchHere(edit code, handlers[0])
    emitPrint(edit code, m, m.create)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // WM_PAINT: BeginPaint, FillRect with a solid brush, TextOutW, then
    // GetPixel inside the painted rectangle, DeleteObject, EndPaint.
    patchHere(edit code, handlers[1])
    emitResolve(edit code, edit imports, n.user32, n.begin_paint, 0, 1)
    x64LoadMem64(edit code, 1, 5, 16)
    leaSlot(edit code, 2, 18)
    callSlot(edit code, 1)
    x64StoreSlot(edit code, 2, 0)
    emitResolve(edit code, edit imports, n.gdi32, n.brush, 0, 1)
    x64MovImm64(edit code, 1, PAINT_COLOR)
    callSlot(edit code, 1)
    x64StoreSlot(edit code, 3, 0)
    x64MovImm64(edit code, 0, 42949672970)          // left 10, top 10
    x64StoreSlot(edit code, 21, 0)
    x64MovImm64(edit code, 0, 257698037870)         // right 110, bottom 60
    x64StoreSlot(edit code, 20, 0)
    emitResolve(edit code, edit imports, n.user32, n.fill_rect, 0, 1)
    x64LoadSlot(edit code, 1, 2)
    leaSlot(edit code, 2, 21)
    x64LoadSlot(edit code, 8, 3)
    callSlot(edit code, 1)
    emitResolve(edit code, edit imports, n.gdi32, n.text_out, 0, 1)
    x64LoadSlot(edit code, 1, 2)
    x64MovImm64(edit code, 2, 12)
    x64MovImm64(edit code, 8, 70)
    leaData(edit code, 9, n.text)
    x64MovImm64(edit code, 0, 3)
    stackArg(edit code, 0, 0)
    callSlot(edit code, 1)
    emitResolve(edit code, edit imports, n.gdi32, n.get_pixel, 0, 1)
    x64LoadSlot(edit code, 1, 2)
    x64MovImm64(edit code, 2, 20)
    x64MovImm64(edit code, 8, 20)
    callSlot(edit code, 1)
    x64MovImm64(edit code, 10, DWORD_MASK)
    x64AndReg(edit code, 0, 10)
    x64StoreSlot(edit code, 4, 0)
    emitResolve(edit code, edit imports, n.gdi32, n.delete_object, 0, 1)
    x64LoadSlot(edit code, 1, 3)
    callSlot(edit code, 1)
    emitResolve(edit code, edit imports, n.user32, n.end_paint, 0, 1)
    x64LoadMem64(edit code, 1, 5, 16)
    leaSlot(edit code, 2, 18)
    callSlot(edit code, 1)
    x64LoadSlot(edit code, 1, 4)
    x64MovImm64(edit code, 10, PAINT_COLOR)
    hold paint_bad = jumpIfNotEqual(edit code, 1, 10)
    emitPrint(edit code, m, m.paint_ok)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    patchHere(edit code, paint_bad)
    emitPrint(edit code, m, m.paint_bad)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // WM_KEYDOWN: wParam must be 'A' (65).
    patchHere(edit code, handlers[2])
    x64LoadMem64(edit code, 1, 5, 32)
    x64MovImm64(edit code, 10, 65)
    hold key_bad = jumpIfNotEqual(edit code, 1, 10)
    emitPrint(edit code, m, m.key_ok)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    patchHere(edit code, key_bad)
    emitPrint(edit code, m, m.key_bad)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // WM_LBUTTONDOWN: lParam must be MAKELPARAM(30, 40).
    patchHere(edit code, handlers[3])
    x64LoadMem64(edit code, 1, 5, 40)
    x64MovImm64(edit code, 10, DWORD_MASK)
    x64AndReg(edit code, 1, 10)
    x64MovImm64(edit code, 10, CLICK)
    hold click_bad = jumpIfNotEqual(edit code, 1, 10)
    emitPrint(edit code, m, m.click_ok)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    patchHere(edit code, click_bad)
    emitPrint(edit code, m, m.click_bad)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // WM_CLOSE: DestroyWindow(hWnd).
    patchHere(edit code, handlers[4])
    emitPrint(edit code, m, m.close)
    emitResolve(edit code, edit imports, n.user32, n.destroy, 0, 1)
    x64LoadMem64(edit code, 1, 5, 16)
    callSlot(edit code, 1)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)

    // WM_DESTROY: PostQuitMessage(0).
    patchHere(edit code, handlers[5])
    emitPrint(edit code, m, m.destroy)
    emitResolve(edit code, edit imports, n.user32, n.quit, 0, 1)
    x64MovImm64(edit code, 1, 0)
    callSlot(edit code, 1)
    x64MovImm64(edit code, 0, 0)
    x64FrameEnd(edit code)
    give entry
}

// Loads `dll_at` from system32 into frame slot `slot` for the whole run;
// exits with status 2 when it cannot be loaded.
flow emitLoadForever(code: edit X64Code, imports: edit Pe64Imports, dll_at: Int, slot: Int) {
    leaData(edit code, 1, dll_at)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, SYSTEM32)
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, slot, 0)
    x64TestRax(edit code)
    hold loaded = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 1, 2)
    w64EmitExitRcx(edit code, edit imports)
    patchHere(edit code, loaded)
}

// Exits with `status` when RAX is zero.
flow exitIfZero(code: edit X64Code, imports: edit Pe64Imports, status: Int) {
    x64TestRax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 1, status)
    w64EmitExitRcx(edit code, edit imports)
    patchHere(edit code, ok)
}

flow emitPost(code: edit X64Code, msg: Int, wparam: Int, lparam: Int) {
    x64LoadSlot(edit code, 1, 2)
    x64MovImm64(edit code, 2, msg)
    x64MovImm64(edit code, 8, wparam)
    x64MovImm64(edit code, 9, lparam)
    callSlot(edit code, 10)
}

flow probeCode(imports: edit Pe64Imports) => Probe {
    change code = x64New()
    hold user32 = "user32.dll"
    hold gdi32 = "gdi32.dll"
    hold class_name = "ELEProbeWindow"
    hold title = "ELE"
    hold n_def = "DefWindowProcW"
    hold n_destroy = "DestroyWindow"
    hold n_quit = "PostQuitMessage"
    hold n_begin = "BeginPaint"
    hold n_end = "EndPaint"
    hold n_fill = "FillRect"
    hold n_brush = "CreateSolidBrush"
    hold n_text = "TextOutW"
    hold n_pixel = "GetPixel"
    hold n_delete = "DeleteObject"
    hold n_register = "RegisterClassExW"
    hold n_create = "CreateWindowExW"
    hold n_show = "ShowWindow"
    hold n_update = "UpdateWindow"
    hold n_post = "PostMessageW"
    hold n_get = "GetMessageW"
    hold n_translate = "TranslateMessage"
    hold n_dispatch = "DispatchMessageW"
    hold names = Names(user32: pushWide(edit code, view user32), gdi32: pushWide(edit code, view gdi32), def_proc: pushAscii(edit code, view n_def), destroy: pushAscii(edit code, view n_destroy), quit: pushAscii(edit code, view n_quit), begin_paint: pushAscii(edit code, view n_begin), end_paint: pushAscii(edit code, view n_end), fill_rect: pushAscii(edit code, view n_fill), brush: pushAscii(edit code, view n_brush), text_out: pushAscii(edit code, view n_text), get_pixel: pushAscii(edit code, view n_pixel), delete_object: pushAscii(edit code, view n_delete), register: pushAscii(edit code, view n_register), create: pushAscii(edit code, view n_create), show: pushAscii(edit code, view n_show), update: pushAscii(edit code, view n_update), post: pushAscii(edit code, view n_post), get_message: pushAscii(edit code, view n_get), translate: pushAscii(edit code, view n_translate), dispatch: pushAscii(edit code, view n_dispatch), class_name: pushWide(edit code, view class_name), title: pushWide(edit code, view title), text: pushWide(edit code, view title))
    hold t_create = "wm-create"
    hold t_paint_ok = "wm-paint-pixel-ok"
    hold t_paint_bad = "wm-paint-pixel-bad"
    hold t_key_ok = "wm-keydown-a"
    hold t_key_bad = "wm-keydown-bad"
    hold t_click_ok = "wm-lbuttondown-30-40"
    hold t_click_bad = "wm-lbuttondown-bad"
    hold t_close = "wm-close"
    hold t_destroy = "wm-destroy"
    hold t_done = "message-loop-done"
    hold create_at = pushMarker(edit code, view t_create)
    hold paint_ok_at = pushMarker(edit code, view t_paint_ok)
    hold paint_bad_at = pushMarker(edit code, view t_paint_bad)
    hold key_ok_at = pushMarker(edit code, view t_key_ok)
    hold key_bad_at = pushMarker(edit code, view t_key_bad)
    hold click_ok_at = pushMarker(edit code, view t_click_ok)
    hold click_bad_at = pushMarker(edit code, view t_click_bad)
    hold close_at = pushMarker(edit code, view t_close)
    hold destroy_at = pushMarker(edit code, view t_destroy)
    hold done_at = pushMarker(edit code, view t_done)
    hold runtime = w64EmitRuntime(edit code, edit imports)
    hold markers = Markers(write_all: runtime[0], create: create_at, paint_ok: paint_ok_at, paint_bad: paint_bad_at, key_ok: key_ok_at, key_bad: key_bad_at, click_ok: click_ok_at, click_bad: click_bad_at, close: close_at, destroy: destroy_at, done: done_at)

    hold wnd_target = emitWndProc(edit code, edit imports, view names, view markers)
    hold wnd_proc = w64EmitCallback4(edit code, wnd_target)

    // PE entry. Slots: 0 user32, 1 gdi32, 2 HWND, 3 hInstance, 4 DLL
    // scratch, 5 RegisterClassExW, 6 CreateWindowExW, 7 ShowWindow,
    // 8 UpdateWindow, 9 GetMessageW, 10 PostMessageW, 11 TranslateMessage,
    // 12 DispatchMessageW, 15..24 WNDCLASSEXW (RBP-200), 30..35 MSG (RBP-288).
    // 96 bytes below RSP: shadow space plus CreateWindowExW's 8 stack args.
    hold entry = code.bytes.length
    x64FrameBegin(edit code, 36)
    w64AlignStack(edit code, 96)
    emitLoadForever(edit code, edit imports, names.user32, 0)
    emitLoadForever(edit code, edit imports, names.gdi32, 1)
    // hInstance: .text starts one section alignment above the image base.
    leaData(edit code, 0, 0)
    x64MovImm64(edit code, 10, 4096)
    x64SubReg(edit code, 0, 10)
    x64StoreSlot(edit code, 3, 0)
    emitResolve(edit code, edit imports, names.user32, names.register, 4, 5)
    emitResolve(edit code, edit imports, names.user32, names.create, 4, 6)
    emitResolve(edit code, edit imports, names.user32, names.show, 4, 7)
    emitResolve(edit code, edit imports, names.user32, names.update, 4, 8)
    emitResolve(edit code, edit imports, names.user32, names.get_message, 4, 9)
    emitResolve(edit code, edit imports, names.user32, names.post, 4, 10)
    emitResolve(edit code, edit imports, names.user32, names.translate, 4, 11)
    emitResolve(edit code, edit imports, names.user32, names.dispatch, 4, 12)

    // WNDCLASSEXW: cbSize 80, style CS_HREDRAW | CS_VREDRAW, lpfnWndProc,
    // hInstance, hbrBackground COLOR_WINDOW + 1, lpszClassName; rest zero.
    x64MovImm64(edit code, 0, 0)
    each s among 15..25 { x64StoreSlot(edit code, s, 0) }
    x64MovImm64(edit code, 0, 12884901968)
    x64StoreSlot(edit code, 24, 0)
    leaData(edit code, 0, wnd_proc)
    x64StoreSlot(edit code, 23, 0)
    x64LoadSlot(edit code, 0, 3)
    x64StoreSlot(edit code, 21, 0)
    x64MovImm64(edit code, 0, 6)
    x64StoreSlot(edit code, 18, 0)
    leaData(edit code, 0, names.class_name)
    x64StoreSlot(edit code, 16, 0)
    leaSlot(edit code, 1, 24)
    callSlot(edit code, 5)
    exitIfZero(edit code, edit imports, 3)

    // CreateWindowExW(0, class, title, WS_OVERLAPPEDWINDOW, 100, 100, 320,
    // 200, NULL, NULL, hInstance, NULL).
    x64MovImm64(edit code, 1, 0)
    leaData(edit code, 2, names.class_name)
    leaData(edit code, 8, names.title)
    x64MovImm64(edit code, 9, 13565952)
    x64MovImm64(edit code, 0, 100)
    stackArg(edit code, 0, 0)
    stackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 320)
    stackArg(edit code, 2, 0)
    x64MovImm64(edit code, 0, 200)
    stackArg(edit code, 3, 0)
    x64MovImm64(edit code, 0, 0)
    stackArg(edit code, 4, 0)
    stackArg(edit code, 5, 0)
    stackArg(edit code, 7, 0)
    x64LoadSlot(edit code, 0, 3)
    stackArg(edit code, 6, 0)
    callSlot(edit code, 6)
    x64StoreSlot(edit code, 2, 0)
    exitIfZero(edit code, edit imports, 4)

    // ShowWindow(SW_SHOWNOACTIVATE), UpdateWindow (a synchronous WM_PAINT).
    x64LoadSlot(edit code, 1, 2)
    x64MovImm64(edit code, 2, 4)
    callSlot(edit code, 7)
    x64LoadSlot(edit code, 1, 2)
    callSlot(edit code, 8)

    // Queued input and the close request, dispatched by the loop below.
    emitPost(edit code, WM_KEYDOWN, 65, 0)
    emitPost(edit code, WM_LBUTTONDOWN, 0, CLICK)
    emitPost(edit code, WM_CLOSE, 0, 0)

    // while GetMessageW(&msg, NULL, 0, 0) > 0: TranslateMessage, Dispatch.
    hold message_top = code.bytes.length
    leaSlot(edit code, 1, 35)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    x64MovImm64(edit code, 9, 0)
    callSlot(edit code, 9)
    x64MovImm64(edit code, 10, DWORD_MASK)
    x64AndReg(edit code, 0, 10)
    x64MovReg(edit code, 1, 0)
    x64TestRax(edit code)
    hold quit = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 10, DWORD_MASK)
    hold not_failed = jumpIfNotEqual(edit code, 1, 10)
    x64MovImm64(edit code, 1, 9)
    w64EmitExitRcx(edit code, edit imports)
    patchHere(edit code, not_failed)
    leaSlot(edit code, 1, 35)
    callSlot(edit code, 11)
    leaSlot(edit code, 1, 35)
    callSlot(edit code, 12)
    hold again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, again, message_top)

    // WM_QUIT: exit with its wParam (MSG + 16).
    patchHere(edit code, quit)
    emitPrint(edit code, view markers, markers.done)
    x64LoadMem64(edit code, 1, 5, -288 + 16)
    w64EmitExitRcx(edit code, edit imports)
    give Probe(code: code, entry: entry)
}

flow main() => Int {
    when processArgCount() != 1 { give 1 }
    choose processArg(0) {
        Ok(path): {
            change imports = pe64NewImports()
            hold probe = probeCode(edit imports)
            when probe.code.error != 0 { give 2 }
            hold image = pe64Executable(view probe.code.bytes, probe.entry, view imports)
            when image.error != 0 { give 3 }
            give writeBytes(path, image.bytes)
        }
        Err(code): { give 4 }
    }
}
