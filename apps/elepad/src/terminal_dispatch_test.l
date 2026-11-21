take terminal_dispatch
take terminal_render

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
    print("elepad-dispatch-ok")
    give 0
}
