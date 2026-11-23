// Insertion: 1 000 000 push into an empty List of[Int] (geometric growth).
flow main() {
    change datos: List of[Int] = List[]
    change i = 0
    during i < 1000000 {
        datos@push(i)
        i += 1
    }
    print(datos.length)
    print(datos.capacity)
}
