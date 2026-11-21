# Native ELEPad terminal integration over redirected console events.
# Usage: ./tests/elepad/terminal.ps1 -Ele <autonomous main_driver.exe>
param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$elePath = (Resolve-Path $Ele).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('elepad-terminal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$exe = Join-Path $work 'elepad-terminal.exe'

function Run-Bytes([string]$file, [byte[]]$keys) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.Arguments = '"' + $file + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.BaseStream.Write($keys, 0, $keys.Length)
        $p.StandardInput.Close()
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(15000)) { $p.Kill(); throw 'ELEPad timed out' }
        return [pscustomobject]@{ Exit = $p.ExitCode; Out = $stdout; Error = $stderr }
    } finally { $p.Dispose() }
}

try {
    & $elePath build (Join-Path $root 'apps/elepad/src/terminal.l') --lib $root --target pe --output $exe | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw 'ELEPad terminal build failed' }
    $file = Join-Path $work 'sample.l'
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)

    # Right, U+00E9, Down, Backspace, Ctrl+S, Ctrl+Q.
    $keys = [byte[]](0x1B,0x5B,0x43,0xC3,0xA9,0x1B,0x5B,0x42,0x7F,0x13,0x11)
    $run = Run-Bytes $file $keys
    if ($run.Exit -ne 0) { throw "edit/save/quit exit $($run.Exit): $($run.Error)" }
    if ([IO.File]::ReadAllText($file, $utf8) -cne ("a" + [char]0xE9 + "b`r`nc")) { throw 'saved UTF-8/CRLF content differs' }
    if (-not $run.Out.Contains([char]27)) { throw 'ANSI renderer did not write stdout' }
    Write-Host 'PASS native ELEPad terminal edit/save/reopen'

    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $unsaved = Run-Bytes $file ([byte[]](0x78))
    if ($unsaved.Exit -ne 33) { throw "unsaved EOF exit $($unsaved.Exit), expected 33" }
    if ([IO.File]::ReadAllText($file, $utf8) -cne "ab`r`ncd") { throw 'unsaved EOF changed file' }
    Write-Host 'PASS unsaved EOF leaves source unchanged'

    # Ctrl+A, Ctrl+X, Ctrl+Z, Ctrl+Y, Ctrl+Z, 'x', Ctrl+Z, Ctrl+F 'c' Enter,
    # Escape (ESC ESC), 'Z' replaces the found "c", Ctrl+S, Ctrl+Q.
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $keys = [byte[]](0x01,0x18,0x1A,0x19,0x1A,0x78,0x1A,0x06,0x63,0x0D,0x1B,0x1B,0x5A,0x13,0x11)
    $run = Run-Bytes $file $keys
    if ($run.Exit -ne 0) { throw "history/find exit $($run.Exit): $($run.Error)" }
    $saved = [IO.File]::ReadAllText($file, $utf8)
    if ($saved -cne "ab`r`nZd") { throw "history/find saved '$saved', expected 'ab<CRLF>Zd'" }
    Write-Host 'PASS native ELEPad undo/redo, cut, find and replace-selection'

    # Typing then undoing back to the loaded text is clean: Ctrl+Q quits at once.
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $clean = Run-Bytes $file ([byte[]](0x78,0x79,0x1A,0x11))
    if ($clean.Exit -ne 0) { throw "undo-to-clean exit $($clean.Exit): $($clean.Error)" }
    if ([IO.File]::ReadAllText($file, $utf8) -cne "ab`r`ncd") { throw 'undo-to-clean changed file' }
    Write-Host 'PASS undo to the loaded state clears the unsaved marker'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
