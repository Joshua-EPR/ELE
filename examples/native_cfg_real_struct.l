shape Pair { left: Int, flag: Bool, right: Int }
flow main() => Int {
    hold pair = Pair(left: 19, flag: true, right: 22)
    when pair.flag { give pair.left + pair.right + 1 }
    give 1
}
