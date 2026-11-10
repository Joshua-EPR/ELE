enum Color { Rojo, Verde, Azul }
fn main() {
    let c = Color.Rojo
    match c {
        Color.Rojo => print("rojo"),
        Color.Verde => print("verde"),
        Color.Azul => print("azul"),
    }
}
