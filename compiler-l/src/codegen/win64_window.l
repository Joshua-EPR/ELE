take x86_64
take pe64
take win64_rt
take win64_callback
take native_rt_platform

// Native windows for Windows x64 (P0-D): ELE-LIR platform codes 17..25.
// Design: docs/native-window-and-callbacks-design.md, Part A.
//
// Contract below sema (a Window is one word):
//   open(RDI = title Text, RSI = width, RDX = height) -> block address, or
//     -1 invalid size/title, -5 system failure, -7 no user32/gdi32.
//   next(RDI) -> packed event (bits: 56..59 kind, 48..50 modifiers shift 1
//     ctrl 2 alt 4, 16..47 lParam low dword, 0..15 wParam low word; the
//     wheel's wParam is its high word), or -5/-6. Kinds: 1 key down, 2 key
//     up, 3 char (UTF-16 unit), 4 mouse move, 5/6 left down/up, 7/8 right
//     down/up, 9 wheel, 10 resize (client size), 11/12 focus in/out,
//     13 close request, 15 events were dropped (queue full).
//   fill(RDI, x, y, w, h, rgb 0xRRGGBB) / text(RDI, x, y, Text, rgb) draw
//     into the back buffer (clipped); present(RDI) invalidates the window;
//     send(RDI, msg, wParam, lParam) posts an input or close message to
//     this window only (a whitelist); pixel(RDI, x, y) reads the back
//     buffer. 0 on success, -1 invalid argument, -5 system failure, -6 not
//     open. close(value) destroys everything; a failed open closes as 0.
//
// The value is the address of a 4 KiB state block from the runtime heap.
// It holds the HWND, the back buffer (a 32-bit top-down DIB section in a
// memory DC), the font, user32/gdi32 functions resolved once at open, and a
// ring of 256 packed events. The one WndProc (w64EmitCallback4 around
// wwEmitWndProc) finds the block through GWLP_USERDATA, set on WM_NCCREATE
// from CreateWindowExW's lpParam. It only enqueues events and copies the
// back buffer on WM_PAINT: no ELE code runs inside it. WM_CLOSE is a
// request event; only close() destroys the window.
//
// user32 and gdi32 are loaded from system32 at open (LOAD_LIBRARY_SEARCH_
// SYSTEM32), so the image keeps its KERNEL32-only import table. The image
// has no writable data, so the WndProc resolves GetWindowLongPtrW with a
// temporary LoadLibraryExW/GetProcAddress/FreeLibrary per message; a data
// section (design step 4) removes that cost.

fixed WB_MAGIC = 0
fixed WB_HWND = 8
fixed WB_HEAD = 16
fixed WB_TAIL = 24
fixed WB_OVERFLOW = 32
fixed WB_MEMDC = 40
fixed WB_DIB = 48
fixed WB_BITS = 56
fixed WB_WIDTH = 64
fixed WB_HEIGHT = 72
fixed WB_FONT = 80
fixed WB_OLDBMP = 88
fixed WB_USER32 = 96
fixed WB_GDI32 = 104
fixed WB_CAPACITY = 112
fixed WB_OLDFONT = 120
fixed WB_FN = 128
fixed WB_RING = 512
fixed WB_SIZE = 4096
fixed WB_MAGIC_VALUE = 1162626391        // "WELE"

// Resolved function table indexes (the first WF_USER32_COUNT from user32).
fixed WF_DEFPROC = 0
fixed WF_REGISTER = 1
fixed WF_CREATEWINDOW = 2
fixed WF_SHOW = 3
fixed WF_DESTROY = 4
fixed WF_GETMESSAGE = 5
fixed WF_TRANSLATE = 6
fixed WF_DISPATCH = 7
fixed WF_POST = 8
fixed WF_INVALIDATE = 9
fixed WF_BEGINPAINT = 10
fixed WF_ENDPAINT = 11
fixed WF_SETLONG = 12
fixed WF_GETKEYSTATE = 13
fixed WF_LOADCURSOR = 14
fixed WF_USER32_COUNT = 15
fixed WF_CREATEDC = 15
fixed WF_CREATEDIB = 16
fixed WF_SELECT = 17
fixed WF_DELETEOBJECT = 18
fixed WF_DELETEDC = 19
fixed WF_BITBLT = 20
fixed WF_CREATEFONT = 21
fixed WF_SETBKMODE = 22
fixed WF_SETTEXTCOLOR = 23
fixed WF_EXTTEXTOUT = 24
fixed WF_GDIFLUSH = 25
fixed WF_COUNT = 26

fixed WW_RESERVE = 128                  // shadow space + 12 stack args
fixed WW_SYSTEM32 = 2048
fixed WW_DWORD = 4294967295
fixed WW_KIND = 72057594037927936       // 2^56
fixed WW_MODS = 281474976710656         // 2^48

expose shape WwData {
    user32: Int
    gdi32: Int
    class_name: Int
    font: Int
    get_long: Int
    names: List of[Int]
}

flow wwPatchHere(code: edit X64Code, at: Int) {
    hold here = code.bytes.length
    x64PatchRelative(edit code, at, here)
}

flow wwPatchAll(code: edit X64Code, at: view List of[Int]) {
    hold here = code.bytes.length
    each i among 0..at.length { x64PatchRelative(edit code, at[i], here) }
}

