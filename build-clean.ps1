# ELE build cleanup inventory: read-only by design.
# The repository stores registered Git worktrees beneath target/;
# never delete target/ or run cargo clean automatically.
param([string]$Root = (Join-Path $PSScriptRoot '.'))
$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path
Push-Location $rootPath
try {
    $trees = @(& git worktree list --porcelain | Where-Object { $_ -match '^worktree ' } | ForEach-Object { $_.Substring(9) })
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate Git worktrees safely.' }
    Write-Host 'READ-ONLY inventory. No files are deleted.' -ForegroundColor Cyan
    Write-Host ('Registered worktrees: {0}' -f $trees.Count)
    $target = Join-Path $rootPath 'target'
    if (-not (Test-Path -LiteralPath $target)) { Write-Host 'No target directory found.'; exit 0 }
    $rootPrefix = $target.TrimEnd('\\','/') + [IO.Path]::DirectorySeparatorChar
    $inside = @($trees | Where-Object { $_.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($inside.Count -gt 0) {
        Write-Warning ('target/ contains {0} registered Git worktree(s). NEVER delete target/ wholesale.' -f $inside.Count)
        $inside | ForEach-Object { Write-Host ('PROTECTED: ' + $_) }
    }
    Get-ChildItem -LiteralPath $target -Directory -Force | ForEach-Object {
        $dir = $_.FullName
        $bytes = (Get-ChildItem -LiteralPath $dir -File -Force -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{ Directory = $dir; GB = [math]::Round(([double]$bytes / 1GB), 2); ProtectedWorktree = @($trees | Where-Object { $_ -eq $dir -or $_.StartsWith($dir.TrimEnd('\\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
    } | Sort-Object GB -Descending | Format-Table -AutoSize
} finally { Pop-Location }
