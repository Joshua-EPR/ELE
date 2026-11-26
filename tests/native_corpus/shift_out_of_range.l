// A shift count outside 0..63 is the arithmetic failure (status 125),
// like overflow; the CPU would silently use only its low 6 bits.
flow shiftLeft(a: Int, n: Int) => Int {
    give a << n
}

flow main() => Int {
    print(shiftLeft(1, 63))
    print("antes")
    hold boom = shiftLeft(1, 64)
    print("no debe imprimirse")
    print(boom)
    give 0
}
