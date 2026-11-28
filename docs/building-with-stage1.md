# Building with Stage 1, and how it compares with the Rust reference compiler

This guide keeps the comparisons with the compiler written in Rust out of the main guides ([getting started](getting-started.md),
[self-hosting](self-hosting.md), the READMEs), which describe the route without Rust. Spanish version: [compilar-con-stage1.md](compilar-con-stage1.md).
Verified 2026-11-27 on commit `ec410984c8311f0e79e1a876932cff785f88ad13` (Windows 10 IoT Enterprise LTSC 2021, Intel Core i5-7300U, about 8 GiB RAM).

## Definitions

- **Stage 0** is the compiler written in Rust (`crates/l`, binary `l`; `cargo build -p project-l --bin l`). It needs the Rust toolchain.
- **Stage 1** is the compiler written in ELE (`compiler-l/src/main_driver.l`, 743 lines, 28,535 B), built **without Rust** from the pinned seed:
  `seed -> Gen1' -> Gen2 -> Gen3`, with `Gen2 == Gen3` bit for bit (the fixpoint). `Gen2`/`Gen3` is what the installers ship as `ele.exe` / `ele.elf`.

Other documents number the stages differently. They are not wrong, but they describe other things:

| Document | Meaning of "Stage N" there |
|---|---|
| [BOOTSTRAP_ARCHITECTURE.md](BOOTSTRAP_ARCHITECTURE.md) (lines 50-66) | Plan: Stage 1 = Stage 0 compiles an L driver; Stage 2 = that executable rebuilds the compiler; Stage 3 = second rebuild |
| [STAGE0_FREE_BOOTSTRAP.md](STAGE0_FREE_BOOTSTRAP.md) | The seed-based chain (seed, Gen1', Gen2, Gen3), with no Stage 0 involved |
| [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) (line 13 and the phase 8.x entries around line 1474) | Historical phase logs: "no Stage 2 or Stage 3 exists" was true when written and is superseded by the fixpoint |
| "Stage 3.x" in [self-hosting.md](self-hosting.md) | Names of engineering milestones of the fixpoint work, not compiler generations |

## Stage 1 route versus the Rust route

| | Stage 1 (no Rust) | Stage 0 (Rust) |
|---|---|---|
| Build | `ele_seed_bootstrap.ps1` from the seed, about 32 s | `cargo build --release -p project-l --bin l` |
| Needs | PowerShell and Python (seed extraction) | Rust toolchain `1.99.1` |
| Backend | ELE native emitter, PE32+ / ELF64 / kernel | Cranelift (`l build --backend cranelift`) |
| Source accepted | `async`, `spawn` and regions are not accepted yet | wider (all the `bench/programs` files compile) |

The Rust route is documented in [getting-started.md](getting-started.md) (Option C). Its tests that check the fixpoint:

```powershell
$env:ELE_TEST_WSL_DISTRO = "Ubuntu"   # Linux execution on a Windows host
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_windows_fixpoint
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_linux_fixpoint
```

## About the fixpoints

- **Current (Windows PE32+, commit `ec41098`, from the seed, no Rust):** `cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218`, 2,438,656 B.
- **Historical, built with Stage 0 as Gen 1** (older source, Stage 3.2/3.3 chain): Windows `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`
  (1,508,352 B) and Linux `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9` (1,511,424 B). The Linux chain was not re-run on 2026-11-27.
- `kernel/compilador/provenance.json` records the same `cfcfa798...` value, but it says `commit 758270d..., tracked_files_dirty: true`. A **clean** checkout of `758270d`
  gives a different fixpoint, `76ba727530350611dff52ba3fbea502ce1580752a0cfdd8e7a55d81e474b44bc` (2,436,096 B, same seed, run on 2026-11-27; provenance in
  [`provenance_758270d_clean.json`](benchmarks/campaign_20261127_stage1/bootstrap/provenance_758270d_clean.json)). The kernel build came from a working tree that already
  contained the compiler changes committed later (`native_cfg_platform.l`, `x86_64.l`, `lir_build.l`, `sema_expr.l`, `sema_ops.l`, 31 lines between `758270d` and `ec41098`), and it matches `ec41098` byte for byte.
- The bootstrap script never runs `cargo`, `rustc` or `rustup`; with `-ForbidToolchainOnPath` it fails if they are on `PATH`.

## Performance: Stage 1 against Stage 0

Median of 5 timed runs after 1 warm-up (min-max in parentheses). Units: B = byte, KiB = 1,024 B, MiB = 2^20 B. Process start costs about 24 ms on this PC, which is the floor of every run time.
Full method, raw CSV and the programs Stage 1 cannot compile: [performance.md](performance.md#0-measurements-2026-11-27-stage-1) and
[campaign_20261127_stage1](benchmarks/campaign_20261127_stage1/README.md).

### Compilation

| Program | Source (B) | Stage 1 compile (ms): median (min–max) | Stage 1 peak (MiB) | Stage 1 exe (B / KiB) | Stage 0 compile (ms): median (min–max) | Stage 0 peak (MiB) | Stage 0 exe (B / KiB) |
|---|---|---:|---:|---:|---:|---:|---:|
| `hello.l` | 87 | **34.8** (34.2–39.7) | 18.61 | 4,608 / 4.5 | **138.4** (130.8–301.5) | 7.79 | 9,216 / 9.0 |
| `fibonacci.l` | 219 | **38.6** (37.7–40.0) | 18.65 | 5,632 / 5.5 | **125.2** (124.4–140.0) | 7.98 | 9,728 / 9.5 |
| `loops.l` | 196 | **39.3** (36.8–45.7) | 18.61 | 5,632 / 5.5 | **135.2** (127.2–140.8) | 7.95 | 9,216 / 9.0 |
| `structs.l` | 1,414 | **65.0** (63.8–68.4) | 18.70 | 9,216 / 9.0 | **137.2** (133.6–201.0) | 8.26 | 11,776 / 11.5 |
| `text.l` | 296 | **36.3** (36.0–54.5) | 18.64 | 5,120 / 5.0 | **165.0** (152.7–172.8) | 8.02 | 9,216 / 9.0 |
| `native_text_stage1.l` | 728 | **43.9** (38.9–344.9) | 18.66 | 7,168 / 7.0 | **163.2** (148.7–239.8) | 7.99 | 10,752 / 10.5 |
| `arithmetic.l` | 225 | **36.2** (35.5–37.5) | 18.64 | 5,632 / 5.5 | **155.8** (146.4–159.7) | 7.95 | 9,216 / 9.0 |
| `text_processing.l` | 245 | **37.2** (36.2–38.6) | 18.64 | 5,120 / 5.0 | **150.4** (139.8–216.0) | 7.95 | 9,728 / 9.5 |
| `fib.l` | 197 | **35.9** (35.2–40.5) | 18.64 | 5,632 / 5.5 | **157.5** (154.3–191.2) | 7.94 | 9,728 / 9.5 |
| `list_search_1m.l` | 672 | **44.4** (42.1–48.7) | 18.66 | 6,656 / 6.5 | **156.2** (150.4–162.2) | 8.07 | 10,240 / 10.0 |

### Compiler compiling itself (`main_driver.l`)

| Compiler | Time: median (min-max) | Peak memory | Output |
|---|---|---|---|
| Stage 1 (`gen2.exe`) | 16.04 s (15.54-17.51 s) | 565.63 MiB | 2,438,656 B (2,381.5 KiB), identical to Gen2 |
| Stage 0 (`l.exe`, Cranelift) | 2.72 s (2.48-3.75 s) | 75.89 MiB | 1,437,696 B (1,404.0 KiB) |

### Run time of the compiled programs

| Program | Stage 1 run (ms): median (min–max) | Stage 0 run (ms): median (min–max) | Stage 1 / Stage 0 | Stage 1 peak (MiB) | Stage 0 peak (MiB) |
|---|---:|---:|---:|---:|---:|
| `fib.l` | **56.0** (55.2–59.0) | **52.7** (50.0–64.6) | 1.06x | 2.20 | 2.19 |
| `fibonacci_recursive.l` | **34.8** (30.6–67.4) | **32.1** (29.6–33.9) | 1.08x | 2.20 | 2.19 |
| `arithmetic_loop.l` | **73.5** (72.5–78.1) | **46.2** (44.9–47.2) | 1.59x | 2.20 | 2.19 |
| `collatz.l` | **2,801.2** (2,784.3–2,841.5) | **540.8** (508.3–580.0) | 5.18x | 2.20 | 2.19 |
| `sum_loop.l` | **4,313.2** (4,168.8–4,356.9) | **912.9** (907.3–1,059.0) | 4.72x | 2.20 | 2.19 |
| `list_index_1m.l` | **119.9** (119.2–121.1) | **86.4** (85.2–92.7) | 1.39x | 9.84 | 9.82 |
| `list_iter_1m.l` | **124.2** (119.5–145.0) | **87.2** (84.2–87.8) | 1.42x | 9.84 | 9.82 |
| `list_search_1m.l` | **172.5** (139.7–186.2) | **92.8** (90.4–94.0) | 1.86x | 10.19 | 11.23 |
| `list_release_100k.l` | **99.5** (93.0–116.4) | **61.8** (60.8–69.5) | 1.61x | 3.19 | 4.00 |
| `list_push_1m.l` | **37.8** (36.9–38.8) | **37.8** (36.8–38.1) | 1.00x | 10.19 | 11.22 |
| `list_text_100k.l` | **424.1** (416.6–445.3) | **58.3** (54.0–109.8) | 7.27x | 395.16 | 9.34 |
| `text_build.l` | **4,362.0** (4,287.1–5,267.8) | **306.5** (268.8–342.3) | 14.23x | 2.22 | 2.20 |

"Stage 1 / Stage 0" is the ratio of medians (above 1 = the Stage 1 executable is slower). Output was identical between both compilers for all 20 programs.

In short: Stage 1 compiles small programs 2.1 to 4.4 times faster and emits smaller executables; the code it generates is within 6-8 % on call-heavy code and
4.7 to 5.2 times slower on tight arithmetic loops, 14 times slower on text building; compiling the compiler takes about 6 times longer and 7.5 times more memory.
