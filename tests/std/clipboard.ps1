param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$driver = (Resolve-Path $Ele).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('ele-clipboard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$write = Join-Path $work 'write.exe'
$read = Join-Path $work 'read.exe'
$input = Join-Path $work 'input.txt'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$oldClipboard = Get-Clipboard -Raw -ErrorAction SilentlyContinue
try {
    & $driver build (Join-Path $root 'tests/std/clipboard_write.l') --lib $root --target pe --output $write
    if ($LASTEXITCODE -ne 0) { throw 'write build failed' }
    & $driver build (Join-Path $root 'tests/std/clipboard_read.l') --lib $root --target pe --output $read
    if ($LASTEXITCODE -ne 0) { throw 'read build failed' }

    function Read-EleClipboard {
        $psi = [Diagnostics.ProcessStartInfo]::new($read)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $stream = [IO.MemoryStream]::new()
        $p.StandardOutput.BaseStream.CopyTo($stream)
        $errorText = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "ELE clipboard read failed: $errorText" }
        return $utf8.GetString($stream.ToArray())
    }

    $cases = @(
        '',
        'ASCII only',
        'áéíóú ñ Ç',
        '😀 🧪 👩‍💻',
        '漢字 العربية हिन्दी',
        "first`r`nsecond`nthird",
        ('á😀漢字' * 40000)
    )
    foreach ($case in $cases) {
        [IO.File]::WriteAllText($input, $case, $utf8)
        & $write $input
        if ($LASTEXITCODE -ne 0) { throw "ELE clipboard write failed for length $($case.Length)" }
        $external = Get-Clipboard -Raw
        if ($null -eq $external) { $external = '' }
        if ($external -cne $case) { throw "ELE -> PowerShell mismatch for length $($case.Length)" }
        $inside = Read-EleClipboard
        if ($inside -cne $case) { throw "ELE round trip mismatch for length $($case.Length)" }
        if ($case.Length -gt 0) {
            Set-Clipboard -Value $case
            $inside = Read-EleClipboard
            if ($inside -cne $case) { throw "PowerShell -> ELE mismatch for length $($case.Length)" }
            if ((Get-Clipboard -Raw) -cne $case) { throw 'ELE read changed the clipboard' }
        }
    }
    'clipboard-matrix-ok'
} finally {
    if ($null -ne $oldClipboard) { Set-Clipboard -Value $oldClipboard }
    Remove-Item -LiteralPath $work -Recurse -Force
}