flow wwJumpTo(code: edit X64Code, target: Int) {
    hold at = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

flow wwCall(code: edit X64Code, target: Int) {
    hold at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

// Jumps when `left` <cond> `right` (signed: 4 eq, 5 ne, 6 lt, 7 le, 8 gt,
// 9 ge). Clobbers RAX; neither operand may be RAX.
flow wwIfReg(code: edit X64Code, left: Int, right: Int, cond: Int) => Int {
    x64CmpReg(edit code, left, right)
    x64SetCondition(edit code, cond)
    x64TestRax(edit code)
    give x64ConditionalPlaceholder(edit code, false)
}

// The same against a constant held in R10. Clobbers RAX and R10.
flow wwIf(code: edit X64Code, left: Int, value: Int, cond: Int) => Int {
    x64MovImm64(edit code, 10, value)
    give wwIfReg(edit code, left, 10, cond)
}

flow wwRet(code: edit X64Code, value: Int) {
    x64MovImm64(edit code, 0, value)
    x64FrameEnd(edit code)
}

flow wwLea(code: edit X64Code, reg: Int, at: Int) {
    hold fix = x64LeaRipPlaceholder(edit code, reg)
    x64PatchRelative(edit code, fix, at)
}

flow wwBegin(code: edit X64Code, slots: Int) {
    x64FrameBegin(edit code, slots)
    w64AlignStack(edit code, WW_RESERVE)
}

flow wwStackArg(code: edit X64Code, n: Int, reg: Int) {
    x64StoreMem64(edit code, 4, 32 + 8 * n, reg)
}

flow wwDword(code: edit X64Code) {
    x64MovImm64(edit code, 10, WW_DWORD)
    x64AndReg(edit code, 0, 10)
}

// Calls table function `index` of the block in frame slot `block` (the
// Win64 arguments are already in place). Clobbers R11.
flow wwFn(code: edit X64Code, block: Int, index: Int) {
    x64LoadSlot(edit code, 11, block)
    x64LoadMem64(edit code, 11, 11, WB_FN + 8 * index)
    x64CallReg(edit code, 11)
}

// The same, skipped when the function was never resolved (a failed open
// releasing a partial block). Clobbers RAX and R11.
flow wwFnGuarded(code: edit X64Code, block: Int, index: Int) {
    x64LoadSlot(edit code, 11, block)
    x64LoadMem64(edit code, 0, 11, WB_FN + 8 * index)
    x64TestRax(edit code)
    hold missing = x64ConditionalPlaceholder(edit code, true)
    x64MovReg(edit code, 11, 0)
    x64CallReg(edit code, 11)
    wwPatchHere(edit code, missing)
}

// A NUL-terminated UTF-16 string in the code section, 8-byte aligned:
// RegisterClassExW and CreateWindowExW reject a misaligned WCHAR pointer
// with ERROR_NOACCESS (998), so an odd offset (which depends on the size
// of the rest of the image) made windowOpen fail in larger programs. The
// padding sits between routines and is never executed.
flow wwPushWide(code: edit X64Code, text: view Text) => Int {
    during code.bytes.length % 8 != 0 { code.bytes@push(0) }
    hold at = code.bytes.length
    each i among 0..text.byteLength {
        code.bytes@push(text@byteAt(i))
        code.bytes@push(0)
    }
    code.bytes@push(0)
    code.bytes@push(0)
    give at
}

flow wwPushAscii(code: edit X64Code, text: view Text) => Int {
    hold at = code.bytes.length
    each i among 0..text.byteLength { code.bytes@push(text@byteAt(i)) }
    code.bytes@push(0)
    give at
}

// Export name of table function `index` (the WF_* order).
flow wwFunctionName(index: Int) => Text {
    when index == 0 { give "DefWindowProcW" }
    when index == 1 { give "RegisterClassExW" }
    when index == 2 { give "CreateWindowExW" }
    when index == 3 { give "ShowWindow" }
    when index == 4 { give "DestroyWindow" }
    when index == 5 { give "GetMessageW" }
    when index == 6 { give "TranslateMessage" }
    when index == 7 { give "DispatchMessageW" }
    when index == 8 { give "PostMessageW" }
    when index == 9 { give "InvalidateRect" }
    when index == 10 { give "BeginPaint" }
    when index == 11 { give "EndPaint" }
    when index == 12 { give "SetWindowLongPtrW" }
    when index == 13 { give "GetKeyState" }
    when index == 14 { give "LoadCursorW" }
    when index == 15 { give "CreateCompatibleDC" }
    when index == 16 { give "CreateDIBSection" }
    when index == 17 { give "SelectObject" }
    when index == 18 { give "DeleteObject" }
    when index == 19 { give "DeleteDC" }
    when index == 20 { give "BitBlt" }
    when index == 21 { give "CreateFontW" }
    when index == 22 { give "SetBkMode" }
    when index == 23 { give "SetTextColor" }
    when index == 24 { give "ExtTextOutW" }
    give "GdiFlush"
}

// Strings used by the routines, emitted between routines (never executed).
flow wwEmitData(code: edit X64Code) => WwData {
    hold user32 = "user32.dll"
    hold gdi32 = "gdi32.dll"
    hold class_name = "ELEWindow"
    hold font = "Consolas"
    hold get_long = "GetWindowLongPtrW"
    hold user32_at = wwPushWide(edit code, view user32)
    hold gdi32_at = wwPushWide(edit code, view gdi32)
    hold class_at = wwPushWide(edit code, view class_name)
    hold font_at = wwPushWide(edit code, view font)
    hold get_long_at = wwPushAscii(edit code, view get_long)
    change names: List of[Int] = List[]
    each i among 0..WF_COUNT {
        hold name = wwFunctionName(i)
        names@push(wwPushAscii(edit code, view name))
    }
    give WwData(user32: user32_at, gdi32: gdi32_at, class_name: class_at, font: font_at, get_long: get_long_at, names: names)
}

// RAX = user32 export `name_at` through a temporary LoadLibraryExW
// reference (slots 0 and 1), or 0.
flow wwResolveUser32(code: edit X64Code, imports: edit Pe64Imports, d: view WwData, name_at: Int) {
    wwLea(edit code, 1, d.user32)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, WW_SYSTEM32)
    w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
    x64StoreSlot(edit code, 0, 0)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 1, 0)
    wwLea(edit code, 2, name_at)
    w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
    x64StoreSlot(edit code, 1, 0)
    x64LoadSlot(edit code, 1, 0)
    w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
    x64LoadSlot(edit code, 0, 1)
    hold done = x64JumpPlaceholder(edit code)
    wwPatchHere(edit code, failed)
    x64MovImm64(edit code, 0, 0)
    wwPatchHere(edit code, done)
}

