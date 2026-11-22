// Gap buffer of UTF-8 bytes. Positions are byte offsets.
expose shape Buffer {
    bytes: List of[Int]
    gap_start: Int
    gap_end: Int
    dirty: Bool
}

expose flow newBuffer() => Buffer {
    change bytes: List of[Int] = List[]
    change i = 0
    during i < 256 {
        bytes@push(0)
        i += 1
    }
    give Buffer(bytes: bytes, gap_start: 0, gap_end: 256, dirty: false)
}

expose flow length(b: view Buffer) => Int {
    give b.bytes.length - b.gap_end + b.gap_start
}

expose flow byteAt(b: view Buffer, offset: Int) => Int {
    when offset < b.gap_start { give b.bytes[offset] }
    give b.bytes[offset + b.gap_end - b.gap_start]
}

expose flow boundary(b: view Buffer, offset: Int) => Bool {
    when offset < 0 || offset > length(b) { give false }
    when offset == 0 || offset == length(b) { give true }
    hold value = byteAt(b, offset)
    give value < 128 || value >= 192
}

flow moveGap(b: edit Buffer, offset: Int) {
    during b.gap_start < offset {
        b.bytes[b.gap_start] = b.bytes[b.gap_end]
        b.gap_start += 1
        b.gap_end += 1
    }
    during b.gap_start > offset {
        b.gap_start -= 1
        b.gap_end -= 1
        b.bytes[b.gap_end] = b.bytes[b.gap_start]
    }
}

flow grow(b: edit Buffer) {
    hold old_end = b.bytes.length
    change i = 0
    during i < 256 {
        b.bytes@push(0)
        i += 1
    }
    change src = old_end
    during src > b.gap_end {
        src -= 1
        b.bytes[src + 256] = b.bytes[src]
    }
    b.gap_end += 256
}

flow insertRaw(b: edit Buffer, offset: Int, value: Int) {
    moveGap(edit b, offset)
    when b.gap_start == b.gap_end { grow(edit b) }
    b.bytes[b.gap_start] = value
    b.gap_start += 1
    b.dirty = true
}

expose flow insertAscii(b: edit Buffer, offset: Int, value: Int) => Bool {
    when value < 0 || value > 127 || !boundary(view b, offset) { give false }
    insertRaw(edit b, offset, value)
    give true
}

expose flow insertText(b: edit Buffer, offset: Int, source: view Text) => Bool {
    when !boundary(view b, offset) { give false }
    change i = 0
    during i < source.byteLength {
        insertRaw(edit b, offset + i, source@byteAt(i))
        i += 1
    }
    give true
}

// Insert one Unicode scalar as UTF-8. Return its encoded byte count, or 0
// for an invalid scalar or a position inside another UTF-8 sequence.
expose flow insertScalar(b: edit Buffer, offset: Int, scalar: Int) => Int {
    when !boundary(view b, offset) || scalar < 0 || scalar > 1114111 || (scalar >= 55296 && scalar <= 57343) { give 0 }
    when scalar < 128 {
        insertRaw(edit b, offset, scalar)
        give 1
    }
    when scalar < 2048 {
        insertRaw(edit b, offset, 192 + scalar / 64)
        insertRaw(edit b, offset + 1, 128 + scalar % 64)
        give 2
    }
    when scalar < 65536 {
        insertRaw(edit b, offset, 224 + scalar / 4096)
        insertRaw(edit b, offset + 1, 128 + (scalar / 64) % 64)
        insertRaw(edit b, offset + 2, 128 + scalar % 64)
        give 3
    }
    insertRaw(edit b, offset, 240 + scalar / 262144)
    insertRaw(edit b, offset + 1, 128 + (scalar / 4096) % 64)
    insertRaw(edit b, offset + 2, 128 + (scalar / 64) % 64)
    insertRaw(edit b, offset + 3, 128 + scalar % 64)
    give 4
}

expose flow deleteForward(b: edit Buffer, offset: Int) => Bool {
    when offset >= length(view b) || !boundary(view b, offset) { give false }
    hold crlf = byteAt(view b, offset) == 13 && offset + 1 < length(view b) && byteAt(view b, offset + 1) == 10
    moveGap(edit b, offset)
    when crlf { b.gap_end += 2 }
    otherwise { b.gap_end += 1 }
    during offset < length(view b) && !boundary(view b, offset) {
        b.gap_end += 1
    }
    b.dirty = true
    give true
}

// Remove the complete UTF-8 scalar immediately before a byte boundary.
// Return false at the start of the document or for an invalid offset.
expose flow deleteBackward(b: edit Buffer, offset: Int) => Bool {
    when offset <= 0 || !boundary(view b, offset) { give false }
    change start = offset - 1
    when offset >= 2 && byteAt(view b, offset - 1) == 10 && byteAt(view b, offset - 2) == 13 {
        start -= 1
    }
    during start > 0 && !boundary(view b, start) { start -= 1 }
    moveGap(edit b, offset)
    b.gap_start = start
    b.dirty = true
    give true
}

// Remove the bytes [start, end). Both ends must be UTF-8 boundaries.
expose flow deleteRange(b: edit Buffer, start: Int, end: Int) => Bool {
    when start < 0 || end > length(view b) || start >= end { give false }
    when !boundary(view b, start) || !boundary(view b, end) { give false }
    moveGap(edit b, end)
    b.gap_start = start
    b.dirty = true
    give true
}

// Insert count bytes of source starting at index from. The caller supplies
// bytes previously taken from this buffer, so they are complete UTF-8.
expose flow insertBytes(b: edit Buffer, offset: Int, source: view List of[Int], from: Int, count: Int) => Bool {
    when !boundary(view b, offset) || from < 0 || count < 0 || from + count > source.length { give false }
    change i = 0
    during i < count {
        insertRaw(edit b, offset + i, source[from + i])
        i += 1
    }
    give true
}

expose flow loadText(source: view Text) => Buffer {
    change b = newBuffer()
    change i = 0
    during i < source.byteLength {
        insertRaw(edit b, i, source@byteAt(i))
        i += 1
    }
    b.dirty = false
    give b
}

expose flow toBytes(b: view Buffer) => List of[Int] {
    change out: List of[Int] = List[]
    out@reserve(length(b))
    change i = 0
    during i < length(b) {
        out@push(byteAt(b, i))
        i += 1
    }
    give out
}
