param([ValidateRange(1, 31)] [int] $Runs = 5)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'target/lexer-file-bench'
[IO.Directory]::CreateDirectory($dir) > $null
Push-Location -LiteralPath $root
try {
    & cargo build --bin l --example lexer_stage0
    if ($LASTEXITCODE -ne 0) { throw 'Falló cargo build' }
    $compiler = (Resolve-Path 'target/debug/l.exe').Path
    $stage0 = (Resolve-Path 'target/debug/examples/lexer_stage0.exe').Path
    $parts = 'compiler-l/src/lexer.l', 'compiler-l/src/tokens.l', 'bench/programs/lexer-file-phases.l' |
        ForEach-Object { [IO.File]::ReadAllText((Join-Path $root $_)) }
    [IO.File]::WriteAllText((Join-Path $dir 'profile.l'), ($parts -join [char]10))
    Push-Location -LiteralPath $dir
    try {
        $output = & $compiler build profile.l --backend cranelift --trace-alloc
        if ($LASTEXITCODE -ne 0) { throw 'Falló la compilación de la sonda L' }
        $native = (Resolve-Path (($output | Where-Object { $_ -like 'Build: *' }).Substring(7))).Path
    } finally {
        Pop-Location
    }
} finally {
    Pop-Location
}

function Invoke-LexerSample($exe, $file, [bool] $isNative) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.Arguments = "`"$file`""
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $tokens = [Text.StringBuilder]::new()
        $markers = @{}
        $peak = 0L
        $lines = 0
        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            $elapsed = $clock.Elapsed.TotalMilliseconds
            $lines++
            if ($line.StartsWith('@')) {
                $markers[$line] = $elapsed
            } else {
                [void] $tokens.Append($line).Append([char]10)
            }
            if ($line.StartsWith('@') -or $lines % 64 -eq 1) {
                try {
                    $process.Refresh()
                    if (!$process.HasExited) {
                        $peak = [Math]::Max($peak, $process.PeakWorkingSet64)
                    }
                } catch [InvalidOperationException] { }
            }
        }
        $process.WaitForExit()
        $wall = $clock.Elapsed.TotalMilliseconds
        $diagnostics = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$exe ($($process.ExitCode)): $diagnostics" }
        $stats = @{}
        foreach ($entry in [regex]::Matches($diagnostics, '([a-z0-9_]+)=(\d+)')) {
            $stats[$entry.Groups[1].Value] = [long] $entry.Groups[2].Value
        }
        if ($isNative) {
            if ($markers.Count -ne 3 -or $stats.file_ticks_hz -le 0 -or $stats.heap_ok -ne 1 -or
                $stats.allocs -ne $stats.frees -or $stats.file_opens -ne $stats.file_closes) {
                throw "Traza incompleta o inconsistente: $diagnostics"
            }
            $msPerTick = 1000.0 / $stats.file_ticks_hz
            return @{
                tokens = $tokens.ToString(); wall = $wall; peakKiB = $peak / 1KB
                open = $stats.file_open_ticks * $msPerTick; read = $stats.file_read_ticks * $msPerTick
                utf8 = $stats.file_utf8_ticks * $msPerTick; scan = $markers['@emit'] - $markers['@scan']
                emit = $markers['@end'] - $markers['@emit']; allocs = $stats.allocs
                reallocs = $stats.reallocs; frees = $stats.frees; shortReads = $stats.file_short_reads
            }
        }
        return @{
            tokens = $tokens.ToString(); wall = $wall; peakKiB = $peak / 1KB
            open = $stats.open_ns / 1e6; read = $stats.read_ns / 1e6; utf8 = $stats.utf8_ns / 1e6
            scan = $stats.scan_ns / 1e6; emit = $stats.emit_ns / 1e6
        }
    } finally {
        $process.Dispose()
    }
}

function Get-Median($values) {
    $ordered = @($values | Sort-Object)
    $middle = [int] [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return $ordered[$middle] }
    return ($ordered[$middle - 1] + $ordered[$middle]) / 2
}

foreach ($size in @(1KB, 45KB, 1MB, 10MB)) {
    # Keep the token count within Stage 0's lexer limit for identical inputs.
    $rows = [int] [Math]::Min(512, $size / 128)
    $width = [int] [Math]::Floor($size / $rows)
    $prefix = 'x += 20 //'
    $line = $prefix + ('x' * ($width - $prefix.Length - 1)) + [char]10
    $fixture = Join-Path $dir "entrada $size.l"
    [IO.File]::WriteAllText($fixture, ($line * $rows) + (' ' * ($size - $width * $rows)))
    $measurements = @{ cranelift = @(); stage0 = @() }
    foreach ($iteration in 0..$Runs) {
        $a = Invoke-LexerSample $native $fixture $true
        $b = Invoke-LexerSample $stage0 $fixture $false
        if ($a.tokens -cne $b.tokens) { throw "Tokens diferentes para $fixture" }
        if ($iteration -gt 0) {
            $measurements.cranelift += $a
            $measurements.stage0 += $b
        }
    }
    foreach ($engine in 'cranelift', 'stage0') {
        $samples = $measurements[$engine]
        $result = [ordered] @{ engine = $engine; bytes = $size; tokens = ($samples[0].tokens.Split([char]10).Count - 1) }
        foreach ($key in 'open', 'read', 'utf8', 'scan', 'emit', 'wall', 'peakKiB') {
            $values = $samples | ForEach-Object { $_[$key] } | Where-Object { $key -ne 'peakKiB' -or $_ -gt 0 }
            $result[$key] = if ($null -eq $values) { $null } else { [Math]::Round((Get-Median $values), 3) }
        }
        if ($engine -eq 'cranelift') {
            foreach ($key in 'allocs', 'reallocs', 'frees', 'shortReads') { $result[$key] = $samples[0][$key] }
        }
        $result | ConvertTo-Json -Compress
    }
}
