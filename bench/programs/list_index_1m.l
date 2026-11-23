// Indexed (bounds-checked) reads: build 1 000 000 elements, 20 passes of datos[i] (ELE v2).
flow main() {
    change datos: List of[Int] = List[]
    datos@reserve(1000000)
    change i = 0
    during i < 1000000 {
        datos@push(i % 1000)
        i += 1
    }
    change total = 0
    change pasada = 0
    during pasada < 20 {
        change j = 0
        during j < datos.length {
            total += datos[j]
            j += 1
        }
        pasada += 1
    }
    print(total)
}
