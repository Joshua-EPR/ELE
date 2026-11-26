// `1.` is not a Float literal (a fraction needs a digit after the dot): it
// is the Int 1 followed by a field access (`1.abc`).
flow main() {
    hold x = 1.abc
    print(x)
}
