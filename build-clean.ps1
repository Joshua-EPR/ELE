# ELE build cleanup inventory: READ-ONLY by design. There is no delete switch.
# The repository stores registered Git worktrees beneath target/; never delete
# target/ or run cargo clean automatically. This script only measures and
# reports which target/ children contain (or are) a registered worktree.
# Directory sizes do not follow junctions/symlinks (reparse points), so a link
# pointing outside the repo is neither traversed nor counted.
param([string]$Root = (Join-Path $PSScriptRoot '.'))
$ErrorActionPreference = 'Stop'

function Normalize-Path([string]$p) {
    # git prints forward slashes; compare using one canonical, slash-terminated form.
    return ([IO.Path]::GetFullPath($p) -replace '/', '\').TrimEnd('\')
}

function Get-DirBytes([string]$dir) {
    $total = [long]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($dir)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object IO.DirectoryInfo $d
            foreach ($f in $di.EnumerateFiles()) { $total += $f.Length }
            foreach ($s in $di.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch { }   # unreadable/long path: skip, measurement only
    }
    return $total
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
Push-Location -LiteralPath $rootPath
try {
    $raw = @(& git worktree list --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate Git worktrees safely.' }
    $trees = @($raw | Where-Object { $_ -match '^worktree ' } | ForEach-Object { Normalize-Path $_.Substring(9) })
    if ($trees.Count -eq 0) { throw 'git reported no worktrees; refusing to continue.' }
    Write-Host 'READ-ONLY inventory. No files are deleted.' -ForegroundColor Cyan
    Write-Host ('Registered worktrees: {0}' -f $trees.Count)
    $target = Normalize-Path (Join-Path $rootPath 'target')
    if (-not (Test-Path -LiteralPath $target)) { Write-Host 'No target directory found.'; exit 0 }
    $prefix = $target + '\'
    $inside = @($trees | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($inside.Count -gt 0) {
        Write-Warning ('target/ contains {0} registered Git worktree(s). NEVER delete target/ wholesale.' -f $inside.Count)
        $inside | ForEach-Object { Write-Host ('PROTECTED: ' + $_) }
    }
    $rows = Get-ChildItem -LiteralPath $target -Directory -Force | ForEach-Object {
        $dir = Normalize-Path $_.FullName
        $isLink = [bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        $protected = @($trees | Where-Object {
            $_ -ieq $dir -or $_.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        $bytes = if ($isLink) { 0 } else { Get-DirBytes $dir }
        [PSCustomObject]@{
            Directory = $dir
            GB = [math]::Round(([double]$bytes / 1GB), 2)
            ProtectedWorktree = $protected
            Link = $isLink
        }
    }
    $rows | Sort-Object GB -Descending | Format-Table -AutoSize
} finally { Pop-Location }
