take buffer

// Return byte offset, or -1. Search begins at a UTF-8 boundary.
expose flow findText(b: view Buffer, needle: view Text, start: Int) => Int {
    when needle.byteLength == 0 || !boundary(b, start) { give -1 }
    change i = start
    during i + needle.byteLength <= length(b) {
        when boundary(b, i) && boundary(b, i + needle.byteLength) {
            change j = 0
            during j < needle.byteLength {
                when byteAt(b, i + j) != needle@byteAt(j) { leave }
                j += 1
            }
            when j == needle.byteLength { give i }
        }
        i += 1
    }
    give -1
}

// Same as findText over the first count bytes of a UTF-8 byte list.
expose flow findBytes(b: view Buffer, needle: view List of[Int], count: Int, start: Int) => Int {
    when count <= 0 || count > needle.length || !boundary(b, start) { give -1 }
    change i = start
    during i + count <= length(b) {
        when boundary(b, i) && boundary(b, i + count) {
            change j = 0
            during j < count {
                when byteAt(b, i + j) != needle[j] { leave }
                j += 1
            }
            when j == count { give i }
        }
        i += 1
    }
    give -1
}
