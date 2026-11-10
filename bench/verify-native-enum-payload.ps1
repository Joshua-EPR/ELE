$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo test --target x86_64-pc-windows-msvc -p project-l --test native_enum_payload_l -- --nocapture
if ($LASTEXITCODE -ne 0) { throw 'Fallo en pruebas ELE de payloads de enum' }
Write-Output 'Windows: ELF64 generado; comprobar ejecucion en Linux x86-64 o WSL.'
