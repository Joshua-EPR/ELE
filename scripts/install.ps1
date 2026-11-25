# scripts/install.ps1
# Native User Installer for the ELE Language (Windows x86-64)
#
# Installs standalone, zero-CRT native ELE compiler directly into a safe user directory
# ($env:LOCALAPPDATA\ele or ~/.ele) and safely configures User PATH.
# Does NOT require Administrator privileges.
# Does NOT overwrite existing PATH entries.

[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$PackagePath = "",
    [switch]$NoPathUpdate,
    [switch]$SkipVerification,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ELE Programming Language — Native Windows Installer" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Resolve Install Directory
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $InstallDir = Join-Path $env:LOCALAPPDATA "ele"
    } else {
        $InstallDir = Join-Path $HOME ".ele"
    }
}

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$binDir = Join-Path $InstallDir "bin"
$examplesDir = Join-Path $InstallDir "examples"

Write-Host "[install] Destination directory: $InstallDir" -ForegroundColor DarkGray

# 2. Locate or Extract Package
$scriptRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path

$tempExtract = $null
try {
    $archiveToUse = $null
    if (-not [string]::IsNullOrWhiteSpace($PackagePath) -and (Test-Path -LiteralPath $PackagePath)) {
        $archiveToUse = (Resolve-Path -LiteralPath $PackagePath).Path
    } else {
        $defaultZip = Join-Path $repoRoot "dist\ele-windows-x86_64.zip"
        if (Test-Path -LiteralPath $defaultZip) {
            $archiveToUse = $defaultZip
        }
    }

    [IO.Directory]::CreateDirectory($InstallDir) > $null
    [IO.Directory]::CreateDirectory($binDir) > $null
    [IO.Directory]::CreateDirectory($examplesDir) > $null

    if ($archiveToUse -and (Test-Path -LiteralPath $archiveToUse)) {
        Write-Host "[install] Extracting package from: $archiveToUse" -ForegroundColor Yellow
        $tempExtract = Join-Path ([IO.Path]::GetTempPath()) ("ele-install-" + [IO.Path]::GetRandomFileName())
        [IO.Directory]::CreateDirectory($tempExtract) > $null

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archiveToUse, $tempExtract)

        $sourceRoot = Join-Path $tempExtract "ele"
        if (-not (Test-Path -LiteralPath $sourceRoot)) {
            $sourceRoot = $tempExtract
        }

        # Copy bin
        Get-ChildItem -LiteralPath (Join-Path $sourceRoot "bin") | Copy-Item -Destination $binDir -Force -Recurse
        # Copy examples
        if (Test-Path -LiteralPath (Join-Path $sourceRoot "examples")) {
            Get-ChildItem -LiteralPath (Join-Path $sourceRoot "examples") | Copy-Item -Destination $examplesDir -Force -Recurse
        }
        # Copy docs & version
        foreach ($doc in @("README.md", "README.es.md", "VERSION")) {
            $srcDoc = Join-Path $sourceRoot $doc
            if (Test-Path -LiteralPath $srcDoc) {
                Copy-Item -LiteralPath $srcDoc -Destination (Join-Path $InstallDir $doc) -Force
            }
        }
    } else {
        throw "ELE distribution archive not found. Pass -PackagePath or run the installer from a directory containing dist/ele-windows-x86_64.zip."
    }

    $eleExe = Join-Path $binDir "ele.exe"
    if (-not (Test-Path -LiteralPath $eleExe)) {
        throw "Installation failed: ele.exe not found at $eleExe"
    }
    Write-Host "[install] Installed ele.exe: $eleExe ($((Get-Item -LiteralPath $eleExe).Length) bytes)" -ForegroundColor Green

    # 3. Configure User PATH
    if (-not $NoPathUpdate) {
        Write-Host "`n[install] Configuring User PATH..." -ForegroundColor Yellow
        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
        if ($null -eq $currentUserPath) { $currentUserPath = "" }

        $normBin = $binDir.TrimEnd('\', '/')
        $pathEntries = $currentUserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $alreadyInPath = $false
        foreach ($entry in $pathEntries) {
            if ($entry.TrimEnd('\', '/') -ieq $normBin) {
                $alreadyInPath = $true
                break
            }
        }

        if (-not $alreadyInPath) {
            $newPath = if ([string]::IsNullOrWhiteSpace($currentUserPath)) { $binDir } else { "$currentUserPath;$binDir" }
            [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::User)
            Write-Host "[install] Added '$binDir' to User PATH." -ForegroundColor Green
        } else {
            Write-Host "[install] '$binDir' is already present in User PATH." -ForegroundColor DarkGray
        }

        # Update current process PATH so caller immediately has access
        $procPathEntries = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $alreadyInProcPath = $false
        foreach ($entry in $procPathEntries) {
            if ($entry.TrimEnd('\', '/') -ieq $normBin) {
                $alreadyInProcPath = $true
                break
            }
        }
        if (-not $alreadyInProcPath) {
            $env:Path = "$binDir;$env:Path"
        }
    }

    # 4. Self-Verification
    if (-not $SkipVerification) {
        Write-Host "`n[verify] Running installation self-verification..." -ForegroundColor Yellow

        # 4a. Check --version
        $verPsi = New-Object System.Diagnostics.ProcessStartInfo
        $verPsi.FileName = $eleExe
        $verPsi.Arguments = "--version"
        $verPsi.RedirectStandardOutput = $true
        $verPsi.UseShellExecute = $false
        $verProc = [System.Diagnostics.Process]::Start($verPsi)
        $verOut = $verProc.StandardOutput.ReadToEnd().Trim()
        $verProc.WaitForExit()

        if ($verProc.ExitCode -ne 0 -or -not ($verOut -like "*ele*")) {
            throw "Self-verification error: 'ele --version' exited with code $($verProc.ExitCode): $verOut"
        }
        Write-Host "  -> ele --version: $verOut [OK]" -ForegroundColor Green

        # 4b. Check --help
        $helpPsi = New-Object System.Diagnostics.ProcessStartInfo
        $helpPsi.FileName = $eleExe
        $helpPsi.Arguments = "--help"
        $helpPsi.RedirectStandardOutput = $true
        $helpPsi.UseShellExecute = $false
        $helpProc = [System.Diagnostics.Process]::Start($helpPsi)
        $helpOut = $helpProc.StandardOutput.ReadToEnd().Trim()
        $helpProc.WaitForExit()

        if ($helpProc.ExitCode -ne 0 -or -not ($helpOut -like "*ELE*")) {
            throw "Self-verification error: 'ele --help' exited with code $($helpProc.ExitCode)"
        }
        Write-Host "  -> ele --help: CLI driver responsive [OK]" -ForegroundColor Green

        # 4c. Compile and execute sample hello.l
        $verifyDir = Join-Path ([IO.Path]::GetTempPath()) ("ele-verify-" + [IO.Path]::GetRandomFileName())
        [IO.Directory]::CreateDirectory($verifyDir) > $null
        try {
            $sampleSrc = Join-Path $verifyDir "hello_verify.l"
            $sampleExe = Join-Path $verifyDir "hello_verify.exe"
            $code = @"
flow main() => Int {
    print("Hello from native ELE installer verification")
    give 0
}
"@
            [IO.File]::WriteAllText($sampleSrc, $code, (New-Object System.Text.UTF8Encoding($false)))

            $buildPsi = New-Object System.Diagnostics.ProcessStartInfo
            $buildPsi.FileName = $eleExe
            $buildPsi.Arguments = "build `"$sampleSrc`" --output `"$sampleExe`""
            $buildPsi.RedirectStandardOutput = $true
            $buildPsi.RedirectStandardError = $true
            $buildPsi.UseShellExecute = $false
            $buildProc = [System.Diagnostics.Process]::Start($buildPsi)
            $buildErr = $buildProc.StandardError.ReadToEnd()
            $buildProc.WaitForExit()

            if ($buildProc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $sampleExe)) {
                throw "Self-verification error: compilation of hello_verify.l failed ($($buildProc.ExitCode)): $buildErr"
            }
            Write-Host "  -> Compilation of sample program: [OK]" -ForegroundColor Green

            $runPsi = New-Object System.Diagnostics.ProcessStartInfo
            $runPsi.FileName = $sampleExe
            $runPsi.RedirectStandardOutput = $true
            $runPsi.UseShellExecute = $false
            $runProc = [System.Diagnostics.Process]::Start($runPsi)
            $runOut = $runProc.StandardOutput.ReadToEnd().Trim()
            $runProc.WaitForExit()

            if ($runProc.ExitCode -ne 0 -or $runOut -ne "Hello from native ELE installer verification") {
                throw "Self-verification error: sample execution failed ($($runProc.ExitCode)): $runOut"
            }
            Write-Host "  -> Execution of native binary: '$runOut' [OK]" -ForegroundColor Green
        } finally {
            if (Test-Path -LiteralPath $verifyDir) {
                Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host " ELE Installation Completed Successfully!" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Location: $InstallDir"
    Write-Host "Binary:   $eleExe"
    Write-Host "`nTo compile ELE programs:"
    Write-Host "  ele build <archivo.l> -o <ejecutable.exe>" -ForegroundColor Yellow
    Write-Host "  ele --help" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Cyan
} finally {
    if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
