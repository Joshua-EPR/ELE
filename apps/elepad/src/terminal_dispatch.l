take editor_core
take editor_commands
take std.io.console

// Terminal frontend: console events into the shared editor command table
// (editor_commands.l). Return codes: those of editorCommand, plus
// 3 = end of redirected input and -1 = console error.
expose flow dispatchEvent(editor: edit Editor, ev: view ConsoleEvent) => Int {
    when ev.kind == EVENT_END { give 3 }
    when ev.kind == EVENT_ERROR { give -1 }
    give editorCommand(edit editor, ev)
}
