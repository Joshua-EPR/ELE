take std.ui.clipboard

flow main() => Int {
    hold sample = "Stress: á😀漢字\r\n"
    change bytes: List of[Int] = List[]
    each i among 0..sample.byteLength { bytes@push(sample@byteAt(i)) }
    change round = 0
    during round < 500 {
        hold wrote = clipboardWrite(view bytes)
        when wrote != 0 { printError("write {round}: {wrote}"); give 1 }
        hold result = clipboardRead(CLIPBOARD_LIMIT)
        when result.status != bytes.length || result.bytes.length != bytes.length { printError("read {round}: {result.status}, len {result.bytes.length}"); give 2 }
        each i among 0..bytes.length {
            when result.bytes[i] != bytes[i] { give 3 }
        }
        round += 1
    }
    give 0
}
