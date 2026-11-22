take editor_core
take std.ui.window

// Window renderer of ELEPad: title bar, line-number gutter, text with tab
// expansion and horizontal scroll, selection, cursor, status bar (or the
// find prompt). Everything is drawn into the window's back buffer from the
// shared Editor and shown with windowPresent. Columns are Unicode scalars
// in one monospace cell each (no grapheme or East Asian width yet), as in
// the terminal renderer.

expose fixed GUI_MESSAGE_NONE = 0
expose fixed GUI_MESSAGE_UNSAVED = 1
expose fixed GUI_MESSAGE_SAVED = 2
expose fixed GUI_MESSAGE_SAVE_FAILED = 3

fixed COLOR_BACKGROUND = 1974052        // 0x1E1F24
fixed COLOR_BAR = 2763827               // 0x2A2C33
fixed COLOR_TEXT = 14211288             // 0xD8D8D8
fixed COLOR_GUTTER = 7041152            // 0x6B7080
fixed COLOR_SELECTION = 2510712         // 0x264F78
fixed COLOR_CURSOR = 16763904           // 0xFFCC00
fixed COLOR_ACCENT = 8441343            // 0x80CCFF

expose shape GuiView {
    top: Int
    left: Int
    width: Int
    height: Int
    cell_w: Int
    cell_h: Int
    message: Int
}

expose flow guiView(cell: Int, width: Int, height: Int) => GuiView {
    change cell_w = cell % 65536
    change cell_h = cell / 65536
    when cell_w < 1 { cell_w = 8 }
    when cell_h < 1 { cell_h = 16 }
    give GuiView(top: 0, left: 0, width: width, height: height, cell_w: cell_w, cell_h: cell_h, message: GUI_MESSAGE_NONE)
}

flow digits(value: Int) => Int {
    change n = value
    change count = 1
    during n >= 10 {
        n = n / 10
        count += 1
    }
    give count
}

flow lineCount(b: view Buffer) => Int {
    change n = 1
    change i = 0
    during i < length(b) {
        when byteAt(b, i) == 10 { n += 1 }
        i += 1
    }
    give n
}

flow lineOf(b: view Buffer, offset: Int) => Int {
    change n = 0
    change i = 0
    during i < offset {
        when byteAt(b, i) == 10 { n += 1 }
        i += 1
    }
    give n
}

// Visual column of `offset` on its line: tabs to the next multiple of 4.
expose flow guiColumn(b: view Buffer, offset: Int) => Int {
    change i = lineStart(b, offset)
    change col = 0
    during i < offset {
        hold ch = byteAt(b, i)
        when ch == 9 { col += 4 - col % 4 }
        otherwise when ch != 13 && (ch < 128 || ch >= 192) { col += 1 }
        i += 1
    }
    give col
}

// Geometry derived from the window and font.
expose flow guiTextTop(v: view GuiView) => Int { give v.cell_h + 12 }
flow statusTop(v: view GuiView) => Int { give v.height - v.cell_h - 8 }

expose flow guiRows(v: view GuiView) => Int {
    hold rows = (statusTop(v) - guiTextTop(v)) / v.cell_h
    when rows < 1 { give 1 }
    give rows
}

flow gutterWidth(b: view Buffer, v: view GuiView) => Int {
    give (digits(lineCount(b)) + 2) * v.cell_w
}

expose flow guiTextLeft(b: view Buffer, v: view GuiView) => Int {
    give gutterWidth(b, v) + 6
}

expose flow guiColumns(b: view Buffer, v: view GuiView) => Int {
    hold cols = (v.width - guiTextLeft(b, v)) / v.cell_w
    when cols < 1 { give 1 }
    give cols
}

// Keep the cursor visible: scroll by lines and by columns.
expose flow guiFollowCursor(editor: view Editor, v: edit GuiView) {
    hold line = lineOf(view editor.document, editor.cursor.offset)
    hold rows = guiRows(view v)
    when line < v.top { v.top = line }
    when line >= v.top + rows { v.top = line - rows + 1 }
    hold col = guiColumn(view editor.document, editor.cursor.offset)
    hold cols = guiColumns(view editor.document, view v)
    when col < v.left { v.left = col }
    when col >= v.left + cols { v.left = col - cols + 1 }
}

// Document offset under window point (x, y), clamped to the document: the
// line under y and the scalar under x (a click past the end of a line
// lands at its end).
expose flow guiOffsetAt(editor: view Editor, v: view GuiView, x: Int, y: Int) => Int {
    hold b = view editor.document
    change row = (y - guiTextTop(v)) / v.cell_h
    when y < guiTextTop(v) { row = 0 }
    hold target_line = v.top + row
    change at = 0
    change line = 0
    during line < target_line && at < length(b) {
        when byteAt(b, at) == 10 { line += 1 }
        at += 1
    }
    when line < target_line { give length(b) }
    change want = v.left + (x - guiTextLeft(b, v) + v.cell_w / 2) / v.cell_w
    when x < guiTextLeft(b, v) { want = v.left }
    change col = 0
    during at < length(b) && byteAt(b, at) != 10 && byteAt(b, at) != 13 {
        hold ch = byteAt(b, at)
        change next = col + 1
        when ch == 9 { next = col + 4 - col % 4 }
        when next > want { leave }
        col = next
        at += 1
        during at < length(b) && !boundary(b, at) { at += 1 }
    }
    give at
}

