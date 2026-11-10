param([ValidateRange(1, 21)] [int] $Runs = 5, [string] $Compiler = (Join-Path $PSScriptRoot '../target/debug/l.exe'))

# Stage 1 drop elaboration workloads. Each group declares an owned Text and
# a struct with two owned fields inside its own scope, moves the Text on a
# branch (reinitialized in even groups, left maybe-moved in odd ones, which
# needs a dynamic flag), moves one field out (partial drop) and every tenth
# group returns early. The `plain` variant has the
# same statements over Int values, so it owns nothing to drop: the
# difference isolates the drop analysis from the rest of the front end.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = & (Join-Path $root 'compiler-l/build-sema.ps1') -TraceAlloc -Compiler $Compiler
$dir = Join-Path $root 'target/stage1-drops-bench'
[IO.Directory]::CreateDirectory($dir) > $null

function Get-Median($values) {
    $ordered = @($values | Sort-Object)
    $middle = [int] [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
    return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

function New-Workload([int] $variables, [bool] $owned) {
    $builder = [Text.StringBuilder]::new()
    if ($owned) {
        [void] $builder.AppendLine('struct P { a: Text, b: Text, n: Int }')
        [void] $builder.AppendLine('fn take(t: Text) -> Int = 1')
        $text = '"x"'
    } else {
        [void] $builder.AppendLine('struct P { a: Int, b: Int, n: Int }')
        [void] $builder.AppendLine('fn take(t: Int) -> Int = 1')
        $text = '1'
    }
    $groups = [int] ($variables / 3)
    $functions = 0
    $done = 0
    while ($done -lt $groups) {
        $count = [Math]::Min(300, $groups - $done)
        [void] $builder.AppendLine("fn work$functions(c: Bool) {")
        for ($i = 0; $i -lt $count; $i++) {
            [void] $builder.AppendLine('  {')
            [void] $builder.AppendLine("    var t$i = $text")
            [void] $builder.AppendLine("    let u$i = P(a: $text, b: $text, n: $i)")
            if ($i % 2 -eq 0) {
                [void] $builder.AppendLine("    if c { take(t$i); t$i = $text }")
            } else {
                [void] $builder.AppendLine("    if c { take(t$i); }")
            }
            [void] $builder.AppendLine("    let m$i = u$i.a")
            if ($i % 10 -eq 9) { [void] $builder.AppendLine('    if c { return }') }
            [void] $builder.AppendLine('  }')
        }
        [void] $builder.AppendLine('}')
        $done += $count
        $functions++
    }
    [void] $builder.AppendLine('fn main() {}')
    return @{ text = $builder.ToString(); functions = $functions }
}

function Measure-Workload([string] $source) {
    $wall = @()
    $peak = @()
    $counts = @{}
    foreach ($run in 0..$Runs) {
        $info = [Diagnostics.ProcessStartInfo]::new($exe)
        $info.Arguments = '"' + $source + '" --check-ownership'
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
            $diagnostics = $stderr.GetAwaiter().GetResult()
            if ($child.ExitCode -ne 0) { throw $diagnostics }
            foreach ($m in [regex]::Matches(($stdout.GetAwaiter().GetResult() + $diagnostics), '(\w+)=(\d+)')) {
                $counts[$m.Groups[1].Value] = [long] $m.Groups[2].Value
            }
            if ($counts.errors -ne 0 -or $counts.heap_ok -ne 1 -or $counts.allocs -ne $counts.frees -or
                $counts.file_opens -ne $counts.file_closes) { throw "Traza incorrecta. $diagnostics" }
            if ($run -gt 0) {
                $wall += $watch.Elapsed.TotalMilliseconds
                $peak += $workingSet / 1KB
            }
        } finally {
            $child.Dispose()
        }
    }
    return @{ ms = [Math]::Round((Get-Median $wall), 2); kib = Get-Median $peak; counts = $counts }
}

foreach ($variables in 100, 1000, 10000) {
    $results = @{}
    foreach ($owned in $true, $false) {
        $work = New-Workload $variables $owned
        $name = if ($owned) { "owned-$variables.l" } else { "plain-$variables.l" }
        $source = Join-Path $dir $name
        [IO.File]::WriteAllText($source, $work.text)
        $results[$owned] = Measure-Workload $source
        $results['functions'] = $work.functions
    }
    $with = $results[$true]
    $without = $results[$false]
    [ordered] @{
        variables = $variables; functions = $results.functions; blocks = $with.counts.blocks
        paths = $with.counts.paths; drops = $with.counts.drops; flags = $with.counts.flags
        drop_ops = $with.counts.drop_ops; drop_iterations = $with.counts.drop_iterations
        total_ms = $with.ms; plain_ms = $without.ms
        drop_ms = [Math]::Round($with.ms - $without.ms, 2)
        peak_kib = $with.kib; plain_peak_kib = $without.kib
        allocs = $with.counts.allocs; frees = $with.counts.frees; reallocs = $with.counts.reallocs
    } | ConvertTo-Json -Compress
}
