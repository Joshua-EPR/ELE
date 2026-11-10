//! Memory regions: `region nombre { ... }`, region buffers (`nombre.bytes(n)`),
//! escape rejection and deterministic release.
//!
//! Positive programs are built with the rustc backend (reference) and with the
//! Cranelift backend instrumented with `--trace-alloc`; stdout, stderr and exit
//! status must match, every heap block must be freed exactly once, the heap
//! must validate, and every region allocation must be 8-aligned (checked by the
//! instrumented runtime). `allocs == frees` is evidence for the paths these
//! programs exercise, not a proof of absence of leaks in general.
use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/regions")
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
    /// Real heap blocks (Text buffers and region blocks).
    allocs: u64,
    frees: u64,
    /// Logical region allocations (`.bytes(n)` calls) and bytes requested.
    region_allocs: u64,
    region_bytes: u64,
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
        frees: field("frees"),
        region_allocs: field("region_allocs"),
        region_bytes: field("region_bytes"),
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

/// Differential run of a program expected to panic: same stdout, same stderr
/// message, same abnormal status in both backends.
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

#[test]
fn canonical_example_and_buffer_parameters() {
    let s = check_program(
        "canonical",
        r#"fn procesarBuffer(buffer: &Bytes) {
    print(buffer.len())
    print(buffer.get(0))
}
fn llenar(buffer: &mut Bytes, v: Int) {
    var i = 0
    while i < buffer.len() {
        buffer.set(i, (v + i) % 256)
        i += 1
    }
}
fn main() {
    region temporal {
        var buffer = temporal.bytes(1024)
        procesarBuffer(buffer)
        llenar(&mut buffer, 250)
        print(buffer.get(10))
        print(buffer.get(1023))
    }
}
"#,
        "1024\n0\n4\n249\n",
    );
    assert_eq!(
        s,
        Stats {
            allocs: 1,
            frees: 1,
            region_allocs: 1,
            region_bytes: 1024
        }
    );
}

#[test]
fn empty_region_allocates_nothing() {
    let s = check_program(
        "empty",
        "fn main() {\n    region vacia {\n    }\n    region otra {\n        print(1)\n    }\n}\n",
        "1\n",
    );
    assert_eq!(s.allocs, 0);
    assert_eq!(s.region_allocs, 0);
}

#[test]
fn many_small_allocations_share_one_block() {
    // 100 buffers of 1..=100 bytes (5050 bytes + alignment padding) need 2
    // blocks: the first holds 4096 bytes, the second is twice as large.
    let s = check_program(
        "bump",
        r#"fn main() {
    region r {
        var suma = 0
        for i in 1..=100 {
            var b = r.bytes(i)
            b.set(i - 1, i)
            suma += b.get(i - 1) + b.get(0)
        }
        print(suma)
    }
}
"#,
        "5051\n",
    );
    assert_eq!(s.region_allocs, 100);
    assert_eq!(s.region_bytes, 5050);
    assert_eq!(s.allocs, 2, "{s:?}");
}

#[test]
fn growth_with_large_and_odd_sizes() {
    // Odd sizes exercise alignment (verified by the instrumented runtime);
    // a buffer larger than the current block gets a block of its own size.
    let s = check_program(
        "growth",
        r#"fn main() {
    region r {
        var a = r.bytes(3)
        var b = r.bytes(7)
        var c = r.bytes(100000)
        var d = r.bytes(1)
        a.set(2, 1)
        b.set(6, 2)
        c.set(99999, 3)
        d.set(0, 4)
        print(a.get(2) + b.get(6) + c.get(99999) + d.get(0))
        print(a.get(0) + b.get(0) + c.get(50000))
        print(c.len())
    }
}
"#,
        "10\n0\n100000\n",
    );
    assert_eq!(s.region_allocs, 4);
    assert_eq!(s.region_bytes, 100011);
    assert!(s.allocs >= 2, "{s:?}");
}

#[test]
fn nested_regions_release_inner_first() {
    let s = check_program(
        "nested",
        r#"fn main() {
    region externa {
        var a = externa.bytes(16)
        a.set(0, 7)
        region interna {
            var b = interna.bytes(16)
            b.set(0, a.get(0) * 2)
            a.set(1, b.get(0))
            region otra {
                let c = otra.bytes(0)
                print(c.len())
            }
        }
        print(a.get(1))
    }
}
"#,
        "0\n14\n",
    );
    assert_eq!(s.region_allocs, 3);
    assert_eq!(s.allocs, 3);
}

