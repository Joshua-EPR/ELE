take gui_dispatch
take gui_render
take document_io
take std.ui.window

// ELEPad with a native window (Windows). Usage: elepad-gui <archivo.l>
// The editing core, the key table and saving are shared with the terminal
// editor (editor_core.l, editor_commands.l, document_io.l).
// Exit codes: 0 normal close; 2 usage; 3 the file cannot be read; 5 the
// window cannot be opened (status printed); 6 window event error.

flow run(path: view Text, source: view Text) => Int {
    change editor = newEditor(source)
    hold title = "ELEPad - {path}"
    hold w = windowOpen(title, 960, 640)
    hold opened = windowStatus(w)
    when opened != 0 {
        windowClose(w)
        printError("No se pudo abrir la ventana: {opened}")
        give 5
    }
    change v = guiView(windowCell(w), 960, 640)
    change reader = windowReader()
    change quit_armed = false
    change exit_code = 0
    guiRender(w, editor, path, v)
    during true {
        hold ev = windowEvent(w, edit reader)
        change redraw = false
        change quit = false
        when ev.kind == WINDOW_ERROR {
            when ev.status != WINDOW_DROPPED {
                exit_code = 6
                leave
            }
        } otherwise when ev.kind == WINDOW_RESIZE {
            v.width = ev.width
            v.height = ev.height
            redraw = true
        } otherwise when ev.kind == WINDOW_CLOSE {
            quit = true
        } otherwise when ev.kind == WINDOW_MOUSE && ev.action == MOUSE_DOWN && ev.button == BUTTON_LEFT {
            editor.cursor.offset = guiOffsetAt(editor, v, ev.x, ev.y)
            editorClearSelection(edit editor)
            rememberColumn(view editor.document, edit editor.cursor)
            editor.h_typing = false
            redraw = true
        } otherwise when ev.kind == WINDOW_WHEEL {
            v.top = v.top - 3 * ev.wheel
            when v.top < 0 { v.top = 0 }
            redraw = true
        } otherwise when ev.kind == WINDOW_KEY || ev.kind == WINDOW_CHAR {
            hold action = guiCommand(edit editor, ev)
            when action == 2 { quit = true }
            when action == 1 {
                hold saved = saveDocument(edit editor, path)
                when saved == 0 { v.message = GUI_MESSAGE_SAVED }
                otherwise { v.message = GUI_MESSAGE_SAVE_FAILED }
                quit_armed = false
            } otherwise when action != 2 && (ev.kind == WINDOW_CHAR || ev.pressed) {
                when v.message != GUI_MESSAGE_NONE { v.message = GUI_MESSAGE_NONE }
                quit_armed = false
            }
            guiFollowCursor(editor, edit v)
            redraw = true
        }
        // Closing with unsaved changes needs a second request.
        when quit {
            when !editor.document.dirty || quit_armed { leave }
            quit_armed = true
            v.message = GUI_MESSAGE_UNSAVED
            redraw = true
        }
        when redraw { guiRender(w, editor, path, v) }
    }
    hold closed = windowClose(w)
    when exit_code == 0 && closed != 0 { give 6 }
    give exit_code
}

flow main() => Int {
    when processArgCount() != 1 {
        printError("Uso: elepad-gui <archivo.l>")
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
