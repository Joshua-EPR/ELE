take terminal_dispatch
take terminal_render
take document_io

flow event(key: Int, scalar: Int, mods: Int) => ConsoleEvent {
    give ConsoleEvent(kind: EVENT_KEY, key: key, character: scalar, modifiers: mods, pressed: true, repeat: 1, x: 0, y: 0, buttons: 0, wheel: 0)
}

flow equals(b: view Buffer, expected: view Text) => Bool {
    when length(b) != expected.byteLength { give false }
    change i = 0
    during i < expected.byteLength {
        when byteAt(b, i) != expected@byteAt(i) { give false }
        i += 1
    }
    give true
}

flow main() => Int {
    hold sample = "José\r\nELE"
    change e = newEditor(view sample)
    hold end = event(KEY_END, 0, 0)
    dispatchEvent(edit e, view end)
    when e.cursor.offset != 5 { give 1 }
    hold down_key = event(KEY_DOWN, 0, 0)
    dispatchEvent(edit e, view down_key)
    when e.cursor.offset != 10 { give 2 }
    hold accent = event(KEY_CHAR, 233, 0)
    dispatchEvent(edit e, view accent)
    hold inserted = "José\r\nELEé"
    when !equals(view e.document, view inserted) { give 3 }
    hold back = event(KEY_BACKSPACE, 0, 0)
    dispatchEvent(edit e, view back)
    when !equals(view e.document, view sample) { give 4 }
    hold home = event(KEY_HOME, 0, 0)
    dispatchEvent(edit e, view home)
    when e.cursor.offset != 7 { give 5 }
    dispatchEvent(edit e, view back)
    hold joined = "JoséELE"
    when !equals(view e.document, view joined) { give 6 }
    when e.cursor.offset != 5 { give 7 }
    hold enter = event(KEY_ENTER, 0, 0)
    dispatchEvent(edit e, view enter)
    when !equals(view e.document, view sample) { give 8 }
    hold save = event(KEY_CHAR, 115, MOD_CTRL)
    when dispatchEvent(edit e, view save) != 1 { give 9 }
    hold quit = event(KEY_CHAR, 113, MOD_CTRL)
    when dispatchEvent(edit e, view quit) != 2 { give 10 }
    when !equals(view e.document, view sample) { give 11 }
    hold invalid = event(KEY_CHAR, 55296, 0)
    dispatchEvent(edit e, view invalid)
    when !equals(view e.document, view sample) { give 12 }
    hold path = "sample.l"
    hold frame = renderFull(view e, view path, 0, 80, 24)
    when frame.length < sample.byteLength || frame[0] != 27 { give 13 }
    hold cursor = renderCursorOnly(view e, 0, 80, 24)
    when cursor.length < 4 || cursor[0] != 27 { give 14 }
    hold history = historyChecks()
    when history != 0 { give history }
    hold opening = openChecks()
    when opening != 0 { give opening }
    print("elepad-dispatch-ok")
    give 0
}

flow key(e: edit Editor, k: Int, scalar: Int, mods: Int) => Int {
    hold ev = event(k, scalar, mods)
    give dispatchEvent(edit e, view ev)
}

