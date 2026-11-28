<#
.SYNOPSIS
  Prepara el corpus de la Fase 4 (hito 23): lista los *.txt y *.jsonl, compila preparar.l
  con el compilador autónomo de ELE y lo ejecuta.

.DESCRIPTION
  Este script solo hace lo que ELE todavía no puede: recorrer carpetas.
  Todo el procesamiento (normalizar, filtrar, deduplicar, dividir, escribir,
  estadísticas) lo hace el programa ELE preparar.l.

  La carpeta de entrada cuyo camino contiene un segmento "dialogos" (sin
  distinguir mayúsculas) marca sus archivos como DIALOGO; el resto es TEXTO.
  Un .jsonl es una conversación por línea (formatos messages, conversations o
  prompt/response); se convierte a turnos "TÚ: ..." / "ENCA: ...".

.EXAMPLE
  .\preparar.ps1 -Entrada D:\corpus\wikipedia,D:\corpus\libros,D:\corpus\dialogos -Salida D:\corpus\salida

.EXAMPLE
  .\preparar.ps1 -Entrada D:\corpus\todo -Salida D:\corpus\salida -Opciones '--min=200','--similitud=80','--semilla=1'

  Opciones: --min --min-dialogo --basura(por mil) --letras(%) --similitud(%)
  --mojibake(0|1) --semilla --prueba(%) --valida(%) --max-doc --max-docs
  --dialogo-reparto=90,5,5 (entrena,valida,prueba de los diálogos)
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Entrada,
    [Parameter(Mandatory = $true)][string]$Salida,
    [string[]]$Opciones = @(),
    [switch]$NoCompilar
)
$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$ele = Join-Path $aqui '..\..\compilador\ele.exe'
$ele = [System.IO.Path]::GetFullPath($ele)
if (-not (Test-Path $ele)) { throw "no existe el compilador: $ele" }

New-Item -ItemType Directory -Force -Path $Salida | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Salida 'prueba_sellada') | Out-Null
$Salida = (Resolve-Path $Salida).Path

# Lista de archivos: orden alfabético ordinal para que sea determinista.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lineas = New-Object System.Collections.Generic.List[string]
$bytesEntrada = [long]0
foreach ($carpeta in $Entrada) {
    if (-not (Test-Path $carpeta -PathType Container)) { throw "no existe la carpeta de entrada: $carpeta" }
    $raiz = (Resolve-Path $carpeta).Path.TrimEnd('\')
    $hoja = Split-Path -Leaf $raiz
    $rels = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $raiz -Recurse -File | Where-Object { $_.Extension -ieq '.txt' -or $_.Extension -ieq '.jsonl' } | ForEach-Object {
        $rels.Add($_.FullName.Substring($raiz.Length + 1).Replace('\', '/'))
    }
    $arr = $rels.ToArray()
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    foreach ($rel in $arr) {
        $segmentos = @($hoja) + $rel.Split('/')
        $tipo = 'T'
        foreach ($s in $segmentos) { if ($s -ieq 'dialogos') { $tipo = 'D' } }
        $abs = Join-Path $raiz ($rel.Replace('/', '\'))
        $bytesEntrada += (Get-Item -LiteralPath $abs).Length
        $lineas.Add("$tipo`t$abs`t$hoja/$rel")
    }
}
if ($lineas.Count -eq 0) { throw 'no hay archivos .txt ni .jsonl en las carpetas de entrada' }
$lista = Join-Path $Salida '_lista.txt'
[System.IO.File]::WriteAllText($lista, (($lineas -join "`n") + "`n"), $utf8)
Write-Host ("lista: {0} archivos, {1:N1} MB -> {2}" -f $lineas.Count, ($bytesEntrada / 1MB), $lista)

# Compilación con el driver autónomo (PE64).
$exe = Join-Path $Salida '_preparar.exe'
if (-not $NoCompilar -or -not (Test-Path $exe)) {
    & $ele build (Join-Path $aqui 'preparar.l') -o $exe
    if ($LASTEXITCODE -ne 0) { throw "falló la compilación de preparar.l ($LASTEXITCODE)" }
}

$cron = [System.Diagnostics.Stopwatch]::StartNew()
& $exe $lista $Salida @Opciones
$codigo = $LASTEXITCODE
$cron.Stop()
if ($codigo -ne 0) { throw "preparar terminó con código $codigo" }
$seg = [Math]::Max($cron.Elapsed.TotalSeconds, 0.001)
Write-Host ("tiempo: {0:N2} s; {1:N2} MB/s de entrada" -f $seg, (($bytesEntrada / 1MB) / $seg))
Write-Host "salida: $Salida (ESTADISTICAS.md, entrena.bin/.idx/.tipos, valida.*, prueba_sellada/, indice.bin)"
