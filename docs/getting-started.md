# Getting Started with ELE

Welcome to **ELE**, an experimental systems programming language designed for deterministic memory safety without a garbage collector, compiled directly to native machine code.

---

## 1. System Requirements

ELE currently targets **x86-64** architectures on:
- **Windows x86-64:** Windows 10/11 (NTFS/FAT filesystem support, PE32+ generation).
- **Linux x86-64:** Ubuntu 20.04+, Debian, Fedora, or WSL2 on Windows (ELF64 generation).

### Prerequisites for Bootstrap
To build the compiler from source:
- **Rust Toolchain:** `1.99.1` (used strictly as the temporary Stage 0 bootstrap compiler).
- **Python:** `3.8+` (used for running benchmarks and verification scripts; not required by the compiled binaries).
- **C/C++ Tools (Optional for comparisons):** MSVC on Windows or GCC on Linux.

---

## 2. Installing ELE

### Option A: End-User Installation (Zero Dependencies)

If you have downloaded a distribution package or cloned the repository, install ELE directly without requiring Rust or Cargo:

**On Windows:**
```powershell
.\install.ps1
# Installs to $env:LOCALAPPDATA\ele\bin and configures User PATH.
```

**On Linux:**
```bash
./scripts/install.sh
# Installs to ~/.ele/bin and configures shell PATH.
```

The installer verifies the installation by running `ele --version` and building a sample verification program.

### Option B: Bootstrapping the Compiler from Source

ELE features an autonomous self-hosting driver (`compiler-l/src/main_driver.l`) capable of compiling ELE programs and rebuilding its own compiler binary without external dependencies.

#### Step 1: Clone the Repository
```bash
git clone https://github.com/Joshua-EPR/ELE.git
cd ELE
```

#### Step 2: Build the Stage 0 Bootstrap Compiler
```bash
cargo build -p project-l --bin l
```

#### Step 3: Compile the Autonomous ELE Driver
Using Stage 0, compile the self-hosting driver to a standalone executable:

**On Windows:**
```powershell
cargo test -p project-l --test ele_build_driver_l driver_cli_help_flag
# The native driver is produced at:
# target/stage1-tests/main_driver/normal/target/cranelift/x86_64-pc-windows-gnu/main_driver.exe
```

Alternatively, build a package on its native runner from the verified seed for
that host. The package builder requires the seed explicitly and verifies the
Gen 2 -> Gen 3 fixpoint; it has no Stage 0/Cargo fallback:

```powershell
python tools/verify_seed_archive.py pe --output .\seed\ele-seed-pe.exe
python scripts/package_distribution.py --target windows --driver-path .\seed\ele-seed-pe.exe
```

```sh
python3 tools/verify_seed_archive.py elf --output ./seed/ele-seed-elf
chmod 755 ./seed/ele-seed-elf
python3 scripts/package_distribution.py --target linux --driver-path ./seed/ele-seed-elf
```

Each native runner produces its own archive and `dist/SHA256SUMS.txt`.


---

## 3. Your First ELE Program

Create a file named `hello.l`:

```ele
// hello.l: Minimal ELE v2 program
flow main() {
    print("Hello from native ELE!")
}
```

### Compilation

Compile `hello.l` using the autonomous `ele` driver:

**On Windows (PE32+ executable):**
```powershell
.\bin\ele.exe build hello.l -o hello.exe
.\hello.exe
```

**On Linux (ELF64 executable):**
```bash
./bin/ele.elf build hello.l --target elf -o hello
chmod +x hello
./hello
```

**Output:**
```text
Hello from native ELE!
```

---

## 4. Multi-Module Project Example

ELE v2 uses `take` to import modules and `expose` to export functions.

### `math_helper.l`:
```ele
// math_helper.l
expose flow add(a: Int, b: Int) => Int {
    give a + b
}

expose flow mul(a: Int, b: Int) => Int {
    give a * b
}
```

### `main.l`:
```ele
// main.l
take math_helper

flow main() => Int {
    hold sum = add(10, 20)
    hold prod = mul(sum, 2)
    print("Result: {prod}")
    give 0
}
```

### Compiling Multi-Module Programs
The driver automatically discovers and resolves dependencies in the same directory:

```powershell
.\bin\ele.exe build main.l -o app.exe
.\app.exe
# Output: Result: 60
```

---

## 5. Command-Line Interface Reference

```text
ELE Compiler Driver 0.3.0
Usage: ele <command> [options]

Commands:
  build <file.l>            Compiles an ELE source file to a native executable

Build Options:
  --output, -o <path>       Destination path for the output binary
  --target <pe|elf>         Target binary format:
                              pe  = Windows x86-64 PE32+
                              elf = Linux x86-64 ELF64
  --pe64                    Shorthand for --target pe
  --elf64                   Shorthand for --target elf

General Options:
  --help, -h                Displays help information
  --version, -v             Displays the ELE version
```

---

## 6. Common Diagnostics and Troubleshooting

- **`error[PARSER]: se esperaba declaración`:** Check that you are using ELE v2 syntax (`flow`, `hold`, `change`, `shape`, `choice`).
- **`error[L0016]: proyección de un valor temporal propietario fuera del subconjunto de Stage 1`:** Avoid chained calls on temporary aggregates (e.g. `foo().field`). Bind the result to a local variable using `hold val = foo()` first.
- **`error: el archivo de salida no puede sobrescribir el archivo de entrada`:** The driver protects against accidental destructive overwrites of source files, imported modules, or filesystem aliases. Specify a distinct output name with `-o`.
