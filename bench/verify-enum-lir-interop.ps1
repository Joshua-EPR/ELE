$ErrorActionPreference = "Stop"
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
$target = "x86_64-pc-windows-msvc"

cargo test -p project-l --test lir_payload_protocol --target $target
if ($LASTEXITCODE -ne 0) { throw "Falló el protocolo payload de ELE-LIR" }

cargo test -p project-l --test native_enum_stage1_l --target $target
if ($LASTEXITCODE -ne 0) { throw "Falló Stage 1 -> LIR -> ELF64" }

Write-Host "Pruebas de interoperabilidad ejecutadas correctamente (ELF generado; ejecución requiere Linux/WSL)."
