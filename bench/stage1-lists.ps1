param([ValidateRange(1, 21)] [int] $Runs = 3, [string] $Compiler = (Join-Path $PSScriptRoot '../target/x86_64-pc-windows-msvc/debug/l.exe'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'target/stage1-lists-bench'
[IO.Directory]::CreateDirectory($dir) > $null
$front = & (Join-Path $root 'compiler-l/build-sema.ps1') -TraceAlloc -Compiler $Compiler
$source = Join-Path $dir 'lists.l'
$lir = Join-Path $dir 'lists.lir'
$text = [Text.StringBuilder]::new()
[void] $text.AppendLine('fn main() -> Int { var xs: List<Int> = List[]')
for ($i = 0; $i -lt 1000; $i++) { [void] $text.AppendLine("xs.push($i)") }
[void] $text.AppendLine('print(xs.length + xs[999] - 999); return 0 }')
[IO.File]::WriteAllText($source, $text.ToString())

function Measure-Process([string] $file, [string[]] $arguments, [string] $output = '') {
    $samples = @()
    for ($run = 0; $run -le $Runs; $run++) {
        $info = [Diagnostics.ProcessStartInfo]::new($file)
        foreach ($argument in $arguments) { [void] $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.WorkingDirectory = $dir
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $child = [Diagnostics.Process]::Start($info)
        $out = $child.StandardOutput.ReadToEndAsync()
        $err = $child.StandardError.ReadToEndAsync()
        $peak = 0L
        while (!$child.HasExited) {
            $child.Refresh()
            $peak = [Math]::Max($peak, $child.PeakWorkingSet64)
            [void] $child.WaitForExit(3)
        }
        $child.WaitForExit()
        $watch.Stop()
        $stdout = $out.GetAwaiter().GetResult()
        $stderr = $err.GetAwaiter().GetResult()
        if ($child.ExitCode -ne 0) { throw "$file returned $($child.ExitCode): $stderr" }
        if ($output) { [IO.File]::WriteAllText($output, $stdout) }
        if ($run -gt 0) { $samples += [pscustomobject]@{ ms = $watch.Elapsed.TotalMilliseconds; peak_kib = [Math]::Round($peak / 1KB) } }
        $child.Dispose()
    }
    return [pscustomobject]@{
        ms = [Math]::Round((($samples.ms | Sort-Object)[[int][Math]::Floor($Runs / 2)]), 2)
        peak_kib = ($samples.peak_kib | Sort-Object)[[int][Math]::Floor($Runs / 2)]
        stdout = $stdout; stderr = $stderr
    }
}

$check = Measure-Process $front @($source, '--check-ownership')
$emit = Measure-Process $front @($source, '--emit-lir') $lir
$backend = Measure-Process $Compiler @('build-lir', $lir, '--trace-alloc')
$relativeExe = ($backend.stdout -split "`n" | Where-Object { $_ -like 'Build: *' } | Select-Object -First 1).Substring(7).Trim()
$exe = Join-Path $dir $relativeExe
$run = Measure-Process $exe @()
$trace = $run.stderr
$allocs = [regex]::Match($trace, 'allocs=(\d+)').Groups[1].Value
$frees = [regex]::Match($trace, 'frees=(\d+)').Groups[1].Value
if ($allocs -ne $frees -or $trace -notmatch 'heap_ok=1') { throw "Unbalanced list execution: $trace" }
[ordered]@{
    list_elements = 1000; runs = $Runs
    check_ms = $check.ms; emit_ms = $emit.ms; lir_finish_ms_estimate = [Math]::Round($emit.ms - $check.ms, 2)
    backend_ms = $backend.ms; run_ms = $run.ms
    check_peak_kib = $check.peak_kib; emit_peak_kib = $emit.peak_kib; backend_peak_kib = $backend.peak_kib
    lir_bytes = (Get-Item $lir).Length; exe_bytes = (Get-Item $exe).Length
    stage1_allocs = [regex]::Match($emit.stderr, 'allocs=(\d+)').Groups[1].Value
    stage1_frees = [regex]::Match($emit.stderr, 'frees=(\d+)').Groups[1].Value
    stage1_reallocs = [regex]::Match($emit.stderr, 'reallocs=(\d+)').Groups[1].Value
    runtime_allocs = $allocs; runtime_frees = $frees
} | ConvertTo-Json -Compress
