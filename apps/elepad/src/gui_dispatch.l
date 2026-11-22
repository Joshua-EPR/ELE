take editor_commands
take std.ui.window
take std.io.console

// Window frontend: WindowEvent into the shared editor command table
// (editor_commands.l), so terminal and window ELEPad have one key table.
//
// Ctrl+letter shortcuts are taken from the control character that
// TranslateMessage produces (WM_CHAR 1..26), not from the key-down event:
// a real Ctrl+S yields both, and only one may act. Units 8, 9, 10 and 13
// come from Backspace, Tab and Enter, which act as keys. Special keys
// (arrows, Home, End, Page, Delete, Escape, Enter, Tab, Backspace) act on
// key-down with their modifiers, so Shift+arrows select.
// Returns the editorCommand code (0, 1 save, 2 quit, 4 redraw).
expose flow guiCommand(editor: edit Editor, ev: view WindowEvent) => Int {
    when ev.kind == WINDOW_KEY {
        when !ev.pressed || ev.key == KEY_NONE || ev.key == KEY_CHAR { give 0 }
        hold key = ConsoleEvent(kind: EVENT_KEY, key: ev.key, character: 0, modifiers: ev.modifiers, pressed: true, repeat: 1, x: 0, y: 0, buttons: 0, wheel: 0)
        give editorCommand(edit editor, view key)
    }
    when ev.kind == WINDOW_CHAR {
        hold c = ev.character
        when c >= 1 && c <= 26 && c != 8 && c != 9 && c != 10 && c != 13 {
            hold shortcut = ConsoleEvent(kind: EVENT_KEY, key: KEY_CHAR, character: 96 + c, modifiers: MOD_CTRL, pressed: true, repeat: 1, x: 0, y: 0, buttons: 0, wheel: 0)
            give editorCommand(edit editor, view shortcut)
        }
        when c < 32 || c == 127 { give 0 }
        hold typed = ConsoleEvent(kind: EVENT_KEY, key: KEY_CHAR, character: c, modifiers: 0, pressed: true, repeat: 1, x: 0, y: 0, buttons: 0, wheel: 0)
        give editorCommand(edit editor, view typed)
    }
    give 0
}
