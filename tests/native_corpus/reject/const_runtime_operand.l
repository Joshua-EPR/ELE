// A local fixed cannot read a runtime binding.
flow main() {
    change valor = 21
    fixed resultado = valor * 2
}
