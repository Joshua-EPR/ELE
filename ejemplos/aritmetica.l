module hola.main
import std.io.print

fn doble(x: Int) -> Int = x * 2

fn main() {
    let resultado = doble(21)
    print(resultado)
}
