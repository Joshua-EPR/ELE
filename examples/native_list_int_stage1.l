// List of[Int] y List of[Bool] en el backend ELE: literal, push con
// crecimiento del buffer, reserve, capacity, lectura y escritura por índice,
// each, paso por view/edit, retorno por valor y lista como campo de shape.
shape Serie {
    valores: List of[Int]
    marcas: List of[Bool]
    nombre: Int
}

flow suma(xs: view List of[Int]) => Int {
    change total = 0
    each x among xs {
        total += x
    }
    give total
}

flow llenar(xs: edit List of[Int], n: Int) {
    change i = 0
    during i < n {
        xs@push(i * 2)
        i += 1
    }
}

flow crear(n: Int) => List of[Int] {
    change xs: List of[Int] = List[]
    xs@reserve(4)
    llenar(edit xs, n)
    give xs
}

flow invertir(xs: edit List of[Int]) {
    change i = 0
    change j = xs.length - 1
    during i < j {
        hold a = xs[i]
        xs[i] = xs[j]
        xs[j] = a
        i += 1
        j -= 1
    }
}

flow contar(s: view Serie) => Int {
    change n = 0
    change i = 0
    during i < s.marcas.length {
        when s.marcas[i] {
            n += s.valores[i]
        }
        i += 1
    }
    give n
}

flow marcar(s: edit Serie, v: Int, m: Bool) {
    s.valores@push(v)
    s.marcas@push(m)
    s.nombre += 1
}

flow main() {
    change xs = crear(10)
    print(xs.length)
    print(suma(view xs))
    xs[3] = 100
    print(xs[3])
    invertir(edit xs)
    print(xs[0])
    print(xs[9])
    hold ys = List[1, 2, 3]
    print(ys[0] + ys[2])
    print(ys.capacity)
    change grande = crear(5000)
    print(grande.length)
    print(grande[4999])
    print(suma(view grande))
    print(grande.capacity >= 5000)
    change vacia: List of[Int] = List[]
    print(vacia.length)
    print(vacia.capacity)
    vacia@push(7)
    print(vacia.capacity)
    print(vacia[0])
    change v: List of[Int] = List[]
    change m: List of[Bool] = List[]
    change s = Serie(valores: v, marcas: m, nombre: 0)
    change k = 0
    during k < 40 {
        marcar(edit s, k, k % 3 == 0)
        k += 1
    }
    print(contar(view s))
    print(s.nombre)
    print(s.marcas[39])
    print(s.valores.length)
}
