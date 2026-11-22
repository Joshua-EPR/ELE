// std/io/console.l: interactive console input for any ELE program.
//
// Built on two platform operations of the compiler (both Int in, Int out):
//   consoleInputMode(request) -> previous opaque state, or < 0 on error.
//     -1 queries, -2 switches to raw input, a state >= 0 restores it.
//     Errors: -1 not a console/terminal, -2 mode rejected, -3 bad request.
//   readConsoleEvent() -> one packed event (blocks until one exists).
//     Windows console: key (kind 1), resize (2) and mouse (3) records of
//     ReadConsoleInputW. Linux terminal, or any redirected input on either
//     system: one byte (kind 4). -2 end of input, -1 read error.
// This module turns both forms into one ConsoleEvent, so applications never
// see virtual-key codes, escape sequences or UTF-8/UTF-16 details.
//
// Limitations (not hidden):
// - Byte input cannot tell a lone Escape from the start of an escape
//   sequence without a timed read, which the runtime does not offer yet: a
//   lone Escape is reported when the next byte arrives (Escape twice gives
//   one Escape immediately).
// - Characters are Unicode scalar values, not grapheme clusters.
// - Windows dead keys and IME composition arrive as the console delivers
//   them; this module does not compose them.

// ConsoleEvent.kind
expose fixed EVENT_NONE = 0
expose fixed EVENT_KEY = 1
expose fixed EVENT_RESIZE = 2
expose fixed EVENT_MOUSE = 3
expose fixed EVENT_END = 4
expose fixed EVENT_ERROR = 5

// ConsoleEvent.key
expose fixed KEY_NONE = 0
expose fixed KEY_CHAR = 1
expose fixed KEY_ENTER = 2
expose fixed KEY_BACKSPACE = 3
expose fixed KEY_DELETE = 4
expose fixed KEY_LEFT = 5
expose fixed KEY_RIGHT = 6
expose fixed KEY_UP = 7
expose fixed KEY_DOWN = 8
expose fixed KEY_HOME = 9
expose fixed KEY_END = 10
expose fixed KEY_PAGE_UP = 11
expose fixed KEY_PAGE_DOWN = 12
expose fixed KEY_TAB = 13
expose fixed KEY_ESCAPE = 14
expose fixed KEY_INSERT = 15
// KEY_F1 + n - 1 is Fn, for n in 1..=12.
expose fixed KEY_F1 = 16

// ConsoleEvent.modifiers: a sum of these.
expose fixed MOD_SHIFT = 1
expose fixed MOD_CTRL = 2
expose fixed MOD_ALT = 4

// Mouse buttons (ConsoleEvent.buttons, a sum) and wheel direction.
expose fixed MOUSE_LEFT = 1
expose fixed MOUSE_RIGHT = 2
expose fixed MOUSE_MIDDLE = 4

expose shape ConsoleEvent {
    kind: Int
    key: Int
    // Unicode scalar value for KEY_CHAR (for Ctrl+letter, the lowercase
    // letter), 0 otherwise.
    character: Int
    modifiers: Int
    pressed: Bool
    repeat: Int
    // Resize: columns and rows. Mouse: column and row.
    x: Int
    y: Int
    buttons: Int
    // Mouse wheel: 1 forward, -1 backward, 0 none.
    wheel: Int
}

expose shape ConsoleReader {
    // Previous console state, restored by consoleClose; -1 when the input
    // is not an interactive console (redirected input still works).
    saved: Int
    interactive: Bool
    // Leading half of a UTF-16 surrogate pair (Windows), or 0.
    surrogate: Int
    // A byte read ahead while decoding an escape sequence, or -1.
    pending: Int
}

flow emptyEvent(kind: Int) => ConsoleEvent {
    give ConsoleEvent(kind: kind, key: KEY_NONE, character: 0, modifiers: 0, pressed: false, repeat: 0, x: 0, y: 0, buttons: 0, wheel: 0)
}

flow keyEvent(key: Int, character: Int, modifiers: Int) => ConsoleEvent {
    change ev = emptyEvent(EVENT_KEY)
    ev.key = key
    ev.character = character
    ev.modifiers = modifiers
    ev.pressed = true
    ev.repeat = 1
    give ev
}

// Switches the console to raw input. The returned reader must be passed to
// consoleClose before the program ends, which restores the original state.
expose flow consoleOpen() => ConsoleReader {
    hold saved = consoleInputMode(-2)
    give ConsoleReader(saved: saved, interactive: saved >= 0, surrogate: 0, pending: -1)
}

