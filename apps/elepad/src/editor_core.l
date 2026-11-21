take buffer
take cursor

// Shared document state for terminal and future graphical frontends.
expose shape Editor {
    document: Buffer
    cursor: Cursor
    newline_crlf: Bool
}

expose flow newEditor(source: view Text) => Editor {
    change crlf = false
    change i = 0
    during i + 1 < source.byteLength {
        when source@byteAt(i) == 13 && source@byteAt(i + 1) == 10 {
            crlf = true
            leave
        }
        i += 1
    }
    give Editor(document: loadText(source), cursor: newCursor(), newline_crlf: crlf)
}

expose flow editorInsertScalar(editor: edit Editor, scalar: Int) => Bool {
    hold n = insertScalar(edit editor.document, editor.cursor.offset, scalar)
    when n == 0 { give false }
    editor.cursor.offset += n
    rememberColumn(view editor.document, edit editor.cursor)
    give true
}

expose flow editorEnter(editor: edit Editor) => Bool {
    when editor.newline_crlf {
        hold newline = "\r\n"
        when !insertText(edit editor.document, editor.cursor.offset, view newline) { give false }
        editor.cursor.offset += 2
    } otherwise {
        hold newline = "\n"
        when !insertText(edit editor.document, editor.cursor.offset, view newline) { give false }
        editor.cursor.offset += 1
    }
    editor.cursor.column_bytes = 0
    give true
}

expose flow editorBackspace(editor: edit Editor) => Bool {
    hold old = editor.cursor.offset
    when old == 0 { give false }
    left(view editor.document, edit editor.cursor)
    when !deleteBackward(edit editor.document, old) { give false }
    rememberColumn(view editor.document, edit editor.cursor)
    give true
}

expose flow editorDelete(editor: edit Editor) => Bool {
    give deleteForward(edit editor.document, editor.cursor.offset)
}

expose flow editorHome(editor: edit Editor) {
    editor.cursor.offset = lineStart(view editor.document, editor.cursor.offset)
    editor.cursor.column_bytes = 0
}

expose flow editorEnd(editor: edit Editor) {
    editor.cursor.offset = lineEnd(view editor.document, editor.cursor.offset)
    rememberColumn(view editor.document, edit editor.cursor)
}
