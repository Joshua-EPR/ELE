// Many lines of output: every byte must reach stdout in order.
flow main() {
    change checksum = 0
    each i among 0..3000 {
        print("linea {i} de 3000")
        checksum = (checksum * 31 + i) % 1000003
    }
    print(checksum)
}
