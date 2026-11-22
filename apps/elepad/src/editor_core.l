take buffer
take cursor
take search

// Shared document state for terminal and future graphical frontends.
//
// Edit history is an operation log kept in flat parallel lists (one entry
// per operation): kind, offset, byte count, start index of the bytes in
// h_data, undo group and the cursor before the operation. Entries at
// [h_top, h_total) are redo-able; a new edit discards them. Operations of
// one group are undone and redone together (a run of typed characters, or
// "delete selection + insert" for paste/replace). h_saved is the h_top that
// matches the file on disk, or -1 when that state is no longer reachable.
//
// The clipboard is internal to the process. It is not the system clipboard.
expose shape Editor {
    document: Buffer
    cursor: Cursor
    newline_crlf: Bool
    anchor: Int
    clipboard: List of[Int]
    h_kind: List of[Int]
    h_offset: List of[Int]
    h_count: List of[Int]
    h_start: List of[Int]
    h_group: List of[Int]
    h_cursor: List of[Int]
    h_data: List of[Int]
    h_top: Int
    h_total: Int
    h_group_next: Int
    h_typing: Bool
    h_saved: Int
    mode: Int
    query: List of[Int]
    query_len: Int
    find_failed: Bool
}

expose fixed OP_INSERT = 1
expose fixed OP_DELETE = 2
expose fixed MODE_EDIT = 0
expose fixed MODE_FIND = 1
// History bytes beyond this bound drop the whole log (no partial undo).
fixed HISTORY_LIMIT = 33554432

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
    change clip: List of[Int] = List[]
    change kinds: List of[Int] = List[]
    change offsets: List of[Int] = List[]
    change counts: List of[Int] = List[]
    change starts: List of[Int] = List[]
    change groups: List of[Int] = List[]
    change cursors: List of[Int] = List[]
    change data: List of[Int] = List[]
    change query: List of[Int] = List[]
    give Editor(document: loadText(source), cursor: newCursor(), newline_crlf: crlf, anchor: -1, clipboard: clip, h_kind: kinds, h_offset: offsets, h_count: counts, h_start: starts, h_group: groups, h_cursor: cursors, h_data: data, h_top: 0, h_total: 0, h_group_next: 0, h_typing: false, h_saved: 0, mode: MODE_EDIT, query: query, query_len: 0, find_failed: false)
}

flow setAt(list: edit List of[Int], index: Int, value: Int) {
    when index < list.length { list[index] = value }
    otherwise { list@push(value) }
}

flow updateDirty(editor: edit Editor) {
    editor.document.dirty = editor.h_top != editor.h_saved
}

flow newGroup(editor: edit Editor) => Int {
    editor.h_group_next += 1
    editor.h_typing = false
    give editor.h_group_next
}

flow dataEnd(editor: view Editor) => Int {
    when editor.h_top == 0 { give 0 }
    hold last = editor.h_top - 1
    give editor.h_start[last] + editor.h_count[last]
}

// Record an operation whose bytes are present in the document at
// [offset, offset + count): after an insert, or before a delete.
flow recordOp(editor: edit Editor, kind: Int, offset: Int, count: Int, cursor_before: Int, group: Int) {
    change base = dataEnd(view editor)
    when base + count > HISTORY_LIMIT {
        editor.h_top = 0
        editor.h_total = 0
        editor.h_saved = -1
        base = 0
        when count > HISTORY_LIMIT { give }
    }
    hold slot = editor.h_top
    setAt(edit editor.h_kind, slot, kind)
    setAt(edit editor.h_offset, slot, offset)
    setAt(edit editor.h_count, slot, count)
    setAt(edit editor.h_start, slot, base)
    setAt(edit editor.h_group, slot, group)
    setAt(edit editor.h_cursor, slot, cursor_before)
    change i = 0
    during i < count {
        hold value = byteAt(view editor.document, offset + i)
        setAt(edit editor.h_data, base + i, value)
        i += 1
    }
    when editor.h_saved > slot { editor.h_saved = -1 }
    editor.h_top = slot + 1
    editor.h_total = slot + 1
}

// ---- selection -----------------------------------------------------------

expose flow editorHasSelection(editor: view Editor) => Bool {
    give editor.anchor >= 0 && editor.anchor != editor.cursor.offset
}

expose flow selectionStart(editor: view Editor) => Int {
    when !editorHasSelection(editor) { give editor.cursor.offset }
    when editor.anchor < editor.cursor.offset { give editor.anchor }
    give editor.cursor.offset
}

expose flow selectionEnd(editor: view Editor) => Int {
    when !editorHasSelection(editor) { give editor.cursor.offset }
    when editor.anchor > editor.cursor.offset { give editor.anchor }
    give editor.cursor.offset
}

expose flow editorClearSelection(editor: edit Editor) {
    editor.anchor = -1
}

// Start (or keep) a selection anchored at the current cursor.
expose flow editorExtendSelection(editor: edit Editor) {
    when editor.anchor < 0 { editor.anchor = editor.cursor.offset }
}