// Restores the console state saved by consoleOpen. 0 on success (or when
// there was nothing to restore), otherwise the negative platform status.
expose flow consoleClose(reader: edit ConsoleReader) => Int {
    when reader.saved < 0 { give 0 }
    hold status = consoleInputMode(reader.saved)
    reader.saved = -1
    when status < 0 { give status }
    give 0
}

// Bits of a packed event: (packed / 2^shift) % 2^width.
flow bits(packed: Int, shift: Int, width: Int) => Int {
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

flow hasBit(value: Int, bit: Int) => Bool {
    give (value / bit) % 2 == 1
}

// Modifiers of a Windows dwControlKeyState low word.
flow windowsModifiers(state: Int) => Int {
    change mods = 0
    when hasBit(state, 16) { mods += MOD_SHIFT }
    when hasBit(state, 4) || hasBit(state, 8) { mods += MOD_CTRL }
    when hasBit(state, 1) || hasBit(state, 2) { mods += MOD_ALT }
    give mods
}

// Special key of a Windows virtual-key code, or KEY_NONE. Shared with
// std.ui.window, so console and window applications see the same keys.
expose flow windowsKey(vk: Int) => Int {
    when vk == 8 { give KEY_BACKSPACE }
    when vk == 9 { give KEY_TAB }
    when vk == 13 { give KEY_ENTER }
    when vk == 27 { give KEY_ESCAPE }
    when vk == 33 { give KEY_PAGE_UP }
    when vk == 34 { give KEY_PAGE_DOWN }
    when vk == 35 { give KEY_END }
    when vk == 36 { give KEY_HOME }
    when vk == 37 { give KEY_LEFT }
    when vk == 38 { give KEY_UP }
    when vk == 39 { give KEY_RIGHT }
    when vk == 40 { give KEY_DOWN }
    when vk == 45 { give KEY_INSERT }
    when vk == 46 { give KEY_DELETE }
    when vk >= 112 && vk <= 123 { give KEY_F1 + vk - 112 }
    give KEY_NONE
}

// Shift, Ctrl, Alt, Caps Lock, Num Lock, Scroll Lock and the Windows keys
// change modifiers only; they are not reported as keys.
expose flow windowsModifierOnly(vk: Int) => Bool {
    give vk == 16 || vk == 17 || vk == 18 || vk == 20 || vk == 91 || vk == 92 || vk == 93 || vk == 144 || vk == 145
}

// Decodes a Windows key record. EVENT_NONE means "read the next record"
// (a release, a bare modifier, or the first half of a surrogate pair).
flow decodeWindowsKey(reader: edit ConsoleReader, packed: Int) => ConsoleEvent {
    hold unit = bits(packed, 0, 16)
    hold vk = bits(packed, 16, 16)
    change mods = windowsModifiers(bits(packed, 32, 16))
    hold down = bits(packed, 48, 1) == 1
    hold repeat = bits(packed, 49, 7)
    when !down || windowsModifierOnly(vk) { give emptyEvent(EVENT_NONE) }
    // AltGr arrives as Right Alt + Left Ctrl with a printable character:
    // the keyboard layout already chose the character.
    hold alt_gr = unit >= 32 && hasBit(mods, MOD_CTRL) && hasBit(mods, MOD_ALT)
    when alt_gr { mods = mods - MOD_CTRL - MOD_ALT }
    change ev = emptyEvent(EVENT_NONE)
    hold special = windowsKey(vk)
    when special != KEY_NONE {
        ev = keyEvent(special, 0, mods)
    } otherwise when hasBit(mods, MOD_CTRL) && vk >= 65 && vk <= 90 && !alt_gr {
        ev = keyEvent(KEY_CHAR, 97 + vk - 65, mods)
    } otherwise when unit >= 55296 && unit <= 56319 {
        reader.surrogate = unit
        give ev
    } otherwise when unit >= 56320 && unit <= 57343 {
        when reader.surrogate == 0 { give keyEvent(KEY_CHAR, 65533, mods) }
        hold scalar = 65536 + (reader.surrogate - 55296) * 1024 + (unit - 56320)
        reader.surrogate = 0
        ev = keyEvent(KEY_CHAR, scalar, mods)
    } otherwise when unit != 0 {
        ev = keyEvent(KEY_CHAR, unit, mods)
        // Shift is part of the character already ('A', '!').
        when unit >= 32 && hasBit(mods, MOD_SHIFT) { ev.modifiers = mods - MOD_SHIFT }
    } otherwise {
        give ev
    }
    when repeat > 1 { ev.repeat = repeat }
    give ev
}

flow decodeMouse(packed: Int) => ConsoleEvent {
    change ev = emptyEvent(EVENT_MOUSE)
    ev.x = bits(packed, 0, 16)
    ev.y = bits(packed, 16, 16)
    hold state = bits(packed, 32, 8)
    change buttons = 0
    when hasBit(state, 1) { buttons += MOUSE_LEFT }
    when hasBit(state, 2) { buttons += MOUSE_RIGHT }
    when hasBit(state, 4) { buttons += MOUSE_MIDDLE }
    ev.buttons = buttons
    ev.modifiers = windowsModifiers(bits(packed, 48, 5))
    when bits(packed, 53, 1) == 1 { ev.wheel = 1 }
    when bits(packed, 54, 1) == 1 { ev.wheel = -1 }
    ev.pressed = buttons != 0
    give ev
}

// Next raw byte (-1 error, -2 end), using the read-ahead byte first.
flow nextByte(reader: edit ConsoleReader) => Int {
    when reader.pending >= 0 {
        hold b = reader.pending
        reader.pending = -1
        give b
    }
    hold packed = readConsoleEvent()
    when packed < 0 { give packed }
    when bits(packed, 56, 4) != 4 { give -1 }
    give bits(packed, 0, 8)
}

// Rest of a UTF-8 sequence after its lead byte: the scalar, or U+FFFD for
// an ill-formed sequence (an unexpected byte is kept for the next event).
flow decodeUtf8(reader: edit ConsoleReader, lead: Int) => Int {
    change need = 0
    change scalar = 0
    change minimum = 0
    when lead >= 194 && lead <= 223 {
        need = 1
        scalar = lead - 192
        minimum = 128
    } otherwise when lead >= 224 && lead <= 239 {
        need = 2
        scalar = lead - 224
        minimum = 2048
    } otherwise when lead >= 240 && lead <= 244 {
        need = 3
        scalar = lead - 240
        minimum = 65536
    } otherwise {
        give 65533
    }
    during need > 0 {
        hold b = nextByte(edit reader)
        when b < 128 || b > 191 {
            when b >= 0 { reader.pending = b }
            give 65533
        }
        scalar = scalar * 64 + (b - 128)
        need -= 1
    }
    when scalar < minimum || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343) { give 65533 }
    give scalar
}

