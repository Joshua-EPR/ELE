// shape construction, field reads, field writes on a change binding.
shape Point {
    x: Int
    y: Int
}

flow main() {
    change p = Point(x: 3, y: 4)
    print(p.x * p.x + p.y * p.y)
    p.x = 10
    p.y += 1
    print("({p.x}, {p.y})")
    hold q = Point(y: 2, x: 1)
    print(q.x - q.y)
}
