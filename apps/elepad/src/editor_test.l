import buffer
import cursor
import search

flow equalsText(b: view Buffer, source: view Text) => Bool {
    when length(b) != source.byteLength { give false }
    change i = 0
    during i < source.byteLength {
        when byteAt(b, i) != source@byteAt(i) { give false }
        i += 1
    }
    give true
}

flow main() => Int {
    change empty = newBuffer()
    when length(view empty) != 0 { give 1 }
    when deleteForward(edit empty, 0) { give 2 }
    hold sample = "José\r\nELE\n"
    change b = loadText(view sample)
    when !equalsText(view b, view sample) { give 3 }
    when boundary(view b, 4) || !boundary(view b, 5) { give 4 }
    when !insertAscii(edit b, 0, 88) { give 5 }
    when !insertAscii(edit b, 6, 33) { give 6 }
    when !deleteForward(edit b, 6) { give 7 }
    when !deleteForward(edit b, 0) { give 8 }
    when !equalsText(view b, view sample) { give 9 }
    when !deleteForward(edit b, 3) { give 10 }
    hold accent = "é"
    when !insertText(edit b, 3, view accent) { give 11 }
    when !equalsText(view b, view sample) { give 12 }
    change c = newCursor()
    c.offset = 3
    right(view b, edit c)
    when c.offset != 5 { give 20 }
    left(view b, edit c)
    when c.offset != 3 { give 21 }
    hold query = "ELE"
    when findText(view b, view query, 0) != 7 { give 22 }
    when insertAscii(edit b, 4, 88) { give 23 }
    when deleteForward(edit b, 4) { give 24 }
    hold absent = "XYZ"
    when findText(view b, view absent, 0) != -1 { give 25 }
    c.offset = 8
    rememberColumn(view b, edit c)
    up(view b, edit c)
    when c.offset != 1 { give 26 }
    down(view b, edit c)
    when c.offset != 8 { give 27 }
    change many = newBuffer()
    change i = 0
    during i < 2000 {
        insertAscii(edit many, i, 65)
        i += 1
    }
    when length(view many) != 2000 { give 13 }
    when byteAt(view many, 1999) != 65 { give 14 }
    when !insertAscii(edit many, 0, 66) { give 28 }
    when byteAt(view many, 0) != 66 || byteAt(view many, 2000) != 65 { give 29 }
    when processArgCount() != 1 { give 15 }
    choose processArg(0) {
        Ok(path): {
            change output = toBytes(view b)
            when writeBytes(path, output) != 0 { give 16 }
            choose readText(path, 1024) {
                Ok(reopened): {
                    when !equalsText(view b, view reopened) { give 17 }
                },
                Err(code): { give 18 },
            }
        },
        Err(code): { give 19 },
    }
    print("elepad-core-ok")
    give 0
}
