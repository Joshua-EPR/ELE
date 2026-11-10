# Windows x64. Build the debug CLI first with cargo build --bin l.
param([ValidateRange(1, 50)][int]$Runs = 7)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$l = Join-Path $root 'target/debug/l.exe'
if (-not (Test-Path $l)) { throw 'Ejecute cargo build --bin l antes del benchmark.' }

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    $sorted[$index]
}

function Build-Program([string]$Dir, [string]$Source, [string]$Backend, [switch]$Trace) {
    Push-Location $Dir
    try {
        $argsList = @('build', $Source, '--backend', $Backend)
        if ($Trace) { $argsList += '--trace-alloc' }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = & $l @argsList
        $watch.Stop()
        if ($LASTEXITCODE -ne 0) { throw "Falló la compilación con $Backend" }
        $relative = ($output | Select-String '^Build: (.*)$').Matches[0].Groups[1].Value
        [pscustomobject]@{ Path = (Join-Path $Dir $relative); Ms = $watch.Elapsed.TotalMilliseconds }
    } finally { Pop-Location }
}

function Measure-Program([string]$Exe, [string]$Expected, [bool]$Latency, [bool]$Native) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($Native) { $info.Environment['PATH'] = '' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $stderr = $proc.StandardError.ReadToEndAsync()
        $lines = [Collections.Generic.List[string]]::new()
        $samples = [Collections.Generic.List[double]]::new()
        $previous = $null
        $peak = 0
        while ($true) {
            $read = $proc.StandardOutput.ReadLineAsync()
            while (-not $read.Wait(1)) {
                $proc.Refresh()
                $peak = [Math]::Max($peak, $proc.PeakWorkingSet64)
            }
            $stamp = $watch.Elapsed.TotalMilliseconds
            $line = $read.Result
            if ($null -eq $line) { break }
            $proc.Refresh()
            $peak = [Math]::Max($peak, $proc.PeakWorkingSet64)
            $lines.Add($line)
            if ($Latency -and $null -ne $previous) { $samples.Add($stamp - $previous) }
            $previous = $stamp
        }
        $proc.WaitForExit()
        $watch.Stop()
        if ($proc.ExitCode -ne 0 -or ($lines -join ',') -ne $Expected) {
            throw "Ejecución incorrecta de $Exe. Código $($proc.ExitCode). $($stderr.Result)"
        }
        $cpu = $proc.TotalProcessorTime.TotalMilliseconds
        [pscustomobject]@{
            Ms = $watch.Elapsed.TotalMilliseconds
            CpuMs = $cpu
            PeakKiB = $peak / 1KB
            Samples = $samples
            Stderr = $stderr.Result.Trim()
        }
    } finally { $proc.Dispose() }
}

$cases = @(
    @{ Name = 'carga'; Source = 'bench/programs/async_timers.l'; Expected = '10,100,1000,10000'; Latency = $false }
    @{ Name = 'latencia'; Source = 'bench/programs/async_timer_latency.l'; Expected = (@(-1) + @(0..99)) -join ','; Latency = $true }
)
# The test suite materializes these fixtures in target/timers.
foreach ($fixture in @(
    @{ Name = 'cancelacion'; Source = 'target/timers/cancelacion/main.l'; Expected = 'cancelar,fin'; Latency = $false }
    @{ Name = 'cola_activa'; Source = 'target/timers/cola_activa/main.l'; Expected = 'vence,fin de la cola'; Latency = $false }
)) {
    if (Test-Path (Join-Path $root $fixture.Source)) { $cases += $fixture }
}

foreach ($case in $cases) {
    foreach ($backend in @('cranelift', 'rustc')) {
        $source = Join-Path $root $case.Source
        $dir = Join-Path $root "target/bench-timers/$($case.Name)/$backend"
        New-Item -ItemType Directory -Force $dir | Out-Null
        $builds = @(for ($i = 0; $i -lt $Runs; $i++) { Build-Program $dir $source $backend })
        $native = $backend -eq 'cranelift'
        $measurements = @(for ($i = 0; $i -lt $Runs; $i++) {
            $run = Measure-Program $builds[-1].Path $case.Expected $case.Latency $native
            if ($run.Stderr) { throw $run.Stderr }
            $run
        })
        $result = [ordered]@{
            workload = $case.Name
            backend = $backend
            build_ms = Get-Percentile $builds.Ms 0.5
            wall_ms = Get-Percentile $measurements.Ms 0.5
            cpu_ms = Get-Percentile $measurements.CpuMs 0.5
            peak_kib = ($measurements.PeakKiB | Measure-Object -Maximum).Maximum
        }
        if ($case.Latency) {
            $samples = @(foreach ($run in $measurements) { $run.Samples })
            $result.samples = $samples.Count
            $result.p50_ms = Get-Percentile $samples 0.50
            $result.p95_ms = Get-Percentile $samples 0.95
            $result.p99_ms = Get-Percentile $samples 0.99
        }
        if ($native) {
            $trace = Build-Program $dir $source $backend -Trace
            $result.trace = (Measure-Program $trace.Path $case.Expected $false $true).Stderr
        }
        [pscustomobject]$result | ConvertTo-Json -Compress
    }
}
