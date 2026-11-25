// A field without default must still be given in the constructor.
shape Punto {
    x: Int
    y: Int = 1
}

flow main() {
    hold p = Punto()
    print(p.y)
}
