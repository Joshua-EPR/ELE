# Benchmark Methodology & Statistical Rigor

This document defines the statistical and experimental protocols used to evaluate the **ELE Programming Language**.

---

## 1. Experimental Integrity Principles

1. **No Simulated Data:** All numbers reported in the ELE documentation, tables, and charts are collected from physical or virtualized CPU executions on real hardware.
2. **Deterministic Outputs:** Every runtime benchmark must verify exact standard output match against expected mathematical constants before the timing sample is accepted.
3. **Transparent Comparison:** No unfavorable cases are concealed. Comparisons with mature optimizing compilers (Rust, GCC) clearly distinguish between unoptimized baseline emission and LLVM/GCC SSA optimization passes.
4. **Separation of Concerns:** Compilation latency, compiler peak memory, binary footprint, and runtime latency are reported independently.

---

## 2. Statistical Metrics & Sampling

For each workload:
- **Warmup:** 1 untimed iteration is executed immediately prior to measurement to ensure operating system filesystem page caches and CPU branch predictors are populated.
- **Timed Iterations:** 10 consecutive executions are recorded (5 executions for large compiler sources exceeding 70,000 LIR lines).
- **Statistical Aggregation:**
  - **Median:** Selected as the primary metric of central tendency because it is robust against transient OS thread preemption and background interrupts.
  - **Spread:** Minimum, maximum, and sample standard deviation are recorded for every series.

$$\text{Median}(T) = \begin{cases} T_{(n+1)/2} & \text{if } n \text{ is odd} \\ \frac{T_{n/2} + T_{(n/2)+1}}{2} & \text{if } n \text{ is even} \end{cases}$$

---

## 3. Memory Measurement via Kernel Accounting

Traditional process polling (sampling RSS every 10 ms) misses transient allocation spikes in short-lived processes. ELE employs continuous kernel-level accounting:

- **Windows x86-64:**
  The benchmark runner creates a dedicated Windows Job Object (`CreateJobObjectW`) and assigns the compiler process (`AssignProcessToJobObject`). Upon termination, `QueryInformationJobObject` with `JobObjectExtendedLimitInformation` (class 9) extracts the exact kernel peak working set:
  ```c
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakProcessMemoryUsed
  ```
  This captures 100% of physical and committed memory throughout the entire execution.
- **Linux x86-64:**
  Process resident memory is collected via Linux kernel resource tracking using `getrusage(RUSAGE_CHILDREN).ru_maxrss` and `/usr/bin/time -v`.

---

## 4. Hardware & Environment Disclosure

All benchmarks recorded in this suite were executed in the following environment:
- **Processor:** Intel x86-64 (4 logical cores / AVX2 supported)
- **Host OS:** Windows 10 (Build 19044) x86-64
- **Linux Subsystem:** Ubuntu 24.04 LTS on WSL2 (Kernel 5.15)
- **Rust Compiler:** `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- **C Compiler:** `gcc (Ubuntu 9.4.0-1ubuntu1~20.04.2) 9.4.0`
- **ELE Compiler:** Autonomous driver v0.3.0 (Commit `33b4a3f4879313c26050920f3441d6eab953e789` / `31add1b`)
