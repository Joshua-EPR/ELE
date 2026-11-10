# Compare native heap/region lists at identical lengths, and a fixed array at
# 1000 elements. Times include process startup and scope destruction.
param(
    [int]$Runs = 5,
    [int[]]$Sizes = @(1000, 100000, 1000000),
    [string]$Compiler = 'target/debug/l.exe'
)

$ErrorActionPreference = 'Stop'
if ($Runs -lt 1 -or ($Sizes | Where-Object { $_ -lt 1 })) { throw 'Runs y Sizes deben ser positivos.' }
$compilerPath = (Resolve-Path -LiteralPath $Compiler).Path
$work = Join-Path (Split-Path -Parent $PSScriptRoot) 'target/bench-regional'
New-Item -ItemType Directory -Force $work | Out-Null

function Build([string]$file, [switch]$Trace) {
    $flags = @('build', $file, '--backend', 'cranelift')
    if ($Trace) { $flags += '--trace-alloc' }
    $output = & $compilerPath @flags
    if ($LASTEXITCODE -ne 0) { throw "No se pudo compilar $file" }
    $path = $output | Select-String '^Build: (.*)$'
    Join-Path $work $path.Matches[0].Groups[1].Value
}

function Measure-Executable([string]$path) {
    $psi = [Diagnostics.ProcessStartInfo]::new($path)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $peak = 0
        while (-not $proc.WaitForExit(1)) {
            $proc.Refresh()
            try { $peak = [Math]::Max($peak, $proc.PeakWorkingSet64) } catch {}
        }
        $watch.Stop()
        try { $peak = [Math]::Max($peak, $proc.PeakWorkingSet64) } catch {}
        if ($proc.ExitCode -ne 0) { throw "$path terminó con código $($proc.ExitCode): $($stderr.Result)" }
        [pscustomobject]@{ Milliseconds = $watch.Elapsed.TotalMilliseconds
            PeakKiB = if ($peak -gt 0) { [math]::Round($peak / 1KB) } else { $null }
            Stdout = $stdout.Result.Trim()
            Stderr = $stderr.Result.Trim() }
    } finally { $proc.Dispose() }
}

Push-Location $work
try {
    $rows = foreach ($n in $Sizes) {
        foreach ($kind in @('heap', 'region', 'array')) {
            if ($kind -eq 'array' -and $n -gt 1000) { continue }
            foreach ($workload in @('insert', 'iterate')) {
                if ($kind -eq 'array' -and $workload -eq 'insert') { continue }
                $begin = switch ($kind) {
                    'heap' { 'var xs: List<Int> = List[]' }
                    'region' { "region r {`n var xs = r.list<Int>()" }
                    'array' { "let xs = [$((0..($n - 1)) -join ',')]" }
                }
                $fill = if ($kind -ne 'array') { "for i in 0..${n} { xs.push(i) }" }
                $end = if ($kind -eq 'region') { '}' }
                $body = if ($workload -eq 'iterate') {
                    "var sum = 0`n for x in xs { sum += x }`n print(sum)"
                } else { 'print(xs.length)' }
                $expected = if ($workload -eq 'iterate') { [long]$n * ($n - 1) / 2 } else { $n }
                $file = "$kind-$workload-$n.l"
                Set-Content -LiteralPath $file -Value "fn main() {`n $begin`n $fill`n $body`n $end`n}" -Encoding ascii
                $exe = Build $file
                $size = (Get-Item -LiteralPath $exe).Length
                $samples = for ($i = 0; $i -lt $Runs; $i++) {
                    $sample = Measure-Executable $exe
                    if ($sample.Stdout -ne "$expected" -or $sample.Stderr) { throw "Salida inesperada de $file" }
                    $sample
                }
                $times = @($samples.Milliseconds | Sort-Object)
                $traced = Measure-Executable (Build $file -Trace)
                if ($traced.Stdout -ne "$expected") { throw "Salida instrumentada inesperada de $file" }
                $stats = @{}
                foreach ($m in [regex]::Matches($traced.Stderr, '(\w+)=(\d+)')) {
                    $stats[$m.Groups[1].Value] = [long]$m.Groups[2].Value
                }
                if ($stats.heap_ok -ne 1 -or $stats.allocs -ne $stats.frees) { throw $traced.Stderr }
                [pscustomobject]@{ Kind = $kind; Workload = $workload; N = $n
                    MedianMs = [math]::Round($times[[int][math]::Floor($Runs / 2)], 2)
                    MinMs = [math]::Round($times[0], 2); MaxMs = [math]::Round($times[-1], 2)
                    PeakKiB = ($samples.PeakKiB | Measure-Object -Maximum).Maximum
                    ExeBytes = $size; Allocs = $stats.allocs; Reallocs = $stats.reallocs; Frees = $stats.frees
                    RegionAllocs = $stats.region_allocs; RegionBytes = $stats.region_bytes
                    RetiredBytes = $stats.region_retired }
            }
        }
    }
    $rows | Export-Csv -NoTypeInformation -LiteralPath 'results.csv'
    $rows | Format-Table -AutoSize
} finally { Pop-Location }
