# scripts/bootstrap_stage2.ps1
# Automación del pipeline de bootstrap de Stage 2 hacia Stage 3 en ELE.
#
# Fases:
# 1. Compilación de los 4 ejecutables de Stage 1/Stage 2 con Stage 0 / Stage 1 (`l build`):
#    - compiler-l/src/main.l (lexer-l)
#    - compiler-l/src/main_parser.l (parser-l)
#    - compiler-l/src/main_sema.l (sema-l)
#    - compiler-l/src/native_cfg_demo.l (native-cfg-demo)
# 2. Prueba de determinismo y paridad bit a bit:
#    - Emisión LIR de `compiler-l/src/main_sema.l` usando `main_sema.exe --emit-lir` (Run 1 vs Run 2)
#    - Construcción de ejecutable Stage 2 vía `l build-lir`
#    - Emisión LIR de `compiler-l/src/main_sema.l` usando el nuevo ejecutable Stage 2
#    - Comparación bit a bit (SHA256 y FC) entre salida Stage 1 y salida Stage 2.
# 3. Prueba de tubería completa (End-to-End):
#    - `main_parser.exe` sobre código .l -> AST canónico
#    - `main_sema.exe --emit-lir` -> ELE-LIR 1
#    - `native_cfg_demo.exe` -> Imagen ELF64 funcional verificada.

param(
    [ValidateSet('cranelift', 'rustc')]
    [string] $Backend = 'cranelift',
    [string] $Compiler = '',
    [string] $OutputDir = '',
    [switch] $SkipCargoBuild,
    [switch] $VerboseOutput
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "ELE Stage 2 / Stage 3 Bootstrap Integration Harness" -ForegroundColor Cyan
Write-Host "Raíz del repositorio: $repoRoot" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan

# 0. Localizar o compilar el compilador base `l` (Stage 0)
if ([string]::IsNullOrWhiteSpace($Compiler)) {
    $targetDebugL = Join-Path $repoRoot 'target/debug/l.exe'
    if (-not (Test-Path -LiteralPath $targetDebugL) -and -not $SkipCargoBuild) {
        Write-Host "`n[Fase 0] Compilando Stage 0 (crates/l) con Cargo..." -ForegroundColor Yellow
        Push-Location -LiteralPath $repoRoot
        try {
            & cargo build -p project-l --bin l
            if ($LASTEXITCODE -ne 0) {
                throw "Fallo al compilar crates/l con cargo ($LASTEXITCODE)"
            }
        } finally {
            Pop-Location
        }
    }
    if (Test-Path -LiteralPath $targetDebugL) {
        $Compiler = $targetDebugL
    } else {
        throw "No se encontró el ejecutable base l.exe en $targetDebugL"
    }
}

$compilerExe = (Resolve-Path -LiteralPath $Compiler).Path
Write-Host "Compilador Stage 0/1: $compilerExe" -ForegroundColor DarkGray

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'target/bootstrap-stage2'
}
[IO.Directory]::CreateDirectory($OutputDir) > $null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
Write-Host "Directorio de trabajo: $OutputDir" -ForegroundColor DarkGray

# 1. Compilar los 4 ejecutables de Stage 1 / Stage 2
Write-Host "`n[Fase 1] Compilando los 4 ejecutables del compilador ELE..." -ForegroundColor Yellow

$entries = @(
    @{ Name = 'lexer';  Source = 'compiler-l/src/main.l';            OutName = 'main' },
    @{ Name = 'parser'; Source = 'compiler-l/src/main_parser.l';     OutName = 'main_parser' },
    @{ Name = 'sema';   Source = 'compiler-l/src/main_sema.l';       OutName = 'main_sema' },
    @{ Name = 'native'; Source = 'compiler-l/src/native_cfg_demo.l'; OutName = 'native_cfg_demo' }
)

$binaries = @{}

