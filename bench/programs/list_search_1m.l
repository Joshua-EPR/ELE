// Linear search: 20 lookups of values near the end of 1 000 000 elements (ELE v2).
flow buscar(datos: view List of[Int], objetivo: Int) => Int {
    change i = 0
    during i < datos.length {
        when datos[i] == objetivo {
            give i
        }
        i += 1
    }
    give -1
}

flow main() {
    change datos: List of[Int] = List[]
    change i = 0
    during i < 1000000 {
        datos@push(i * 3)
        i += 1
    }
    change encontrados = 0
    change k = 0
    during k < 20 {
        when buscar(view datos, (999980 + k) * 3) >= 0 {
            encontrados += 1
        }
        k += 1
    }
    print(encontrados)
}
