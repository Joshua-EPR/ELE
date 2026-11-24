// Nested shapes, field paths of depth two, Text fields and by-value copies
// returned from flows.
shape Point {
    x: Int
    y: Int
}

shape Rect {
    min: Point
    max: Point
    label: Text
}

flow area(r: view Rect) => Int {
    give (r.max.x - r.min.x) * (r.max.y - r.min.y)
}

flow grow(r: Rect, d: Int) => Rect {
    give Rect(min: Point(x: r.min.x - d, y: r.min.y - d), max: Point(x: r.max.x + d, y: r.max.y + d), label: r.label)
}

flow main() {
    change r = Rect(min: Point(x: 0, y: 0), max: Point(x: 4, y: 3), label: "caja")
    print(area(view r))
    r.max.x = 10
    print(area(view r))
    hold g = grow(r, 1)
    print(area(view g))
    print("{g.label} {g.min.x} {g.min.y} {g.max.x} {g.max.y}")
}
