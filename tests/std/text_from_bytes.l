// textFromBytes on PE32+ and ELF64: a Text from the UTF-8 bytes of a
// List of[Int], with strict validation. Prints text-from-bytes-ok; any
// other exit code names the failed check.

flow okText(bytes: view List of[Int], count: Int, expected: view Text) => Bool {
    choose textFromBytes(bytes, count) {
        Ok(t): {
            when t.byteLength != expected.byteLength { give false }
            change i = 0
            during i < t.byteLength {
                when t@byteAt(i) != expected@byteAt(i) { give false }
                i += 1
            }
            give true
        },
        Err(code): { give false },
    }
}

flow errCode(bytes: view List of[Int], count: Int) => Int {
    choose textFromBytes(bytes, count) {
        Ok(t): { give 0 },
        Err(code): { give code },
    }
}

flow main() => Int {
    hold ascii: List of[Int] = List[69, 76, 69, 33]
    hold ele = "ELE!"
    when !okText(view ascii, 4, view ele) { give 10 }
    hold prefix = "EL"
    when !okText(view ascii, 2, view prefix) { give 11 }
    hold empty = ""
    when !okText(view ascii, 0, view empty) { give 12 }
    // "José ✓" in UTF-8.
    hold utf8: List of[Int] = List[74, 111, 115, 195, 169, 32, 226, 156, 147]
    hold jose = "José ✓"
    when !okText(view utf8, 9, view jose) { give 13 }
    // A count that cuts a scalar, a lone continuation byte, an overlong
    // form and a surrogate are not UTF-8.
    when errCode(view utf8, 4) != 4 { give 14 }
    hold lone: List of[Int] = List[128]
    when errCode(view lone, 1) != 4 { give 15 }
    hold overlong: List of[Int] = List[192, 175]
    when errCode(view overlong, 2) != 4 { give 16 }
    hold surrogate: List of[Int] = List[237, 160, 128]
    when errCode(view surrogate, 3) != 4 { give 17 }
    // Bytes outside 0..255 and counts outside 0..length are rejected.
    hold wide: List of[Int] = List[65, 256]
    when errCode(view wide, 2) != 1 { give 18 }
    hold negative: List of[Int] = List[65, -1]
    when errCode(view negative, 2) != 1 { give 19 }
    when errCode(view ascii, 5) != 1 || errCode(view ascii, -1) != 1 { give 20 }
    // Owned results are released: many conversions stay bounded.
    change n = 0
    change rounds = 0
    during rounds < 20000 {
        choose textFromBytes(utf8, 9) {
            Ok(t): { n += t.byteLength },
            Err(code): { give 21 },
        }
        rounds += 1
    }
    when n != 180000 { give 22 }
    // The Text works like any other: interpolation and path use.
    choose textFromBytes(ascii, 3) {
        Ok(name): {
            hold line = "name={name}"
            when line.byteLength != 8 { give 23 }
        },
        Err(code): { give 24 },
    }
    print("text-from-bytes-ok")
    give 0
}