#[test]
fn early_return_break_and_continue_release_regions() {
    let s = check_program(
        "control",
        r#"fn primero(n: Int) -> Int {
    region r {
        var b = r.bytes(8)
        b.set(0, n)
        if n > 3 {
            return b.get(0) * 10
        }
        return b.get(0)
    }
}
fn main() {
    print(primero(2))
    print(primero(5))
    var total = 0
    for i in 0..10 {
        region iter {
            var b = iter.bytes(4)
            b.set(0, i)
            if i == 3 {
                continue
            }
            if i == 6 {
                break
            }
            total += b.get(0)
        }
    }
    print(total)
}
"#,
        "2\n50\n12\n",
    );
    // Two calls + seven loop iterations, each region freed on its own path.
    assert_eq!(s.region_allocs, 9);
    assert_eq!(s.allocs, 9);
}

#[test]
fn regions_with_text_structs_enums_and_result() {
    let s = check_program(
        "mixed",
        r#"struct Medida {
    nombre: Text
    valor: Int
}
fn leer(b: &Bytes, i: Int) -> Result<Int, Text> {
    if i >= b.len() {
        return Err("fuera: {i}")
    }
    return Ok(b.get(i))
}
fn suma(b: &Bytes) -> Result<Int, Text> {
    let x = leer(b, 0)?
    let y = leer(b, 1)?
    return Ok(x + y)
}
fn main() {
    region r {
        var b = r.bytes(2)
        b.set(0, 40)
        b.set(1, 2)
        let m = Medida(nombre: "total {b.len()}", valor: 0)
        match suma(b) {
            Ok(v) => print("{m.nombre}: {v}"),
            Err(e) => print(e),
        }
        let estado: Option<Int> = Some(b.get(0))
        print(estado ?? 0)
        match leer(b, 9) {
            Ok(v) => print(v),
            Err(e) => print(e),
        }
    }
}
"#,
        "total 2: 42\n40\nfuera: 9\n",
    );
    assert_eq!(s.region_allocs, 1);
}

#[test]
fn runtime_errors_are_located_panics() {
    check_panic(
        "oob",
        "fn main() {\n    region r {\n        let b = r.bytes(4)\n        print(b.get(3))\n        print(b.get(4))\n    }\n}\n",
        "0\n",
        "ELE 5:16: índice de buffer fuera de rango",
    );
    check_panic(
        "negative_index",
        "fn main() {\n    region r {\n        var b = r.bytes(4)\n        b.set(-1, 0)\n    }\n}\n",
        "",
        "índice de buffer fuera de rango",
    );
    check_panic(
        "byte_range",
        "fn main() {\n    region r {\n        var b = r.bytes(4)\n        b.set(0, 255)\n        print(b.get(0))\n        b.set(0, 256)\n    }\n}\n",
        "255\n",
        "valor de byte fuera de rango (0..=255)",
    );
    check_panic(
        "negative_size",
        "fn main() {\n    let n = -1\n    region r {\n        let b = r.bytes(n)\n    }\n}\n",
        "",
        "tamaño de buffer negativo",
    );
}

#[test]
fn allocation_failure_in_a_region_is_a_clean_panic() {
    let dir = work("oom");
    fs::write(
        dir.join("oom.l"),
        "fn main() {\n    print(1)\n    region r {\n        let b = r.bytes(10)\n        print(b.len())\n    }\n}\n",
    )
    .unwrap();
    let exe = build(
        &dir,
        "oom.l",
        &["--backend", "cranelift", "--alloc-fail-after", "0"],
    );
    let (stdout, stderr, code) = run(&exe);
    assert_eq!(stdout, "1\n");
    assert_eq!(stderr, "ELE: memoria insuficiente\n");
    assert_eq!(code, Some(project_l::native::PANIC_EXIT_CODE as i32));
}

