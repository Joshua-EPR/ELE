param([ValidateRange(1, 21)] [int] $Runs = 5)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = & (Join-Path $root 'compiler-l/build-sema.ps1') -TraceAlloc
$dir = Join-Path $root 'target/stage1-cfg-bench'
[IO.Directory]::CreateDirectory($dir) > $null

function Get-Median($values) {
    $ordered = @($values | Sort-Object)
    $middle = [int] [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
    return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

foreach ($bindings in 100, 1000, 10000) {
    $builder = [Text.StringBuilder]::new()
    $remaining = $bindings
    $functions = 0
    while ($remaining -gt 0) {
        $count = [Math]::Min(1000, $remaining)
        [void] $builder.AppendLine("fn work$functions() -> Int {")
        for ($i = 0; $i -lt $count; $i++) {
            [void] $builder.AppendLine("  let n$i = $i")
        }
        [void] $builder.AppendLine('  var sum = 0')
        [void] $builder.AppendLine('  for i in 0..2 {')
        [void] $builder.AppendLine('    while sum < 2 { sum += 1 }')
        [void] $builder.AppendLine('    if i < 1 { continue }')
        [void] $builder.AppendLine('    break')
        [void] $builder.AppendLine('  }')
        [void] $builder.AppendLine("  return n$($count - 1) + sum")
        [void] $builder.AppendLine('}')
        $remaining -= $count
        $functions++
    }
    [void] $builder.AppendLine('fn main() {}')
    $source = Join-Path $dir "$bindings.l"
    [IO.File]::WriteAllText($source, $builder.ToString())
    $wall = @()
    $peak = @()
    $counts = @{}
    foreach ($run in 0..$Runs) {
        $info = [Diagnostics.ProcessStartInfo]::new($exe)
        $info.ArgumentList.Add($source)
        $info.ArgumentList.Add('--check-ownership')
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
    [ordered] @{
        bindings = $bindings; functions = $functions; blocks = $counts.blocks
        edges = $counts.edges; paths = $counts.paths; iterations = $counts.iterations
        total_ms = [Math]::Round((Get-Median $wall), 2)
        peak_kib = Get-Median $peak
        allocs = $counts.allocs; frees = $counts.frees; reallocs = $counts.reallocs
    } | ConvertTo-Json -Compress
}