foreach ($entry in $entries) {
    $srcPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot $entry.Source)).Path
    $buildDir = Join-Path $OutputDir "build-$($entry.Name)"
    [IO.Directory]::CreateDirectory($buildDir) > $null
    
    Write-Host "  -> Compilando $($entry.Name) ($($entry.Source))..." -NoNewline
    Push-Location -LiteralPath $buildDir
    try {
        $output = & $compilerExe build $srcPath --backend $Backend
        if ($LASTEXITCODE -ne 0) {
            Write-Host " [FALLO]" -ForegroundColor Red
            throw "Falló la compilación de $($entry.Name) ($LASTEXITCODE)"
        }
        $relPath = ($output | Where-Object { $_ -like 'Build: *' }).Substring(7)
        $fullPath = (Resolve-Path -LiteralPath $relPath).Path
        $binaries[$entry.Name] = $fullPath
        Write-Host " [OK] -> $(Split-Path -Leaf $fullPath)" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

# 2. Prueba de determinismo y paridad bit a bit
Write-Host "`n[Fase 2] Determinismo y paridad bit a bit (Stage 1 vs Stage 2)..." -ForegroundColor Yellow

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$detDir = Join-Path $OutputDir 'determinism'
[IO.Directory]::CreateDirectory($detDir) > $null

$semaExe = $binaries['sema']
$mainSemaSrc = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'compiler-l/src/main_sema.l')).Path

$lirRun1 = Join-Path $detDir 'main_sema_stage1_run1.lir'
$lirRun2 = Join-Path $detDir 'main_sema_stage1_run2.lir'

Write-Host "  -> Ejecutando Stage 1 (main_sema.exe) sobre main_sema.l [Ejecución 1]..." -NoNewline
$psi1 = New-Object System.Diagnostics.ProcessStartInfo
$psi1.FileName = $semaExe
$psi1.Arguments = "`"$mainSemaSrc`" --emit-lir"
$psi1.RedirectStandardOutput = $true
$psi1.RedirectStandardError = $true
$psi1.UseShellExecute = $false
$p1 = [System.Diagnostics.Process]::Start($psi1)
$stdout1 = $p1.StandardOutput.ReadToEnd()
$stderr1 = $p1.StandardError.ReadToEnd()
$p1.WaitForExit()

if ($p1.ExitCode -ne 0) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "Stage 1 falló al compilar main_sema.l: $stderr1"
}
[IO.File]::WriteAllText($lirRun1, $stdout1, $utf8NoBom)
Write-Host " [OK] ($([Math]::Round($stdout1.Length / 1024, 1)) KiB)" -ForegroundColor Green

Write-Host "  -> Ejecutando Stage 1 (main_sema.exe) sobre main_sema.l [Ejecución 2]..." -NoNewline
$p2 = [System.Diagnostics.Process]::Start($psi1)
$stdout2 = $p2.StandardOutput.ReadToEnd()
$stderr2 = $p2.StandardError.ReadToEnd()
$p2.WaitForExit()

if ($p2.ExitCode -ne 0) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "Stage 1 ejecución 2 falló al compilar main_sema.l: $stderr2"
}
[IO.File]::WriteAllText($lirRun2, $stdout2, $utf8NoBom)
Write-Host " [OK] ($([Math]::Round($stdout2.Length / 1024, 1)) KiB)" -ForegroundColor Green

# Comprobación de determinismo Run 1 vs Run 2
$hashRun1 = (Get-FileHash -Algorithm SHA256 -LiteralPath $lirRun1).Hash
$hashRun2 = (Get-FileHash -Algorithm SHA256 -LiteralPath $lirRun2).Hash

Write-Host "  -> SHA256 Run 1: $hashRun1" -ForegroundColor DarkGray
Write-Host "  -> SHA256 Run 2: $hashRun2" -ForegroundColor DarkGray

if ($hashRun1 -ne $hashRun2) {
    throw "Determinismo violado: La salida de Stage 1 difiere entre ejecuciones idénticas."
}
Write-Host "  -> Determinismo intrafase (Stage 1): 100% IDÉNTICO" -ForegroundColor Green

# Construir ejecutable Stage 2 con `l build-lir`
Write-Host "  -> Construyendo ejecutable Stage 2 (sema_stage2.exe) vía l build-lir..." -NoNewline
Push-Location -LiteralPath $detDir
try {
    $stage2BuildOut = & $compilerExe build-lir $lirRun1
    if ($LASTEXITCODE -ne 0) {
        Write-Host " [FALLO]" -ForegroundColor Red
        throw "l build-lir falló al compilar LIR a ejecutable Stage 2 ($LASTEXITCODE)"
    }
    $relStage2 = ($stage2BuildOut | Where-Object { $_ -like 'Build: *' }).Substring(7)
    $stage2Exe = (Resolve-Path -LiteralPath $relStage2).Path
    Write-Host " [OK] -> $(Split-Path -Leaf $stage2Exe)" -ForegroundColor Green
} finally {
    Pop-Location
}

# Ejecutar el nuevo compilador Stage 2 sobre main_sema.l
$lirStage2 = Join-Path $detDir 'main_sema_stage2_output.lir'
Write-Host "  -> Ejecutando Stage 2 (sema_stage2.exe) sobre main_sema.l..." -NoNewline
$psiS2 = New-Object System.Diagnostics.ProcessStartInfo
$psiS2.FileName = $stage2Exe
$psiS2.Arguments = "`"$mainSemaSrc`" --emit-lir"
$psiS2.RedirectStandardOutput = $true
$psiS2.RedirectStandardError = $true
$psiS2.UseShellExecute = $false
$pS2 = [System.Diagnostics.Process]::Start($psiS2)
$stdoutS2 = $pS2.StandardOutput.ReadToEnd()
$stderrS2 = $pS2.StandardError.ReadToEnd()
$pS2.WaitForExit()