// Undo/redo, selection, clipboard and find through the dispatcher.
flow historyChecks() => Int {
    hold abc = "abc"
    change e = newEditor(view abc)
    key(edit e, KEY_CHAR, 120, 0)
    key(edit e, KEY_CHAR, 121, 0)
    hold xy = "xyabc"
    when !equals(view e.document, view xy) { give 20 }
    when !e.document.dirty { give 21 }
    when key(edit e, KEY_CHAR, 122, MOD_CTRL) != ACTION_REDRAW { give 22 }
    when !equals(view e.document, view abc) { give 23 }
    // Undo back to the loaded state is clean again.
    when e.document.dirty { give 24 }
    when e.cursor.offset != 0 { give 25 }
    key(edit e, KEY_CHAR, 121, MOD_CTRL)
    when !equals(view e.document, view xy) { give 26 }
    when e.cursor.offset != 2 { give 27 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    when !equals(view e.document, view abc) { give 28 }

    // Shift+Right twice selects "ab"; copy, End, paste.
    key(edit e, KEY_RIGHT, 0, MOD_SHIFT)
    when key(edit e, KEY_RIGHT, 0, MOD_SHIFT) != ACTION_REDRAW { give 30 }
    when selectionStart(view e) != 0 || selectionEnd(view e) != 2 { give 31 }
    hold frame = renderFull(view e, view abc, 0, 80, 24)
    when !containsReverse(view frame) { give 32 }
    key(edit e, KEY_CHAR, 99, MOD_CTRL)
    key(edit e, KEY_END, 0, 0)
    when editorHasSelection(view e) { give 33 }
    key(edit e, KEY_CHAR, 118, MOD_CTRL)
    hold pasted = "abcab"
    when !equals(view e.document, view pasted) { give 34 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    when !equals(view e.document, view abc) { give 35 }

    // Select all, cut, paste, then undo both steps.
    key(edit e, KEY_CHAR, 97, MOD_CTRL)
    key(edit e, KEY_CHAR, 120, MOD_CTRL)
    when length(view e.document) != 0 { give 40 }
    key(edit e, KEY_CHAR, 118, MOD_CTRL)
    when !equals(view e.document, view abc) { give 41 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    when length(view e.document) != 0 { give 42 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    when !equals(view e.document, view abc) { give 43 }

    // Typing over a selection replaces it as one undo step.
    key(edit e, KEY_CHAR, 97, MOD_CTRL)
    key(edit e, KEY_CHAR, 122, 0)
    hold z = "z"
    when !equals(view e.document, view z) { give 50 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    when !equals(view e.document, view abc) { give 51 }

    // A new edit after undo discards the redo branch.
    key(edit e, KEY_END, 0, 0)
    key(edit e, KEY_CHAR, 33, 0)
    key(edit e, KEY_CHAR, 121, MOD_CTRL)
    hold bang = "abc!"
    when !equals(view e.document, view bang) { give 52 }

    // Backspace deletes a selection; UTF-8 delete/undo round trip.
    key(edit e, KEY_LEFT, 0, MOD_SHIFT)
    key(edit e, KEY_BACKSPACE, 0, 0)
    when !equals(view e.document, view abc) { give 53 }
    key(edit e, KEY_CHAR, 233, 0)
    key(edit e, KEY_BACKSPACE, 0, 0)
    when !equals(view e.document, view abc) { give 54 }
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    hold accent = "abcé"
    when !equals(view e.document, view accent) { give 55 }

    // Find "b": Ctrl+F, type, Enter selects it; Escape leaves find mode.
    key(edit e, KEY_HOME, 0, 0)
    when key(edit e, KEY_CHAR, 102, MOD_CTRL) != ACTION_REDRAW { give 60 }
    when e.mode != MODE_FIND { give 61 }
    key(edit e, KEY_CHAR, 98, 0)
    when !equals(view e.document, view accent) { give 62 }
    key(edit e, KEY_ENTER, 0, 0)
    when selectionStart(view e) != 1 || selectionEnd(view e) != 2 { give 63 }
    key(edit e, KEY_BACKSPACE, 0, 0)
    key(edit e, KEY_CHAR, 113, 0)
    key(edit e, KEY_ENTER, 0, 0)
    when !e.find_failed { give 64 }
    key(edit e, KEY_ESCAPE, 0, 0)
    when e.mode != MODE_EDIT { give 65 }
    when !equals(view e.document, view accent) { give 66 }
    give 0
}

flow containsReverse(frame: view List of[Int]) => Bool {
    change i = 0
    during i + 3 < frame.length {
        when frame[i] == 27 && frame[i + 1] == 91 && frame[i + 2] == 55 && frame[i + 3] == 109 { give true }
        i += 1
    }
    give false
}

// Ctrl+O: the open prompt, then openDocument against real files.
flow openChecks() => Int {
    hold target = "elepad-open-target.l"
    hold content: List of[Int] = List[110, 101, 119, 13, 10, 76]         // "new\r\nL"
    when writeBytes(target, content) != 0 { give 70 }
    hold start = "abc"
    change e = newEditor(view start)
    change current = "first.l"
    when key(edit e, KEY_CHAR, 111, MOD_CTRL) != ACTION_REDRAW { give 71 }
    when e.mode != MODE_OPEN { give 72 }
    // Typing the path; Backspace removes a whole scalar ("é" is two bytes).
    hold typed = "elepad-open-target.lé"
    change k = 0
    during k < typed.byteLength {
        hold b = typed@byteAt(k)
        when b < 128 { key(edit e, KEY_CHAR, b, 0) }
        k += 1
    }
    key(edit e, KEY_CHAR, 233, 0)
    when e.path_len != 22 { give 73 }
    key(edit e, KEY_BACKSPACE, 0, 0)
    when e.path_len != 20 { give 74 }
    // Typing in the prompt never edits the document.
    when !equals(view e.document, view start) { give 75 }
    when key(edit e, KEY_ENTER, 0, 0) != ACTION_OPEN { give 76 }
    // Unsaved changes refuse the open.
    e.clipboard@push(90)
    e.mode = MODE_EDIT
    key(edit e, KEY_CHAR, 33, 0)
    e.mode = MODE_OPEN
    when openDocument(edit e, edit current) != OPEN_UNSAVED { give 77 }
    hold edited = "!abc"
    when !equals(view e.document, view edited) || e.open_failed != OPEN_UNSAVED { give 78 }
    // Back to the clean text, the open succeeds.
    e.mode = MODE_EDIT
    key(edit e, KEY_CHAR, 122, MOD_CTRL)
    e.mode = MODE_OPEN
    when openDocument(edit e, edit current) != OPEN_OK { give 79 }
    hold opened = "new\r\nL"
    when !equals(view e.document, view opened) { give 80 }
    when current.byteLength != 20 || current@byteAt(0) != 101 { give 81 }
    when e.mode != MODE_EDIT || e.document.dirty || !e.newline_crlf { give 82 }
    when e.clipboard.length != 1 || e.clipboard[0] != 90 || e.path_len != 20 { give 83 }
    // A missing file and a path that is not UTF-8.
    e.path_input@push(0)
    e.path_len = 21
    e.path_input[20] = 120                      // "elepad-open-target.lx"
    when openDocument(edit e, edit current) != OPEN_READ_FAILED { give 84 }
    e.path_input[20] = 255
    when openDocument(edit e, edit current) != OPEN_BAD_PATH { give 85 }
    when !equals(view e.document, view opened) || current.byteLength != 20 { give 86 }
    // Escape leaves the prompt.
    e.mode = MODE_OPEN
    key(edit e, KEY_ESCAPE, 0, 0)
    when e.mode != MODE_EDIT { give 87 }
    give 0
}