// The WndProc target (arguments at RBP+16 hWnd, +24 msg, +32 wParam,
// +40 lParam). Slots: 0 DLL, 1 function, 2 block, 3 message, 4 packed,
// 5 kind, 6..14 PAINTSTRUCT (RBP-120), 15 HDC, 16 then-default flag,
// 17 modifiers.
flow wwEmitWndProc(code: edit X64Code, imports: edit Pe64Imports, d: view WwData) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 18)
    x64LoadMem64(edit code, 1, 5, 24)
    x64MovImm64(edit code, 10, WW_DWORD)
    x64AndReg(edit code, 1, 10)
    x64StoreSlot(edit code, 3, 1)
    change to_default: List of[Int] = List[]
    change no_block: List of[Int] = List[]
    // WM_NCCREATE: block = CREATESTRUCTW.lpCreateParams; remember it.
    hold not_create = wwIf(edit code, 1, 129, 5)
    x64LoadMem64(edit code, 0, 5, 40)
    x64LoadMem64(edit code, 0, 0, 0)
    x64StoreSlot(edit code, 2, 0)
    x64LoadMem64(edit code, 1, 5, 16)
    x64StoreMem64(edit code, 0, WB_HWND, 1)
    x64LoadMem64(edit code, 1, 5, 16)
    x64MovImm64(edit code, 2, -21)          // GWLP_USERDATA
    x64LoadSlot(edit code, 8, 2)
    wwFn(edit code, 2, WF_SETLONG)
    to_default@push(x64JumpPlaceholder(edit code))
    wwPatchHere(edit code, not_create)
    // Any other message: block = GetWindowLongPtrW(hWnd, GWLP_USERDATA).
    wwResolveUser32(edit code, edit imports, d, d.get_long)
    x64TestRax(edit code)
    no_block@push(x64ConditionalPlaceholder(edit code, true))
    x64MovReg(edit code, 11, 0)
    x64LoadMem64(edit code, 1, 5, 16)
    x64MovImm64(edit code, 2, -21)
    x64CallReg(edit code, 11)
    x64StoreSlot(edit code, 2, 0)
    x64TestRax(edit code)
    no_block@push(x64ConditionalPlaceholder(edit code, true))
    // Dispatch on the message.
    x64LoadSlot(edit code, 1, 3)
    hold paint_hit = wwIf(edit code, 1, 15, 4)
    hold erase_hit = wwIf(edit code, 1, 20, 4)
    hold msgs: List of[Int] = List[16, 256, 257, 260, 261, 258, 512, 513, 514, 516, 517, 522, 5, 7, 8]
    hold kinds: List of[Int] = List[13, 1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    hold flags: List of[Int] = List[0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    change hits: List of[Int] = List[]
    each k among 0..msgs.length { hits@push(wwIf(edit code, 1, msgs[k], 4)) }
    to_default@push(x64JumpPlaceholder(edit code))
    change enqueue: List of[Int] = List[]
    each k among 0..msgs.length {
        wwPatchHere(edit code, hits[k])
        x64MovImm64(edit code, 0, kinds[k])
        x64StoreSlot(edit code, 5, 0)
        x64MovImm64(edit code, 0, flags[k])
        x64StoreSlot(edit code, 16, 0)
        enqueue@push(x64JumpPlaceholder(edit code))
    }

    // Enqueue the packed event of kind slot 5.
    wwPatchAll(edit code, view enqueue)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 17, 0)
    hold vks: List of[Int] = List[16, 17, 18]
    hold bits: List of[Int] = List[1, 2, 4]
    each k among 0..vks.length {
        x64MovImm64(edit code, 1, vks[k])
        wwFn(edit code, 2, WF_GETKEYSTATE)
        x64MovImm64(edit code, 10, 32768)
        x64AndReg(edit code, 0, 10)
        x64TestRax(edit code)
        hold up = x64ConditionalPlaceholder(edit code, true)
        x64LoadSlot(edit code, 0, 17)
        x64MovImm64(edit code, 10, bits[k])
        x64AddReg(edit code, 0, 10)
        x64StoreSlot(edit code, 17, 0)
        wwPatchHere(edit code, up)
    }
    x64LoadSlot(edit code, 1, 5)
    hold not_wheel = wwIf(edit code, 1, 9, 5)
    x64LoadMem64(edit code, 0, 5, 32)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 10, 65536)
    x64DivUnsignedReg(edit code, 10)
    x64StoreSlot(edit code, 4, 0)
    hold wheel_done = x64JumpPlaceholder(edit code)
    wwPatchHere(edit code, not_wheel)
    x64LoadMem64(edit code, 0, 5, 32)
    x64StoreSlot(edit code, 4, 0)
    wwPatchHere(edit code, wheel_done)
    x64LoadSlot(edit code, 9, 4)
    x64MovImm64(edit code, 10, 65535)
    x64AndReg(edit code, 9, 10)
    x64LoadMem64(edit code, 8, 5, 40)
    x64MovImm64(edit code, 10, WW_DWORD)
    x64AndReg(edit code, 8, 10)
    x64MovImm64(edit code, 10, 65536)
    x64MulReg(edit code, 8, 10)
    x64AddReg(edit code, 9, 8)
    x64LoadSlot(edit code, 8, 17)
    x64MovImm64(edit code, 10, WW_MODS)
    x64MulReg(edit code, 8, 10)
    x64AddReg(edit code, 9, 8)
    x64LoadSlot(edit code, 8, 5)
    x64MovImm64(edit code, 10, WW_KIND)
    x64MulReg(edit code, 8, 10)
    x64AddReg(edit code, 9, 8)
    x64StoreSlot(edit code, 4, 9)
    // Ring: full when tail - head >= 256 (the event is dropped and counted).
    x64LoadSlot(edit code, 1, 2)
    x64LoadMem64(edit code, 8, 1, WB_HEAD)
    x64LoadMem64(edit code, 9, 1, WB_TAIL)
    x64MovReg(edit code, 11, 9)
    x64SubReg(edit code, 11, 8)
    x64MovImm64(edit code, 10, 256)
    hold full = wwIfReg(edit code, 11, 10, 9)
    x64MovReg(edit code, 11, 9)
    x64MovImm64(edit code, 10, 255)
    x64AndReg(edit code, 11, 10)
    x64MovImm64(edit code, 10, 8)
    x64MulReg(edit code, 11, 10)
    x64AddReg(edit code, 11, 1)
    x64LoadSlot(edit code, 0, 4)
    x64StoreMem64(edit code, 11, WB_RING, 0)
    x64MovImm64(edit code, 10, 1)
    x64AddReg(edit code, 9, 10)
    x64StoreMem64(edit code, 1, WB_TAIL, 9)
    hold stored = x64JumpPlaceholder(edit code)
    wwPatchHere(edit code, full)
    x64LoadMem64(edit code, 0, 1, WB_OVERFLOW)
    x64MovImm64(edit code, 10, 1)
    x64AddReg(edit code, 0, 10)
    x64StoreMem64(edit code, 1, WB_OVERFLOW, 0)
    wwPatchHere(edit code, stored)
    x64LoadSlot(edit code, 1, 16)
    to_default@push(wwIf(edit code, 1, 0, 5))
    wwRet(edit code, 0)

    // WM_PAINT: copy the back buffer.
    wwPatchHere(edit code, paint_hit)
    x64LoadMem64(edit code, 1, 5, 16)
    x64LeaMem(edit code, 2, 5, -120)
    wwFn(edit code, 2, WF_BEGINPAINT)
    x64StoreSlot(edit code, 15, 0)
    x64LoadSlot(edit code, 10, 2)
    x64LoadMem64(edit code, 0, 10, WB_HEIGHT)
    wwStackArg(edit code, 0, 0)
    x64LoadMem64(edit code, 0, 10, WB_MEMDC)
    wwStackArg(edit code, 1, 0)
    x64MovImm64(edit code, 0, 0)
    wwStackArg(edit code, 2, 0)
    wwStackArg(edit code, 3, 0)
    x64MovImm64(edit code, 0, 13369376)     // SRCCOPY
    wwStackArg(edit code, 4, 0)
    x64LoadSlot(edit code, 1, 15)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    x64LoadMem64(edit code, 9, 10, WB_WIDTH)
    wwFn(edit code, 2, WF_BITBLT)
    x64LoadMem64(edit code, 1, 5, 16)
    x64LeaMem(edit code, 2, 5, -120)
    wwFn(edit code, 2, WF_ENDPAINT)
    wwRet(edit code, 0)

    // WM_ERASEBKGND: the back buffer covers the client area.
    wwPatchHere(edit code, erase_hit)
    wwRet(edit code, 1)

    // DefWindowProcW from the block's table.
    wwPatchAll(edit code, view to_default)
    x64LoadMem64(edit code, 1, 5, 16)
    x64LoadMem64(edit code, 2, 5, 24)
    x64LoadMem64(edit code, 8, 5, 32)
    x64LoadMem64(edit code, 9, 5, 40)
    wwFn(edit code, 2, WF_DEFPROC)
    x64FrameEnd(edit code)

    // No block (messages before WM_NCCREATE): DefWindowProcW resolved now.
    wwPatchAll(edit code, view no_block)
    hold def_name = d.names[WF_DEFPROC]
    wwResolveUser32(edit code, edit imports, d, def_name)
    x64TestRax(edit code)
    hold none = x64ConditionalPlaceholder(edit code, true)
    x64MovReg(edit code, 11, 0)
    x64LoadMem64(edit code, 1, 5, 16)
    x64LoadMem64(edit code, 2, 5, 24)
    x64LoadMem64(edit code, 8, 5, 32)
    x64LoadMem64(edit code, 9, 5, 40)
    x64CallReg(edit code, 11)
    x64FrameEnd(edit code)
    wwPatchHere(edit code, none)
    wwRet(edit code, 0)
    give entry
}

