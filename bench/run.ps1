# Reproducible benchmarks: rustc backend vs Cranelift backend.
#
# Usage (from the repository root, Windows PowerShell 5.1+):
#   $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
#   cargo build --release
#   powershell -ExecutionPolicy Bypass -File bench\run.ps1 [-Runs 5]
#
# For every program in bench\programs and every backend it measures:
#   - compile time (l build, wall clock, includes linking),
#   - executable size,
#   - run time (median of -Runs executions, wall clock),
#   - peak working set (maximum over the runs),
# and checks that both backends print the same output. Results are written to
# bench\results.md. Nothing is extrapolated: the table only reports what ran.
param([int]$Runs = 5)

$ErrorActionPreference = 'Stop'
# Decimal point independent of the machine's locale.
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
$l = Join-Path $root 'target\release\l.exe'
if (-not (Test-Path $l)) { throw "Falta $l; ejecute 'cargo build --release' primero." }
$work = Join-Path $root 'target\bench'
New-Item -ItemType Directory -Force $work | Out-Null

function Measure-Run([string]$exe) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $peak = 0
    $out = $p.StandardOutput.ReadToEndAsync()
    while (-not $p.HasExited) {
        try { $p.Refresh(); if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 } } catch {}
        Start-Sleep -Milliseconds 5
    }
    $p.WaitForExit()
    $watch.Stop()
    try { if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 } } catch {}
    [pscustomobject]@{ Ms = $watch.Elapsed.TotalMilliseconds; Peak = $peak; Out = $out.Result; Code = $p.ExitCode }
}

$rows = @()
foreach ($program in Get-ChildItem (Join-Path $root 'bench\programs') -Filter *.l) {
    $outputs = @{}
    foreach ($backend in @('rustc', 'cranelift')) {
        $dir = Join-Path $work $backend
        New-Item -ItemType Directory -Force $dir | Out-Null
        Push-Location $dir
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $build = & $l build $program.FullName --backend $backend
            $watch.Stop()
            if ($LASTEXITCODE -ne 0) { throw "build $backend $($program.Name) falló" }
            $exe = Join-Path $dir (($build | Select-String '^Build: (.*)$').Matches[0].Groups[1].Value)
        } finally { Pop-Location }
        $times = @(); $peak = 0
        for ($i = 0; $i -lt $Runs; $i++) {
            $r = Measure-Run $exe
            if ($r.Code -ne 0) { throw "$($program.Name) ($backend) terminó con código $($r.Code)" }
            $times += $r.Ms
            if ($r.Peak -gt $peak) { $peak = $r.Peak }
            $outputs[$backend] = $r.Out
        }
        $sorted = $times | Sort-Object
        # Heap operations (cranelift only): a separate instrumented build, run
        # once; the timed build above is not instrumented.
        $allocs = 'n/d'; $reallocs = 'n/d'; $suspends = 'n/d'
        if ($backend -eq 'cranelift') {
            $tdir = Join-Path $work 'trace'
            New-Item -ItemType Directory -Force $tdir | Out-Null
            Push-Location $tdir
            try {
                $tb = & $l build $program.FullName --backend cranelift --trace-alloc
                if ($LASTEXITCODE -ne 0) { throw "build instrumentado $($program.Name) falló" }
                $texe = Join-Path $tdir (($tb | Select-String '^Build: (.*)$').Matches[0].Groups[1].Value)
            } finally { Pop-Location }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $texe; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $tp = [System.Diagnostics.Process]::Start($psi)
            $null = $tp.StandardOutput.ReadToEndAsync()
            $err = $tp.StandardError.ReadToEnd(); $tp.WaitForExit()
            $m = [regex]::Match($err, 'allocs=(\d+) reallocs=(\d+) frees=(\d+).*suspends=(\d+) heap_ok=(\d)')
            if (-not $m.Success -or $m.Groups[5].Value -ne '1') { throw "$($program.Name): informe de heap inválido: $err" }
            if ($m.Groups[1].Value -ne $m.Groups[3].Value) { throw "$($program.Name): allocs != frees: $err" }
            $allocs = $m.Groups[1].Value; $reallocs = $m.Groups[2].Value; $suspends = $m.Groups[4].Value
        }
        $rows += [pscustomobject]@{
            Allocs     = $allocs
            Reallocs   = $reallocs
            Suspende   = $suspends
            Programa   = $program.BaseName
            Backend    = $backend
            CompilarMs = [math]::Round($watch.Elapsed.TotalMilliseconds)
            Bytes      = (Get-Item $exe).Length
            MedianaMs  = [math]::Round($sorted[[int][math]::Floor($Runs / 2)], 1)
            MinMs      = [math]::Round($sorted[0], 1)
            PicoKiB    = [math]::Round($peak / 1KB)
        }
    }
    if ($outputs['rustc'] -ne $outputs['cranelift']) { throw "$($program.Name): salidas distintas entre backends" }
}

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
$rustc = ((& rustc -vV) | Select-String '^(release|host): ').Line -join ', '
$lines = @(
    '# Resultados de benchmarks',
    '',
    "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm'). CPU: $cpu. Ejecuciones por medida: $Runs.",
    "Backend rustc: -C opt-level=0 (su configuración actual), rustc $rustc. Backend cranelift: opt_level=speed.",
    'Tiempo de compilar incluye enlazado. Pico de memoria: PeakWorkingSet64 muestreado cada 5 ms.',
    'Reservas/realocaciones de heap y suspensiones: build cranelift aparte con --trace-alloc (allocs == frees y heap_ok=1 verificados); n/d en rustc.',
    '',
    '| Programa | Backend | Compilar (ms) | Ejecutable (bytes) | Mediana (ms) | Mínimo (ms) | Pico memoria (KiB) | Reservas | Realocaciones | Suspensiones |',
    '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|'
)
foreach ($r in $rows) {
    $lines += "| $($r.Programa) | $($r.Backend) | $($r.CompilarMs) | $($r.Bytes) | $($r.MedianaMs) | $($r.MinMs) | $($r.PicoKiB) | $($r.Allocs) | $($r.Reallocs) | $($r.Suspende) |"
}
$lines | Set-Content -Encoding utf8 (Join-Path $root 'bench\results.md')
$rows | Format-Table -AutoSize
