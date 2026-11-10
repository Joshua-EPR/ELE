struct Pair { left: Int, flag: Bool, right: Int }
fn main() -> Int {
    let pair = Pair(left: 19, flag: true, right: 22)
    if pair.flag { return pair.left + pair.right + 1 }
    return 1
}
