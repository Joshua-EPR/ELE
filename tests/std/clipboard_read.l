take std.ui.clipboard

flow main() => Int {
    hold read = clipboardRead(CLIPBOARD_LIMIT)
    when read.status < 0 { printError("clipboardRead: {read.status}"); give 1 }
    when writeConsoleBytes(read.bytes) != 0 { give 2 }
    give 0
}
