// Reading a field that the shape does not declare.
shape Point {
    x: Int
    y: Int
}

flow main() => Int {
    hold p = Point(x: 1, y: 2)
    give p.z
}
