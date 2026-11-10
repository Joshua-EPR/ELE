# Build Stage-0 and compile the ELE-written native backend's struct fixtures.
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    cargo test -p project-l --test native_struct_cfg_l --target x86_64-pc-windows-msvc -- --nocapture
    if ($LASTEXITCODE -ne 0) { throw 'Error en las pruebas de structs nativos de ELE' }
} finally { Pop-Location }
