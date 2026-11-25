// The default must have the type of the field.
shape Punto {
    x: Int = "cero"
}

flow main() {
    hold p = Punto()
    print(p.x)
}
