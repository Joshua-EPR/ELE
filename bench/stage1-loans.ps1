param([ValidateRange(1, 21)] [int] $Runs = 5, [string] $Compiler = (Join-Path $PSScriptRoot '../target/debug/l.exe'))

# Stage 1 borrow checker workloads. Each group creates five loans: a shared
# borrow, a borrowed call result (argument loan + result node), a mutable
# borrow that starts after the last shared use (NLL) and a mutable reborrow.
# Groups sit inside loops and branches. The `copies` variant keeps the same
# statements without borrows, so the difference isolates the loan analysis.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = & (Join-Path $root 'compiler-l/build-sema.ps1') -TraceAlloc -Compiler $Compiler
$dir = Join-Path $root 'target/stage1-loans-bench'
[IO.Directory]::CreateDirectory($dir) > $null

function Get-Median($values) {
    $ordered = @($values | Sort-Object)
    $middle = [int] [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
    return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

function New-Workload([int] $loans, [bool] $borrow) {
    $builder = [Text.StringBuilder]::new()
    [void] $builder.AppendLine('fn pick(n: &Int) -> &Int { return n }')
    [void] $builder.AppendLine('fn same(n: Int) -> Int = n')
    $groups = [int] ($loans / 5)
    $functions = 0
    $done = 0
    while ($done -lt $groups) {
        $count = [Math]::Min(200, $groups - $done)
        [void] $builder.AppendLine("fn work$functions() -> Int {")
        [void] $builder.AppendLine('  var sum = 0')
        [void] $builder.AppendLine('  for k in 0..2 {')
        for ($i = 0; $i -lt $count; $i++) {
            if ($i % 50 -eq 0) { [void] $builder.AppendLine('  if sum >= 0 {') }
            [void] $builder.AppendLine("    var v$i = $i")
            if ($borrow) {
                [void] $builder.AppendLine("    let a$i = &v$i")
                [void] $builder.AppendLine("    let r$i = pick(&v$i)")
                [void] $builder.AppendLine("    sum += a$i + r$i")
                [void] $builder.AppendLine("    let m$i = &mut v$i")
                [void] $builder.AppendLine("    let b$i = &mut m$i")
                [void] $builder.AppendLine("    b$i = sum")
            } else {
                [void] $builder.AppendLine("    let a$i = v$i")
                [void] $builder.AppendLine("    let r$i = same(v$i)")
                [void] $builder.AppendLine("    sum += a$i + r$i")
                [void] $builder.AppendLine("    var m$i = v$i")
                [void] $builder.AppendLine("    var b$i = m$i")
                [void] $builder.AppendLine("    b$i = sum")
            }
            if ($i % 50 -eq 49 -or $i -eq $count - 1) { [void] $builder.AppendLine('  }') }
        }
        [void] $builder.AppendLine('    if k < 1 { continue }')
        [void] $builder.AppendLine('    break')
        [void] $builder.AppendLine('  }')
        [void] $builder.AppendLine('  return sum')
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
        # Arguments (not ArgumentList) keeps Windows PowerShell 5.1 working.
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

foreach ($loans in 100, 1000, 10000) {
    $results = @{}
    foreach ($borrow in $true, $false) {
        $work = New-Workload $loans $borrow
        $name = if ($borrow) { "loans-$loans.l" } else { "copies-$loans.l" }
        $source = Join-Path $dir $name
        [IO.File]::WriteAllText($source, $work.text)
        $results[$borrow] = Measure-Workload $source
        $results['functions'] = $work.functions
    }
    $with = $results[$true]
    $without = $results[$false]
    [ordered] @{
        loans = $with.counts.loans; functions = $results.functions; blocks = $with.counts.blocks
        paths = $with.counts.paths; ownership_iterations = $with.counts.iterations
        loan_iterations = $with.counts.loan_iterations
        total_ms = $with.ms; copies_ms = $without.ms
        loan_ms = [Math]::Round($with.ms - $without.ms, 2)
        peak_kib = $with.kib; copies_peak_kib = $without.kib
        allocs = $with.counts.allocs; frees = $with.counts.frees; reallocs = $with.counts.reallocs
    } | ConvertTo-Json -Compress
}
