// writeBytes then readText of a file in the working directory, plus the
// error paths: a missing file and an invalid byte.
flow bytesOf(t: view Text) => List of[Int] {
    change out: List of[Int] = List[]
    each i among 0..t.byteLength {
        out@push(t@byteAt(i))
    }
    give out
}

flow main() => Int {
    hold path = "corpus_io_roundtrip.tmp"
    hold content = "linea uno\nlinea dos\n"
    hold bytes = bytesOf(view content)
    hold status = writeBytes(path, bytes)
    print("write {status}")
    choose readText(path, 1000) {
        Ok(text): {
            print("leidos {text.byteLength}")
            print(text)
        },
        Err(code): {
            print("error {code}")
            give 1
        },
    }
    hold missing = "corpus_io_missing.tmp"
    choose readText(missing, 1000) {
        Ok(text): {
            print("inesperado")
            give 2
        },
        Err(code): { print("missing {code}") },
    }
    change bad: List of[Int] = List[]
    bad@push(256)
    hold rejected = writeBytes(path, bad)
    print("rechazado {rejected}")
    choose readText(path, 5) {
        Ok(text): {
            print("inesperado")
            give 3
        },
        Err(code): { print("limite {code}") },
    }
    give 0
}
