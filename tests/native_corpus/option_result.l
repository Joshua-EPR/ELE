// Option and Result as error paths: checked parsing of a digit string,
// safe division, and propagation by explicit choose.
flow digit(b: Int) => Option of[Int] {
    when b >= 48 && b <= 57 { give Some(b - 48) }
    give None
}

flow parse(t: view Text) => Result of[Int, Int] {
    when t.byteLength == 0 { give Err(0 - 1) }
    change value = 0
    each i among 0..t.byteLength {
        choose digit(t@byteAt(i)) {
            Some(d): { value = value * 10 + d },
            None: { give Err(i) },
        }
    }
    give Ok(value)
}

flow safeDiv(a: Int, b: Int) => Result of[Int, Text] {
    when b == 0 { give Err("division por cero") }
    give Ok(a / b)
}

flow report(t: Text) {
    choose parse(view t) {
        Ok(v): { print("ok {v}") },
        Err(at): { print("error en {at}") },
    }
}

flow main() => Int {
    report("1234")
    report("12x4")
    report("")
    choose safeDiv(10, 4) {
        Ok(v): { print("cociente {v}") },
        Err(e): { print(e) },
    }
    choose safeDiv(1, 0) {
        Ok(v): { print("cociente {v}") },
        Err(e): { print(e) },
    }
    hold missing: Option of[Int] = None
    choose missing {
        Some(v): { give v },
        None: { give 3 },
    }
    give 0
}
