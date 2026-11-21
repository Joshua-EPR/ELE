import buffer

expose shape Cursor {
    offset: Int
    column_bytes: Int
}

expose flow newCursor() => Cursor {
    give Cursor(offset: 0, column_bytes: 0)
}

expose flow left(b: view Buffer, c: edit Cursor) {
    when c.offset == 0 { give }
    c.offset -= 1
    when c.offset > 0 && byteAt(b, c.offset) == 10 && byteAt(b, c.offset - 1) == 13 { c.offset -= 1 }
    during c.offset > 0 && !boundary(b, c.offset) { c.offset -= 1 }
    rememberColumn(b, edit c)
}

expose flow right(b: view Buffer, c: edit Cursor) {
    when c.offset >= length(b) { give }
    hold crlf = byteAt(b, c.offset) == 13 && c.offset + 1 < length(b) && byteAt(b, c.offset + 1) == 10
    c.offset += 1
    when crlf { c.offset += 1 }
    during c.offset < length(b) && !boundary(b, c.offset) { c.offset += 1 }
    rememberColumn(b, edit c)
}

expose flow lineStart(b: view Buffer, offset: Int) => Int {
    change i = offset
    during i > 0 {
        when byteAt(b, i - 1) == 10 { leave }
        i -= 1
    }
    give i
}

expose flow lineEnd(b: view Buffer, offset: Int) => Int {
    change i = offset
    during i < length(b) {
        when byteAt(b, i) == 10 { leave }
        i += 1
    }
    when i > 0 && i < length(b) && byteAt(b, i - 1) == 13 { give i - 1 }
    give i
}

// Position of the LF delimiter, or the document end. A CRLF delimiter is
// kept intact in the buffer; only the cursor's visible end excludes CR.
flow lineBreak(b: view Buffer, offset: Int) => Int {
    change i = offset
    during i < length(b) && byteAt(b, i) != 10 { i += 1 }
    give i
}

expose flow rememberColumn(b: view Buffer, c: edit Cursor) {
    c.column_bytes = c.offset - lineStart(b, c.offset)
}

expose flow up(b: view Buffer, c: edit Cursor) {
    hold start = lineStart(b, c.offset)
    when start == 0 { give }
    hold previous = lineStart(b, start - 1)
    hold end = lineEnd(b, previous)
    change target = previous + c.column_bytes
    when target > end { target = end }
    during target > previous && !boundary(b, target) { target -= 1 }
    c.offset = target
}

expose flow down(b: view Buffer, c: edit Cursor) {
    hold delimiter = lineBreak(b, c.offset)
    when delimiter == length(b) { give }
    hold start = delimiter + 1
    hold next_end = lineEnd(b, start)
    change target = start + c.column_bytes
    when target > next_end { target = next_end }
    during target > start && !boundary(b, target) { target -= 1 }
    c.offset = target
}
