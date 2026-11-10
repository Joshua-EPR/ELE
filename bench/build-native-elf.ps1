# Stage 0 bootstrap: compile the ELE-written backend and ask it to save ELF64.
# This does not prove self-hosting; test with Stage 2/3 is still outstanding.
param([string]$Lir = 'examples/native_int_subset.lir')
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path $root 'target/native-ele'
[IO.Directory]::CreateDirectory($work) > $null
$entry = Join-Path $root 'compiler-l/src/native_lir_demo.l'
$inputPath = (Resolve-Path (Join-Path $root $Lir)).Path
$compiler = Join-Path $root 'target/x86_64-pc-windows-msvc/debug/l.exe'
Push-Location $root
try {
    cargo build -p project-l --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build Stage 0' }
} finally { Pop-Location }
Push-Location $work
try {
    $lines = & $compiler build $entry --backend cranelift
    if ($LASTEXITCODE -ne 0) { throw 'Failed to compile ELE-written backend' }
    $exeName = $lines | Where-Object { $_ -like 'Build: *' } | Select-Object -First 1
    if (-not $exeName) { throw 'Missing Stage 0 Build: output' }
    $exe = (Resolve-Path $exeName.Substring(7)).Path
    $out = Join-Path $work 'ele-generated.elf'
    & $exe $inputPath $out
    if ($LASTEXITCODE -ne 0) { throw 'ELE-written backend failed to write ELF' }
    $data = [IO.File]::ReadAllBytes($out)
    if ($data.Length -lt 4096 -or $data[0] -ne 127 -or $data[1] -ne 69 -or $data[2] -ne 76 -or $data[3] -ne 70) {
        throw 'Invalid ELF64 output'
    }
    Write-Output "Generated ELF64: $out ($($data.Length) bytes)"
    Write-Output 'Use Linux x86-64 (WSL) to run it; expected exit code: 42.'
} finally { Pop-Location }
