// Text grown by interpolation in a loop: the heap buffer is reallocated
// many times and the final length and edges are checked.
flow main() {
    change s = ""
    each i among 0..200 {
        s = "{s}{i % 10}"
    }
    print(s.byteLength)
    print(s@byteAt(0))
    print(s@byteAt(199))
    change csv = ""
    each i among 1..6 {
        when i > 1 {
            csv = "{csv},"
        }
        csv = "{csv}{i * i}"
    }
    print(csv)
}
