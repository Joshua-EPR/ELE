//! Native collections: fixed arrays `[T; N]`, slice views `&[T]`/`&mut [T]`
//! and `List<T>`.
//!
//! Positive programs are built with the rustc backend (reference) and with the
//! Cranelift backend instrumented with `--trace-alloc`; stdout, stderr and exit
//! status must match, every heap block must be freed exactly once and the heap
//! must validate at exit. `allocs == frees` is evidence for the paths these
//! programs exercise, not a proof of absence of leaks in general.
use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/collections")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(dir: &Path, file: &str, extra: &[&str]) -> PathBuf {
    let mut args = vec!["build", file];
    args.extend_from_slice(extra);
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(&args)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{file} {extra:?}: {stdout}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    dir.join(
        stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    )
}

fn run(exe: &Path) -> (String, String, Option<i32>) {
    let out = Command::new(exe).output().unwrap();
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code(),
    )
}

#[derive(Debug, PartialEq)]
struct Stats {
    allocs: u64,
    reallocs: u64,
    frees: u64,
}

fn stats(stderr: &str) -> Stats {
    let line = stderr
        .lines()
        .find(|l| l.starts_with("l-alloc: "))
        .unwrap_or_else(|| panic!("sin informe de memoria: {stderr}"));
    let field = |name: &str| -> u64 {
        line.split_whitespace()
            .find_map(|w| w.strip_prefix(&format!("{name}=")))
            .unwrap()
            .parse()
            .unwrap()
    };
    assert_eq!(field("heap_ok"), 1, "heap corrupto: {line}");
    Stats {
        allocs: field("allocs"),
        reallocs: field("reallocs"),
        frees: field("frees"),
    }
}

/// Differential + instrumented run of a program expected to exit normally.
fn check_program(name: &str, source: &str, expected: &str) -> Stats {
    let dir = work(name);
    let file = format!("{name}.l");
    fs::write(dir.join(&file), source).unwrap();
    let reference = run(&build(&dir, &file, &[]));
    let native = run(&build(
        &dir,
        &file,
        &["--backend", "cranelift", "--trace-alloc"],
    ));
    assert_eq!(reference.2, Some(0), "{name} rustc: {}", reference.1);
    assert_eq!(native.2, Some(0), "{name} cranelift: {}", native.1);
    assert_eq!(reference.0, expected, "{name}: salida rustc");
    assert_eq!(native.0, expected, "{name}: salida cranelift");
    let s = stats(&native.1);
    assert_eq!(s.allocs, s.frees, "{name}: bloques sin liberar: {s:?}");
    s
}

/// Differential run of a program expected to panic: same stdout, same stderr,
/// same abnormal status in both backends.
fn check_panic(name: &str, source: &str, expected_stdout: &str, message: &str) {
    let dir = work(name);
    let file = format!("{name}.l");
    fs::write(dir.join(&file), source).unwrap();
    let reference = run(&build(&dir, &file, &[]));
    let native = run(&build(&dir, &file, &["--backend", "cranelift"]));
    assert_eq!(reference, native, "{name}: rustc y cranelift difieren");
    assert_eq!(native.0, expected_stdout, "{name}");
    assert!(native.1.contains(message), "{name}: {}", native.1);
    assert_eq!(native.2, Some(project_l::native::PANIC_EXIT_CODE as i32));
}

/// A program rejected at compile time with `code` and a message containing `cause`.
fn rejects(source: &str, code: &str, cause: &str) {
    let e = check(source).expect_err(source);
    assert_eq!(e.code, code, "{source}: {e:?}");
    assert!(e.message.contains(cause), "{source}: {e:?}");
    assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
}

// ------------------------------------------------------------------ arrays --

#[test]
fn arrays_literals_indexing_and_iteration() {
    let s = check_program(
        "arrays",
        r#"fn main() {
    let numeros = [10, 20, 30, 40]
    print(numeros.length)
    print(numeros[2])
    var i = 0
    var suma = 0
    while i < numeros.length {
        suma += numeros[i]
        i += 1
    }
    print(suma)
    var copia = [10, 20, 30, 40]
    copia[0] = 99
    print(copia[0])
    print(numeros[0])
    let vacio: [Int; 0] = []
    print(vacio.length)
    let reales = [1.5, 2.25]
    print(reales[1])
    let banderas = [true, false, true]
    for b in banderas {
        print(b)
    }
    let matriz = [[1, 2, 3], [4, 5, 6]]
    var total = 0
    for fila in matriz {
        for x in fila {
            total += x
        }
    }
    print(total)
    print(matriz[1][2])
}
"#,
        "4\n30\n100\n99\n10\n0\n2.25\ntrue\nfalse\ntrue\n21\n6\n",
    );
    assert_eq!(s.allocs, 0, "un array fijo no reserva heap: {s:?}");
}