#[test]
fn escapes_and_misuse_are_rejected() {
    let cases: [(&str, &str); 18] = [
        // Two borrows of one buffer in the same call, one of them mutable.
        (
            "fn copiar(d: &mut Bytes, s: &Bytes) {
 d.set(0, s.get(0))
}
fn main() {
 region r {
  var b = r.bytes(4)
  copiar(&mut b, &b)
 }
}",
            "préstamos incompatibles",
        ),
        // The specification's example: returning a buffer of a local region.
        (
            "fn crearBuffer() {\n    region temporal {\n        let buffer = temporal.bytes(1024)\n        return buffer\n    }\n}\nfn main() {}",
            "no puede devolverse",
        ),
        // Tail expression of the function.
        (
            "fn f() {\n region r {\n  r.bytes(1)\n }\n}\nfn main() {}",
            "no puede devolverse",
        ),
        // Assignment to a variable of an outer region.
        (
            "fn main() {\n region a {\n  var x = a.bytes(4)\n  region b {\n   x = b.bytes(4)\n  }\n  print(x.len())\n }\n}",
            "escaparía de su región",
        ),
        // Use after the region ended: the name is out of scope.
        (
            "fn main() {\n region r {\n  let b = r.bytes(4)\n }\n print(b.len())\n}",
            "no definido",
        ),
        // Stored in a struct field (the type is not even expressible there).
        (
            "struct H {\n b: Bytes\n}\nfn main() {}",
            "pertenece a una región",
        ),
        // Inside Option / a generic enum.
        (
            "fn main() {\n region r {\n  let o = Some(r.bytes(4))\n }\n}",
            "enum genérico",
        ),
        // Through a generic function.
        (
            "fn id<T>(x: T) -> T = x\nfn main() {\n region r {\n  let b = id(r.bytes(4))\n }\n}",
            "función genérica",
        ),
        // By-value parameter of type Bytes.
        ("fn f(b: Bytes) {}\nfn main() {}", "pertenece a una región"),
        // Returning Bytes from a function signature.
        (
            "fn f(b: &Bytes) -> Bytes = b\nfn main() {}",
            "pertenece a una región",
        ),
        // The region itself is not a value.
        (
            "fn main() {\n region r {\n  let otra = r\n }\n}",
            "receptor de .bytes",
        ),
        // Writing through an immutable binding.
        (
            "fn main() {\n region r {\n  let b = r.bytes(4)\n  b.set(0, 1)\n }\n}",
            "declárelo con var",
        ),
        // Writing through a shared reference parameter.
        (
            "fn f(b: &Bytes) {\n b.set(0, 1)\n}\nfn main() {}",
            "&mut Bytes",
        ),
        // Use after move of a buffer.
        (
            "fn main() {\n region r {\n  let a = r.bytes(4)\n  let b = a\n  print(a.len())\n }\n}",
            "después de moverlo",
        ),
        // Printing or interpolating a buffer.
        (
            "fn main() {\n region r {\n  let b = r.bytes(4)\n  print(b)\n }\n}",
            "print soporta",
        ),
        (
            "fn main() {\n region r {\n  let b = r.bytes(4)\n  print(\"{b}\")\n }\n}",
            "no convertible",
        ),
        // Unknown operations.
        (
            "fn main() {\n region r {\n  let b = r.text(4)\n }\n}",
            "solo tienen .bytes",
        ),
        // Allocation through a region is still an allocation for @noalloc.
        (
            "@noalloc\nfn f() -> Int {\n region r {\n  let b = r.bytes(4)\n  return b.len()\n }\n}\nfn main() {\n print(f())\n}",
            "violación de @noalloc",
        ),
    ];
    for (src, cause) in cases {
        let e = check(src).expect_err(src);
        assert!(e.message.contains(cause), "{src}\n{e:?}");
        assert_ne!(e.code, "L0007", "error interno en:\n{src}\n{e:?}");
        assert!(e.span.line > 0, "{src}");
    }
}

#[test]
fn region_effects_are_inferred() {
    // A region allocation contributes alloc and panic; reading a length
    // contributes nothing beyond the region allocation itself.
    check("fn f() -> Int !{alloc, panic} {\n region r {\n  let b = r.bytes(4)\n  return b.len()\n }\n}\nfn main() {\n print(f())\n}").unwrap();
    let e = check("fn f() -> Int !{panic} {\n region r {\n  let b = r.bytes(4)\n  return b.len()\n }\n}\nfn main() {}").unwrap_err();
    assert_eq!(e.code, "L0010");
    assert!(e.message.contains("región"), "{}", e.message);
    // Reading a buffer behind a parameter only may panic (bounds check).
    check("fn f(b: &Bytes) -> Int !{panic} = b.get(0)\nfn main() {}").unwrap();
    check("fn f(b: &Bytes) -> Int !{} = b.len()\nfn main() {}").unwrap();
}

#[test]
fn regional_lists_grow_and_borrow_slices() {
    let s = check_program(
        "regional_lists",
        r#"
fn sum(xs: &[Int]) -> Int {
 var result = 0
 for x in xs { result += x }
 return result
}
fn change(xs: &mut [Int]) { xs[0] = 10 }
fn main() {
 region r {
  var xs = r.list<Int>()
  print(xs.length)
  for i in 0..40 { xs.push(i) }
  change(&mut xs)
  print(sum(xs))
  print(xs.capacity)
  let moved = xs
  print(moved[39])
  region inner {
   var ys = inner.list<Float>()
   ys.push(1.5)
   print(ys[0])
  }
 }
}
"#,
        "0\n790\n64\n39\n1.5\n",
    );
    assert_eq!(s.region_allocs, 6);
    assert_eq!(s.region_bytes, 1024);
    assert_eq!(s.allocs, 2);
}

