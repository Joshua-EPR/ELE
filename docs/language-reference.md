# ELE Language Reference (v2 Syntax)

This document specifies the canonical surface syntax, type system, ownership semantics, and module structure of the **ELE Programming Language**.

---

## 1. Lexical Structure

- **Source encoding:** UTF-8 strictly enforced.
- **File extension:** `.l`
- **Comments:**
  - Single-line: `// comment`
  - Block: `/* comment */`
- **Identifiers:** Standard alphanumeric starting with lowercase or underscore (`[a-z_][a-zA-Z0-9_]*`). Types start with uppercase (`[A-Z][a-zA-Z0-9_]*`).

---

## 2. Declarations

### Functions (`flow`)
Functions are declared with the `flow` keyword:

```ele
flow add(x: Int, y: Int) => Int {
    give x + y
}

// Single-expression shorthand
flow square(x: Int) => Int = x * x
```

- Parameters require explicit types.
- The return type is indicated by `=> Type`. If omitted, the return type is unit.
- The `give` keyword returns a value from the function.

### Constants (`fixed`)
Global and local compile-time evaluated constants:

```ele
fixed MAX_BUFFER_SIZE: Int = 1048576
fixed DEFAULT_PREFIX: Text = "ELE-CORE:"
```

### Structures (`shape`)
Product types with named fields:

```ele
shape Point {
    x: Int
    y: Int
}

shape Config {
    title: Text
    retries: Int = 3
}
```

Instantiation:
```ele
hold p = Point(x: 10, y: 20)
```

### Tagged Unions (`choice`)
Sum types (algebraic data types):

```ele
choice Status {
    Pending
    Active(code: Int)
    Failed(reason: Text)
}
```

---

## 3. Variables and Ownership

ELE enforces deterministic memory safety at compile time through an affine type system with move semantics and drop elaboration, without a garbage collector.

### Variable Bindings
- `hold`: Immutable owner binding.
- `change`: Mutable owner binding.

```ele
hold initial_name: Text = "Alice"
// initial_name cannot be reassigned

change counter: Int = 0
counter = counter + 1
```

### Move Semantics
Non-copy types (such as `Text`, `shape`, `choice`, and `List of[T]`) are moved when assigned or passed by value:

```ele
hold original: Text = "Ownership Token"
hold transferred = original
// 'original' is now moved; subsequent reads are rejected by the borrow checker.
```

### References and Borrows
ELE distinguishes between shared read-only loans and exclusive mutable loans:
- `view T`: Shared, read-only loan. Multiple views may coexist simultaneously.
- `edit T`: Exclusive, read-write loan. No other views or edits can coexist.

```ele
flow inspect(item: view Text) {
    print(item)
}

flow append_suffix(target: edit Text) {
    // Modify target through exclusive loan
}
```

---

## 4. Control Flow

### Conditional (`when` / `otherwise`)
```ele
when x > 10 {
    print("Greater than 10")
} otherwise when x == 10 {
    print("Exactly 10")
} otherwise {
    print("Less than 10")
}
```

### While Loop (`during`)
```ele
change i = 0
during i < 10 {
    print(i)
    i = i + 1
}
```

### Iteration (`each` / `among`)
```ele
each item among items {
    print(item)
}
```

### Pattern Matching (`choose`)
Pattern matching is exhaustive and checks unreachable branches:

```ele
choose status {
    Status.Pending: {
        print("Pending...")
    }
    Status.Active(code): {
        print("Active with code: {code}")
    }
    Status.Failed(reason): {
        print("Failed: {reason}")
    }
}
```

---

## 5. Primitive Types and Collections

| Type | Description | Size | Copyable? |
|---|---|---|---|
| `Int` | 64-bit signed integer | 8 bytes | Yes (`Copy`) |
| `Bool` | Boolean (`true` or `false`) | 1 byte | Yes (`Copy`) |
| `Float` | 64-bit IEEE floating-point | 8 bytes | Yes (`Copy`) |
| `Text` | Dynamic UTF-8 heap string | 24 bytes | **No** (Affine owner, deterministic drop) |
| `List of[T]` | Dynamic growable array | 24 bytes | **No** (Affine owner, deterministic drop) |
| `Option of[T]` | Optional value (`Some(T)` or `None`) | Sized | By payload |
| `Result of[T, E]` | Error container (`Ok(T)` or `Err(E)`) | Sized | By payload |