#[test]
fn arrays_of_text_structs_and_enums_drop_their_elements() {
    let s = check_program(
        "arrays_owned",
        r#"struct Persona {
    nombre: Text
    edad: Int
}
enum Forma {
    Punto
    Circulo(Int)
    Etiqueta(Text)
}
fn describir(f: Forma) -> Int {
    match f {
        Forma.Punto => return 0,
        Forma.Circulo(r) => return r,
        Forma.Etiqueta(t) => {
            print(t)
            return -1
        }
    }
}
fn main() {
    let n = 7
    var nombres = ["Ana", "Luis {n}", "Eva {n + 1}"]
    print(nombres[1])
    nombres[2] = "Sol {n * 2}"
    for nombre in nombres {
        print(nombre)
    }
    let personas = [Persona(nombre: "Ana {n}", edad: 30), Persona(nombre: "Bo", edad: 41)]
    var edades = 0
    for p in personas {
        edades += p.edad
        print(p.nombre)
    }
    print(edades)
    let formas = [Forma.Circulo(3), Forma.Etiqueta("e{n}"), Forma.Punto]
    var total = 0
    for f in formas {
        match f {
            Forma.Circulo(r) => {
                total += r
            }
            _ => {}
        }
    }
    print(total)
    print(describir(Forma.Etiqueta("fin {n}")))
}
"#,
        "Luis 7\nAna\nLuis 7\nSol 14\nAna 7\nBo\n71\n3\nfin 7\n-1\n",
    );
    assert!(s.allocs >= 5, "{s:?}");
}

#[test]
fn arrays_as_parameters_and_results() {
    check_program(
        "arrays_params",
        r#"fn invertir(a: [Int; 3]) -> [Int; 3] {
    return [a[2], a[1], a[0]]
}
fn etiquetas(n: Int) -> [Text; 2] {
    return ["a{n}", "b{n}"]
}
fn main() {
    let a = invertir([1, 2, 3])
    print(a[0])
    print(a[2])
    let e = etiquetas(5)
    print(e[1])
    var i = 0
    let indices = [2, 0, 1]
    for k in indices {
        i = i * 10 + a[k]
    }
    print(i)
}
"#,
        "3\n1\nb5\n132\n",
    );
}

// ------------------------------------------------------------------ slices --

#[test]
fn slices_view_arrays_and_lists() {
    let s = check_program(
        "slices",
        r#"fn sumar(datos: &[Int]) -> Int {
    var total = 0
    for numero in datos {
        total += numero
    }
    return total
}
fn mayor(datos: &[Int]) -> Int {
    var m = datos[0]
    var i = 1
    while i < datos.length {
        if datos[i] > m {
            m = datos[i]
        }
        i += 1
    }
    return m
}
fn duplicar(datos: &mut [Int]) {
    var i = 0
    while i < datos.length {
        datos[i] = datos[i] * 2
        i += 1
    }
}
fn reenviar(datos: &[Int]) -> Int {
    return sumar(datos) + mayor(datos)
}
fn largos(textos: &[Text]) -> Int {
    var n = 0
    for t in textos {
        print(t)
        n += 1
    }
    return n
}
fn main() {
    let numeros = [10, 20, 30]
    print(sumar(numeros))
    var lista = List[5, 9, 2]
    print(sumar(lista))
    print(mayor(lista))
    duplicar(&mut lista)
    print(lista[1])
    var arr = [1, 2, 3, 4]
    duplicar(&mut arr)
    print(reenviar(arr))
    let k = 3
    let textos = List["x{k}", "y"]
    print(largos(textos))
    print(textos.length)
}
"#,
        "60\n16\n9\n18\n28\nx3\ny\n2\n2\n",
    );
    assert_eq!(s.allocs, 3, "{s:?}");
}

// ------------------------------------------------------------------- lists --

