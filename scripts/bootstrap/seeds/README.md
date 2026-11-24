# Versioned bootstrap seeds

These archives contain the first pinned ELE driver seeds for ELF64 Linux and
PE32+ Windows. CI verifies both the archive checksum and the extracted driver
checksum before execution. `manifest.json` records the format, architecture,
source revision, driver source hash, originating Actions run, artifact IDs and
SHA-256 values.

The ELF64 seed is an x86-64 PIE (`ET_DYN`); the PE seed is an AMD64 PE32+
image. The seed binaries were produced once by the transitional Stage 0 job in Actions
run [45494392548](https://github.com/Joshua-EPR/ELE/actions/runs/45494392548),
whose head was `122c411eff59687f3a33abbe0470137517126b8c`. The manifest records
the committed LF source hash and each runner checkout hash: the Windows PE
checkout used CRLF while the Linux ELF checkout used LF; normalizing CRLF to LF
produces the committed source bytes exactly. The same run passed the Rust-free Gen1' -> Gen2 -> Gen3 bootstrap and native
conformance on both target runners. The binaries are then stored here so future
bootstrap CI consumes fixed hashes instead of regenerating the seed.

To verify and extract one seed:

```powershell
python tools/verify_seed_archive.py pe --output .\seed\ele-seed-pe.exe
```

```sh
python3 tools/verify_seed_archive.py elf --output ./seed/ele-seed-elf
```

The verifier checks the pinned archive and payload hashes, ZIP member names,
image architecture and binary-format identification fields. Native execution
and bootstrap smoke tests on each target runner provide the executable check;
the format parser is not a complete structural ELF/PE validator. Output files
are created exclusively, so existing paths are never overwritten.