// buffer(RDI = block, RSI = width, RDX = height) -> 0 or -5: a new
// top-down 32-bit DIB section selected into the memory DC; the previous
// one is deleted (the first call keeps the DC's original bitmap). Slots:
// 0 block, 1 width, 2 height, 3..8 BITMAPINFO (RBP-72), 9 bits, 10 DIB.
flow wwEmitBuffer(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 11)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    // biSize 40 | biWidth << 32.
    x64LoadSlot(edit code, 0, 1)
    x64MovImm64(edit code, 10, 4294967296)
    x64MulReg(edit code, 0, 10)
    x64MovImm64(edit code, 10, 40)
    x64AddReg(edit code, 0, 10)
    x64StoreSlot(edit code, 8, 0)
    // biHeight = -height (top-down), biPlanes 1, biBitCount 32.
    x64MovImm64(edit code, 0, 9007207844675584)
    x64LoadSlot(edit code, 1, 2)
    x64SubReg(edit code, 0, 1)
    x64StoreSlot(edit code, 7, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 6, 0)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 4, 0)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 9, 0)
    // CreateDIBSection(memdc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0).
    wwStackArg(edit code, 0, 0)
    wwStackArg(edit code, 1, 0)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64LeaMem(edit code, 2, 5, -72)
    x64MovImm64(edit code, 8, 0)
    x64LeaMem(edit code, 9, 5, -80)
    wwFn(edit code, 0, WF_CREATEDIB)
    x64StoreSlot(edit code, 10, 0)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64LoadSlot(edit code, 2, 10)
    wwFn(edit code, 0, WF_SELECT)
    x64MovReg(edit code, 9, 0)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_OLDBMP)
    hold had = wwIf(edit code, 1, 0, 5)
    x64LoadSlot(edit code, 10, 0)
    x64StoreMem64(edit code, 10, WB_OLDBMP, 9)
    hold kept = x64JumpPlaceholder(edit code)
    wwPatchHere(edit code, had)
    x64MovReg(edit code, 1, 9)
    wwFn(edit code, 0, WF_DELETEOBJECT)
    wwPatchHere(edit code, kept)
    x64LoadSlot(edit code, 10, 0)
    x64LoadSlot(edit code, 0, 10)
    x64StoreMem64(edit code, 10, WB_DIB, 0)
    x64LoadSlot(edit code, 0, 9)
    x64StoreMem64(edit code, 10, WB_BITS, 0)
    x64LoadSlot(edit code, 0, 1)
    x64StoreMem64(edit code, 10, WB_WIDTH, 0)
    x64LoadSlot(edit code, 0, 2)
    x64StoreMem64(edit code, 10, WB_HEIGHT, 0)
    wwRet(edit code, 0)
    wwPatchHere(edit code, failed)
    wwRet(edit code, -5)
    give entry
}

// close(RDI = block) -> 0. Also the cleanup of a partially opened block:
// each resource is released only if it was created, each function called
// only if it was resolved. Slots: 0 block.
flow wwEmitClose(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 2)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 1, 7)
    hold failed_open = wwIf(edit code, 1, 0, 7)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_HWND)
    x64MovReg(edit code, 0, 1)
    x64TestRax(edit code)
    hold no_window = x64ConditionalPlaceholder(edit code, true)
    wwFnGuarded(edit code, 0, WF_DESTROY)
    wwPatchHere(edit code, no_window)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 0, 10, WB_MEMDC)
    x64TestRax(edit code)
    hold no_dc = x64ConditionalPlaceholder(edit code, true)
    hold restore: List of[Int] = List[WB_OLDFONT, WB_OLDBMP]
    each k among 0..restore.length {
        x64LoadSlot(edit code, 10, 0)
        x64LoadMem64(edit code, 2, 10, restore[k])
        x64MovReg(edit code, 0, 2)
        x64TestRax(edit code)
        hold skip = x64ConditionalPlaceholder(edit code, true)
        x64LoadMem64(edit code, 1, 10, WB_MEMDC)
        wwFnGuarded(edit code, 0, WF_SELECT)
        wwPatchHere(edit code, skip)
    }
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    wwFnGuarded(edit code, 0, WF_DELETEDC)
    wwPatchHere(edit code, no_dc)
    hold objects: List of[Int] = List[WB_DIB, WB_FONT]
    each k among 0..objects.length {
        x64LoadSlot(edit code, 10, 0)
        x64LoadMem64(edit code, 1, 10, objects[k])
        x64MovReg(edit code, 0, 1)
        x64TestRax(edit code)
        hold skip = x64ConditionalPlaceholder(edit code, true)
        wwFnGuarded(edit code, 0, WF_DELETEOBJECT)
        wwPatchHere(edit code, skip)
    }
    hold libraries: List of[Int] = List[WB_GDI32, WB_USER32]
    each k among 0..libraries.length {
        x64LoadSlot(edit code, 10, 0)
        x64LoadMem64(edit code, 1, 10, libraries[k])
        x64MovReg(edit code, 0, 1)
        x64TestRax(edit code)
        hold skip = x64ConditionalPlaceholder(edit code, true)
        w64CallImport(edit code, edit imports, pe64ImportFreeLibrary())
        wwPatchHere(edit code, skip)
    }
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 6, 10, WB_CAPACITY)
    x64LoadSlot(edit code, 7, 0)
    wwCall(edit code, rt.text_drop)
    wwRet(edit code, 0)
    wwPatchHere(edit code, failed_open)
    wwRet(edit code, 0)
    give entry
}