// One document line from `start`: visible bytes (tabs as spaces, columns
// [left, left + cols)) into `out`; returns its LF offset or the end.
flow visibleLine(b: view Buffer, start: Int, left: Int, cols: Int, out: edit List of[Int]) => Int {
    change i = start
    change col = 0
    during i < length(b) && byteAt(b, i) != 10 {
        hold ch = byteAt(b, i)
        when ch == 13 {
            i += 1
        } otherwise when ch == 9 {
            hold spaces = 4 - col % 4
            change k = 0
            during k < spaces {
                when col >= left && col < left + cols { out@push(32) }
                col += 1
                k += 1
            }
            i += 1
        } otherwise {
            hold visible = col >= left && col < left + cols
            when visible { out@push(ch) }
            i += 1
            during i < length(b) && !boundary(b, i) {
                when visible { out@push(byteAt(b, i)) }
                i += 1
            }
            col += 1
        }
    }
    give i
}

flow fill(w: view Window, x: Int, y: Int, width: Int, height: Int, rgb: Int, status: edit Int) {
    hold r = windowFill(w, x, y, width, height, rgb)
    when r != 0 && status == 0 { status = r }
}

expose flow guiRender(w: view Window, editor: view Editor, title: view Text, v: view GuiView) => Int {
    change status = 0
    hold b = view editor.document
    hold cw = v.cell_w
    hold ch = v.cell_h
    fill(w, 0, 0, v.width, v.height, COLOR_BACKGROUND, edit status)
    // Title bar.
    fill(w, 0, 0, v.width, ch + 8, COLOR_BAR, edit status)
    change marker = ""
    when b.dirty { marker = "  ●" }
    hold heading = "ELEPad  {title}{marker}"
    windowText(w, 8, 4, heading, COLOR_TEXT)
    // Text area.
    hold top_y = guiTextTop(v)
    hold rows = guiRows(v)
    hold x0 = guiTextLeft(b, v)
    hold cols = guiColumns(b, v)
    hold sel_lo = selectionStart(editor)
    hold sel_hi = selectionEnd(editor)
    hold selecting = editorHasSelection(editor)
    change at = 0
    change line = 0
    during line < v.top && at < length(b) {
        when byteAt(b, at) == 10 { line += 1 }
        at += 1
    }
    change row = 0
    change ended = line < v.top
    during row < rows && !ended {
        hold y = top_y + row * ch
        hold number = "{line + 1}"
        windowText(w, cw, y, number, COLOR_GUTTER)
        change out: List of[Int] = List[]
        hold line_end = visibleLine(b, at, v.left, cols, edit out)
        when selecting && sel_lo <= line_end && sel_hi > at {
            change lo = at
            when sel_lo > lo { lo = sel_lo }
            change hi = line_end
            when sel_hi < hi { hi = sel_hi }
            change c0 = guiColumn(b, lo) - v.left
            change c1 = guiColumn(b, hi) - v.left
            when hi == line_end && sel_hi > line_end { c1 += 1 }
            when c0 < 0 { c0 = 0 }
            when c1 > cols { c1 = cols }
            when c1 > c0 { fill(w, x0 + c0 * cw, y, (c1 - c0) * cw, ch, COLOR_SELECTION, edit status) }
        }
        when out.length > 0 { windowTextBytes(w, x0, y, out, out.length, COLOR_TEXT) }
        // Cursor: a two-pixel bar before the cursor's column.
        when editor.cursor.offset >= at && editor.cursor.offset <= line_end {
            hold col = guiColumn(b, editor.cursor.offset) - v.left
            when col >= 0 && col <= cols { fill(w, x0 + col * cw, y, 2, ch, COLOR_CURSOR, edit status) }
        }
        when line_end >= length(b) { ended = true }
        at = line_end + 1
        line += 1
        row += 1
    }
    // Status bar, or the find prompt.
    hold bar_y = statusTop(v)
    fill(w, 0, bar_y, v.width, ch + 8, COLOR_BAR, edit status)
    when editor.mode == MODE_FIND {
        hold label = "Buscar: "
        windowText(w, 8, bar_y + 4, label, COLOR_ACCENT)
        when editor.query_len > 0 { windowTextBytes(w, 8 + 8 * cw, bar_y + 4, editor.query, editor.query_len, COLOR_TEXT) }
        change hint = "Enter siguiente  Esc volver"
        when editor.find_failed { hint = "sin resultados  Enter siguiente  Esc volver" }
        windowText(w, 8 + (10 + editor.query_len) * cw, bar_y + 4, hint, COLOR_GUTTER)
    } otherwise {
        hold cursor_line = lineOf(b, editor.cursor.offset) + 1
        hold cursor_col = guiColumn(b, editor.cursor.offset) + 1
        change note = "^S guardar  ^Q salir  ^F buscar  ^Z/^Y deshacer/rehacer"
        when v.message == GUI_MESSAGE_UNSAVED { note = "Cambios sin guardar: cerrar otra vez para descartarlos" }
        when v.message == GUI_MESSAGE_SAVED { note = "Guardado" }
        when v.message == GUI_MESSAGE_SAVE_FAILED { note = "Error al guardar" }
        hold status_text = "Ln {cursor_line}, Col {cursor_col}    {note}"
        windowText(w, 8, bar_y + 4, status_text, COLOR_TEXT)
    }
    hold presented = windowPresent(w)
    when status == 0 { status = presented }
    give status
}