### Text Formatting & Interpolation
Strings are enclosed in double quotes. Interpolation evaluates expressions directly:

```ele
hold name = "World"
hold greeting = "Hello, {name}! 2 + 2 = {2 + 2}"
```
Literal braces inside text literals are escaped using `{{` and `}}`.

### Integer Literals and Operators

`Int` literals are decimal (`1_000`), hexadecimal (`0xFF_00`) or binary
(`0b1010`); `_` separates digits. A `0x`/`0b` literal is a **64-bit two's
complement pattern**: up to 64 significant bits are accepted and bit 63 is
the sign, so `0xFFFF_FFFF_8000_0000` is `-2147483648` (a higher-half
address). More than 64 significant bits is an error.

| Operators | Meaning | Traps |
|---|---|---|
| `*` `/` `%` `*%` | multiply, divide, remainder, wrapping multiply | `*` `/` `%` on overflow or zero divisor |
| `+` `-` `+%` `-%` | add, subtract, wrapping add/subtract | `+` `-` on overflow |
| `<<` `>>` | shift left, logical shift right (zeros enter) | count outside `0..63` |
| `&` | bitwise and | never |
| `^` | bitwise xor | never |
| `\|` | bitwise or | never |
| `<` `>` `<=` `>=` | comparison (not chainable) | never |
| `==` `!=` | equality | never |
| `&&` | logical and (short-circuit) | never |
| `\|\|` | logical or (short-circuit) | never |
| `??` | option default | never |

Rows are in decreasing precedence (as in Rust), so `x & MASK == 0` is
`(x & MASK) == 0` and `1 + 2 << 3` is `24`. The prefix operators `-`, `!`
and `~` (bitwise not of an `Int`) bind tighter than every binary operator.
Bitwise, shift and wrapping operators take only `Int` operands; they are
also folded in `fixed` constants, where a failing operation is a
compile-time error. A failure at run time stops the program with status
125, like an overflow.

---

## 6. Modules and Visibility

ELE organizes programs into single-file modules resolved relative to the root compilation unit.

- **Importing a module:** `take <module_name>`
- **Exporting a symbol:** `expose <declaration>`

```ele
// In utils.l
expose flow compute_hash(data: view Text) => Int {
    // ...
}

// In main.l
take utils

flow main() {
    hold h = compute_hash("sample")
    print(h)
}
```

Circular imports are statically detected and rejected with an explicit error diagnostic.

### Kernel Intrinsics and `--target kernel`

`take nucleo.cpu` and `take nucleo.mem` are not files: they enable, inside the
module that takes them, flows that the compiler lowers to inline code. Every
argument is an `Int`.