#[test]
fn list_push_pop_capacity_and_reserve() {
    let s = check_program(
        "list_basic",
        r#"fn main() {
    var numeros = List[10, 20, 30]
    numeros.push(40)
    numeros.push(50)
    print(numeros.length)
    print(numeros[4])
    var vacia: List<Int> = List[]
    print(vacia.length)
    print(vacia.capacity)
    var i = 0
    while i < 9 {
        vacia.push(i)
        print(vacia.capacity)
        i += 1
    }
    match vacia.pop() {
        Some(x) => print(x),
        None => print(-1)
    }
    print(vacia.length)
    var otra: List<Int> = List[]
    match otra.pop() {
        Some(x) => print(x),
        None => print(-1)
    }
    otra.reserve(10)
    print(otra.capacity)
    otra.reserve(5)
    print(otra.capacity)
    otra.push(1)
    print(otra.capacity)
    numeros[0] = 7
    var suma = 0
    for x in numeros {
        suma += x
    }
    print(suma)
}
"#,
        "5\n50\n0\n0\n4\n4\n4\n4\n8\n8\n8\n8\n16\n8\n8\n-1\n10\n10\n10\n147\n",
    );
    // numeros: literal + 1 growth; vacia: 1 alloc + 2 growths; otra: 1 alloc.
    assert_eq!(s.allocs, 3, "{s:?}");
    assert_eq!(s.reallocs, 3, "{s:?}");
}

#[test]
fn list_of_text_replaces_pops_and_releases_elements() {
    let s = check_program(
        "list_text",
        r#"fn main() {
    var nombres: List<Text> = List[]
    var i = 0
    while i < 6 {
        nombres.push("nombre {i}")
        i += 1
    }
    nombres[1] = "reemplazo {i}"
    print(nombres[1])
    match nombres.pop() {
        Some(t) => print(t),
        None => {}
    }
    var largo = 0
    for n in nombres {
        largo += 1
    }
    print(largo)
    print(nombres[0])
}
"#,
        "reemplazo 6\nnombre 5\n5\nnombre 0\n",
    );
    // 6 texts + 1 replacement + list buffer.
    assert_eq!(s.allocs, 8, "{s:?}");
}

#[test]
fn list_of_structs_moves_and_functions() {
    check_program(
        "list_structs",
        r#"struct Persona {
    nombre: Text
    edad: Int
}
fn crear(n: Int) -> List<Persona> {
    var gente: List<Persona> = List[]
    var i = 0
    while i < n {
        gente.push(Persona(nombre: "p{i}", edad: 20 + i))
        i += 1
    }
    return gente
}
fn edades(gente: &[Persona]) -> Int {
    var total = 0
    for p in gente {
        total += p.edad
    }
    return total
}
fn consumir(gente: List<Persona>) -> Int {
    return gente.length
}
fn main() {
    let gente = crear(5)
    print(edades(gente))
    print(gente[3].nombre)
    print(gente[3].edad)
    let otros = gente
    print(otros.length)
    print(consumir(otros))
    var lote = crear(3)
    lote[0] = Persona(nombre: "nuevo", edad: 1)
    print(lote[0].nombre)
    print(edades(lote))
}
"#,
        "110\np3\n23\n5\n5\nnuevo\n44\n",
    );
}

#[test]
fn nested_lists_and_lists_in_structs() {
    check_program(
        "list_nested",
        r#"struct Bolsa {
    nombre: Text
    items: List<Int>
}
fn main() {
    var filas: List<List<Int>> = List[]
    var i = 0
    while i < 3 {
        filas.push(List[i, i * 10])
        i += 1
    }
    filas[1].push(99)
    print(filas[1].length)
    print(filas[1][2])
    var total = 0
    for fila in filas {
        for x in fila {
            total += x
        }
    }
    print(total)
    var b = Bolsa(nombre: "b", items: List[1, 2])
    b.items.push(3)
    print(b.items.length)
    print(b.items[2])
    let palabras = [List["a", "b"], List["c"]]
    print(palabras[0][1])
    print(palabras[1].length)
}
"#,
        "3\n99\n132\n3\n3\nb\n1\n",
    );
}

#[test]
fn early_exits_release_collections() {
    let s = check_program(
        "list_exits",
        r#"fn buscar(objetivo: Int) -> Int {
    var datos: List<Text> = List[]
    var i = 0
    while i < 20 {
        datos.push("v{i}")
        if i == objetivo {
            return i
        }
        i += 1
    }
    return -1
}
fn main() {
    print(buscar(3))
    print(buscar(50))
    var lista = List["a{1}", "b{2}", "c{3}"]
    var visto = 0
    for t in lista {
        visto += 1
        if visto == 1 {
            continue
        }
        print(t)
        break
    }
    var j = 0
    while true {
        let tmp = List[j, j]
        j += 1
        if j > 3 {
            break
        }
    }
    print(j)
}
"#,
        "3\n-1\nb2\n4\n",
    );
    assert!(s.reallocs > 0, "{s:?}");
}

