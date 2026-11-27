# Compilador usado por el kernel

`ele.exe` es el driver de ELE escrito en ELE (`compiler-l/src/main_driver.l`,
versión 0.3.0), compilado **sin Stage 0** desde la semilla PE fijada en
`scripts/bootstrap/seeds/`:

```
semilla (sha256 eb98a908…) → Gen1' → Gen2 → Gen3
Gen2 == Gen3 bit a bit (punto fijo)
sha256(ele.exe) = cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218
```

- Fuente: `main` `758270d` + rama `feat/compiler-crc32c`: intrínsecos
  `crc32c64` y `crc32c8` (SSE4.2), además de los de sistema, datos estáticos,
  stubs de interrupción y SSE empaquetado.
- Generado el 2026-11-26 con `scripts/bootstrap/ele_seed_bootstrap.ps1`.
- `provenance.json` es el registro completo de esa ejecución.
- Versiones anteriores: anterior a CRC32C → `1d229f95…8ff67`; PR #187 → `75a07f21…30aa2`; `main` `3d54d99` → `e06e500d…77ca8`; `main` `5ee1286` → `8f11ed74…b17f6`.

Uso (el script `herramientas/construir.ps1` lo hace todo):

```powershell
.\kernel\compilador\ele.exe build kmain.l --target kernel -o kernel.elf
```

`.gitignore` excluye los `.exe` y `provenance.json` (rutas locales): se
regeneran con el bootstrap.