// Key of a CSI sequence ending in `final` with numeric parameter `number`.
flow csiKey(final: Int, number: Int) => Int {
    when final == 65 { give KEY_UP }
    when final == 66 { give KEY_DOWN }
    when final == 67 { give KEY_RIGHT }
    when final == 68 { give KEY_LEFT }
    when final == 72 { give KEY_HOME }
    when final == 70 { give KEY_END }
    when final == 90 { give KEY_TAB }
    when final == 80 { give KEY_F1 }
    when final == 81 { give KEY_F1 + 1 }
    when final == 82 { give KEY_F1 + 2 }
    when final == 83 { give KEY_F1 + 3 }
    when final != 126 { give KEY_NONE }
    when number == 1 || number == 7 { give KEY_HOME }
    when number == 4 || number == 8 { give KEY_END }
    when number == 2 { give KEY_INSERT }
    when number == 3 { give KEY_DELETE }
    when number == 5 { give KEY_PAGE_UP }
    when number == 6 { give KEY_PAGE_DOWN }
    when number == 15 { give KEY_F1 + 4 }
    when number >= 17 && number <= 21 { give KEY_F1 + number - 12 }
    when number == 23 || number == 24 { give KEY_F1 + number - 13 }
    give KEY_NONE
}

// After ESC '[': parameters, then the final byte. xterm modifier parameter
// m encodes (m - 1) as shift 1, alt 2, ctrl 4.
flow decodeCsi(reader: edit ConsoleReader) => ConsoleEvent {
    change number = 0
    change modifier = 0
    change field = 0
    change final = -1
    during true {
        hold b = nextByte(edit reader)
        when b < 0 { leave }
        when b >= 48 && b <= 57 {
            when field == 0 { number = number * 10 + b - 48 }
            otherwise { modifier = modifier * 10 + b - 48 }
        } otherwise when b == 59 {
            field += 1
        } otherwise when b >= 64 && b <= 126 {
            final = b
            leave
        }
    }
    hold key = csiKey(final, number)
    when key == KEY_NONE { give emptyEvent(EVENT_NONE) }
    change mods = 0
    when modifier >= 2 {
        hold m = modifier - 1
        when hasBit(m, 1) { mods += MOD_SHIFT }
        when hasBit(m, 2) { mods += MOD_ALT }
        when hasBit(m, 4) { mods += MOD_CTRL }
    }
    when final == 90 { mods += MOD_SHIFT }
    give keyEvent(key, 0, mods)
}

