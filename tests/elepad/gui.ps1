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
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
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

function Send-Key($hwnd, [uint32]$msg, [long]$wp, [long]$lp = 0) {
    # SendMessage delivers the key event without TranslateMessage adding a
    # second synthetic character. WM_CHAR is posted explicitly below.
    [void][EleGuiDriver]::SendMessageW($hwnd, $msg, [IntPtr]$wp, [IntPtr]$lp)
}

# A sent message overtakes every posted one. Let the editor consume what was
# posted before sending a release, so it arrives after it as on a keyboard.
function Settle { Start-Sleep -Milliseconds 200 }

function Same-Content([string]$file, [string]$expected) {
    $actual = [IO.File]::ReadAllBytes($file)
    $wanted = $utf8.GetBytes($expected)
    if ($actual.Length -ne $wanted.Length) { return $false }
    for ($j = 0; $j -lt $actual.Length; $j++) {
        if ($actual[$j] -ne $wanted[$j]) { return $false }
    }
    return $true
}

function Wait-Content([string]$file, [string]$expected) {
    for ($i = 0; $i -lt 200; $i++) {
        if (Same-Content $file $expected) { return }
        Start-Sleep -Milliseconds 25
    }
    throw "file bytes differ from expected UTF-8 ($(([IO.File]::ReadAllBytes($file)).Length) bytes)"
}

$utf8 = [Text.UTF8Encoding]::new($false)
$WM_KEYDOWN = 256; $WM_KEYUP = 257; $WM_CHAR = 258; $WM_CLOSE = 16
$WM_SYSKEYDOWN = 260; $WM_SYSKEYUP = 261
$WM_SYSCOMMAND = 274; $SC_CLOSE = 61536; $ALT_DOWN = 536870912
$VK_END = 35; $VK_CONTROL = 17; $VK_MENU = 18; $VK_Q = 81; $VK_F4 = 115

function Ctrl-Q($hwnd) {
    Send-Key $hwnd $WM_KEYDOWN $VK_CONTROL
    Send-Key $hwnd $WM_KEYDOWN $VK_Q
    Post $hwnd $WM_CHAR 17
    Settle
    Send-Key $hwnd $WM_KEYUP $VK_Q
    Send-Key $hwnd $WM_KEYUP $VK_CONTROL
}

function Alt-F4($hwnd) {
    # No WM_CLOSE here: DefWindowProc derives it from F4 with Alt down.
    Send-Key $hwnd $WM_SYSKEYDOWN $VK_MENU $ALT_DOWN
    Send-Key $hwnd $WM_SYSKEYDOWN $VK_F4 $ALT_DOWN
    Settle
    Send-Key $hwnd $WM_SYSKEYUP $VK_F4 $ALT_DOWN
    Send-Key $hwnd $WM_SYSKEYUP $VK_MENU
}

function Assert-Running($p, [string]$name) {
    if ($p.WaitForExit(800)) { throw "$name closed on first request (exit $($p.ExitCode))" }
}

function Assert-Closed($p, [string]$name) {
    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw "$name ignored confirmed close" }
    if ($p.ExitCode -ne 0) { throw "$name exited $($p.ExitCode)" }
}
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
    if (-not (Same-Content $file $edited)) { throw 'discarded change reached the file' }
    Write-Host 'PASS unsaved change needs a second close and is discarded'

    # Complete keyboard sequences: modifier down, key down, translated char,
    # key up, modifier up. A held Q may emit repeated WM_CHAR events.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Send-Key $hwnd $WM_KEYDOWN $VK_CONTROL
    Send-Key $hwnd $WM_KEYDOWN $VK_Q
    Post $hwnd $WM_CHAR 17
    Settle
    Send-Key $hwnd $WM_KEYDOWN $VK_Q
    Post $hwnd $WM_CHAR 17
    Assert-Running $p 'repeated Ctrl+Q'
    Send-Key $hwnd $WM_KEYUP $VK_Q
    Send-Key $hwnd $WM_KEYUP $VK_CONTROL
    Ctrl-Q $hwnd
    Assert-Closed $p 'second deliberate Ctrl+Q'
    Write-Host 'PASS Ctrl+Q modifiers, repeat and second gesture'

    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Send-Key $hwnd $WM_SYSKEYDOWN $VK_MENU $ALT_DOWN
    Send-Key $hwnd $WM_SYSKEYDOWN $VK_F4 $ALT_DOWN
    Settle
    Send-Key $hwnd $WM_SYSKEYDOWN $VK_F4 $ALT_DOWN
    Assert-Running $p 'repeated Alt+F4'
    Send-Key $hwnd $WM_SYSKEYUP $VK_F4
    Send-Key $hwnd $WM_SYSKEYUP $VK_MENU
    Alt-F4 $hwnd
    Assert-Closed $p 'second deliberate Alt+F4'
    Write-Host 'PASS Alt+F4 modifiers, repeat and second gesture'

    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Ctrl-Q $hwnd
    Assert-Running $p 'first Ctrl+Q before Escape'
    Send-Key $hwnd $WM_KEYDOWN 27
    Send-Key $hwnd $WM_KEYUP 27
    Ctrl-Q $hwnd
    Assert-Running $p 'Ctrl+Q after Escape'
    Ctrl-Q $hwnd
    Assert-Closed $p 'Ctrl+Q after new confirmation'
    Write-Host 'PASS Escape cancels close confirmation'

    $p, $hwnd = Start-Editor $file
    Ctrl-Q $hwnd
    Assert-Closed $p 'Ctrl+Q on a clean document'
    Write-Host 'PASS Ctrl+Q closes a clean document at once'

    $p, $hwnd = Start-Editor $file
    Alt-F4 $hwnd
    Assert-Closed $p 'Alt+F4 on a clean document'
    Write-Host 'PASS Alt+F4 closes a clean document at once'

    # The title bar button reaches the editor as SC_CLOSE, without any key.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Post $hwnd $WM_SYSCOMMAND $SC_CLOSE
    Assert-Running $p 'close button'
    Post $hwnd $WM_SYSCOMMAND $SC_CLOSE
    Assert-Closed $p 'second close button'
    Write-Host 'PASS close button needs a second click'

    # Typing between two requests withdraws the first one.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 122
    Ctrl-Q $hwnd
    Post $hwnd $WM_CHAR 120
    Ctrl-Q $hwnd
    Assert-Running $p 'Ctrl+Q after typing'
    Ctrl-Q $hwnd
    Assert-Closed $p 'Ctrl+Q confirmed after typing'
    if (-not (Same-Content $file $edited)) { throw 'discarded typing reached the file' }
    Write-Host 'PASS typing cancels close confirmation'

    # Undo back to the saved text is clean: one close is enough.
    $p, $hwnd = Start-Editor $file
    Post $hwnd $WM_CHAR 113
    Post $hwnd $WM_CHAR 26
    Post $hwnd $WM_CLOSE 0
    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'ELEPad stayed open after undo to the saved text' }
    if ($p.ExitCode -ne 0) { throw "exit $($p.ExitCode) after undo" }
    Write-Host 'PASS undo to the saved text closes at once'
} finally {
    if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
    Remove-Item -LiteralPath $work -Recurse -Force
}
