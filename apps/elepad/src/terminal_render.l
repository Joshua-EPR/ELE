take editor_core

// ANSI/VT renderer. Bytes are returned to the caller for one checked write.
// Columns are Unicode scalar positions, not grapheme or East Asian widths.
flow appendText(out: edit List of[Int], value: view Text) {
    change i = 0
    during i < value.byteLength {
        out@push(value@byteAt(i))
        i += 1
    }
}

flow lineNumber(b: view Buffer, offset: Int) => Int {
    change n = 0
    change i = 0
    during i < offset {
        when byteAt(b, i) == 10 { n += 1 }
        i += 1
    }
    give n
}

flow decimalDigits(value: Int) => Int {
    change n = value
    change digits = 1
    during n >= 10 {
        n = n / 10
        digits += 1
    }
    give digits
}

flow visualColumn(b: view Buffer, offset: Int) => Int {
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

flow emitPosition(out: edit List of[Int], row: Int, col: Int) {
    hold seq = "\u{1b}[{row};{col}H"
    appendText(edit out, view seq)
}

flow emitLine(out: edit List of[Int], b: view Buffer, start: Int, n: Int, width: Int) {
    hold line_number = n + 1
    hold prefix = "{line_number}  "
    appendText(edit out, view prefix)
    change col = prefix.byteLength
    change tab_col = 0
    change i = start
    during i < length(b) && byteAt(b, i) != 10 {
        hold ch = byteAt(b, i)
        when ch == 13 { i += 1 }
        otherwise when ch == 9 {
            hold spaces = 4 - tab_col % 4
            change k = 0
            during k < spaces && col < width {
                out@push(32)
                col += 1
                k += 1
            }
            tab_col += spaces
            i += 1
        } otherwise {
            when col >= width { leave }
            out@push(ch)
            i += 1
            during i < length(b) && !boundary(b, i) {
                out@push(byteAt(b, i))
                i += 1
            }
            col += 1
            tab_col += 1
        }
    }
}

flow emitStatus(out: edit List of[Int], editor: view Editor, path: view Text, height: Int) {
    emitPosition(edit out, height, 1)
    hold clear = "\u{1b}[2K"
    appendText(edit out, view clear)
    hold line = lineNumber(view editor.document, editor.cursor.offset) + 1
    hold col = visualColumn(view editor.document, editor.cursor.offset) + 1
    change marker = ""
    when editor.document.dirty { marker = " *" }
    hold status = "{path}{marker}  Ln {line}, Col {col}  Ctrl+S guardar  Ctrl+Q salir"
    appendText(edit out, view status)
}

flow emitCursor(out: edit List of[Int], editor: view Editor, top: Int, width: Int, height: Int) {
    hold line = lineNumber(view editor.document, editor.cursor.offset)
    change row = line - top + 2
    when row < 2 { row = 2 }
    when row >= height { row = height - 1 }
    change col = decimalDigits(line + 1) + 3 + visualColumn(view editor.document, editor.cursor.offset)
    when col > width { col = width }
    emitPosition(edit out, row, col)
    hold show = "\u{1b}[?25h"
    appendText(edit out, view show)
}

expose flow renderFull(editor: view Editor, path: view Text, top: Int, width: Int, height: Int) => List of[Int] {
    change out: List of[Int] = List[]
    out@reserve(height * (width + 20) + path.byteLength + 256)
    hold clear = "\u{1b}[?25l\u{1b}[2J\u{1b}[H"
    appendText(edit out, view clear)
    hold title = "ELEPad  {path}"
    appendText(edit out, view title)
    change n = 0
    change at = 0
    during n < top && at < length(view editor.document) {
        during at < length(view editor.document) && byteAt(view editor.document, at) != 10 { at += 1 }
        when at < length(view editor.document) { at += 1 }
        n += 1
    }
    change row = 2
    during row < height {
        emitPosition(edit out, row, 1)
        when at <= length(view editor.document) {
            emitLine(edit out, view editor.document, at, n, width)
            during at < length(view editor.document) && byteAt(view editor.document, at) != 10 { at += 1 }
            when at < length(view editor.document) { at += 1 }
            otherwise { at = length(view editor.document) + 1 }
        }
        row += 1
        n += 1
    }
    emitStatus(edit out, editor, path, height)
    emitCursor(edit out, editor, top, width, height)
    give out
}

expose flow renderCursorOnly(editor: view Editor, top: Int, width: Int, height: Int) => List of[Int] {
    change out: List of[Int] = List[]
    out@reserve(48)
    emitCursor(edit out, editor, top, width, height)
    give out
}

expose flow renderCurrentLine(editor: view Editor, path: view Text, top: Int, width: Int, height: Int) => List of[Int] {
    change out: List of[Int] = List[]
    out@reserve(width + path.byteLength + 128)
    hold n = lineNumber(view editor.document, editor.cursor.offset)
    when n < top || n >= top + height - 2 { give renderFull(editor, path, top, width, height) }
    emitPosition(edit out, n - top + 2, 1)
    hold clear = "\u{1b}[2K"
    appendText(edit out, view clear)
    emitLine(edit out, view editor.document, lineStart(view editor.document, editor.cursor.offset), n, width)
    emitStatus(edit out, editor, path, height)
    emitCursor(edit out, editor, top, width, height)
    give out
}
