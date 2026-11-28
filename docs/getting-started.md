# Getting Started with ELE

Welcome to **ELE**, an experimental systems programming language designed for deterministic memory safety without a garbage collector, compiled directly to native machine code.

---

## 1. System Requirements

ELE currently targets **x86-64** architectures on:
- **Windows x86-64:** Windows 10/11 (NTFS/FAT filesystem support, PE32+ generation).
- **Linux x86-64:** Ubuntu 20.04+, Debian, Fedora, or WSL2 on Windows (ELF64 generation).

### Prerequisites for Bootstrap
To build the compiler from source **without Rust** (Stage 1, Option B below):
- **Windows PowerShell** (the bootstrap script is `scripts/bootstrap/ele_seed_bootstrap.ps1`; POSIX `sh` on Linux: `ele_seed_bootstrap.sh`).
- **Python:** `3.8+` (extracts and verifies the pinned seed with `tools/verify_seed_archive.py`; not required by the compiled binaries).

Only the optional Stage 0 route (Option C) needs the **Rust Toolchain** `1.99.1`. Terms (Stage 0, Stage 1, fixpoint) are defined once in
[self-hosting.md](self-hosting.md#0-terminology-stage-0-and-stage-1).
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

> **Checked 2026-11-27:** `install.ps1` only forwards to `scripts/install.ps1`, which installs `bin\ele.exe` **from a distribution archive**
> (`dist/ele-windows-x86_64.zip` or `-PackagePath`); it does not build anything and throws "ELE distribution archive not found" without one.
> That `ele.exe` is the Stage 1 compiler (Gen2/Gen3). To get it from a fresh clone, use Option B and build the archive with
> `scripts/package_distribution.py`, or simply copy `gen2.exe` anywhere and call it (see below).

### Option B: Build the Stage 1 compiler from the pinned seed (no Rust)

ELE features an autonomous self-hosting driver (`compiler-l/src/main_driver.l`) capable of compiling ELE programs and rebuilding its own compiler binary without external dependencies.
**Stage 1** is that driver built from a hash-pinned seed: `seed -> Gen1' -> Gen2 -> Gen3`, accepted only if `Gen2 == Gen3` bit for bit.
These commands were executed on 2026-11-27 (commit `ec41098`, Windows 10, i5-7300U) and took about 32 s in total.

```powershell
git clone https://github.com/Joshua-EPR/ELE.git
cd ELE

# 1. Extract and verify the seed (archive and payload SHA-256, PE32+ AMD64 header)
python tools/verify_seed_archive.py pe --output .\seed\ele-seed-pe.exe
#    verified PE32+ AMD64 seed: ...\seed\ele-seed-pe.exe

# 2. Bootstrap (the output folder must not exist or be empty)
.\scripts\bootstrap\ele_seed_bootstrap.ps1 -Seed .\seed\ele-seed-pe.exe `
    -SeedSha256 eb98a908ca5a36b5a4f29c9114a8232a6031f7d35c2c4298569adf67ebccc2f5 -Target pe -OutDir .\out\bootstrap
```

Expected end of the output:

```text
    gen2 sha256 cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218 (2438656 bytes, 13.33 s)
    gen3 sha256 cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218 (2438656 bytes, 13 s)
    BITWISE EQUAL (gen1prime == gen2: False)
==> OK: Stage-0-free chain seed -> gen1prime -> gen2 -> gen3 is a bitwise fixpoint (cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218)
```

`out\bootstrap` then holds `gen1prime.exe`, `gen2.exe`, `gen3.exe` (2,438,656 B = 2,381.5 KiB each), `provenance.json`, `SHA256SUMS`, `logs\` and `smoke\`.
`gen2.exe` **is** the compiler: copy it where you want (for example `bin\ele.exe`) and use it as in section 3. Details, the meaning of each output and the
note about the hash recorded in `kernel/compilador/provenance.json`: [self-hosting.md](self-hosting.md#01-stage-1-step-by-step-verified-2026-11-27).
If the hash differs from the one above, your sources differ from commit `ec41098`; the fixpoint (`gen2 == gen3`) is what must hold.

### Option C: Build the Stage 0 compiler (needs Rust)

Stage 0 is the Rust compiler. It is the reference and the faster-running (optimizing) backend, but it is not needed to build or use ELE.

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

Compile `hello.l` using the autonomous `ele` driver (checked with `gen2.exe` from Option B; replace `.\bin\ele.exe` by the path to your copy):

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
  --target kernel           Freestanding ELF64 x86-64 in the upper half (0xFFFFFFFF80000000), no runtime
                            (no print, Text, List or system I/O)
  --entry <flow>            Entry flow (default 'main'; 'kmain' with --target kernel)
  --lib <root>              Search missing imports under this root (e.g. --lib . for std/)
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