// One key from byte input (Linux terminals and redirected input).
flow decodeByte(reader: edit ConsoleReader, b: Int) => ConsoleEvent {
    when b == 13 || b == 10 { give keyEvent(KEY_ENTER, 0, 0) }
    when b == 9 { give keyEvent(KEY_TAB, 0, 0) }
    when b == 127 || b == 8 { give keyEvent(KEY_BACKSPACE, 0, 0) }
    when b == 0 { give keyEvent(KEY_CHAR, 32, MOD_CTRL) }
    when b == 27 {
        hold next = nextByte(edit reader)
        when next < 0 || next == 27 { give keyEvent(KEY_ESCAPE, 0, 0) }
        when next == 91 { give decodeCsi(edit reader) }
        when next == 79 {
            hold f = nextByte(edit reader)
            hold key = csiKey(f, 0)
            when key == KEY_NONE { give emptyEvent(EVENT_NONE) }
            give keyEvent(key, 0, 0)
        }
        // Alt + key.
        change inner = decodeByte(edit reader, next)
        inner.modifiers = inner.modifiers + MOD_ALT
        give inner
    }
    when b < 27 { give keyEvent(KEY_CHAR, 96 + b, MOD_CTRL) }
    when b < 128 { give keyEvent(KEY_CHAR, b, 0) }
    give keyEvent(KEY_CHAR, decodeUtf8(edit reader, b), 0)
}

// Blocks until the next key press, resize, mouse event, end of input or
// error. Key releases and bare modifier presses are skipped.
expose flow consoleNext(reader: edit ConsoleReader) => ConsoleEvent {
    during true {
        change packed = 0
        when reader.pending >= 0 {
            packed = 288230376151711744 + reader.pending
            reader.pending = -1
        } otherwise {
            packed = readConsoleEvent()
        }
        when packed == -2 { give emptyEvent(EVENT_END) }
        when packed < 0 { give emptyEvent(EVENT_ERROR) }
        hold kind = bits(packed, 56, 4)
        change ev = emptyEvent(EVENT_NONE)
        when kind == 1 {
            ev = decodeWindowsKey(edit reader, packed)
        } otherwise when kind == 2 {
            ev = emptyEvent(EVENT_RESIZE)
            ev.x = bits(packed, 0, 16)
            ev.y = bits(packed, 16, 16)
        } otherwise when kind == 3 {
            ev = decodeMouse(packed)
        } otherwise when kind == 4 {
            ev = decodeByte(edit reader, bits(packed, 0, 8))
        }
        when ev.kind != EVENT_NONE { give ev }
    }
    give emptyEvent(EVENT_ERROR)
}

// True for Ctrl + `letter` (a lowercase ASCII letter), with or without Shift.
expose flow isCtrl(ev: view ConsoleEvent, letter: Int) => Bool {
    give ev.kind == EVENT_KEY && ev.key == KEY_CHAR && ev.character == letter && hasBit(ev.modifiers, MOD_CTRL) && !hasBit(ev.modifiers, MOD_ALT)
}

// A stable English name of a key, for logs and tests.
expose flow keyName(key: Int) => Text {
    when key == KEY_CHAR { give "char" }
    when key == KEY_ENTER { give "enter" }
    when key == KEY_BACKSPACE { give "backspace" }
    when key == KEY_DELETE { give "delete" }
    when key == KEY_LEFT { give "left" }
    when key == KEY_RIGHT { give "right" }
    when key == KEY_UP { give "up" }
    when key == KEY_DOWN { give "down" }
    when key == KEY_HOME { give "home" }
    when key == KEY_END { give "end" }
    when key == KEY_PAGE_UP { give "pageup" }
    when key == KEY_PAGE_DOWN { give "pagedown" }
    when key == KEY_TAB { give "tab" }
    when key == KEY_ESCAPE { give "escape" }
    when key == KEY_INSERT { give "insert" }
    when key >= KEY_F1 && key < KEY_F1 + 12 {
        hold n = key - KEY_F1 + 1
        give "f{n}"
    }
    give "none"
}

// "ctrl+shift+" style prefix of a modifier sum.
expose flow modifierPrefix(mods: Int) => Text {
    change out = ""
    when hasBit(mods, MOD_CTRL) { out = "{out}ctrl+" }
    when hasBit(mods, MOD_ALT) { out = "{out}alt+" }
    when hasBit(mods, MOD_SHIFT) { out = "{out}shift+" }
    give out
}
