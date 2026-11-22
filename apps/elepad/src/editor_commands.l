take editor_core
take std.io.console

// Return codes of editorCommand (the terminal adds 3 = end of redirected
// input and -1 = console error):
// 0 = handled/ignored (cursor or current line may have changed),
// 1 = save requested, 2 = quit requested,
// 4 = handled, full redraw needed (selection, undo/redo, paste, find).
expose fixed ACTION_REDRAW = 4

flow isMove(key: Int) => Bool {
    give key == KEY_LEFT || key == KEY_RIGHT || key == KEY_UP || key == KEY_DOWN || key == KEY_HOME || key == KEY_END || key == KEY_PAGE_UP || key == KEY_PAGE_DOWN
}

flow move(editor: edit Editor, key: Int) {
    when key == KEY_LEFT {
        left(view editor.document, edit editor.cursor)
    } otherwise when key == KEY_RIGHT {
        right(view editor.document, edit editor.cursor)
    } otherwise when key == KEY_UP {
        up(view editor.document, edit editor.cursor)
    } otherwise when key == KEY_DOWN {
        down(view editor.document, edit editor.cursor)
    } otherwise when key == KEY_HOME {
        editorHome(edit editor)
    } otherwise when key == KEY_END {
        editorEnd(edit editor)
    } otherwise when key == KEY_PAGE_UP {
        change step = 0
        during step < 20 {
            up(view editor.document, edit editor.cursor)
            step += 1
        }
    } otherwise when key == KEY_PAGE_DOWN {
        change step = 0
        during step < 20 {
            down(view editor.document, edit editor.cursor)
            step += 1
        }
    }
}

// Find prompt: printable scalars edit the query, Enter (or Ctrl+F) selects
// the next match, Escape returns to editing.
flow dispatchFind(editor: edit Editor, ev: view ConsoleEvent) => Int {
    when isCtrl(ev, 102) || ev.key == KEY_ENTER {
        editorFindNext(edit editor)
        give ACTION_REDRAW
    }
    when ev.key == KEY_ESCAPE {
        editor.mode = MODE_EDIT
        give ACTION_REDRAW
    }
    when ev.modifiers >= MOD_CTRL { give 0 }
    when ev.key == KEY_BACKSPACE {
        editorQueryPop(edit editor)
        give ACTION_REDRAW
    }
    when ev.key == KEY_CHAR && ev.character >= 32 {
        editorQueryPush(edit editor, ev.character)
        give ACTION_REDRAW
    }
    give 0
}

// The editor command of one key event, shared by the terminal and window
// frontends (terminal_dispatch.l, gui_dispatch.l): the one key table.
expose flow editorCommand(editor: edit Editor, ev: view ConsoleEvent) => Int {
    when ev.kind != EVENT_KEY || !ev.pressed { give 0 }
    editor.clipboard_status = 0
    when isCtrl(ev, 115) { give 1 }
    when isCtrl(ev, 113) { give 2 }
    when editor.mode == MODE_FIND { give dispatchFind(edit editor, ev) }
    when isCtrl(ev, 102) {
        editor.mode = MODE_FIND
        give ACTION_REDRAW
    }
    when isCtrl(ev, 122) {
        editorUndo(edit editor)
        give ACTION_REDRAW
    }
    when isCtrl(ev, 121) {
        editorRedo(edit editor)
        give ACTION_REDRAW
    }
    when isCtrl(ev, 97) {
        editorSelectAll(edit editor)
        give ACTION_REDRAW
    }
    when isCtrl(ev, 99) {
        editorCopy(edit editor)
        give 0
    }
    when isCtrl(ev, 120) {
        editorCut(edit editor)
        give ACTION_REDRAW
    }
    when isCtrl(ev, 118) {
        editorPaste(edit editor)
        give ACTION_REDRAW
    }
    // Other Ctrl/Alt combinations are reserved; never insert control bytes.
    when ev.modifiers >= MOD_CTRL { give 0 }
    hold had_selection = editorHasSelection(view editor)
    hold shift = ev.modifiers % 2 == 1
    change count = ev.repeat
    when count < 1 { count = 1 }
    when count > 128 { count = 128 }
    change i = 0
    during i < count {
        when isMove(ev.key) {
            when shift { editorExtendSelection(edit editor) }
            otherwise { editorClearSelection(edit editor) }
            editor.h_typing = false
            move(edit editor, ev.key)
        } otherwise when ev.key == KEY_ESCAPE {
            editorClearSelection(edit editor)
        } otherwise when ev.key == KEY_CHAR && ev.character >= 32 {
            editorInsertScalar(edit editor, ev.character)
        } otherwise when ev.key == KEY_ENTER {
            editorEnter(edit editor)
        } otherwise when ev.key == KEY_TAB {
            editorInsertScalar(edit editor, 9)
        } otherwise when ev.key == KEY_BACKSPACE {
            editorBackspace(edit editor)
        } otherwise when ev.key == KEY_DELETE {
            editorDelete(edit editor)
        }
        i += 1
    }
    when had_selection || editorHasSelection(view editor) { give ACTION_REDRAW }
    give 0
}
