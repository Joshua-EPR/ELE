// In-process test of the window ELEPad (Windows): a real window and back
// buffer, WindowEvent values built directly (deterministic, no desktop
// input). Prints elepad-gui-ok; any other exit code names the failed check.
take gui_dispatch
take gui_render
take std.ui.window

fixed BACKGROUND = 1974052
fixed SELECTION = 2510712
fixed CURSOR = 16763904

flow event(kind: Int, key: Int, character: Int, mods: Int) => WindowEvent {
    give WindowEvent(kind: kind, key: key, vk: 0, pressed: true, character: character, modifiers: mods, x: 0, y: 0, action: MOUSE_MOVE, button: BUTTON_NONE, wheel: 0, width: 0, height: 0, focused: false, status: 0)
}

flow same(b: view Buffer, expected: view Text) => Bool {
    when length(b) != expected.byteLength { give false }
    change i = 0
    during i < expected.byteLength {
        when byteAt(b, i) != expected@byteAt(i) { give false }
        i += 1
    }
    give true
}

flow checks(w: view Window) => Int {
    // Wait for the first resize: the back buffer then has the client size.
    change reader = windowReader()
    change width = 0
    change height = 0
    during width == 0 {
        hold ev = windowEvent(w, edit reader)
        when ev.kind == WINDOW_ERROR { give 20 }
        when ev.kind == WINDOW_RESIZE {
            width = ev.width
            height = ev.height
        }
    }
    hold sample = "ab\tc\r\nsecond line"
    change editor = newEditor(view sample)
    change v = guiView(windowCell(w), width, height)
    hold cw = v.cell_w
    hold ch = v.cell_h
    hold title = "sample.l"
    when guiRender(w, editor, title, v) != 0 { give 21 }
    hold x0 = guiTextLeft(view editor.document, view v)
    hold y0 = guiTextTop(view v)
    // The cursor bar at line 1, column 0.
    when windowPixel(w, x0, y0 + ch / 2) != CURSOR { give 22 }
    // Text was drawn on line 1 (some pixel differs from the background).
    change inked = false
    change y = y0
    during y < y0 + ch && !inked {
        change x = x0 + 3
        during x < x0 + 6 * cw && !inked {
            hold p = windowPixel(w, x, y)
            when p != BACKGROUND && p != CURSOR { inked = true }
            x += 1
        }
        y += 1
    }
    when !inked { give 23 }
    // Tab expansion: 'c' is at column 4.
    when guiColumn(view editor.document, 3) != 4 { give 24 }
    // Shift+Right selects "a": its cell is highlighted above the glyph.
    hold select = event(WINDOW_KEY, KEY_RIGHT, 0, MOD_SHIFT)
    when guiCommand(edit editor, view select) != 4 { give 25 }
    when guiRender(w, editor, title, v) != 0 { give 26 }
    when windowPixel(w, x0 + cw / 2, y0 + 1) != SELECTION { give 27 }
    // A click on line 2, third cell: "second line" offset 6 + 2.
    hold clicked = guiOffsetAt(editor, v, x0 + 2 * cw + 1, y0 + ch + 2)
    when clicked != 8 { give 28 }
    // A click past the end of line 1 lands before its CR LF.
    when guiOffsetAt(editor, v, x0 + 40 * cw, y0 + 2) != 4 { give 29 }
    // Typing replaces the selection; Ctrl+Z (WM_CHAR 26) undoes it.
    hold typed = event(WINDOW_CHAR, KEY_NONE, 88, 0)
    guiCommand(edit editor, view typed)
    hold replaced = "Xb\tc\r\nsecond line"
    when !same(view editor.document, view replaced) { give 30 }
    hold undo = event(WINDOW_CHAR, KEY_NONE, 26, 0)
    when guiCommand(edit editor, view undo) != 4 { give 31 }
    when !same(view editor.document, view sample) { give 32 }
    // The key-down half of Ctrl+Z must not act a second time.
    hold redo_key = event(WINDOW_KEY, KEY_CHAR, 121, MOD_CTRL)
    when guiCommand(edit editor, view redo_key) != 0 { give 33 }
    when !same(view editor.document, view sample) { give 34 }
    // Control units of Backspace, Tab and Enter do not act as Ctrl+H/I/M.
    hold tab_unit = event(WINDOW_CHAR, KEY_NONE, 9, 0)
    guiCommand(edit editor, view tab_unit)
    when !same(view editor.document, view sample) { give 35 }
    // Ctrl+S (WM_CHAR 19) asks to save; Ctrl+Q (17) to quit.
    hold save = event(WINDOW_CHAR, KEY_NONE, 19, 0)
    when guiCommand(edit editor, view save) != 1 { give 36 }
    hold quit = event(WINDOW_CHAR, KEY_NONE, 17, 0)
    when guiCommand(edit editor, view quit) != 2 { give 37 }
    // Ctrl+F opens the find prompt, rendered in the status bar.
    hold find = event(WINDOW_CHAR, KEY_NONE, 6, 0)
    guiCommand(edit editor, view find)
    when editor.mode != MODE_FIND { give 38 }
    when guiRender(w, editor, title, v) != 0 { give 39 }
    give 0
}

flow main() => Int {
    hold title = "ELEPad GUI test"
    hold w = windowOpen(title, 640, 480)
    when windowStatus(w) != 0 {
        windowClose(w)
        give 10
    }
    hold result = checks(view w)
    hold closed = windowClose(w)
    when result != 0 { give result }
    when closed != 0 { give 11 }
    print("elepad-gui-ok")
    give 0
}
