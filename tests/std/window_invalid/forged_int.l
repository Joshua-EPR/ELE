// L0004: an Int is not a Window; window handles cannot be forged.
flow main() => Int {
    hold handle = 4096
    give windowPresent(handle)
}
