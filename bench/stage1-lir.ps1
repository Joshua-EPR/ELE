param([ValidateRange(1, 21)] [int] $Runs = 5, [string] $Compiler = (Join-Path $PSScriptRoot '../target/debug/l.exe'))

# Stage 1 LIR workloads: functions with branches, loops, calls, owned Text
# values (some only maybe moved, so they need drop flags) and struct
# fields. Each workload is measured twice with the same traced Stage 1
# driver:
#   check: `--check-ownership` (front end, ownership, loans, drop plan and
#          the in-pass lowering that records LIR instructions);
#   emit:  `--emit-lir` (the same, plus splicing the drop plan, the LIR
#          verifier and the serialization).
# `emit - check` estimates the LIR finish, verify and write cost; the
# in-pass lowering is part of both and is not isolated (L has no clock).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = & (Join-Path $root 'compiler-l/build-sema.ps1') -TraceAlloc -Compiler $Compiler
$dir = Join-Path $root 'target/stage1-lir-bench'
[IO.Directory]::CreateDirectory($dir) > $null

function Get-Median($values) {
    $ordered = @($values | Sort-Object)
    $middle = [int] [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
    return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

function New-Workload([int] $statements) {
    $builder = [Text.StringBuilder]::new()
    [void] $builder.AppendLine('struct P { a: Text, n: Int }')
    [void] $builder.AppendLine('fn take(t: Text) -> Int = 1')
    [void] $builder.AppendLine('fn step(x: Int) -> Int = x + 1')
    # Each group lowers to about ten LIR instructions.
    $groups = [int] ($statements / 10)
    $functions = 0
    $done = 0
    while ($done -lt $groups) {
        $count = [Math]::Min(100, $groups - $done)
        [void] $builder.AppendLine("fn work$functions(c: Bool) -> Int {")
        [void] $builder.AppendLine('  var sum = 0')
        for ($i = 0; $i -lt $count; $i++) {
            [void] $builder.AppendLine("  var t$i = ""x""")
            [void] $builder.AppendLine("  let p$i = P(a: ""a"", n: $i)")
            [void] $builder.AppendLine("  if c { take(t$i); }")
            [void] $builder.AppendLine("  for k in 0..2 { sum = step(sum) + p$i.n * k }")
            if ($i % 10 -eq 9) { [void] $builder.AppendLine('  if sum > 1000000 { return sum }') }
        }
        [void] $builder.AppendLine('  return sum')
        [void] $builder.AppendLine('}')
        $done += $count
        $functions++
    }
    [void] $builder.AppendLine('fn main() -> Int { return 0 }')
    return @{ text = $builder.ToString(); functions = $functions }
}

function Measure-Run([string] $source, [string] $flag) {
    $wall = @()
    $peak = @()
    $counts = @{}
    $bytes = 0
    foreach ($run in 0..$Runs) {
        $info = [Diagnostics.ProcessStartInfo]::new($exe)
        $info.Arguments = '"' + $source + '" ' + $flag
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $child = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            $workingSet = 0L
            while (!$child.HasExited) {
                try {
                    $child.Refresh()
                    $workingSet = [Math]::Max($workingSet, $child.PeakWorkingSet64)
                } catch [InvalidOperationException] {}
                [void] $child.WaitForExit(3)
            }
            $child.WaitForExit()
            $watch.Stop()
            $out = $stdout.GetAwaiter().GetResult()
            $diagnostics = $stderr.GetAwaiter().GetResult()
            if ($child.ExitCode -ne 0) { throw $diagnostics }
            $bytes = $out.Length
            $text = $diagnostics
            if ($flag -eq '--check-ownership') { $text = $out + $diagnostics }
            foreach ($m in [regex]::Matches($text, '(\w+)=(\d+)')) {
                $counts[$m.Groups[1].Value] = [long] $m.Groups[2].Value
            }
            if ($counts.heap_ok -ne 1 -or $counts.allocs -ne $counts.frees -or
                $counts.file_opens -ne $counts.file_closes) { throw "Traza incorrecta. $diagnostics" }
            if ($run -gt 0) {
                $wall += $watch.Elapsed.TotalMilliseconds
                $peak += $workingSet / 1KB
            }
        } finally {
            $child.Dispose()
        }
    }
    return @{ ms = [Math]::Round((Get-Median $wall), 2); kib = Get-Median $peak; counts = $counts; bytes = $bytes }
}

foreach ($statements in 100, 1000, 10000) {
    $work = New-Workload $statements
    $source = Join-Path $dir "lir-$statements.l"
    [IO.File]::WriteAllText($source, $work.text)
    $check = Measure-Run $source '--check-ownership'
    $emit = Measure-Run $source '--emit-lir'
    [ordered] @{
        target_insts = $statements; functions = $work.functions
        blocks = $emit.counts.blocks; insts = $emit.counts.insts
        drops = $emit.counts.drops; flags = $emit.counts.flags
        lir_bytes = $emit.bytes
        check_ms = $check.ms; emit_ms = $emit.ms
        lir_ms = [Math]::Round($emit.ms - $check.ms, 2)
        check_peak_kib = $check.kib; emit_peak_kib = $emit.kib
        allocs = $emit.counts.allocs; frees = $emit.counts.frees; reallocs = $emit.counts.reallocs
    } | ConvertTo-Json -Compress
}