// open(RDI = title Text, RSI = width, RDX = height). Slots: 0 title,
// 1 width, 2 height, 3 block, 4 capacity, 5 UTF-8 title, 6 its capacity,
// 7 UTF-16 title, 8 its capacity, 9 hInstance, 10 status, 11..20
// WNDCLASSEXW (RBP-168).
flow wwEmitOpen(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int, d: view WwData, wndproc: Int, buffer: Int, close: Int) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 21)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 7, 0)
    change invalid: List of[Int] = List[]
    change bad_title: List of[Int] = List[]
    change no_gui: List of[Int] = List[]
    change failed: List of[Int] = List[]
    each s among 1..3 {
        x64LoadSlot(edit code, 1, s)
        invalid@push(wwIf(edit code, 1, 1, 6))
        invalid@push(wwIf(edit code, 1, 16384, 8))
    }
    // A zeroed state block.
    x64MovImm64(edit code, 7, WB_SIZE)
    wwCall(edit code, rt.text_new)
    x64StoreSlot(edit code, 3, 0)
    x64StoreSlot(edit code, 4, 2)
    x64MovImm64(edit code, 1, 0)
    hold zero_top = code.bytes.length
    x64MovImm64(edit code, 10, WB_SIZE)
    hold zeroed = wwIfReg(edit code, 1, 10, 9)
    x64LoadSlot(edit code, 8, 3)
    x64AddReg(edit code, 8, 1)
    x64MovImm64(edit code, 0, 0)
    x64StoreMem64(edit code, 8, 0, 0)
    x64MovImm64(edit code, 10, 8)
    x64AddReg(edit code, 1, 10)
    wwJumpTo(edit code, zero_top)
    wwPatchHere(edit code, zeroed)
    x64LoadSlot(edit code, 10, 3)
    x64MovImm64(edit code, 0, WB_MAGIC_VALUE)
    x64StoreMem64(edit code, 10, WB_MAGIC, 0)
    x64LoadSlot(edit code, 0, 4)
    x64StoreMem64(edit code, 10, WB_CAPACITY, 0)
    // user32 and gdi32 from system32, kept until close.
    hold dlls: List of[Int] = List[d.user32, d.gdi32]
    hold dll_slots: List of[Int] = List[WB_USER32, WB_GDI32]
    each k among 0..dlls.length {
        wwLea(edit code, 1, dlls[k])
        x64MovImm64(edit code, 2, 0)
        x64MovImm64(edit code, 8, WW_SYSTEM32)
        w64CallImport(edit code, edit imports, pe64ImportLoadLibraryExW())
        x64LoadSlot(edit code, 10, 3)
        x64StoreMem64(edit code, 10, dll_slots[k], 0)
        x64TestRax(edit code)
        no_gui@push(x64ConditionalPlaceholder(edit code, true))
    }
    each i among 0..WF_COUNT {
        x64LoadSlot(edit code, 10, 3)
        when i < WF_USER32_COUNT { x64LoadMem64(edit code, 1, 10, WB_USER32) }
        otherwise { x64LoadMem64(edit code, 1, 10, WB_GDI32) }
        wwLea(edit code, 2, d.names[i])
        w64CallImport(edit code, edit imports, pe64ImportGetProcAddress())
        x64LoadSlot(edit code, 10, 3)
        x64StoreMem64(edit code, 10, WB_FN + 8 * i, 0)
        x64TestRax(edit code)
        failed@push(x64ConditionalPlaceholder(edit code, true))
    }
    // Title: validated UTF-8, then UTF-16.
    x64LoadSlot(edit code, 7, 0)
    wwCall(edit code, path_z)
    x64StoreSlot(edit code, 5, 0)
    x64StoreSlot(edit code, 6, 2)
    x64TestRax(edit code)
    bad_title@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 7, 5)
    wwCall(edit code, wide_z)
    x64StoreSlot(edit code, 7, 0)
    x64StoreSlot(edit code, 8, 2)
    x64LoadSlot(edit code, 7, 5)
    x64LoadSlot(edit code, 6, 6)
    wwCall(edit code, rt.text_drop)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, 5, 0)
    x64LoadSlot(edit code, 0, 7)
    x64TestRax(edit code)
    bad_title@push(x64ConditionalPlaceholder(edit code, true))
    // hInstance: .text is one section alignment above the image base.
    wwLea(edit code, 0, 0)
    x64MovImm64(edit code, 10, 4096)
    x64SubReg(edit code, 0, 10)
    x64StoreSlot(edit code, 9, 0)
    // WNDCLASSEXW: cbSize 80, CS_HREDRAW | CS_VREDRAW, the WndProc adapter,
    // hInstance, the arrow cursor, the class name. Registered once per
    // process: ERROR_CLASS_ALREADY_EXISTS (1410) is accepted.
    x64MovImm64(edit code, 0, 0)
    each s among 11..21 { x64StoreSlot(edit code, s, 0) }
    x64MovImm64(edit code, 0, 12884901968)
    x64StoreSlot(edit code, 20, 0)
    wwLea(edit code, 0, wndproc)
    x64StoreSlot(edit code, 19, 0)
    x64LoadSlot(edit code, 0, 9)
    x64StoreSlot(edit code, 17, 0)
    x64MovImm64(edit code, 1, 0)
    x64MovImm64(edit code, 2, 32512)            // IDC_ARROW
    wwFn(edit code, 3, WF_LOADCURSOR)
    x64StoreSlot(edit code, 15, 0)
    wwLea(edit code, 0, d.class_name)
    x64StoreSlot(edit code, 12, 0)
    x64LeaMem(edit code, 1, 5, -168)
    wwFn(edit code, 3, WF_REGISTER)
    x64MovImm64(edit code, 10, 65535)
    x64AndReg(edit code, 0, 10)
    x64TestRax(edit code)
    hold registered = x64ConditionalPlaceholder(edit code, false)
    w64CallImport(edit code, edit imports, pe64ImportGetLastError())
    wwDword(edit code)
    x64MovReg(edit code, 1, 0)
    failed@push(wwIf(edit code, 1, 1410, 5))
    wwPatchHere(edit code, registered)
    // Back buffer: a memory DC with the DIB section, a monospace font and
    // transparent text.
    x64MovImm64(edit code, 1, 0)
    wwFn(edit code, 3, WF_CREATEDC)
    x64LoadSlot(edit code, 10, 3)
    x64StoreMem64(edit code, 10, WB_MEMDC, 0)
    x64TestRax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 7, 3)
    x64LoadSlot(edit code, 6, 1)
    x64LoadSlot(edit code, 2, 2)
    wwCall(edit code, buffer)
    x64TestRax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, false))
    // CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
    // CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, "Consolas").
    hold font_args: List of[Int] = List[400, 0, 0, 0, 1, 0, 0, 5, 49]
    each k among 0..font_args.length {
        x64MovImm64(edit code, 0, font_args[k])
        wwStackArg(edit code, k, 0)
    }
    wwLea(edit code, 0, d.font)
    wwStackArg(edit code, 9, 0)
    x64MovImm64(edit code, 1, -16)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    x64MovImm64(edit code, 9, 0)
    wwFn(edit code, 3, WF_CREATEFONT)
    x64LoadSlot(edit code, 10, 3)
    x64StoreMem64(edit code, 10, WB_FONT, 0)
    x64TestRax(edit code)
    hold no_font = x64ConditionalPlaceholder(edit code, true)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64MovReg(edit code, 2, 0)
    wwFn(edit code, 3, WF_SELECT)
    x64LoadSlot(edit code, 10, 3)
    x64StoreMem64(edit code, 10, WB_OLDFONT, 0)
    wwPatchHere(edit code, no_font)
    x64LoadSlot(edit code, 10, 3)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64MovImm64(edit code, 2, 1)                // TRANSPARENT
    wwFn(edit code, 3, WF_SETBKMODE)
    // CreateWindowExW(0, class, title, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
    // CW_USEDEFAULT, width, height, NULL, NULL, hInstance, block).
    x64MovImm64(edit code, 0, 2147483648)
    wwStackArg(edit code, 0, 0)
    wwStackArg(edit code, 1, 0)
    x64LoadSlot(edit code, 0, 1)
    wwStackArg(edit code, 2, 0)
    x64LoadSlot(edit code, 0, 2)
    wwStackArg(edit code, 3, 0)
    x64MovImm64(edit code, 0, 0)
    wwStackArg(edit code, 4, 0)
    wwStackArg(edit code, 5, 0)
    x64LoadSlot(edit code, 0, 9)
    wwStackArg(edit code, 6, 0)
    x64LoadSlot(edit code, 0, 3)
    wwStackArg(edit code, 7, 0)
    x64MovImm64(edit code, 1, 0)
    wwLea(edit code, 2, d.class_name)
    x64LoadSlot(edit code, 8, 7)
    x64MovImm64(edit code, 9, 13565952)
    wwFn(edit code, 3, WF_CREATEWINDOW)
    x64LoadSlot(edit code, 10, 3)
    x64StoreMem64(edit code, 10, WB_HWND, 0)
    x64TestRax(edit code)
    failed@push(x64ConditionalPlaceholder(edit code, true))
    x64LoadSlot(edit code, 10, 3)
    x64LoadMem64(edit code, 1, 10, WB_HWND)
    x64MovImm64(edit code, 2, 5)                // SW_SHOW
    wwFn(edit code, 3, WF_SHOW)
    x64LoadSlot(edit code, 7, 7)
    x64LoadSlot(edit code, 6, 8)
    wwCall(edit code, rt.text_drop)
    x64LoadSlot(edit code, 0, 3)
    x64FrameEnd(edit code)

    // Failures after the block exists: release it through close.
    hold statuses: List of[Int] = List[-7, -1, -5]
    change exits: List of[Int] = List[]
    each k among 0..statuses.length {
        when k == 0 { wwPatchAll(edit code, view no_gui) }
        otherwise when k == 1 { wwPatchAll(edit code, view bad_title) }
        otherwise { wwPatchAll(edit code, view failed) }
        x64MovImm64(edit code, 0, statuses[k])
        x64StoreSlot(edit code, 10, 0)
        exits@push(x64JumpPlaceholder(edit code))
    }
    wwPatchAll(edit code, view exits)
    x64LoadSlot(edit code, 0, 7)
    x64TestRax(edit code)
    hold no_wide = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 7, 7)
    x64LoadSlot(edit code, 6, 8)
    wwCall(edit code, rt.text_drop)
    wwPatchHere(edit code, no_wide)
    x64LoadSlot(edit code, 7, 3)
    wwCall(edit code, close)
    x64LoadSlot(edit code, 0, 10)
    x64FrameEnd(edit code)
    wwPatchAll(edit code, view invalid)
    wwRet(edit code, -1)
    give entry
}

