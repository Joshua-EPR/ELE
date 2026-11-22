take terminal_dispatch
take terminal_render
take document_io

flow cursorLine(editor: view Editor) => Int {
    change line = 0
    change i = 0
    during i < editor.cursor.offset {
        when byteAt(view editor.document, i) == 10 { line += 1 }
        i += 1
    }
    give line
}

flow run(path: view Text, source: view Text) => Int {
    change editor = newEditor(source)
    // The open document's path changes with Ctrl+O.
    change current = "{path}"
    change reader = consoleOpen()
    change width = 80
    change height = 24
    change top = 0
    change exit_code = 0
    change quit_armed = false
    change frame = renderFull(view editor, current, top, width, height)
    when writeConsoleBytes(frame) != 0 {
        consoleClose(edit reader)
        give 30
    }
    during true {
        hold ev = consoleNext(edit reader)
        when ev.kind == EVENT_RESIZE {
            when ev.x >= 20 { width = ev.x }
            when ev.y >= 4 { height = ev.y }
            when width > 240 { width = 240 }
            when height > 100 { height = 100 }
            frame = renderFull(view editor, current, top, width, height)
            when writeConsoleBytes(frame) != 0 { exit_code = 31; leave }
        } otherwise {
            hold old_line = cursorLine(view editor)
            hold old_offset = editor.cursor.offset
            hold old_end = lineEnd(view editor.document, old_offset)
            hold action = dispatchEvent(edit editor, view ev)
            when action == -1 { exit_code = 32; leave }
            when action == 3 {
                when editor.document.dirty { exit_code = 33 }
                leave
            }
            when action == 2 {
                when !editor.document.dirty || quit_armed { leave }
                quit_armed = true
                printError("Cambios sin guardar: Ctrl+Q otra vez para descartarlos")
            } otherwise {
                quit_armed = false
            }
            when action == ACTION_OPEN {
                hold opened = openDocument(edit editor, edit current)
                when opened == OPEN_UNSAVED { printError("Cambios sin guardar: Ctrl+S antes de abrir otro archivo") }
                when opened == OPEN_BAD_PATH { printError("Ruta no válida") }
                when opened == OPEN_READ_FAILED { printError("No se pudo abrir el archivo") }
                when opened == OPEN_OK { top = 0 }
                frame = renderFull(view editor, current, top, width, height)
            } otherwise when action == 1 {
                hold saved = saveDocument(edit editor, current)
                when saved != 0 { printError("Error al guardar: {saved}") }
                frame = renderFull(view editor, current, top, width, height)
            } otherwise {
                hold new_line = cursorLine(view editor)
                change scroll = false
                when new_line < top { top = new_line; scroll = true }
                when new_line >= top + height - 2 { top = new_line - height + 3; scroll = true }
                when scroll || action == ACTION_REDRAW || ev.key == KEY_ENTER || (ev.key == KEY_DELETE && old_offset == old_end) || new_line != old_line {
                    frame = renderFull(view editor, current, top, width, height)
                } otherwise when ev.kind == EVENT_KEY && (ev.key == KEY_CHAR || ev.key == KEY_TAB || ev.key == KEY_BACKSPACE || ev.key == KEY_DELETE) {
                    frame = renderCurrentLine(view editor, current, top, width, height)
                } otherwise {
                    frame = renderCursorOnly(view editor, top, width, height)
                }
            }
            when writeConsoleBytes(frame) != 0 { exit_code = 34; leave }
        }
    }
    when consoleClose(edit reader) != 0 { give 35 }
    give exit_code
}

flow main() => Int {
    when processArgCount() != 1 {
        printError("Uso: elepad-terminal <archivo.l>")
        give 2
    }
    choose processArg(0) {
        Ok(path): {
            choose readText(path, 16 * 1024 * 1024) {
                Ok(source): { give run(view path, view source) },
                Err(code): {
                    printError("No se pudo abrir el archivo: {code}")
                    give 3
                },
            }
        },
        Err(code): { give 4 },
    }
}
