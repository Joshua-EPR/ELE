// Native Window (P0-D) on Windows: open, draw into the back buffer and read
// it back, synthetic input through the real WndProc and message loop, the
// close request, and close. Prints window-events-ok and exits 0; any other
// exit code names the first failed check.
take std.ui.window
take std.io.console

// The next event that is not produced by the desktop itself (resize, focus
// and pointer movement depend on the session, not on this test).
flow nextInput(w: view Window, reader: edit WindowReader) => WindowEvent {
    during true {
        hold ev = windowEvent(w, edit reader)
        hold noise = ev.kind == WINDOW_RESIZE || ev.kind == WINDOW_FOCUS || (ev.kind == WINDOW_MOUSE && ev.action == MOUSE_MOVE)
        when !noise { give ev }
    }
    give windowEvent(w, edit reader)
}

flow drawChecks(w: view Window) => Int {
    when windowFill(w, 0, 0, 4000, 4000, 1056816) != 0 { give 30 }          // 0x102030, clipped
    when windowFill(w, 10, 10, 51, 21, 16744448) != 0 { give 31 }            // 0xFF8000, odd width
    when windowPixel(w, 5, 5) != 1056816 { give 32 }
    when windowPixel(w, 10, 10) != 16744448 { give 33 }
    when windowPixel(w, 60, 30) != 16744448 { give 34 }
    when windowPixel(w, 61, 30) != 1056816 { give 35 }
    when windowPixel(w, 60, 31) != 1056816 { give 36 }
    when windowPixel(w, -1, 0) != -1 || windowPixel(w, 0, 100000) != -1 { give 37 }
    when windowFill(w, 0, 0, 1, 1, 16777216) != -1 { give 38 }               // rgb out of range
    when windowFill(w, 0, 0, -1, 1, 0) != -1 { give 39 }
    hold label = "ELE ✓"
    when windowText(w, 100, 100, label, 16777215) != 0 { give 40 }
    change inked = false
    change y = 100
    during y < 120 && !inked {
        change x = 100
        during x < 160 && !inked {
            when windowPixel(w, x, y) != 1056816 { inked = true }
            x += 1
        }
        y += 1
    }
    when !inked { give 41 }
    hold empty = ""
    when windowText(w, 0, 0, empty, 0) != 0 { give 42 }
    when windowPresent(w) != 0 { give 43 }
    give 0
}

flow inputChecks(w: view Window) => Int {
    change reader = windowReader()
    // Posted in order through the window's own queue.
    when windowSend(w, 256, 116, 0) != 0 { give 50 }            // WM_KEYDOWN F5
    when windowSend(w, 258, 233, 0) != 0 { give 51 }            // WM_CHAR é
    when windowSend(w, 258, 55357, 0) != 0 { give 52 }          // U+1F600, high
    when windowSend(w, 258, 56832, 0) != 0 { give 53 }          // and low half
    when windowSend(w, 513, 1, 2621470) != 0 { give 54 }        // left down (30, 40)
    when windowSend(w, 522, 7864320, 0) != 0 { give 55 }        // wheel +120
    when windowSend(w, 16, 0, 0) != 0 { give 56 }               // WM_CLOSE
    when windowSend(w, 2, 0, 0) != -1 { give 57 }               // WM_DESTROY is refused
    hold key = nextInput(w, edit reader)
    when key.kind != WINDOW_KEY || key.key != KEY_F1 + 4 || !key.pressed { give 60 }
    // The first resize has replaced the back buffer by now: draw on it.
    hold drawn = drawChecks(w)
    when drawn != 0 { give drawn }
    hold accent = nextInput(w, edit reader)
    when accent.kind != WINDOW_CHAR || accent.character != 233 { give 61 }
    hold emoji = nextInput(w, edit reader)
    when emoji.kind != WINDOW_CHAR || emoji.character != 128512 { give 62 }
    hold click = nextInput(w, edit reader)
    when click.kind != WINDOW_MOUSE || click.action != MOUSE_DOWN || click.button != BUTTON_LEFT || click.x != 30 || click.y != 40 { give 63 }
    hold wheel = nextInput(w, edit reader)
    when wheel.kind != WINDOW_WHEEL || wheel.wheel != 1 { give 64 }
    hold close = nextInput(w, edit reader)
    when close.kind != WINDOW_CLOSE { give 65 }
    give 0
}

flow main() => Int {
    hold title = "ELE window test"
    hold w = windowOpen(title, 400, 300)
    hold status = windowStatus(w)
    when status != 0 {
        windowClose(w)
        printError("windowOpen failed: {status}")
        give 10
    }
    hold result = inputChecks(view w)
    hold closed = windowClose(w)
    when result != 0 { give result }
    when closed != 0 { give 11 }
    // A failed open is a Window too: it reports its status and closes as 0.
    hold small = windowOpen(title, 0, 300)
    hold small_status = windowStatus(small)
    hold small_next = windowNext(small)
    hold small_closed = windowClose(small)
    when small_status != -1 || small_next != -6 || small_closed != 0 { give 12 }
    print("window-events-ok")
    give 0
}
