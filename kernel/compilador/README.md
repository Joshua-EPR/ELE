# Compilador usado por el kernel

`ele.exe` es el driver de ELE escrito en ELE (`compiler-l/src/main_driver.l`,
versión 0.3.0), compilado **sin Stage 0** desde la semilla PE fijada en
`scripts/bootstrap/seeds/`:

```
semilla (sha256 eb98a908…) → Gen1' → Gen2 → Gen3
Gen2 == Gen3 bit a bit (punto fijo)
sha256(ele.exe) = 1d229f958846b5e606565bfb88a2db098b12f05f902982d31c5851505228ff67
```

- Fuente: `main` `9d3a42d` (PR #187) + rama
  `feat/kernel-static-data-interrupts`: datos estáticos (`reservar`,
  `datos64`, `cadena`), intrínsecos de sistema, stubs de interrupción y SSE
  empaquetado.
- Generado el 2026-11-26 con `scripts/bootstrap/ele_seed_bootstrap.ps1`.
- `provenance.json` es el registro completo de esa ejecución.
- Versiones anteriores: PR #187 → `75a07f21…30aa2`; `main` `3d54d99` → `e06e500d…77ca8`; `main` `5ee1286` → `8f11ed74…b17f6`.

Uso (el script `herramientas/construir.ps1` lo hace todo):

```powershell
.\kernel\compilador\ele.exe build kmain.l --target kernel -o kernel.elf
```

`.gitignore` excluye los `.exe` y `provenance.json` (rutas locales): se
regeneran con el bootstrap.
