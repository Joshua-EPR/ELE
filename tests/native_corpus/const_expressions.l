// fixed constants folded at compile time: references in any order, checked
// Int arithmetic, comparisons, short-circuit logic, Text and Unit values and
// local fixed bindings.
fixed ANSWER: Int = BASE * 2
fixed BASE = 21
fixed NEG = -5
fixed MIX = BASE * 6 - 2 / 2 + BASE % 4 - NEG
fixed FLAG: Bool = ANSWER == 42 && !(MIX <= 0) || false
fixed LAZY_AND = false && 1 / 0 == 1
fixed LAZY_OR = true || 1 % 0 == 1
fixed EDGE = -9223372036854775807 - 1
fixed GREETING = "hola"
fixed ALIAS: Text = GREETING
fixed SAME = () == ()

flow main() => Int {
    fixed next = ANSWER + 1
    print(ANSWER)
    print(next)
    print(MIX)
    print(FLAG)
    print(LAZY_AND)
    print(LAZY_OR)
    print(EDGE)
    print(ALIAS)
    print(SAME)
    change total = next
    total = total + NEG
    when total > 0 {
        fixed inner = next * 10
        print(inner)
    }
    print(total)
    give MIX % 7
}
