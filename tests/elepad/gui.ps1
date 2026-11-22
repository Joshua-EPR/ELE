# End-to-end test of the window ELEPad (Windows): the real executable edits
# and saves a file through window messages posted from outside, and closing
# with unsaved changes needs a second request.
# Usage: ./tests/elepad/gui.ps1 -Ele <autonomous main_driver.exe>
param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$elePath = (Resolve-Path $Ele).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('elepad-gui-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$exe = Join-Path $work 'elepad-gui.exe'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EleGuiDriver {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
}
'@

function Start-Editor([string]$file) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.Arguments = '"' + $file + '"'
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $title = 'ELEPad - ' + $file
    for ($i = 0; $i -lt 200; $i++) {
        $hwnd = [EleGuiDriver]::FindWindowW('ELEWindow', $title)
        if ($hwnd -ne [IntPtr]::Zero) { return @($p, $hwnd) }
        if ($p.HasExited) { throw "ELEPad exited early with $($p.ExitCode)" }
        Start-Sleep -Milliseconds 25
    }
    $p.Kill()
    throw 'ELEPad window not found'
}

function Post($hwnd, [uint32]$msg, [long]$wp) {
    if (-not [EleGuiDriver]::PostMessageW($hwnd, $msg, [IntPtr]$wp, [IntPtr]::Zero)) { throw "PostMessageW $msg failed" }
}

function Wait-Content([string]$file, [string]$expected) {
    for ($i = 0; $i -lt 200; $i++) {
        if ([IO.File]::ReadAllText($file, $utf8) -ceq $expected) { return }
        Start-Sleep -Milliseconds 25
    }
    throw "file content stayed '$([IO.File]::ReadAllText($file, $utf8))'"
}

$utf8 = [Text.UTF8Encoding]::new($false)
$WM_KEYDOWN = 256; $WM_CHAR = 258; $WM_CLOSE = 16; $VK_END = 35
try {
    & $elePath build (Join-Path $root 'apps/elepad/src/gui.l') --lib $root --target pe --output $exe | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw 'ELEPad GUI build failed' }
    $file = Join-Path $work 'sample.l'
    $edited = "ab" + [char]0xE9 + "`r`ncd"

    # End, é, Ctrl+S (the WM_CHAR 19 a real Ctrl+S produces), then close.
    [IO.File]::WriteAllText($file, "ab`r`ncd", $utf8)
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_KEYDOWN $VK_END
    Post $hwnd $WM_CHAR 233
    Post $hwnd $WM_CHAR 19
    Wait-Content $file $edited
    Post $hwnd $WM_CLOSE 0
    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'ELEPad did not close after saving' }
    if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode) after save" }
    Write-Host 'PASS window ELEPad edit/save/close'

    # Unsaved change: the first close is refused, the second discards it.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Post $hwnd $WM_CLOSE 0
    if ($p.WaitForExit(800)) { throw "ELEPad closed with unsaved changes (exit $($p.ExitCode))" }
    Post $hwnd $WM_CLOSE 0
    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'ELEPad ignored the second close' }
    if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode) after discarding" }
    if ([IO.File]::ReadAllText($file, $utf8) -cne $edited) { throw 'discarded change reached the file' }
    Write-Host 'PASS unsaved change needs a second close and is discarded'

    # Undo back to the saved text is clean: one close is enough.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 113
    Post $hwnd $WM_CHAR 26
    Post $hwnd $WM_CLOSE 0
    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'ELEPad stayed open after undo to the saved text' }
    if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode) after undo" }
    Write-Host 'PASS undo to the saved text closes at once'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