#[test]
fn regional_lists_drop_owned_elements_on_control_exits() {
    let s = check_program(
        "regional_owned",
        r#"
struct Item { text: Text }
enum Entry { Row(Item), Other }
fn build(n: Int) -> Option<Int> {
 region r {
  var a = r.list<Entry>()
  var b = r.list<List<Text>>()
  for i in 0..n {
   a.push(Entry.Row(Item(text: "item{i}")))
   b.push(List["nested{i}"])
   if i == 1 { continue }
   if i == 7 { break }
  }
  let v = a.pop()
  let nothing: Option<Int> = Option.None
  let x = nothing?
  return Option.Some(x)
 }
}
fn main() { print(build(10) ?? 42) }
"#,
        "42\n",
    );
    assert_eq!(s.region_allocs, 4);
    assert!(s.allocs > 20);
}

#[test]
fn regional_list_escapes_and_invalid_borrows_are_rejected() {
    for (source, code) in [
        (
            "fn f() { region r { return r.list<Int>() } }\nfn main() {}",
            "L0011",
        ),
        (
            "fn main() { var a: List<Int> = List[]\n region r { a = r.list<Int>() } }",
            "L0011",
        ),
        (
            "fn main() { region r { var a = r.list<Int>()\n region s { a = s.list<Int>() } } }",
            "L0011",
        ),
        (
            "fn main() { region r { let a = r.list<Int>()\n let b = &a\n return &b } }",
            "L0001",
        ),
        (
            "fn main() { region r { var a = r.list<Int>()\n for x in a { a.push(x) } } }",
            "L0005",
        ),
        (
            "fn main() { region r { let a = r.list<Int>()\n let b = a\n print(a.length) } }",
            "L0005",
        ),
        (
            "fn main() { region r { var a = r.list<Int>()\n a.push(true) } }",
            "L0001",
        ),
        (
            "@noalloc fn f() { region r { var a = r.list<Int>()\n a.push(1) } }\nfn main() {}",
            "L0010",
        ),
    ] {
        let error = check(source).unwrap_err();
        assert_eq!(error.code, code, "{source}: {error:?}");
    }
}

#[test]
fn regional_list_reserve_panics_and_allocation_failure() {
    for (name, amount, message) in [
        (
            "regional_list_negative",
            "-1",
            "reserve con tamaño negativo",
        ),
        (
            "regional_list_overflow",
            "9223372036854775807",
            "capacidad de List desbordada",
        ),
    ] {
        check_panic(
            name,
            &format!(
                "fn main() {{\n region r {{\n  var a = r.list<Int>()\n  a.reserve({amount})\n }}\n}}"
            ),
            "",
            message,
        );
    }
    let dir = work("regional_list_oom");
    fs::write(dir.join("oom.l"), "fn main() {\n region r {\n  var a = r.list<Int>()\n  a.push(1)\n  print(a[0])\n  a.reserve(4096)\n }\n}").unwrap();
    let out = run(&build(
        &dir,
        "oom.l",
        &["--backend", "cranelift", "--alloc-fail-after", "1"],
    ));
    assert_eq!(
        out,
        (
            "1\n".into(),
            "ELE: memoria insuficiente\n".into(),
            Some(project_l::native::PANIC_EXIT_CODE as i32)
        )
    );
}

#[test]
fn regional_list_cfg_rejects_early_region_drop() {
    use project_l::{
        cfg::{InstKind, verify},
        lir::Type,
        lower_to_cfg,
    };
    let ir = check("fn main() {\n region r {\n  var a = r.list<Text>()\n  a.push(\"{1}\")\n  print(a.length)\n }\n}").unwrap();
    let mut module = lower_to_cfg(&ir).unwrap();
    let f = &mut module.funcs[module.main];
    let mut changed = false;
    for block in &mut f.blocks {
        let region = block.insts.iter().position(|i| matches!(i.kind, InstKind::Drop(v, _) if matches!(f.vars[v].pointee(), Type::Region(_))));
        let list = block.insts.iter().rposition(|i| matches!(i.kind, InstKind::Drop(v, _) if matches!(f.vars[v].pointee(), Type::RegionList(..))));
        if let (Some(region), Some(list)) = (region, list) {
            assert!(list < region);
            block.insts.swap(list, region);
            changed = true;
        }
    }
    assert!(changed);
    assert!(
        verify(&module)
            .unwrap_err()
            .message
            .contains("listas vivas")
    );
}

#[test]
fn empty_regional_lists_and_arrays_as_elements() {
    let s = check_program(
        "regional_arrays",
        r#"
fn main() {
 region r {
  let empty = r.list<Text>()
  print(empty.length)
  var rows = r.list<[Int; 2]>()
  rows.push([10, 20])
  print(rows[0][1])
 }
}
"#,
        "0\n20\n",
    );
    assert_eq!(s.region_allocs, 1);
}
