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
    # Windows PowerShell 5.1 builds StandardInput from Console.InputEncoding,
    # whose UTF-8 preamble would reach ELEPad as a typed U+FEFF. Start the
    # process with a preamble-free encoding (pwsh 7 already omits it).
    $saved = [Console]::InputEncoding
    try { [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
    try { $p = [Diagnostics.Process]::Start($psi) } finally {
        try { [Console]::InputEncoding = $saved } catch {}
    }
    try {
        $p.StandardInput.BaseStream.Write($keys, 0, $keys.Length)
        $p.StandardInput.Close()
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(15000)) { $p.Kill(); throw 'ELEPad timed out' }
        return [pscustomobject]@{ Exit = $p.ExitCode; Out = $stdout; Error = $stderr }
    } finally { $p.Dispose() }
}

# Exact file content: fails on a byte-order mark (File.ReadAllText would hide
# one), then decodes strict UTF-8.
function Read-Exact([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$path starts with a byte-order mark"
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
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
    if ((Read-Exact $file) -cne ("a" + [char]0xE9 + "b`r`nc")) { throw 'saved UTF-8/CRLF content differs' }
    if (-not $run.Out.Contains([char]27)) { throw 'ANSI renderer did not write stdout' }
    Write-Host 'PASS native ELEPad terminal edit/save/reopen'

    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $unsaved = Run-Bytes $file ([byte[]](0x78))
    if ($unsaved.Exit -ne 33) { throw "unsaved EOF exit $($unsaved.Exit), expected 33" }
    if ((Read-Exact $file) -cne "ab`r`ncd") { throw 'unsaved EOF changed file' }
    Write-Host 'PASS unsaved EOF leaves source unchanged'

    # Ctrl+A, Ctrl+X, Ctrl+Z, Ctrl+Y, Ctrl+Z, 'x', Ctrl+Z, Ctrl+F 'c' Enter,
    # Escape (ESC ESC), 'Z' replaces the found "c", Ctrl+S, Ctrl+Q.
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $keys = [byte[]](0x01,0x18,0x1A,0x19,0x1A,0x78,0x1A,0x06,0x63,0x0D,0x1B,0x1B,0x5A,0x13,0x11)
    $run = Run-Bytes $file $keys
    if ($run.Exit -ne 0) { throw "history/find exit $($run.Exit): $($run.Error)" }
    $saved = (Read-Exact $file)
    if ($saved -cne "ab`r`nZd") { throw "history/find saved '$saved', expected 'ab<CRLF>Zd'" }
    Write-Host 'PASS native ELEPad undo/redo, cut, find and replace-selection'

    # Typing then undoing back to the loaded text is clean: Ctrl+Q quits at once.
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $clean = Run-Bytes $file ([byte[]](0x78,0x79,0x1A,0x11))
    if ($clean.Exit -ne 0) { throw "undo-to-clean exit $($clean.Exit): $($clean.Error)" }
    if ((Read-Exact $file) -cne "ab`r`ncd") { throw 'undo-to-clean changed file' }
    Write-Host 'PASS undo to the loaded state clears the unsaved marker'

    # Ctrl+O: open a second file, edit and save it; the first stays intact.
    $second = Join-Path $work 'second.l'
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    [IO.File]::WriteAllText($second, "one", $utf8)
    $keys = [Collections.Generic.List[byte]]::new()
    $keys.Add(0x0F)
    $keys.AddRange([Text.Encoding]::ASCII.GetBytes($second))
    $keys.AddRange([byte[]](0x0D, 0x78, 0x13, 0x11))
    $open = Run-Bytes $file $keys.ToArray()
    if ($open.Exit -ne 0) { throw "open exit $($open.Exit): $($open.Error)" }
    if ((Read-Exact $second) -cne "xone") { throw "Ctrl+O did not edit and save the opened file; stderr: $($open.Error)" }
    if ((Read-Exact $file) -cne "ab`r`ncd") { throw 'Ctrl+O changed the first file' }
    Write-Host 'PASS Ctrl+O opens, edits and saves another file'

    # Ctrl+O with unsaved changes is refused; nothing is lost or opened.
    $keys = [Collections.Generic.List[byte]]::new()
    $keys.AddRange([byte[]](0x7A, 0x0F))
    $keys.AddRange([Text.Encoding]::ASCII.GetBytes($second))
    $keys.AddRange([byte[]](0x0D, 0x1B, 0x1B, 0x13, 0x11))
    $refused = Run-Bytes $file $keys.ToArray()
    if ($refused.Exit -ne 0) { throw "refused-open exit $($refused.Exit): $($refused.Error)" }
    if ((Read-Exact $file) -cne "zab`r`ncd") { throw 'the unsaved edit was not kept and saved' }
    if ((Read-Exact $second) -cne "xone") { throw 'the refused open touched the other file' }
    Write-Host 'PASS Ctrl+O with unsaved changes is refused'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