if ($pS2.ExitCode -ne 0) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "Stage 2 falló al compilar main_sema.l: $stderrS2"
}
[IO.File]::WriteAllText($lirStage2, $stdoutS2, $utf8NoBom)
Write-Host " [OK] ($([Math]::Round($stdoutS2.Length / 1024, 1)) KiB)" -ForegroundColor Green

$hashStage2 = (Get-FileHash -Algorithm SHA256 -LiteralPath $lirStage2).Hash
Write-Host "  -> SHA256 Stage 2 LIR: $hashStage2" -ForegroundColor DarkGray

if ($hashRun1 -ne $hashStage2) {
    throw "Paridad Stage 1 / Stage 2 violada: El compilador Stage 2 emite LIR diferente a Stage 1."
}
Write-Host "  -> Paridad interfase (Stage 1 vs Stage 2): 100% BIT A BIT IDÉNTICO" -ForegroundColor Green

# 3. Prueba de tubería completa (End-to-End)
Write-Host "`n[Fase 3] Prueba de tubería completa (Parser -> Sema LIR -> Native Backend ELF64)..." -ForegroundColor Yellow

$pipeDir = Join-Path $OutputDir 'pipeline'
[IO.Directory]::CreateDirectory($pipeDir) > $null

$testSource = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'compiler-l/src/flow_self_harness.l')).Path
$parserExe = $binaries['parser']
$nativeExe = $binaries['native']

# Paso 3.1: Parser
Write-Host "  [Paso 3.1] Ejecutando parser-l sobre $(Split-Path -Leaf $testSource)..." -NoNewline
$psiParser = New-Object System.Diagnostics.ProcessStartInfo
$psiParser.FileName = $parserExe
$psiParser.Arguments = "`"$testSource`""
$psiParser.RedirectStandardOutput = $true
$psiParser.RedirectStandardError = $true
$psiParser.UseShellExecute = $false
$pParser = [System.Diagnostics.Process]::Start($psiParser)
$outParser = $pParser.StandardOutput.ReadToEnd()
$errParser = $pParser.StandardError.ReadToEnd()
$pParser.WaitForExit()

if ($pParser.ExitCode -ne 0 -or (-not ($outParser -like '*AstSummary*'))) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "parser-l falló: $errParser"
}
Write-Host " [OK] (AST verificado)" -ForegroundColor Green

# Paso 3.2: Sema --emit-lir
$pipeLir = Join-Path $pipeDir 'flow_pipeline.lir'
Write-Host "  [Paso 3.2] Ejecutando sema-l --emit-lir sobre $(Split-Path -Leaf $testSource)..." -NoNewline
$psiPipeSema = New-Object System.Diagnostics.ProcessStartInfo
$psiPipeSema.FileName = $semaExe
$psiPipeSema.Arguments = "`"$testSource`" --emit-lir"
$psiPipeSema.RedirectStandardOutput = $true
$psiPipeSema.RedirectStandardError = $true
$psiPipeSema.UseShellExecute = $false
$pPipeSema = [System.Diagnostics.Process]::Start($psiPipeSema)
$outPipeSema = $pPipeSema.StandardOutput.ReadToEnd()
$errPipeSema = $pPipeSema.StandardError.ReadToEnd()
$pPipeSema.WaitForExit()