#[test]
fn many_pushes_grow_geometrically() {
    let s = check_program(
        "list_growth",
        r#"fn main() {
    var datos: List<Int> = List[]
    var i = 0
    while i < 100000 {
        datos.push(i)
        i += 1
    }
    var suma = 0
    for x in datos {
        suma += x
    }
    print(suma)
    print(datos.length)
    print(datos.capacity)
    print(datos[99999])
}
"#,
        "4999950000\n100000\n131072\n99999\n",
    );
    assert_eq!(s.allocs, 1, "{s:?}");
    // 4 → 8 → … → 131072: 15 growths after the first allocation.
    assert_eq!(s.reallocs, 15, "{s:?}");
}

// ----------------------------------------------------------------- panics --

#[test]
fn dynamic_out_of_range_indices_panic() {
    check_panic(
        "oob_array",
        "fn main() {\n    let a = [1, 2, 3]\n    var i = 2\n    print(a[i])\n    i += 1\n    print(a[i])\n}\n",
        "3\n",
        "ELE 6:12: índice fuera de rango",
    );
    check_panic(
        "oob_negative",
        "fn main() {\n    var l = List[1, 2]\n    let i = 0 - 1\n    l[i] = 5\n}\n",
        "",
        "ELE 4:6: índice fuera de rango",
    );
    check_panic(
        "oob_slice",
        "fn f(d: &[Int], i: Int) -> Int {\n    return d[i]\n}\nfn main() {\n    let l = List[1, 2]\n    print(f(l, 1))\n    print(f(l, 2))\n}\n",
        "2\n",
        "ELE 2:13: índice fuera de rango",
    );
    check_panic(
        "oob_after_pop",
        "fn main() {\n    var l = List[\"a{1}\"]\n    match l.pop() {\n        Some(t) => print(t),\n        None => {}\n    }\n    print(l[0])\n}\n",
        "a1\n",
        "ELE 7:12: índice fuera de rango",
    );
}

#[test]
fn negative_and_overflowing_reserve_panic() {
    check_panic(
        "reserve_negative",
        "fn main() {\n    var l: List<Int> = List[]\n    let n = 0 - 5\n    l.reserve(n)\n}\n",
        "",
        "reserve con tamaño negativo",
    );
    check_panic(
        "reserve_overflow",
        "fn main() {\n    var l = List[1]\n    l.reserve(9223372036854775807)\n}\n",
        "",
        "capacidad de List desbordada",
    );
}

// --------------------------------------------------------------- rejected --

#[test]
fn constant_out_of_range_indices_are_compile_errors() {
    rejects(
        "fn main() {\n    let a = [1, 2, 3]\n    print(a[3])\n}",
        "L0001",
        "fuera de rango",
    );
    rejects(
        "fn main() {\n    var a = [1, 2, 3]\n    a[-1] = 0\n}",
        "L0001",
        "índice constante negativo",
    );
}

#[test]
fn type_errors_are_rejected() {
    rejects("fn main() {\n    let a = [1, true]\n}", "L0001", "");
    rejects("fn main() {\n    let l = List[1, \"a\"]\n}", "L0001", "");
    rejects("fn main() {\n    let a = []\n}", "L0001", "");
    rejects(
        "fn main() {\n    var l = List[1]\n    l.push(\"x\")\n}",
        "L0001",
        "",
    );
    rejects(
        "fn f(d: &[Int]) -> Int = d.length\nfn main() {\n    let l = List[\"a\"]\n    print(f(l))\n}",
        "L0001",
        "",
    );
    rejects(
        "fn main() {\n    let a = [1, 2]\n    let b = a + a\n}",
        "L0001",
        "",
    );
}

