# Generate ELF64 using the backend written in ELE, compiled by temporary Stage0.
param([string]$Output = 'target/native-ele/ele-struct.elf')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    .\bench\build-native-cfg.ps1 -Lir 'examples/native_cfg_struct_copy.lir' -Output $Output
    if ($LASTEXITCODE -ne 0) { throw 'Error al emitir ELF64 con structs' }
    Write-Output 'En Linux x86-64/WSL: chmod +x target/native-ele/ele-struct.elf; ./target/native-ele/ele-struct.elf; echo $? (esperado 42)'
} finally { Pop-Location }
