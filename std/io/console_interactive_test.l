// Interactive (Windows console) test of std/io/console.l. It must run on a
// real console: tests/std/console_input.ps1 allocates one and writes these
// INPUT_RECORDs with WriteConsoleInputW before starting this program:
//   'a'; Ctrl+S; Up; Shift press (bare modifier), Shift+'A' press and its
//   release; U+1F600 as a surrogate pair; AltGr+'2' giving '@'; a
//   100x30 buffer resize; a left click at (5, 7); F5 with repeat 3;
//   Escape.
// Exit status 0 on success, otherwise the number of the failed check. The
// console mode is restored on every path, and an unexpected event is printed
// so a failure can be diagnosed from the harness log.
take console

flow expectKey(ev: view ConsoleEvent, key: Int, character: Int, mods: Int) => Bool {
    give ev.kind == EVENT_KEY && ev.key == key && ev.character == character && ev.modifiers == mods && ev.pressed
}

flow report(check: Int, ev: view ConsoleEvent) {
    print("check {check} got kind={ev.kind} key={ev.key} character={ev.character} modifiers={ev.modifiers} pressed={ev.pressed} repeat={ev.repeat} x={ev.x} y={ev.y} buttons={ev.buttons} wheel={ev.wheel}")
}

flow readAll(reader: edit ConsoleReader) => Int {
    hold e1 = consoleNext(edit reader)
    when !expectKey(view e1, KEY_CHAR, 97, 0) { report(2, view e1) give 2 }
    hold e2 = consoleNext(edit reader)
    when !isCtrl(view e2, 115) { report(3, view e2) give 3 }
    hold e3 = consoleNext(edit reader)
    when !expectKey(view e3, KEY_UP, 0, 0) { report(4, view e3) give 4 }
    // The bare Shift press is skipped; Shift is folded into 'A'.
    hold e4 = consoleNext(edit reader)
    when !expectKey(view e4, KEY_CHAR, 65, 0) { report(5, view e4) give 5 }
    // The release of 'A' is skipped.
    hold e5 = consoleNext(edit reader)
    when !expectKey(view e5, KEY_CHAR, 128512, 0) { report(6, view e5) give 6 }
    hold e6 = consoleNext(edit reader)
    when !expectKey(view e6, KEY_CHAR, 64, 0) { report(7, view e6) give 7 }
    hold e7 = consoleNext(edit reader)
    when e7.kind != EVENT_RESIZE || e7.x != 100 || e7.y != 30 { report(8, view e7) give 8 }
    hold e8 = consoleNext(edit reader)
    when e8.kind != EVENT_MOUSE || e8.x != 5 || e8.y != 7 || e8.buttons != MOUSE_LEFT || e8.wheel != 0 { report(9, view e8) give 9 }
    hold e9 = consoleNext(edit reader)
    when !expectKey(view e9, KEY_F1 + 4, 0, 0) || e9.repeat != 3 { report(10, view e9) give 10 }
    hold e10 = consoleNext(edit reader)
    when !expectKey(view e10, KEY_ESCAPE, 0, 0) { report(11, view e10) give 11 }
    // Raw mode was in force while reading.
    when consoleInputMode(-1) == reader.saved { give 13 }
    give 0
}

flow main() => Int {
    change reader = consoleOpen()
    when !reader.interactive { give 1 }
    hold original = reader.saved
    hold status = readAll(edit reader)
    when consoleClose(edit reader) != 0 { give 12 }
    // After restoring, the console reports the original state again.
    when consoleInputMode(-1) != original { give 14 }
    give status
}
