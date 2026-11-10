# Validate ELE-written x86-64/ELF64 generator against independent expected bytes.
# Requires Stage 0 bootstrap on Windows/MSVC; does not claim self-hosting.
# Also validates writeBytes binary persistence, invalid bytes, and ELF output.
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    cargo test -p project-l --test native_encoder_l --target x86_64-pc-windows-msvc -- --nocapture
    if ($LASTEXITCODE -ne 0) { throw "Error en pruebas del encoder nativo ELE" }
} finally {
    Pop-Location
}