expose flow editorSelectAll(editor: edit Editor) {
    editor.anchor = 0
    editor.cursor.offset = length(view editor.document)
    rememberColumn(view editor.document, edit editor.cursor)
    editor.h_typing = false
}

flow deleteSelectionIn(editor: edit Editor, group: Int) => Bool {
    when !editorHasSelection(view editor) {
        editor.anchor = -1
        give false
    }
    hold lo = selectionStart(view editor)
    hold hi = selectionEnd(view editor)
    hold before = editor.cursor.offset
    recordOp(edit editor, OP_DELETE, lo, hi - lo, before, group)
    when !deleteRange(edit editor.document, lo, hi) { give false }
    editor.cursor.offset = lo
    editor.anchor = -1
    rememberColumn(view editor.document, edit editor.cursor)
    give true
}

// ---- editing -------------------------------------------------------------

flow continuesTyping(editor: view Editor) => Bool {
    when !editor.h_typing || editor.h_top == 0 { give false }
    hold last = editor.h_top - 1
    give editor.h_kind[last] == OP_INSERT && editor.h_offset[last] + editor.h_count[last] == editor.cursor.offset
}

expose flow editorInsertScalar(editor: edit Editor, scalar: Int) => Bool {
    change group = 0
    when editorHasSelection(view editor) {
        group = newGroup(edit editor)
        deleteSelectionIn(edit editor, group)
    } otherwise when continuesTyping(view editor) {
        group = editor.h_group[editor.h_top - 1]
    } otherwise {
        group = newGroup(edit editor)
    }
    editor.anchor = -1
    hold at = editor.cursor.offset
    hold n = insertScalar(edit editor.document, at, scalar)
    when n == 0 {
        updateDirty(edit editor)
        give false
    }
    recordOp(edit editor, OP_INSERT, at, n, at, group)
    editor.cursor.offset = at + n
    rememberColumn(view editor.document, edit editor.cursor)
    // Whitespace closes the current undo word.
    editor.h_typing = scalar != 32 && scalar != 9
    updateDirty(edit editor)
    give true
}

expose flow editorEnter(editor: edit Editor) => Bool {
    hold group = newGroup(edit editor)
    deleteSelectionIn(edit editor, group)
    hold at = editor.cursor.offset
    change n = 1
    when editor.newline_crlf {
        hold newline = "\r\n"
        when !insertText(edit editor.document, at, view newline) { give false }
        n = 2
    } otherwise {
        hold newline = "\n"
        when !insertText(edit editor.document, at, view newline) { give false }
    }
    recordOp(edit editor, OP_INSERT, at, n, at, group)
    editor.cursor.offset = at + n
    editor.cursor.column_bytes = 0
    updateDirty(edit editor)
    give true
}

expose flow editorBackspace(editor: edit Editor) => Bool {
    hold group = newGroup(edit editor)
    when deleteSelectionIn(edit editor, group) {
        updateDirty(edit editor)
        give true
    }
    hold old = editor.cursor.offset
    when old == 0 { give false }
    left(view editor.document, edit editor.cursor)
    hold start = editor.cursor.offset
    recordOp(edit editor, OP_DELETE, start, old - start, old, group)
    when !deleteRange(edit editor.document, start, old) { give false }
    rememberColumn(view editor.document, edit editor.cursor)
    updateDirty(edit editor)
    give true
}

expose flow editorDelete(editor: edit Editor) => Bool {
    hold group = newGroup(edit editor)
    when deleteSelectionIn(edit editor, group) {
        updateDirty(edit editor)
        give true
    }
    hold at = editor.cursor.offset
    change probe = Cursor(offset: at, column_bytes: 0)
    right(view editor.document, edit probe)
    when probe.offset == at { give false }
    recordOp(edit editor, OP_DELETE, at, probe.offset - at, at, group)
    when !deleteRange(edit editor.document, at, probe.offset) { give false }
    updateDirty(edit editor)
    give true
}

expose flow editorHome(editor: edit Editor) {
    editor.cursor.offset = lineStart(view editor.document, editor.cursor.offset)
    editor.cursor.column_bytes = 0
}

expose flow editorEnd(editor: edit Editor) {
    editor.cursor.offset = lineEnd(view editor.document, editor.cursor.offset)
    rememberColumn(view editor.document, edit editor.cursor)
}

// ---- undo / redo ---------------------------------------------------------

expose flow editorUndo(editor: edit Editor) => Bool {
    when editor.h_top == 0 { give false }
    hold group = editor.h_group[editor.h_top - 1]
    during editor.h_top > 0 && editor.h_group[editor.h_top - 1] == group {
        hold slot = editor.h_top - 1
        hold offset = editor.h_offset[slot]
        hold count = editor.h_count[slot]
        when editor.h_kind[slot] == OP_INSERT {
            when !deleteRange(edit editor.document, offset, offset + count) { give false }
        } otherwise {
            hold start = editor.h_start[slot]
            when !insertBytes(edit editor.document, offset, view editor.h_data, start, count) { give false }
        }
        editor.cursor.offset = editor.h_cursor[slot]
        editor.h_top = slot
    }
    editor.anchor = -1
    editor.h_typing = false
    rememberColumn(view editor.document, edit editor.cursor)
    updateDirty(edit editor)
    give true
}

