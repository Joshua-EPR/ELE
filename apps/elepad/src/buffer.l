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

expose flow deleteForward(b: edit Buffer, offset: Int) => Bool {
    when offset >= length(view b) || !boundary(view b, offset) { give false }
    moveGap(edit b, offset)
    b.gap_end += 1
    during offset < length(view b) && !boundary(view b, offset) {
        b.gap_end += 1
    }
    b.dirty = true
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
