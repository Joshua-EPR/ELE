take gui_dispatch
take gui_render
take document_io
take std.ui.window

fixed CLOSE_CLEAN = 0
fixed CLOSE_DIRTY = 1
fixed CLOSE_PENDING = 2
fixed CLOSE_CONFIRMED = 3

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
    // A close request is confirmed only by a separate gesture. Key releases
    // reset the gesture latch; modifier events never cancel confirmation.
    change close_state = CLOSE_CLEAN
    change q_down = false
    change q_consumed = false
    change f4_down = false
    change f4_consumed = false
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
            when !f4_down || !f4_consumed {
                quit = true
                when f4_down { f4_consumed = true }
            }
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
            when ev.kind == WINDOW_KEY {
                when ev.vk == 81 {
                    q_down = ev.pressed
                    when !ev.pressed { q_consumed = false }
                }
                when ev.vk == 115 {
                    f4_down = ev.pressed
                    when !ev.pressed { f4_consumed = false }
                }
                when ev.pressed && ev.key == KEY_ESCAPE {
                    close_state = CLOSE_DIRTY
                    v.message = GUI_MESSAGE_NONE
                }
                // Ctrl, Alt and Shift are part of the close gesture. Other
                // editing keys cancel a pending request before dispatch.
                when ev.pressed && ev.vk != 16 && ev.vk != 17 && ev.vk != 18 && ev.vk != 81 && ev.vk != 115 && ev.key != KEY_ESCAPE {
                    close_state = CLOSE_DIRTY
                    v.message = GUI_MESSAGE_NONE
                }
            }
            hold action = guiCommand(edit editor, ev)
            when action == 2 && (!q_down || !q_consumed) {
                quit = true
                when q_down { q_consumed = true }
            }
            when action == 1 {
                hold saved = saveDocument(edit editor, path)
                when saved == 0 { v.message = GUI_MESSAGE_SAVED }
                otherwise { v.message = GUI_MESSAGE_SAVE_FAILED }
                close_state = CLOSE_DIRTY
            } otherwise when action != 2 && ev.kind == WINDOW_CHAR && ev.character != 17 {
                when v.message != GUI_MESSAGE_NONE { v.message = GUI_MESSAGE_NONE }
                close_state = CLOSE_DIRTY
            }
            guiFollowCursor(editor, edit v)
            redraw = true
        }
        // The dirty bit is authoritative after save, undo and editing.
        when !editor.document.dirty { close_state = CLOSE_CLEAN }
        otherwise when close_state == CLOSE_CLEAN { close_state = CLOSE_DIRTY }
        // A second distinct close gesture confirms discarding changes.
        when quit {
            when close_state == CLOSE_CLEAN || close_state == CLOSE_PENDING {
                close_state = CLOSE_CONFIRMED
                leave
            }
            close_state = CLOSE_PENDING
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
