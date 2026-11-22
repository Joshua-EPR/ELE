// Decoder test of std/io/console.l over redirected (byte) input. The harness
// (tests/std/console_input.ps1) pipes this exact byte sequence:
//   "a"  C3 A9 ("é")  ESC[A  ESC[1;5C  ESC[3~  13 ("Ctrl+S")  7F  CR  TAB
//   ESC ESC  ESCOP  ESC[15~  F0 9F 98 80 (U+1F600)  FF  ESC "x" ("Alt+x")
//   then end of input.
// Exit status 0 on success, otherwise the number of the failed check.
take console

flow expectKey(ev: view ConsoleEvent, key: Int, character: Int, mods: Int) => Bool {
    give ev.kind == EVENT_KEY && ev.key == key && ev.character == character && ev.modifiers == mods && ev.pressed
}

flow main() => Int {
    change reader = consoleOpen()
    // Redirected input is not an interactive console.
    when reader.interactive { give 1 }
    hold e1 = consoleNext(edit reader)
    when !expectKey(view e1, KEY_CHAR, 97, 0) { give 2 }
    hold e2 = consoleNext(edit reader)
    when !expectKey(view e2, KEY_CHAR, 233, 0) { give 3 }
    hold e3 = consoleNext(edit reader)
    when !expectKey(view e3, KEY_UP, 0, 0) { give 4 }
    hold e4 = consoleNext(edit reader)
    when !expectKey(view e4, KEY_RIGHT, 0, MOD_CTRL) { give 5 }
    hold e5 = consoleNext(edit reader)
    when !expectKey(view e5, KEY_DELETE, 0, 0) { give 6 }
    hold e6 = consoleNext(edit reader)
    when !isCtrl(view e6, 115) { give 7 }
    hold e7 = consoleNext(edit reader)
    when !expectKey(view e7, KEY_BACKSPACE, 0, 0) { give 8 }
    hold e8 = consoleNext(edit reader)
    when !expectKey(view e8, KEY_ENTER, 0, 0) { give 9 }
    hold e9 = consoleNext(edit reader)
    when !expectKey(view e9, KEY_TAB, 0, 0) { give 10 }
    hold e10 = consoleNext(edit reader)
    when !expectKey(view e10, KEY_ESCAPE, 0, 0) { give 11 }
    hold e11 = consoleNext(edit reader)
    when !expectKey(view e11, KEY_F1, 0, 0) { give 12 }
    hold e12 = consoleNext(edit reader)
    when !expectKey(view e12, KEY_F1 + 4, 0, 0) { give 13 }
    hold e13 = consoleNext(edit reader)
    when !expectKey(view e13, KEY_CHAR, 128512, 0) { give 14 }
    hold e14 = consoleNext(edit reader)
    when !expectKey(view e14, KEY_CHAR, 65533, 0) { give 15 }
    hold e15 = consoleNext(edit reader)
    when !expectKey(view e15, KEY_CHAR, 120, MOD_ALT) { give 16 }
    hold e16 = consoleNext(edit reader)
    when e16.kind != EVENT_END { give 17 }
    // End of input is stable.
    hold e17 = consoleNext(edit reader)
    when e17.kind != EVENT_END { give 18 }
    when consoleClose(edit reader) != 0 { give 19 }
    hold name = keyName(KEY_F1 + 11)
    hold f12 = "f12"
    when !sameText(view name, view f12) { give 20 }
    hold prefix = modifierPrefix(MOD_CTRL + MOD_SHIFT)
    hold expected_prefix = "ctrl+shift+"
    when !sameText(view prefix, view expected_prefix) { give 21 }
    give 0
}

flow sameText(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength { give false }
    change i = 0
    during i < a.byteLength {
        when a@byteAt(i) != b@byteAt(i) { give false }
        i += 1
    }
    give true
}
