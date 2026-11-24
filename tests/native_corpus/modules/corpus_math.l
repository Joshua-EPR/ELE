// Helper module of the native corpus (not a case: it has no .exit file).
expose shape Vec2 {
    x: Int
    y: Int
}

expose flow addNums(a: Int, b: Int) => Int {
    give a + b
}

expose flow mulNums(a: Int, b: Int) => Int {
    give a * b
}

expose flow vec(x: Int, y: Int) => Vec2 {
    give Vec2(x: x, y: y)
}

expose flow lengthSquared(v: view Vec2) => Int {
    give v.x * v.x + v.y * v.y
}
