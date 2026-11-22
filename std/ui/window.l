// std.ui.window: events of a native Window (P0-D).
//
// The compiler builtins own the Window (a linear resource, like File):
//   windowOpen(title, width, height) => Window   windowStatus(w) => Int
//   windowNext(w) => Int (packed)                windowClose(w) => Int
//   windowFill(w, x, y, width, height, rgb)      windowPresent(w)
//   windowText(w, x, y, text, rgb)               windowPixel(w, x, y)
//   windowSend(w, message, wparam, lparam)  (synthetic input, this window)
// This module turns the packed events of windowNext into WindowEvent, with
// the key codes of std.io.console, so terminal and window frontends of the
// same application share one key table. Windows only for now: on Linux
// windowOpen reports -7 (no graphical session).
take std.io.console

expose fixed WINDOW_NONE = 0
expose fixed WINDOW_KEY = 1
expose fixed WINDOW_CHAR = 2
expose fixed WINDOW_MOUSE = 3
expose fixed WINDOW_WHEEL = 4
expose fixed WINDOW_RESIZE = 5
expose fixed WINDOW_FOCUS = 6
expose fixed WINDOW_CLOSE = 7
expose fixed WINDOW_ERROR = 8

// WindowEvent.action for WINDOW_MOUSE, and WindowEvent.button.
expose fixed MOUSE_MOVE = 0
expose fixed MOUSE_DOWN = 1
expose fixed MOUSE_UP = 2
expose fixed BUTTON_NONE = 0
expose fixed BUTTON_LEFT = 1
expose fixed BUTTON_RIGHT = 2

// Platform error statuses (WINDOW_ERROR.status): -5 system failure, -6 the
// window is not open, -8 events were dropped because the queue was full.
expose fixed WINDOW_DROPPED = -8

expose shape WindowEvent {
    kind: Int
    // WINDOW_KEY: a KEY_* code of std.io.console (KEY_NONE for keys that
    // have no code; Ctrl+letter is KEY_CHAR with the lowercase letter),
    // `vk` the Windows virtual-key code and `pressed` down or up.
    key: Int
    vk: Int
    pressed: Bool
    // WINDOW_CHAR: a Unicode scalar (surrogate pairs are joined; a lone
    // surrogate becomes U+FFFD).
    character: Int
    // MOD_SHIFT, MOD_CTRL, MOD_ALT of std.io.console.
    modifiers: Int
    // WINDOW_MOUSE (client coordinates), WINDOW_WHEEL (screen coordinates).
    x: Int
    y: Int
    action: Int
    button: Int
    // WINDOW_WHEEL: notches, positive away from the user.
    wheel: Int
    // WINDOW_RESIZE: the new client size (the back buffer is resized and
    // cleared before this event is reported; redraw everything).
    width: Int
    height: Int
    // WINDOW_FOCUS.
    focused: Bool
    // WINDOW_ERROR.
    status: Int
}

// Joins UTF-16 surrogate pairs across WINDOW_CHAR events.
expose shape WindowReader {
    surrogate: Int
}

expose flow windowReader() => WindowReader {
    give WindowReader(surrogate: 0)
}

flow field(packed: Int, shift: Int, width: Int) => Int {
    change divisor = 1
    change i = 0
    during i < shift {
        divisor = divisor * 2
        i += 1
    }
    change modulus = 1
    i = 0
    during i < width {
        modulus = modulus * 2
        i += 1
    }
    give (packed / divisor) % modulus
}

flow signed16(value: Int) => Int {
    when value >= 32768 { give value - 65536 }
    give value
}

flow emptyWindowEvent(kind: Int) => WindowEvent {
    give WindowEvent(kind: kind, key: KEY_NONE, vk: 0, pressed: false, character: 0, modifiers: 0, x: 0, y: 0, action: MOUSE_MOVE, button: BUTTON_NONE, wheel: 0, width: 0, height: 0, focused: false, status: 0)
}

// The next event of `w`, blocking until one exists.
expose flow windowEvent(w: view Window, reader: edit WindowReader) => WindowEvent {
    during true {
        hold packed = windowNext(w)
        when packed < 0 {
            change failed = emptyWindowEvent(WINDOW_ERROR)
            failed.status = packed
            give failed
        }
        hold kind = field(packed, 56, 4)
        hold mods = field(packed, 48, 3)
        hold lp = field(packed, 16, 32)
        hold wp = field(packed, 0, 16)
        when kind == 1 || kind == 2 {
            change ev = emptyWindowEvent(WINDOW_KEY)
            ev.vk = wp
            ev.pressed = kind == 1
            ev.modifiers = mods
            ev.key = windowsKey(wp)
            when ev.key == KEY_NONE && wp >= 65 && wp <= 90 && mods % 4 >= MOD_CTRL {
                ev.key = KEY_CHAR
                ev.character = 97 + wp - 65
            }
            give ev
        }
        when kind == 3 {
            when wp >= 55296 && wp <= 56319 {
                reader.surrogate = wp
                proceed
            }
            change ev = emptyWindowEvent(WINDOW_CHAR)
            ev.modifiers = mods
            when wp >= 56320 && wp <= 57343 {
                when reader.surrogate > 0 {
                    ev.character = 65536 + (reader.surrogate - 55296) * 1024 + (wp - 56320)
                } otherwise {
                    ev.character = 65533
                }
            } otherwise {
                // A high surrogate without its low half is dropped; the
                // current unit is still reported.
                ev.character = wp
            }
            reader.surrogate = 0
            give ev
        }
        when kind >= 4 && kind <= 8 {
            change ev = emptyWindowEvent(WINDOW_MOUSE)
            ev.modifiers = mods
            ev.x = signed16(lp % 65536)
            ev.y = signed16(lp / 65536)
            when kind == 5 || kind == 7 { ev.action = MOUSE_DOWN }
            when kind == 6 || kind == 8 { ev.action = MOUSE_UP }
            when kind == 5 || kind == 6 { ev.button = BUTTON_LEFT }
            when kind == 7 || kind == 8 { ev.button = BUTTON_RIGHT }
            give ev
        }
        when kind == 9 {
            change ev = emptyWindowEvent(WINDOW_WHEEL)
            ev.modifiers = mods
            ev.x = signed16(lp % 65536)
            ev.y = signed16(lp / 65536)
            ev.wheel = signed16(wp) / 120
            give ev
        }
        when kind == 10 {
            change ev = emptyWindowEvent(WINDOW_RESIZE)
            ev.width = lp % 65536
            ev.height = lp / 65536
            give ev
        }
        when kind == 11 || kind == 12 {
            change ev = emptyWindowEvent(WINDOW_FOCUS)
            ev.focused = kind == 11
            give ev
        }
        when kind == 13 { give emptyWindowEvent(WINDOW_CLOSE) }
        when kind == 15 {
            change dropped = emptyWindowEvent(WINDOW_ERROR)
            dropped.status = WINDOW_DROPPED
            give dropped
        }
    }
    give emptyWindowEvent(WINDOW_NONE)
}
