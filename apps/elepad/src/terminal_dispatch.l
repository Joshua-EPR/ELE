take editor_core
take std.io.console

// 0 = handled/ignored, 1 = save requested, 2 = quit requested,
// 3 = end of redirected input, -1 = console error.
expose flow dispatchEvent(editor: edit Editor, ev: view ConsoleEvent) => Int {
    when ev.kind == EVENT_END { give 3 }
    when ev.kind == EVENT_ERROR { give -1 }
    when ev.kind != EVENT_KEY || !ev.pressed { give 0 }
    when isCtrl(ev, 115) { give 1 }
    when isCtrl(ev, 113) { give 2 }
    // Other Ctrl/Alt combinations are reserved; never insert control bytes.
    when ev.modifiers >= MOD_CTRL { give 0 }
    change count = ev.repeat
    when count < 1 { count = 1 }
    when count > 128 { count = 128 }
    change i = 0
    during i < count {
        when ev.key == KEY_CHAR && ev.character >= 32 {
            editorInsertScalar(edit editor, ev.character)
        } otherwise when ev.key == KEY_ENTER {
            editorEnter(edit editor)
        } otherwise when ev.key == KEY_TAB {
            editorInsertScalar(edit editor, 9)
        } otherwise when ev.key == KEY_BACKSPACE {
            editorBackspace(edit editor)
        } otherwise when ev.key == KEY_DELETE {
            editorDelete(edit editor)
        } otherwise when ev.key == KEY_LEFT {
            left(view editor.document, edit editor.cursor)
        } otherwise when ev.key == KEY_RIGHT {
            right(view editor.document, edit editor.cursor)
        } otherwise when ev.key == KEY_UP {
            up(view editor.document, edit editor.cursor)
        } otherwise when ev.key == KEY_DOWN {
            down(view editor.document, edit editor.cursor)
        } otherwise when ev.key == KEY_HOME {
            editorHome(edit editor)
        } otherwise when ev.key == KEY_END {
            editorEnd(edit editor)
        } otherwise when ev.key == KEY_PAGE_UP {
            change step = 0
            during step < 20 {
                up(view editor.document, edit editor.cursor)
                step += 1
            }
        } otherwise when ev.key == KEY_PAGE_DOWN {
            change step = 0
            during step < 20 {
                down(view editor.document, edit editor.cursor)
                step += 1
            }
        }
        i += 1
    }
    give 0
}
