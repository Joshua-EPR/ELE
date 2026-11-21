// L0004: an Int is not a File; handles cannot be forged.
flow main() => Int {
    hold handle = 3
    give fileSize(handle)
}
