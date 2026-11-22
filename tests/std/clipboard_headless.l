take std.ui.clipboard

flow main() => Int {
    change bytes: List of[Int] = List[65]
    when clipboardWrite(view bytes) != CLIPBOARD_UNAVAILABLE { give 1 }
    hold incoming = clipboardRead(100)
    when incoming.status != CLIPBOARD_UNAVAILABLE || incoming.bytes.length != 0 { give 2 }
    give 0
}