| Module | Flow | Code | Result |
|---|---|---|---|
| `nucleo.cpu` | `hlt()`, `cli()`, `sti()`, `pause()`, `int3()`, `wbinvd()` | one instruction | — |
| `nucleo.cpu` | `in8/in16/in32(puerto)` | `IN AL/AX/EAX, DX` | `Int`, zero-extended |
| `nucleo.cpu` | `out8/out16/out32(puerto, valor)` | `OUT DX, AL/AX/EAX` | — |
| `nucleo.cpu` | `cpuid(hoja, subhoja, dir)` | `CPUID`; EAX EBX ECX EDX as four u32 at `dir` | — |
| `nucleo.cpu` | `rdtsc()`, `rdmsr(msr)`, `wrmsr(msr, valor)` | `RDTSC`, `RDMSR`, `WRMSR` | `Int` / — |
| `nucleo.cpu` | `leerCr0/2/3/4()`, `escribirCr0/3/4(valor)`, `leerRflags()`, `leerRsp()` | `MOV r, CRn` / `MOV CRn, r` / `PUSHFQ` / `MOV RAX, RSP` | `Int` / — |
| `nucleo.cpu` | `lgdt(dir)`, `lidt(dir)`, `ltr(selector)`, `invlpg(dir)` | one instruction | — |
| `nucleo.cpu` | `recargarSegmentos(codigo, datos)` | DS/ES/SS/FS/GS = `datos`, far return to CS = `codigo` | — |
| `nucleo.cpu` | `fxsave(dir)`, `fxrstor(dir)` | `FXSAVE64` / `FXRSTOR64` | — |
| `nucleo.cpu` | `stubInterrupcion(vector)` | address of the compiler-generated stub (kernel only) | `Int` |
| `nucleo.cpu` | `xmmCero(r)`, `xmmCargar(r, dir)`, `xmmGuardar(dir, r)`, `xmmDifundir(r, dir)`, `xmmCopiar(d, s)`, `xmmMultiplicar(d, s)`, `xmmSumar(d, s)` | `XORPS`, `MOVUPS`, `MOVSS`+`SHUFPS`, `MOVAPS`, `MULPS`, `ADDPS` on XMM1..XMM15 | — |
| `nucleo.cpu` | `xmmDifundirEn(r, dir, desp)`, `xmmMulSumar4(acc, a, dir, desp)`, `xmmMulSumar4M(acc, a, dir, desp)` (MULPS from memory, 16-byte aligned) | broadcast of `[dir+desp]`; `acc+j += a * [dir+desp+16j]` for j = 0..3 (`MOVUPS`+`MULPS`+`ADDPS` through XMM0) | — |
| `nucleo.mem` | `leer8/leer16/leer32/leer64(dir)` | `MOVZX`/`MOV` from `[dir]` | `Int`, zero-extended |
| `nucleo.mem` | `escribir8/escribir16/escribir32/escribir64(dir, valor)` | `MOV [dir]`, low bytes | — |
| `nucleo.mem` | `reservar(bytes, alineacion)` | zeroed `.bss` block (kernel only) | its address |
| `nucleo.mem` | `datos64(w0, w1, ...)` | initialized `.data` words, up to 256 (kernel only) | its address |
| `nucleo.mem` | `cadena("texto")` | `.rodata` record `[bytes: u64][UTF-8 bytes]` (kernel only) | its address |

Each access is emitted exactly once and in program order (the backend keeps
no value in a register across instructions), so memory-mapped I/O needs no
`volatile` marker. A module that does not take these modules can still define
flows with the same names.

Static storage is per call site: `flow peticion() => Int { give datos64(...) }`
returns the same address on every call. The arguments of `reservar` and
`datos64` must be constant expressions (literals, `fixed` names and their
operators); `cadena` takes a literal without interpolation. The XMM
intrinsics take constant register numbers 1..15 (XMM0 is their scratch;
Float code uses XMM0..XMM5, so only XMM6..XMM15 survive Float statements)
and keep their values across statements, so a loop can hold accumulators in
XMM registers.

`stubInterrupcion(v)` returns the address of one of 256 generated stubs. Each
stub pushes a zero error code when the CPU pushes none, then the vector and
the 15 general registers, and calls `kinterrupcion(marco: Int)`. On return
it restores the registers and executes `IRETQ`. The frame holds R15..R8 at
0..56, RDI 64, RSI 72, RBP 80, RBX 88, RDX 96, RCX 104, RAX 112, vector 120,
error code 128, RIP 136, CS 144, RFLAGS 152, RSP 160 and SS 168. The program
must define `kinterrupcion`.

`ele build kmain.l --target kernel -o kernel.elf` writes a freestanding
ELF64 `ET_EXEC` image for the top 2 GiB. `.text` (R+X) starts at
`0xFFFFFFFF80001000`. `.rodata` (R), `.data` and `.bss` (R+W) each start on
their own page, and a `.symtab` names every flow. The entry stub calls the
entry flow (`kmain`, or `--entry <flow>`, with no parameters) and stops the
CPU (`CLI; HLT`) if it returns.

There is no runtime: `print`, owned `Text` (including a Text literal bound to
a variable), `List` and platform I/O are rejected (backend code 75). A failed
run-time check (overflow, index, inactive variant) stops the CPU with the
status (125/126/127) in `RDI` and the packed source position in `RAX`.
Backend codes: 77 static storage or stubs outside `--target kernel`,
78 non-constant `reservar`/`datos64`/`cadena` arguments, 79 `kinterrupcion`
missing, 80 XMM register outside 1..15 (for `xmmMulSumar4`/`xmmMulSumar4M`, `acc` <= 12 and
`a` outside `acc..acc+3`) or a non-constant displacement.

If the program defines `kpanico(codigo: Int, posicion: Int)`, a failed
run-time check in a kernel image calls it (status 125/126/127, position =
line * 2^20 + column) before stopping the CPU.