#[test]
fn ownership_errors_are_rejected() {
    // Arrays are moved like lists (no implicit copies of collections).
    rejects(
        "fn main() {\n    let a = [1, 2]\n    let b = a\n    print(a.length)\n}",
        "L0005",
        "",
    );
    // Use after move of a whole list.
    rejects(
        "fn main() {\n    let nombres = List[\"Ana\", \"Luis\"]\n    let otros = nombres\n    print(nombres.length)\n}",
        "L0005",
        "",
    );
    // No partial moves out of a collection.
    rejects(
        "fn main() {\n    let t = List[\"a\"]\n    let x = t[0]\n}",
        "L0005",
        "mover un elemento",
    );
    // No mutation while iterating.
    rejects(
        "fn main() {\n    var l = List[1, 2]\n    for x in l {\n        l.push(x)\n    }\n}",
        "L0005",
        "prestada",
    );
    rejects(
        "fn main() {\n    var l = List[1, 2]\n    for x in l {\n        l[0] = x\n    }\n}",
        "L0005",
        "prestada",
    );
    // Immutable bindings cannot be modified.
    rejects(
        "fn main() {\n    let l = List[1]\n    l.push(2)\n}",
        "L0001",
        "",
    );
    rejects("fn main() {\n    let a = [1]\n    a[0] = 2\n}", "L0001", "");
    rejects(
        "fn f(d: &[Int]) {\n    d[0] = 1\n}\nfn main() {}",
        "L0001",
        "",
    );
    // Moving a list into a loop body more than once.
    rejects(
        "fn consumir(l: List<Int>) {}\nfn main() {\n    let l = List[1]\n    for i in 0..2 {\n        consumir(l)\n    }\n}",
        "L0005",
        "",
    );
}

#[test]
fn allocation_effects_are_checked() {
    rejects(
        "@noalloc fn crearLista() {\n    let numeros = List[1, 2, 3]\n}\nfn main() {}",
        "L0010",
        "",
    );
    rejects(
        "@noalloc fn f(l: &mut List<Int>) {\n    l.push(1)\n}\nfn main() {}",
        "L0010",
        "",
    );
    // Fixed arrays live in place: no allocation.
    check("@noalloc fn f() -> Int {\n    let a = [1, 2, 3]\n    var s = 0\n    for x in a {\n        s += x\n    }\n    return s\n}\nfn main() {}").unwrap();
}

#[test]
fn growth_failure_is_out_of_memory_not_corruption() {
    // The 3rd heap request (growth from 4 to 8) fails: the program has printed
    // what came before and stops with the out-of-memory panic.
    let dir = work("oom");
    let source = "fn main() {\n    var l = List[1]\n    print(l.capacity)\n    l.push(2)\n    print(l.capacity)\n    var i = 0\n    while i < 10 {\n        l.push(i)\n        i += 1\n    }\n    print(l.length)\n}\n";
    fs::write(dir.join("oom.l"), source).unwrap();
    let exe = build(
        &dir,
        "oom.l",
        &["--backend", "cranelift", "--alloc-fail-after", "2"],
    );
    let (stdout, stderr, code) = run(&exe);
    assert_eq!(stdout, "1\n4\n");
    assert_eq!(stderr, "ELE: memoria insuficiente\n");
    assert_eq!(code, Some(project_l::native::PANIC_EXIT_CODE as i32));
    let exe = build(
        &dir,
        "oom.l",
        &["--backend", "cranelift", "--alloc-fail-after", "4"],
    );
    // Literal, then growth to 4, 8 and 16: four heap requests in all.
    assert_eq!(run(&exe).0, "1\n4\n12\n");
}

#[test]
fn elements_in_interpolation_and_lists_of_enums() {
    check_program(
        "list_enums",
        r#"enum Tarea {
    Hecha(Text)
    Pendiente(Int)
}
fn main() {
    var tareas: List<Tarea> = List[]
    tareas.push(Tarea.Hecha("lavar {1}"))
    tareas.push(Tarea.Pendiente(3))
    tareas.push(Tarea.Hecha("barrer"))
    let numeros = [4, 5, 6]
    print("n={numeros[1]} t={tareas.length}")
    var pendientes = 0
    for t in tareas {
        match t {
            Tarea.Hecha(nombre) => print(nombre),
            Tarea.Pendiente(n) => {
                pendientes += n
            }
        }
    }
    print(pendientes)
    match tareas.pop() {
        Some(t) => {
            match t {
                Tarea.Hecha(nombre) => print("ultima {nombre}"),
                Tarea.Pendiente(_) => print(0)
            }
        }
        None => print(-1)
    }
    tareas[0] = Tarea.Pendiente(9)
    print(tareas.length)
}
"#,
        "n=5 t=3\nlavar 1\nbarrer\n3\nultima barrer\n2\n",
    );
    check_panic(
        "oob_interpolation",
        "fn main() {\n    let l = List[1, 2]\n    var i = 1\n    print(\"a {l[i]}\")\n    i += 1\n    print(\"b {l[i]}\")\n}\n",
        "a 2\n",
        "índice fuera de rango",
    );
}