// next(RDI = block). Slots: 0 block, 1..6 MSG (RBP-56), 7 packed.
flow wwEmitNext(code: edit X64Code, buffer: Int) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 8)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    hold top = code.bytes.length
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_HEAD)
    x64LoadMem64(edit code, 2, 10, WB_TAIL)
    hold empty = wwIfReg(edit code, 1, 2, 9)
    x64LoadSlot(edit code, 10, 0)
    x64MovReg(edit code, 8, 1)
    x64MovImm64(edit code, 9, 255)
    x64AndReg(edit code, 8, 9)
    x64MovImm64(edit code, 9, 8)
    x64MulReg(edit code, 8, 9)
    x64AddReg(edit code, 8, 10)
    x64LoadMem64(edit code, 0, 8, WB_RING)
    x64StoreSlot(edit code, 7, 0)
    x64MovImm64(edit code, 9, 1)
    x64AddReg(edit code, 1, 9)
    x64StoreMem64(edit code, 10, WB_HEAD, 1)
    // A resize event replaces the back buffer before it is reported.
    x64LoadSlot(edit code, 0, 7)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 9, WW_KIND)
    x64DivUnsignedReg(edit code, 9)
    x64MovReg(edit code, 1, 0)
    hold not_resize = wwIf(edit code, 1, 10, 5)
    x64LoadSlot(edit code, 0, 7)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 9, 65536)
    x64DivUnsignedReg(edit code, 9)
    x64MovImm64(edit code, 9, 65535)
    x64AndReg(edit code, 0, 9)
    x64MovReg(edit code, 6, 0)
    x64LoadSlot(edit code, 0, 7)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 9, 4294967296)
    x64DivUnsignedReg(edit code, 9)
    x64MovImm64(edit code, 9, 65535)
    x64AndReg(edit code, 0, 9)
    x64MovReg(edit code, 2, 0)
    x64MovReg(edit code, 1, 6)
    hold zero_width = wwIf(edit code, 1, 0, 4)
    x64MovReg(edit code, 1, 2)
    hold zero_height = wwIf(edit code, 1, 0, 4)
    x64LoadSlot(edit code, 7, 0)
    wwCall(edit code, buffer)
    wwPatchHere(edit code, zero_width)
    wwPatchHere(edit code, zero_height)
    wwPatchHere(edit code, not_resize)
    x64LoadSlot(edit code, 0, 7)
    x64FrameEnd(edit code)
    // Empty: report dropped events once, otherwise pump one message.
    wwPatchHere(edit code, empty)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_OVERFLOW)
    hold no_overflow = wwIf(edit code, 1, 0, 4)
    x64MovImm64(edit code, 0, 0)
    x64LoadSlot(edit code, 10, 0)
    x64StoreMem64(edit code, 10, WB_OVERFLOW, 0)
    wwRet(edit code, 15 * WW_KIND)
    wwPatchHere(edit code, no_overflow)
    x64LeaMem(edit code, 1, 5, -56)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    x64MovImm64(edit code, 9, 0)
    wwFn(edit code, 0, WF_GETMESSAGE)
    wwDword(edit code)
    x64MovReg(edit code, 1, 0)
    hold quit = wwIf(edit code, 1, 0, 4)
    hold error = wwIf(edit code, 1, WW_DWORD, 4)
    x64LeaMem(edit code, 1, 5, -56)
    wwFn(edit code, 0, WF_TRANSLATE)
    x64LeaMem(edit code, 1, 5, -56)
    wwFn(edit code, 0, WF_DISPATCH)
    wwJumpTo(edit code, top)
    wwPatchHere(edit code, quit)
    wwRet(edit code, 13 * WW_KIND)
    wwPatchHere(edit code, error)
    wwRet(edit code, -5)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    give entry
}

