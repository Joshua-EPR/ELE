# Stage-0-free seed bootstrap

This document describes the first stretch of the ELE build pipeline that runs
without Stage 0 (the Rust crate `crates/l`, binary `l`) and without any Rust
tooling, what is still not Stage-0-free, and how to reproduce it.

## What the bootstrap does

Input: a **seed** ELE driver binary, its expected SHA-256, a target and a new
(or empty) output directory.

1. Verify the seed's SHA-256 against the pin; refuse on mismatch. The seed is
   copied into the output directory, the copy is re-hashed, and only the copy
   is executed. The seed must also identify itself as the ELE driver
   (`--help` prints `ELE Compiler Driver`).
2. seed builds **Gen1'** from `compiler-l/src/main_driver.l`.
3. Gen1' builds **Gen2**.
4. Gen2 builds **Gen3**.
5. Gen2 and Gen3 must be **bitwise identical**. Both hashes are always
   printed; on a mismatch the sizes, the number of differing bytes and the
   first differing offsets are printed and recorded, and the run fails.
6. Gen3 compiles and runs every program in
   `scripts/bootstrap/smoke/cases.txt` (six examples from `examples/` plus
   `scripts/bootstrap/smoke/exit_code.l`). Stdout is compared byte for byte
   with `scripts/bootstrap/smoke/expected/<name>.stdout`, and the exit code
   with the manifest (one case expects exit code 7).
7. Gen3 must reject every program in `scripts/bootstrap/smoke/reject.txt`
   (four programs from `examples/invalid/`): expected non-zero exit code, the
   listed diagnostic code (e.g. `error[L0005]`) on stderr, and no output image
   written.
8. `provenance.json` and `SHA256SUMS` are written to the output directory:
   source commit (from `ELE_SOURCE_COMMIT` if set, else `git rev-parse HEAD`,
   else `GITHUB_SHA`), whether tracked files were dirty, the SHA-256 of
   `main_driver.l`, the seed's expected and actual SHA-256, each generation's
   SHA-256/size/timestamps, the fixpoint result, every smoke/reject result,
   and the guard information below. Provenance is also written on failure,
   with `"status": "failed"` and the reason.

Scripts:

| Script | Host | Target |
| --- | --- | --- |
| `scripts/bootstrap/ele_seed_bootstrap.ps1` | Windows (PowerShell 5.1 or 7) | `pe` (PE32+) |
| `scripts/bootstrap/ele_seed_bootstrap.sh` | POSIX `sh` on Linux x86-64 | `elf` (ELF64) |

### Guard: no compiler toolchain

The scripts never run `cargo`, `rustc`, `rustup`, Stage 0 (`l`), `cl`, `link`,
`gcc`, `clang`, `ld` (or `lld`, `ld.lld`, `cc`). Every child process goes
through one function that only executes images located inside the output
directory (the verified seed copy, the generations and the smoke programs)
and refuses any image or seed named like one of those programs.

Whether those programs are resolvable on `PATH` is recorded in
`provenance.json` (`guard.host_tools_info`) **for information only**. With
`-ForbidToolchainOnPath` / `--forbid-toolchain-on-path` (or
`ELE_BOOTSTRAP_FORBID_TOOLCHAIN=1`) a resolvable `cargo`, `rustc` or `rustup`
is an error. C toolchain programs are not forbidden on `PATH` because the
hosted runners ship them (e.g. `gcc`, `ld`); they are only never executed.

The seed identity check runs the pinned seed with `--help`. If someone pins
the hash of a Stage 0 binary renamed to something other than `l`, that one
`--help` call is the only thing executed before the run is refused.

### Never overwriting outputs

The output directory must not exist or must be empty; every output file is
checked to be absent before it is written.

## What is Stage-0-free now

Verified locally (see below) and enforced in CI by
`.github/workflows/stage0-free-bootstrap.yml`, jobs `bootstrap-linux` and
`bootstrap-windows`:

- Rebuilding the ELE driver from `compiler-l/src/main_driver.l` through three
  generations (seed -> Gen1' -> Gen2 -> Gen3) with ELE-built drivers only.
- The PE32+ and ELF64 images are written by the ELE driver's own native
  backend; the scripts never invoke a linker, assembler or C/Rust compiler.
- Those CI jobs do not install Rust, scrub `cargo`/`rustc`/`rustup` from
  `PATH`, and assert they are not resolvable before running the scripts.

## What is NOT Stage-0-free yet

- **The seed itself comes from Stage 0.** In CI the transitional `seed` job
  (clearly labelled as the only Stage 0 use) builds Stage 0 with Rust and then
  the Gen1 driver: on `windows-latest` with Stage 0's Cranelift backend (this
  links with the MSVC linker), on `ubuntu-latest` with Stage 0's reference
  `rustc` backend. The bootstrap jobs consume that seed through a workflow
  artifact whose SHA-256 is computed by the same `seed` job, so the pin is
  only as trustworthy as that job.