if ($pPipeSema.ExitCode -ne 0 -or (-not ($outPipeSema.StartsWith("ELE-LIR 1`n")))) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "sema-l falló al emitir LIR: $errPipeSema"
}
[IO.File]::WriteAllText($pipeLir, $outPipeSema, $utf8NoBom)
Write-Host " [OK] (ELE-LIR 1 verificado)" -ForegroundColor Green

# Paso 3.3: Native backend ELF64
$pipeElf = Join-Path $pipeDir 'flow_pipeline.elf'
if (Test-Path -LiteralPath $pipeElf) {
    Remove-Item -LiteralPath $pipeElf -Force
}

Write-Host "  [Paso 3.3] Ejecutando native-cfg-demo para generar ELF64..." -NoNewline
$psiNative = New-Object System.Diagnostics.ProcessStartInfo
$psiNative.FileName = $nativeExe
$psiNative.Arguments = "`"$pipeLir`" `"$pipeElf`""
$psiNative.RedirectStandardOutput = $true
$psiNative.RedirectStandardError = $true
$psiNative.UseShellExecute = $false
$pNative = [System.Diagnostics.Process]::Start($psiNative)
$outNative = $pNative.StandardOutput.ReadToEnd()
$errNative = $pNative.StandardError.ReadToEnd()
$pNative.WaitForExit()

if ($pNative.ExitCode -ne 0 -or (-not (Test-Path -LiteralPath $pipeElf))) {
    Write-Host " [FALLO]" -ForegroundColor Red
    throw "native-cfg-demo falló: $errNative"
}

$elfBytes = [IO.File]::ReadAllBytes($pipeElf)
$elfMagic = [BitConverter]::ToString($elfBytes[0..6])
# 7F-45-4C-46-02-01-01 = \x7fELF (64-bit Little Endian, ELF Version 1)
if ($elfMagic -ne '7F-45-4C-46-02-01-01') {
    throw "Cabecera ELF inválida: $elfMagic (esperado: 7F-45-4C-46-02-01-01)"
}
if ($elfBytes.Length -le 4096) {
    throw "Imagen ELF demasiado pequeña ($($elfBytes.Length) bytes)"
}
Write-Host " [OK] ($($elfBytes.Length) bytes, Magic: ELF64 LE)" -ForegroundColor Green

# 4. Resumen final
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "RESUMEN DE VERIFICACIÓN DE BOOTSTRAP STAGE 2" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  [✓] 4 Ejecutables compilados: lexer, parser, sema, native_cfg_demo" -ForegroundColor Green
Write-Host "  [✓] Determinismo intrafase (Stage 1 Run 1 == Run 2): OK ($hashRun1)" -ForegroundColor Green
Write-Host "  [✓] Paridad interfase (Stage 1 == Stage 2 LIR):      OK ($hashStage2)" -ForegroundColor Green
Write-Host "  [✓] Pipeline completo Parser -> Sema -> ELF64:       OK ($($elfBytes.Length) bytes ELF64)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "ESTADO: VERIFICACIÓN 100% REPRODUCIBLE Y DETERMINISTA APROBADA`n" -ForegroundColor Green

exit 0