// fill(RDI = block, RSI = x, RDX = y, RCX = width, R8 = height, R9 = rgb):
// writes the clipped rectangle straight into the DIB memory (pixel dword
// 0x00RRGGBB). Slots: 0 block, 1 x, 2 y, 3 w, 4 h, 5 rgb, 6 x0, 7 y0,
// 8 x1, 9 y1, 10 pixel pair, 11 row.
flow wwEmitFill(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 12)
    hold regs: List of[Int] = List[7, 6, 2, 1, 8, 9]
    each k among 0..6 { x64StoreSlot(edit code, k, regs[k]) }
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    change invalid: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 3)
    invalid@push(wwIf(edit code, 1, 0, 6))
    x64LoadSlot(edit code, 1, 4)
    invalid@push(wwIf(edit code, 1, 0, 6))
    x64LoadSlot(edit code, 1, 5)
    invalid@push(wwIf(edit code, 1, 0, 6))
    invalid@push(wwIf(edit code, 1, 16777215, 8))
    wwFn(edit code, 0, WF_GDIFLUSH)
    // x0 = max(x, 0), y0 = max(y, 0).
    each k among 0..2 {
        x64LoadSlot(edit code, 1, 1 + k)
        hold keep = wwIf(edit code, 1, 0, 9)
        x64MovImm64(edit code, 1, 0)
        wwPatchHere(edit code, keep)
        x64StoreSlot(edit code, 6 + k, 1)
    }
    // x1 = min(x + w, width), y1 = min(y + h, height).
    hold limits: List of[Int] = List[WB_WIDTH, WB_HEIGHT]
    each k among 0..2 {
        x64LoadSlot(edit code, 1, 1 + k)
        x64LoadSlot(edit code, 2, 3 + k)
        x64AddReg(edit code, 1, 2)
        x64LoadSlot(edit code, 8, 0)
        x64LoadMem64(edit code, 2, 8, limits[k])
        hold keep = wwIfReg(edit code, 1, 2, 7)
        x64MovReg(edit code, 1, 2)
        wwPatchHere(edit code, keep)
        x64StoreSlot(edit code, 8 + k, 1)
    }
    change done: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 6)
    x64LoadSlot(edit code, 2, 8)
    done@push(wwIfReg(edit code, 1, 2, 9))
    x64LoadSlot(edit code, 1, 7)
    x64LoadSlot(edit code, 2, 9)
    done@push(wwIfReg(edit code, 1, 2, 9))
    x64LoadSlot(edit code, 1, 5)
    x64MovReg(edit code, 2, 1)
    x64MovImm64(edit code, 10, 4294967296)
    x64MulReg(edit code, 2, 10)
    x64AddReg(edit code, 1, 2)
    x64StoreSlot(edit code, 10, 1)
    x64LoadSlot(edit code, 1, 7)
    x64StoreSlot(edit code, 11, 1)
    hold row_top = code.bytes.length
    x64LoadSlot(edit code, 1, 11)
    x64LoadSlot(edit code, 2, 9)
    done@push(wwIfReg(edit code, 1, 2, 9))
    // R8 = bits + (row * width + x0) * 4, R9 = x1 - x0, RDX = pixel pair.
    x64LoadSlot(edit code, 8, 0)
    x64LoadMem64(edit code, 2, 8, WB_WIDTH)
    x64MulReg(edit code, 1, 2)
    x64LoadSlot(edit code, 2, 6)
    x64AddReg(edit code, 1, 2)
    x64MovImm64(edit code, 10, 4)
    x64MulReg(edit code, 1, 10)
    x64LoadMem64(edit code, 2, 8, WB_BITS)
    x64AddReg(edit code, 1, 2)
    x64MovReg(edit code, 8, 1)
    x64LoadSlot(edit code, 9, 8)
    x64LoadSlot(edit code, 2, 6)
    x64SubReg(edit code, 9, 2)
    x64LoadSlot(edit code, 2, 10)
    hold pair_top = code.bytes.length
    x64MovImm64(edit code, 10, 2)
    hold tail = wwIfReg(edit code, 9, 10, 6)
    x64StoreMem64(edit code, 8, 0, 2)
    x64MovImm64(edit code, 10, 8)
    x64AddReg(edit code, 8, 10)
    x64MovImm64(edit code, 10, -2)
    x64AddReg(edit code, 9, 10)
    wwJumpTo(edit code, pair_top)
    wwPatchHere(edit code, tail)
    hold no_tail = wwIf(edit code, 9, 1, 5)
    // The last pixel of an odd-width row: four bytes, B, G, R, 0.
    x64LoadSlot(edit code, 0, 5)
    x64StoreMem8(edit code, 8, 0, 0)
    each k among 1..3 {
        x64MovImm64(edit code, 2, 0)
        x64MovImm64(edit code, 10, 256)
        x64DivUnsignedReg(edit code, 10)
        x64StoreMem8(edit code, 8, k, 0)
    }
    x64MovImm64(edit code, 0, 0)
    x64StoreMem8(edit code, 8, 3, 0)
    wwPatchHere(edit code, no_tail)
    x64LoadSlot(edit code, 1, 11)
    x64MovImm64(edit code, 10, 1)
    x64AddReg(edit code, 1, 10)
    x64StoreSlot(edit code, 11, 1)
    wwJumpTo(edit code, row_top)
    wwPatchAll(edit code, view done)
    wwRet(edit code, 0)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    wwPatchAll(edit code, view invalid)
    wwRet(edit code, -1)
    give entry
}