expose flow editorRedo(editor: edit Editor) => Bool {
    when editor.h_top >= editor.h_total { give false }
    hold group = editor.h_group[editor.h_top]
    during editor.h_top < editor.h_total && editor.h_group[editor.h_top] == group {
        hold slot = editor.h_top
        hold offset = editor.h_offset[slot]
        hold count = editor.h_count[slot]
        when editor.h_kind[slot] == OP_INSERT {
            hold start = editor.h_start[slot]
            when !insertBytes(edit editor.document, offset, view editor.h_data, start, count) { give false }
            editor.cursor.offset = offset + count
        } otherwise {
            when !deleteRange(edit editor.document, offset, offset + count) { give false }
            editor.cursor.offset = offset
        }
        editor.h_top = slot + 1
    }
    editor.anchor = -1
    editor.h_typing = false
    rememberColumn(view editor.document, edit editor.cursor)
    updateDirty(edit editor)
    give true
}

// The document now matches the file on disk.
expose flow editorMarkSaved(editor: edit Editor) {
    editor.h_saved = editor.h_top
    editor.document.dirty = false
}

// ---- clipboard -----------------------------------------------------------

expose flow editorCopy(editor: edit Editor) => Bool {
    when !editorHasSelection(view editor) { give false }
    hold lo = selectionStart(view editor)
    hold hi = selectionEnd(view editor)
    change clip: List of[Int] = List[]
    clip@reserve(hi - lo)
    change i = lo
    during i < hi {
        clip@push(byteAt(view editor.document, i))
        i += 1
    }
    editor.clipboard = clip
    give true
}

expose flow editorCut(editor: edit Editor) => Bool {
    when !editorCopy(edit editor) { give false }
    hold group = newGroup(edit editor)
    hold done = deleteSelectionIn(edit editor, group)
    updateDirty(edit editor)
    give done
}

expose flow editorPaste(editor: edit Editor) => Bool {
    hold count = editor.clipboard.length
    when count == 0 { give false }
    hold group = newGroup(edit editor)
    deleteSelectionIn(edit editor, group)
    hold at = editor.cursor.offset
    when !insertBytes(edit editor.document, at, view editor.clipboard, 0, count) {
        updateDirty(edit editor)
        give false
    }
    recordOp(edit editor, OP_INSERT, at, count, at, group)
    editor.cursor.offset = at + count
    rememberColumn(view editor.document, edit editor.cursor)
    updateDirty(edit editor)
    give true
}

// ---- find ----------------------------------------------------------------

// Append one Unicode scalar, UTF-8 encoded, to the find query.
expose flow editorQueryPush(editor: edit Editor, scalar: Int) => Bool {
    when scalar < 32 || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343) { give false }
    change at = editor.query_len
    when scalar < 128 {
        setAt(edit editor.query, at, scalar)
        at += 1
    } otherwise when scalar < 2048 {
        setAt(edit editor.query, at, 192 + scalar / 64)
        setAt(edit editor.query, at + 1, 128 + scalar % 64)
        at += 2
    } otherwise when scalar < 65536 {
        setAt(edit editor.query, at, 224 + scalar / 4096)
        setAt(edit editor.query, at + 1, 128 + (scalar / 64) % 64)
        setAt(edit editor.query, at + 2, 128 + scalar % 64)
        at += 3
    } otherwise {
        setAt(edit editor.query, at, 240 + scalar / 262144)
        setAt(edit editor.query, at + 1, 128 + (scalar / 4096) % 64)
        setAt(edit editor.query, at + 2, 128 + (scalar / 64) % 64)
        setAt(edit editor.query, at + 3, 128 + scalar % 64)
        at += 4
    }
    editor.query_len = at
    editor.find_failed = false
    give true
}

// Remove the last complete UTF-8 scalar of the find query.
expose flow editorQueryPop(editor: edit Editor) => Bool {
    when editor.query_len == 0 { give false }
    change at = editor.query_len - 1
    during at > 0 && editor.query[at] >= 128 && editor.query[at] < 192 { at -= 1 }
    editor.query_len = at
    editor.find_failed = false
    give true
}

// Select the next match after the cursor, wrapping once to the start.
expose flow editorFindNext(editor: edit Editor) => Bool {
    when editor.query_len == 0 { give false }
    change at = findBytes(view editor.document, view editor.query, editor.query_len, editor.cursor.offset)
    when at < 0 { at = findBytes(view editor.document, view editor.query, editor.query_len, 0) }
    when at < 0 {
        editor.find_failed = true
        give false
    }
    editor.anchor = at
    editor.cursor.offset = at + editor.query_len
    rememberColumn(view editor.document, edit editor.cursor)
    editor.h_typing = false
    editor.find_failed = false
    give true
}
