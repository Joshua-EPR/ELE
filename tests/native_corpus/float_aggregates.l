// Float as shape field, choice payload, list element, Option/Result payload
// and through choose branches.
shape Account {
    owner: Text
    balance: Float
}

choice Reading {
    Missing,
    Celsius(Float),
    Count(Int),
}

flow describe(r: Reading) => Float {
    choose r {
        Reading.Missing: { give -1.0 },
        Reading.Celsius(t): { give t * 1.8 + 32.0 },
        Reading.Count(n): { give Float(n) },
    }
    give 0.0
}

flow half(x: Float) => Option of[Float] {
    when x < 0.0 { give None }
    give Some(x / 2.0)
}

flow divide(a: Float, b: Float) => Result of[Float, Text] {
    when b == 0.0 { give Err("division por cero") }
    give Ok(a / b)
}

flow main() {
    change acct = Account(owner: "ana", balance: 100.5)
    acct.balance += 24.5
    acct.balance = acct.balance * 2.0
    print("{acct.owner}: {acct.balance}")
    print(describe(Reading.Missing))
    print(describe(Reading.Celsius(100.0)))
    print(describe(Reading.Count(3)))
    change xs: List of[Float] = List[1.5, 2.5]
    xs@push(0.25)
    change sum = 0.0
    each x among xs {
        sum += x
    }
    print(xs.length)
    print(xs[2])
    xs[0] = 9.75
    print(xs[0] + sum)
    choose half(9.0) {
        Some(v): { print(v) },
        None: { print("none") },
    }
    choose half(-1.0) {
        Some(v): { print(v) },
        None: { print("none") },
    }
    choose divide(10.0, 4.0) {
        Ok(v): { print(v) },
        Err(e): { print(e) },
    }
    choose divide(1.0, 0.0) {
        Ok(v): { print(v) },
        Err(e): { print(e) },
    }
    hold pick = choose acct.balance > 200.0 {
        true: 1.5,
        false: 2.5,
    }
    print(pick)
}