// text(RDI = block, RSI = x, RDX = y, RCX = Text, R8 = rgb). Slots:
// 0 block, 1 x, 2 y, 3 Text, 4 rgb, 5 UTF-16 copy, 6 its capacity,
// 7 units, 8 COLORREF, 9 ExtTextOutW result.
flow wwEmitText(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 10)
    hold regs: List of[Int] = List[7, 6, 2, 1, 8]
    each k among 0..5 { x64StoreSlot(edit code, k, regs[k]) }
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    change invalid: List of[Int] = List[]
    x64LoadSlot(edit code, 1, 4)
    invalid@push(wwIf(edit code, 1, 0, 6))
    invalid@push(wwIf(edit code, 1, 16777215, 8))
    x64LoadSlot(edit code, 10, 3)
    x64LoadMem64(edit code, 1, 10, 8)
    hold empty = wwIf(edit code, 1, 0, 4)
    invalid@push(wwIf(edit code, 1, 65536, 8))
    // Units: MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, n,
    // NULL, 0); then the conversion into a fresh buffer.
    each pass among 0..2 {
        x64MovImm64(edit code, 1, 65001)
        x64MovImm64(edit code, 2, 8)
        x64LoadSlot(edit code, 10, 3)
        x64LoadMem64(edit code, 8, 10, 0)
        x64LoadMem64(edit code, 9, 10, 8)
        when pass == 0 {
            x64MovImm64(edit code, 0, 0)
            wwStackArg(edit code, 0, 0)
            wwStackArg(edit code, 1, 0)
        } otherwise {
            x64LoadSlot(edit code, 0, 5)
            wwStackArg(edit code, 0, 0)
            x64LoadSlot(edit code, 0, 7)
            wwStackArg(edit code, 1, 0)
        }
        w64CallImport(edit code, edit imports, pe64ImportMultiByteToWideChar())
        when pass == 0 {
            wwDword(edit code)
            x64StoreSlot(edit code, 7, 0)
            x64TestRax(edit code)
            invalid@push(x64ConditionalPlaceholder(edit code, true))
            x64LoadSlot(edit code, 7, 7)
            x64AddReg(edit code, 7, 7)
            wwCall(edit code, rt.text_new)
            x64StoreSlot(edit code, 5, 0)
            x64StoreSlot(edit code, 6, 2)
        }
    }
    // COLORREF 0x00BBGGRR from 0xRRGGBB.
    x64LoadSlot(edit code, 0, 4)
    x64MovImm64(edit code, 10, 255)
    x64AndReg(edit code, 0, 10)
    x64MovImm64(edit code, 10, 65536)
    x64MulReg(edit code, 0, 10)
    x64StoreSlot(edit code, 8, 0)
    hold divisors: List of[Int] = List[256, 65536]
    hold scales: List of[Int] = List[256, 1]
    each k among 0..2 {
        x64LoadSlot(edit code, 0, 4)
        x64MovImm64(edit code, 2, 0)
        x64MovImm64(edit code, 10, divisors[k])
        x64DivUnsignedReg(edit code, 10)
        x64MovImm64(edit code, 10, 255)
        x64AndReg(edit code, 0, 10)
        x64MovImm64(edit code, 10, scales[k])
        x64MulReg(edit code, 0, 10)
        x64LoadSlot(edit code, 1, 8)
        x64AddReg(edit code, 1, 0)
        x64StoreSlot(edit code, 8, 1)
    }
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64LoadSlot(edit code, 2, 8)
    wwFn(edit code, 0, WF_SETTEXTCOLOR)
    // ExtTextOutW(memdc, x, y, 0, NULL, text, units, NULL).
    x64MovImm64(edit code, 0, 0)
    wwStackArg(edit code, 0, 0)
    x64LoadSlot(edit code, 0, 5)
    wwStackArg(edit code, 1, 0)
    x64LoadSlot(edit code, 0, 7)
    wwStackArg(edit code, 2, 0)
    x64MovImm64(edit code, 0, 0)
    wwStackArg(edit code, 3, 0)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_MEMDC)
    x64LoadSlot(edit code, 2, 1)
    x64LoadSlot(edit code, 8, 2)
    x64MovImm64(edit code, 9, 0)
    wwFn(edit code, 0, WF_EXTTEXTOUT)
    wwDword(edit code)
    x64StoreSlot(edit code, 9, 0)
    x64LoadSlot(edit code, 7, 5)
    x64LoadSlot(edit code, 6, 6)
    wwCall(edit code, rt.text_drop)
    x64LoadSlot(edit code, 0, 9)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    wwRet(edit code, 0)
    wwPatchHere(edit code, failed)
    wwRet(edit code, -5)
    wwPatchHere(edit code, empty)
    wwRet(edit code, 0)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    wwPatchAll(edit code, view invalid)
    wwRet(edit code, -1)
    give entry
}

// present(RDI = block): InvalidateRect(hwnd, NULL, FALSE).
flow wwEmitPresent(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 1)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_HWND)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    wwFn(edit code, 0, WF_INVALIDATE)
    wwDword(edit code)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    wwRet(edit code, 0)
    wwPatchHere(edit code, failed)
    wwRet(edit code, -5)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    give entry
}

// send(RDI = block, RSI = msg, RDX = wParam, RCX = lParam): PostMessageW to
// this window, for input and close messages only.
flow wwEmitSend(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 4)
    hold regs: List of[Int] = List[7, 6, 2, 1]
    each k among 0..4 { x64StoreSlot(edit code, k, regs[k]) }
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    x64LoadSlot(edit code, 1, 1)
    hold allowed: List of[Int] = List[16, 256, 257, 258, 260, 261, 512, 513, 514, 516, 517, 522]
    change ok: List of[Int] = List[]
    each k among 0..allowed.length { ok@push(wwIf(edit code, 1, allowed[k], 4)) }
    wwRet(edit code, -1)
    wwPatchAll(edit code, view ok)
    x64LoadSlot(edit code, 10, 0)
    x64LoadMem64(edit code, 1, 10, WB_HWND)
    x64LoadSlot(edit code, 2, 1)
    x64LoadSlot(edit code, 8, 2)
    x64LoadSlot(edit code, 9, 3)
    wwFn(edit code, 0, WF_POST)
    wwDword(edit code)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, true)
    wwRet(edit code, 0)
    wwPatchHere(edit code, failed)
    wwRet(edit code, -5)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    give entry
}

// pixel(RDI = block, RSI = x, RDX = y) -> 0xRRGGBB of the back buffer.
flow wwEmitPixel(code: edit X64Code) => Int {
    hold entry = code.bytes.length
    wwBegin(edit code, 3)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64MovReg(edit code, 1, 7)
    hold not_open = wwIf(edit code, 1, 0, 7)
    change invalid: List of[Int] = List[]
    hold limits: List of[Int] = List[WB_WIDTH, WB_HEIGHT]
    each k among 0..2 {
        x64LoadSlot(edit code, 1, 1 + k)
        invalid@push(wwIf(edit code, 1, 0, 6))
        x64LoadSlot(edit code, 8, 0)
        x64LoadMem64(edit code, 2, 8, limits[k])
        invalid@push(wwIfReg(edit code, 1, 2, 9))
    }
    wwFn(edit code, 0, WF_GDIFLUSH)
    x64LoadSlot(edit code, 8, 0)
    x64LoadSlot(edit code, 1, 2)
    x64LoadMem64(edit code, 2, 8, WB_WIDTH)
    x64MulReg(edit code, 1, 2)
    x64LoadSlot(edit code, 2, 1)
    x64AddReg(edit code, 1, 2)
    x64MovImm64(edit code, 10, 4)
    x64MulReg(edit code, 1, 10)
    x64LoadMem64(edit code, 2, 8, WB_BITS)
    x64AddReg(edit code, 1, 2)
    x64LoadMem32(edit code, 0, 1, 0)
    x64MovImm64(edit code, 10, 16777215)
    x64AndReg(edit code, 0, 10)
    x64FrameEnd(edit code)
    wwPatchHere(edit code, not_open)
    wwRet(edit code, -6)
    wwPatchAll(edit code, view invalid)
    wwRet(edit code, -1)
    give entry
}

// Emits the window routines; returns their entries for platform codes
// 17..25 (open, status, next, fill, text, present, send, pixel, close).
expose flow w64EmitWindows(code: edit X64Code, imports: edit Pe64Imports, rt: view PfRuntime, path_z: Int, wide_z: Int) => List of[Int] {
    hold d = wwEmitData(edit code)
    hold target = wwEmitWndProc(edit code, edit imports, view d)
    hold wndproc = w64EmitCallback4(edit code, target)
    hold buffer = wwEmitBuffer(edit code)
    hold close = wwEmitClose(edit code, edit imports, rt)
    change at: List of[Int] = List[]
    at@push(wwEmitOpen(edit code, edit imports, rt, path_z, wide_z, view d, wndproc, buffer, close))
    at@push(pfEmitFileStatus(edit code))
    at@push(wwEmitNext(edit code, buffer))
    at@push(wwEmitFill(edit code))
    at@push(wwEmitText(edit code, edit imports, rt))
    at@push(wwEmitPresent(edit code))
    at@push(wwEmitSend(edit code))
    at@push(wwEmitPixel(edit code))
    at@push(close)
    give at
}
