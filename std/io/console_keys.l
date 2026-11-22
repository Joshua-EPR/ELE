// Interactive keyboard demo of std/io/console.l: prints every key, resize
// and mouse event until Escape or Ctrl+Q, then restores the console.
//   ele build std/io/console_keys.l -o console_keys.exe
take console

flow describe(ev: view ConsoleEvent) => Text {
    when ev.kind == EVENT_RESIZE { give "resize {ev.x}x{ev.y}" }
    when ev.kind == EVENT_MOUSE {
        give "mouse x={ev.x} y={ev.y} buttons={ev.buttons} wheel={ev.wheel}"
    }
    hold prefix = modifierPrefix(ev.modifiers)
    hold name = keyName(ev.key)
    when ev.key == KEY_CHAR { give "key {prefix}{name} U+{ev.character} repeat={ev.repeat}" }
    give "key {prefix}{name} repeat={ev.repeat}"
}

flow main() => Int {
    change reader = consoleOpen()
    when reader.interactive {
        print("ELE console input: press keys; Escape or Ctrl+Q exits.")
    } otherwise {
        print("ELE console input: reading redirected input until its end.")
    }
    change status = 0
    during true {
        hold ev = consoleNext(edit reader)
        when ev.kind == EVENT_END { leave }
        when ev.kind == EVENT_ERROR {
            printError("console read failed")
            status = 1
            leave
        }
        hold line = describe(view ev)
        print(line)
        when ev.kind == EVENT_KEY && ev.key == KEY_ESCAPE { leave }
        when isCtrl(view ev, 113) { leave }
        when isCtrl(view ev, 115) { print("  Ctrl+S detected (save)") }
    }
    when consoleClose(edit reader) != 0 {
        printError("console state could not be restored")
        give 2
    }
    print("console restored")
    give status
}
