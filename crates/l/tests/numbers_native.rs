//! Integration tests for native floating-point numbers in ELE.
//!
//! Tests Float (f64), f32, f64, arithmetic, IEEE 754 behavior,
//! explicit conversions, structs, enums, print, and string interpolation.

use std::{fs, path::PathBuf, process::Command};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn run_cranelift(name: &str, src: &str, trace_alloc: bool) -> (String, String, bool) {
    let dir = root().join("../../target/test_numbers").join(name);
    fs::create_dir_all(&dir).unwrap();
    let src_path = dir.join("main.l");
    fs::write(&src_path, src).unwrap();

    let mut args = vec!["run", src_path.to_str().unwrap(), "--backend", "cranelift"];
    if trace_alloc {
        args.push("--trace-alloc");
    }

    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .args(&args)
        .output()
        .expect("executing l run");

    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.success(),
    )
}

#[test]
fn float_basic_arithmetic() {
    let src = r#"
fn calcular(a: Float, b: Float) -> Float {
    return (a + b) * 2.0
}

fn main() {
    let resultado = calcular(10.5, 4.5)
    print(resultado)
}
"#;
    let (stdout, stderr, success) = run_cranelift("basic_arithmetic", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(stdout, "30\n");
}

#[test]
fn float_types_f32_and_f64() {
    let src = r#"
fn main() {
    let precio: Float = 19.99
    let descuento: f32 = 0.5
    let precision: f64 = 3.141592653589793
    print(precio)
    print(descuento)
    print(precision)
}
"#;
    let (stdout, stderr, success) = run_cranelift("types_f32_f64", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(stdout, "19.99\n0.5\n3.141592653589793\n");
}

#[test]
fn float_operations_and_comparisons() {
    let src = r#"
fn main() {
    let a = 10.0
    let b = 4.0
    print(a + b)
    print(a - b)
    print(a * b)
    print(a / b)
    print(-a)
    print(a == 10.0)
    print(a != b)
    print(a < b)
    print(a <= 10.0)
    print(a > b)
    print(a >= 10.0)
}
"#;
    let (stdout, stderr, success) = run_cranelift("ops_and_cmps", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(
        stdout,
        "14\n6\n40\n2.5\n-10\ntrue\ntrue\nfalse\ntrue\ntrue\ntrue\n"
    );
}

#[test]
fn float_ieee754_semantics() {
    let src = r#"
fn main() {
    let zero = 0.0
    let pos_inf = 1.0 / zero
    let neg_inf = -1.0 / zero
    let nan = zero / zero

    print(pos_inf)
    print(neg_inf)
    print(nan)

    // NaN comparisons: all ordered comparisons and == are false, != is true
    print(nan == nan)
    print(nan != nan)
    print(nan < 1.0)
    print(nan > 1.0)
    print(nan <= 1.0)
    print(nan >= 1.0)

    // Negative and positive zero are equal
    let neg_zero = -0.0
    print(neg_zero == 0.0)
}
"#;
    let (stdout, stderr, success) = run_cranelift("ieee754", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(
        stdout,
        "inf\n-inf\nNaN\nfalse\ntrue\nfalse\nfalse\nfalse\nfalse\ntrue\n"
    );
}

#[test]
fn float_explicit_conversions() {
    let src = r#"
fn main() {
    let i = 42
    let f = Float(i)
    let f_32 = f32(i)
    let f_64 = f64(i)
    print(f)
    print(f_32)
    print(f_64)

    let f2 = 42.99
    let i2 = Int(f2)
    print(i2)

    // Saturation on NaN and Inf
    let zero = 0.0
    let nan_val = zero / zero
    let inf_val = 1.0 / zero
    print(Int(nan_val))
    print(Int(inf_val))

    // Float <-> f32
    let small: f32 = 1.25
    let big = Float(small)
    print(big)
    let back = f32(big)
    print(back)
}
"#;
    let (stdout, stderr, success) = run_cranelift("conversions", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(
        stdout,
        "42\n42\n42\n42\n0\n9223372036854775807\n1.25\n1.25\n"
    );
}

#[test]
fn float_in_structs_and_methods() {
    let src = r#"
struct Vector2 {
    x: Float
    y: Float
}

impl Vector2 {
    fn length_squared() -> Float {
        return self.x * self.x + self.y * self.y
    }
}

fn main() {
    let v = Vector2(x: 3.0, y: 4.0)
    print(v.x)
    print(v.y)
    print(v.length_squared())
}
"#;
    let (stdout, stderr, success) = run_cranelift("structs_and_methods", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(stdout, "3\n4\n25\n");
}

#[test]
fn float_in_enums_option_and_result() {
    let src = r#"
enum OptionFloat {
    None
    Some(Float)
}

fn unwrap_or(opt: OptionFloat, default: Float) -> Float {
    return match opt {
        OptionFloat.None => default,
        OptionFloat.Some(v) => v,
    }
}

fn main() {
    let o1 = OptionFloat.Some(3.14)
    let o2 = OptionFloat.None
    print(unwrap_or(o1, 0.0))
    print(unwrap_or(o2, 0.0))
}
"#;
    let (stdout, stderr, success) = run_cranelift("enums_floats", src, false);
    assert!(success, "stderr: {stderr}");
    assert_eq!(stdout, "3.14\n0\n");
}

#[test]
fn float_string_interpolation_and_trace_alloc() {
    let src = r#"
fn main() {
    let temp = 36.6
    let target: f32 = 37.0
    let msg = "Temperatura: {temp} C (meta: {target})"
    print(msg)
}
"#;
    let (stdout, stderr, success) = run_cranelift("interpolation_trace", src, true);
    assert!(success, "stderr: {stderr}");
    assert_eq!(stdout, "Temperatura: 36.6 C (meta: 37)\n");
    assert!(
        stderr.contains("heap_ok=1"),
        "expected heap_ok=1 in trace output: {stderr}"
    );
    assert!(
        stderr.contains("allocs=1") && stderr.contains("frees=1"),
        "expected allocs == frees in trace output: {stderr}"
    );
}
