// Native system clipboard, UTF-8 bytes in ELE and CF_UNICODETEXT on Windows.
// Status: 0 write success; read returns a nonnegative byte count. -1 invalid
// bytes/limit, -2 no Unicode text, -5 OS failure, -7 unsupported platform.
// The read operation leaves the clipboard untouched and returns an empty
// list on failure. There is no implicit fallback on an OS error.
expose fixed CLIPBOARD_UNAVAILABLE = -7
expose fixed CLIPBOARD_NO_TEXT = -2
expose fixed CLIPBOARD_LIMIT = 67108864

expose shape ClipboardData {
    bytes: List of[Int]
    status: Int
}

expose flow clipboardWrite(bytes: view List of[Int]) => Int {
    give clipboardWriteBytes(bytes, bytes.length)
}

expose flow clipboardRead(limit: Int) => ClipboardData {
    change bytes: List of[Int] = List[]
    hold status = clipboardReadBytes(bytes, limit)
    give ClipboardData(bytes: bytes, status: status)
}
