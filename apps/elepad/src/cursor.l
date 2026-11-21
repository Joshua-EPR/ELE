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
    during c.offset > 0 && !boundary(b, c.offset) { c.offset -= 1 }
}

expose flow right(b: view Buffer, c: edit Cursor) {
    when c.offset >= length(b) { give }
    c.offset += 1
    during c.offset < length(b) && !boundary(b, c.offset) { c.offset += 1 }
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
    hold end = lineEnd(b, c.offset)
    when end == length(b) { give }
    hold start = end + 1
    hold next_end = lineEnd(b, start)
    change target = start + c.column_bytes
    when target > next_end { target = next_end }
    during target > start && !boundary(b, target) { target -= 1 }
    c.offset = target
}
