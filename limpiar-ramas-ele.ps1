# Limpieza segura de ramas remotas de Joshua-EPR/ELE.
# Por defecto SOLO muestra una vista previa.
# Ejecucion real: powershell -ExecutionPolicy Bypass -File .\limpiar-ramas-ele.ps1 -Apply
# Requisitos: PowerShell y git con acceso de escritura al repositorio.
param(
    [switch]$Apply,
    [string]$Remote = 'origin'
)

$ErrorActionPreference = 'Stop'
$owner = 'Joshua-EPR'
$repo = 'ELE'
$api = "https://api.github.com/repos/$owner/$repo"
$headers = @{ 'User-Agent' = 'ELE-branch-cleanup' ; 'Accept' = 'application/vnd.github+json' }

function Get-GitHubPages([string]$Path) {
    # Invoke-RestMethod can preserve a JSON array as ONE pipeline object in
    # Windows PowerShell 5.1. Do not wrap its result directly in @(...): that
    # may turn 77 remote branches into one nested array.
    $items = [System.Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $url = "$api/$Path${separator}per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        $count = 0
        foreach ($item in $response) {
            # Defensively flatten an array wrapped by the shell/API client.
            if ($item -is [System.Array]) {
                foreach ($inner in $item) {
                    $items.Add($inner)
                    $count++
                }
            } else {
                $items.Add($item)
                $count++
            }
        }
        $page++
    } while ($count -eq 100)
    # PowerShell enumerates this return value for the caller.
    return $items.ToArray()
}


if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git no esta instalado o no se encuentra en PATH.'
}
$remoteUrl = (& git remote get-url $Remote 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $remoteUrl) {
    throw "No se encontro el remoto '$Remote'. Ejecuta el script desde el clon local de ELE."
}
$remoteUrl = ($remoteUrl | Out-String).Trim()
$expected = '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?i:Joshua-EPR/ELE)(?:\.git)?/?$'
if ($remoteUrl -notmatch $expected) {
    throw "Remoto inesperado: $remoteUrl. Por seguridad solo se admite Joshua-EPR/ELE."
}

Write-Host 'Consultando ramas y PRs de Joshua-EPR/ELE...' -ForegroundColor Cyan
$branches = @(Get-GitHubPages 'branches')
$closedPrs = @(Get-GitHubPages 'pulls?state=closed&sort=created&direction=desc')
$openPrs = @(Get-GitHubPages 'pulls?state=open')

# Fail closed: a nested JSON array or truncated API response must never
# produce a misleading "one branch" preview or permit deletion.
if ($branches.Count -lt 2 -or @($branches | Where-Object { $_.name -eq 'main' }).Count -ne 1) {
    throw "Inventario de ramas invalido ($($branches.Count) entradas o falta main). No se borrara nada."
}
foreach ($branch in $branches) {
    if ($branch -is [System.Array] -or -not $branch.name -or -not $branch.commit.sha) {
        throw "Respuesta de GitHub con estructura inesperada. No se borrara nada."
    }
}

$openHeads = @{}
foreach ($pr in $openPrs) {
    if ($pr.head -and $pr.head.ref) { $openHeads[$pr.head.ref] = $true }
}
$mergedHeads = @{}
foreach ($pr in $closedPrs) {
    if (-not $pr.merged_at -or -not $pr.head -or -not $pr.head.ref) { continue }
    if ($pr.head.repo -and $pr.head.repo.full_name -ne "$owner/$repo") { continue }
    # La API esta ordenada por fecha descendente; preservar el ultimo PR de cada rama.
    if (-not $mergedHeads.ContainsKey($pr.head.ref)) {
        $mergedHeads[$pr.head.ref] = $pr
    }
}

$currentBranch = (& git branch --show-current 2>$null | Out-String).Trim()
$safe = @()
$excluded = @()
foreach ($branch in $branches) {
    $name = [string]$branch.name
    if ($name -eq 'main' -or $branch.protected -or $name -eq $currentBranch -or $openHeads.ContainsKey($name)) {
        $excluded += $name
        continue
    }
    if (-not $mergedHeads.ContainsKey($name)) {
        $excluded += $name
        continue
    }
    $pr = $mergedHeads[$name]
    # Si alguien modifico la rama despues del PR, NO borrar.
    if ([string]$branch.commit.sha -ne [string]$pr.head.sha) {
        $excluded += $name
        continue
    }
    $safe += [PSCustomObject]@{ Name = $name; Sha = [string]$branch.commit.sha; PR = $pr.number }
}

Write-Host "Ramas actuales: $($branches.Count)" -ForegroundColor White
Write-Host "Candidatas seguras: $($safe.Count)" -ForegroundColor Green
Write-Host "Conservadas o pendientes de revision: $($excluded.Count)" -ForegroundColor Yellow
foreach ($item in $safe) { Write-Host ("  PR #{0}: {1}" -f $item.PR, $item.Name) }

if (-not $Apply) {
    Write-Host "`nVISTA PREVIA. No se borro ninguna rama." -ForegroundColor Yellow
    Write-Host 'Para borrar solo las candidatas verificadas, ejecuta:' -ForegroundColor Cyan
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\limpiar-ramas-ele.ps1 -Apply'
    exit 0
}

$deleted = @()
$failed = @()
foreach ($item in $safe) {
    # La lease exige que el SHA remoto siga siendo exactamente el auditado:
    # protege contra cambios concurrentes entre el inventario y la eliminacion.
    $lease = "--force-with-lease=refs/heads/$($item.Name):$($item.Sha)"
    $refspec = ":refs/heads/$($item.Name)"
    & git push $Remote $lease $refspec
    if ($LASTEXITCODE -eq 0) {
        $deleted += $item.Name
    } else {
        $failed += $item.Name
        Write-Warning "No se pudo borrar '$($item.Name)' (permisos, cambio de SHA o proteccion de GitHub)."
    }
}
Write-Host "`nBorradas: $($deleted.Count); no borradas por error: $($failed.Count); conservadas deliberadamente: $($excluded.Count)"
if ($failed.Count -gt 0) { exit 1 }
