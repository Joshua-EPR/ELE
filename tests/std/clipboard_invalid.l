take std.ui.clipboard

flow main() => Int {
    change good: List of[Int] = List[107, 101, 101, 112]
    when clipboardWrite(view good) != 0 { give 1 }
    change nul: List of[Int] = List[0]
    when clipboardWrite(view nul) != -1 { give 3 }
    change overlong: List of[Int] = List[192, 175]
    when clipboardWrite(view overlong) != -1 { give 2 }
    change nonbyte: List of[Int] = List[256]
    when clipboardWrite(view nonbyte) != -1 { give 4 }
    hold after = clipboardRead(CLIPBOARD_LIMIT)
    when after.status != 4 || after.bytes[0] != 107 || after.bytes[3] != 112 { give 5 }
    change occupied: List of[Int] = List[9]
    when clipboardReadBytes(occupied, CLIPBOARD_LIMIT) != -1 { give 6 }
    when occupied.length != 1 || occupied[0] != 9 { give 7 }
    give 0
}
