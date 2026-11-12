// Drop-free aggregate payloads in Option/Result through checked ELE-LIR enums.
// Stage 1 -> ELE-LIR -> ELE-written native backend -> ELF64. Expected stdout:
// 42, 205, 8, 156, 3 (one per line) and process exit 158, as with Stage 0.
choice Kind {
    Small,
    Large,
}

shape Problem {
    kind: Kind,
    offset: Int,
    fatal: Bool,
}

shape Point {
    x: Int,
    y: Int,
}

flow kindCode(kind: Kind) => Int {
    choose kind {
        Kind.Small: { give 1 },
        Kind.Large: { give 2 },
    }
}

flow parse(n: Int) => Result of[Int, Problem] {
    when n < 0 {
        give Err(Problem(kind: Kind.Large, offset: 0 - n, fatal: true))
    }
    when n == 0 {
        give Err(Problem(kind: Kind.Small, offset: 7, fatal: false))
    }
    give Ok(n * 2)
}

flow find(n: Int) => Option of[Point] {
    when n > 10 { give Some(Point(x: n, y: n + 1)) }
    give None
}

flow score(r: Result of[Int, Problem]) => Int {
    choose r {
        Ok(value): { give value },
        Err(problem): {
            hold fatal = problem.fatal
            hold offset = problem.offset
            hold code = kindOf(problem)
            when fatal { give 100 * code + offset }
            give offset + code
        },
    }
}

flow area(o: Option of[Point]) => Int {
    choose o {
        Some(point): { give point.x * point.y },
        None: { give 3 },
    }
}

flow main() => Int {
    hold a = score(parse(21))
    hold b = score(parse(0 - 5))
    hold c = score(parse(0))
    hold d = area(find(12))
    hold e = area(find(2))
    print(a)
    print(b)
    print(c)
    print(d)
    print(e)
    give (a + b + c + d + e) % 256
}

flow kindOf(problem: Problem) => Int {
    hold kind = problem.kind
    give kindCode(kind)
}