- **Next step (not done here):** publish a seed release (PE and ELF driver
  images plus their SHA-256), commit the hashes to the repository, and make
  the bootstrap jobs download that release instead of depending on `seed`.
  Only then can the `seed` job, and Stage 0 in this pipeline, be removed.
- All other workflows (`native-selfhosting-validation.yml`, etc.) and the
  Rust test suites still build Stage 0 and Stage 1 with Stage 0; this PR does
  not change them.
- The smoke set is small (seven programs and four rejections); it is a
  sanity check of Gen3, not a replacement for the existing test suites.

## Running it locally

### Windows (PE32+)

Building the seed uses Stage 0 (this is the transitional, Rust-dependent
step):

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build -p project-l --bin l
New-Item -ItemType Directory -Force target/seed-build | Out-Null
Push-Location target/seed-build
../debug/l.exe build ../../compiler-l/src/main_driver.l --backend cranelift
Pop-Location
$seed = 'target/seed-build/target/cranelift/x86_64-pc-windows-msvc/main_driver.exe'
$sha = (Get-FileHash -Algorithm SHA256 $seed).Hash
```

Stage-0-free part:

```powershell
./scripts/bootstrap/ele_seed_bootstrap.ps1 -Seed $seed -SeedSha256 $sha `
    -Target pe -OutDir <new empty directory>
```

### Linux / WSL (ELF64)

Any ELF64 ELE driver can be the seed. Two ways to obtain one with Stage 0:

- on Linux: `l build compiler-l/src/main_driver.l` (Stage 0's `rustc`
  backend), as the CI `seed` job does;
- on Windows: let the Windows Gen1 cross-emit an ELF64 driver,
  `<gen1>.exe build compiler-l/src/main_driver.l --target elf --output main_driver.elf`.

Then, on Linux x86-64 (or inside WSL):

```sh
sh scripts/bootstrap/ele_seed_bootstrap.sh --seed main_driver.elf \
    --seed-sha256 <sha256 of main_driver.elf> --target elf \
    --out-dir <new empty directory> [--forbid-toolchain-on-path]
```

When the checkout belongs to another OS (a Windows tree seen from WSL), set
`ELE_SOURCE_COMMIT=<commit>` so the script records it without running git.

## Local verification record (2026-11-24, source commit d27dc67)

Windows 10 x86-64, PowerShell 5.1; WSL2 Ubuntu x86-64 for ELF64 (no `cargo`,
`rustc` or `rustup` installed in WSL; the script ran with
`--forbid-toolchain-on-path`).

| Chain | Seed SHA-256 | Gen1' = Gen2 = Gen3 SHA-256 | Size | Smoke | Reject |
| --- | --- | --- | --- | --- | --- |
| PE32+ | `01649c7f...5a196` (Stage 0 Cranelift Gen1, 1,177,088 bytes) | `0fa24fe43d0eb3a1290f08f07d9b52bcd6eb91802a4f7ff5e953f1c9ab081ea6` | 1,922,048 | 7/7 | 4/4 |
| ELF64 | `77666ed0...ed462` (cross-emitted by the Windows Gen1) | `77666ed03af34641819becb2d56d642ab2a4256d518037238ddc6436637ed462` | 1,921,024 | 7/7 | 4/4 |

Observations:

- On both targets Gen1' already equals Gen2: the Stage-0-built seed and the
  ELE-built drivers emit the same bytes for the driver source.
- The ELF64 seed obtained by cross-emitting from the Windows Gen1 is itself
  the fixpoint image (seed = Gen1' = Gen2 = Gen3).
- Negative checks exercised locally: wrong seed hash (refused, exit 1, failed
  provenance written), non-empty output directory (refused), Rust on `PATH`
  with the forbid flag (refused), seed named `l.exe` (refused), a renamed
  Stage 0 binary pinned as the seed (refused by the `--help` identity check),
  `--target pe` passed to the POSIX script (refused).
- Not part of the smoke set because Gen3 rejects them today:
  `examples/enums.l` (Gen3 reports `UTF-8 inválido` on the Windows checkout
  although the file is valid UTF-8; not investigated here),
  `examples/constants.l` and `examples/contador.l` (outside the Stage 1
  subset / parser errors).
