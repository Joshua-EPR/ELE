# install.ps1
# Root convenience wrapper for ELE Windows installer.
# Invokes scripts/install.ps1 with forwarded arguments.

[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$PackagePath = "",
    [switch]$NoPathUpdate,
    [switch]$SkipVerification,
    [switch]$Force
)

$scriptPath = Join-Path $PSScriptRoot "scripts\install.ps1"
& $scriptPath @PSBoundParameters
