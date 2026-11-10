# Build and execute the ELE-written ELF emitter through the historical Stage 0.
# Output is a Linux x86-64 ELF; execute it in WSL/Linux, never directly on Windows.
param([string]$Output = 'target/native-ele/ele-stack.elf')
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path $root 'target/native-ele-stack'
[IO.Directory]::CreateDirectory($work) > $null
Push-Location $root
try {
    cargo build -p project-l --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build Stage 0' }
} finally { Pop-Location }
$stage0 = Join-Path $root 'target/x86_64-pc-windows-msvc/debug/l.exe'
$source = Join-Path $root 'compiler-l/src/native_stack_aggregate_demo.l'
$dest = [IO.Path]::GetFullPath((Join-Path $root $Output))
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) > $null
Push-Location $work
try {
    $lines = & $stage0 build $source --backend cranelift
    if ($LASTEXITCODE -ne 0) { throw 'ELE fixture cannot be bootstrapped' }
    $line = $lines | Where-Object { $_ -like 'Build: *' } | Select-Object -First 1
    if (-not $line) { throw 'Missing Build: output' }
    $emitter = (Resolve-Path $line.Substring(7)).Path
    & $emitter $dest
    if ($LASTEXITCODE -ne 0) { throw 'ELE emitter failed to write ELF' }
    $bytes = [IO.File]::ReadAllBytes($dest)
    if ($bytes.Length -le 4096 -or $bytes[0] -ne 127 -or $bytes[1] -ne 69 -or $bytes[2] -ne 76 -or $bytes[3] -ne 70) {
        throw 'ELE output is not a valid ELF64 magic image'
    }
    Write-Output "ELE-written stack/layout image: $dest ($($bytes.Length) bytes)"
    Write-Output 'Run in Linux x86-64 / WSL; expected process exit code: 42.'
} finally { Pop-Location }
