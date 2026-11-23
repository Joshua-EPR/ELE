// Branch-heavy integer workload (ELE v2).
flow pasos(n: Int) => Int {
    change x = n
    change p = 0
    during x != 1 {
        when x % 2 == 0 {
            x = x / 2
        } otherwise {
            x = 3 * x + 1
        }
        p += 1
    }
    give p
}

flow main() {
    change mejor = 0
    change arg = 0
    each n among 1..1000000 {
        hold p = pasos(n)
        when p > mejor {
            mejor = p
            arg = n
        }
    }
    print(arg)
    print(mejor)
}
