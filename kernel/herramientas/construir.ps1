<#
.SYNOPSIS
    Compila el kernel ELE, arma la partición EFI con Limine y lo arranca en QEMU.

.DESCRIPTION
    Un solo comando desde Windows:
      1. kernel\compilador\ele.exe build kernel\kmain.l --target kernel
      2. kernel\construccion\esp\  (EFI\BOOT\BOOTX64.EFI = Limine,
         boot\kernel.elf, boot\limine\limine.conf). QEMU la expone como un
         disco FAT (vvfat), así que no hace falta crear una imagen de disco.
      3. QEMU q35 + OVMF (UEFI), CPU sin AVX/FMA (como el Celeron 3865U).

    -Prueba arranca sin ventana, espera a que la salida serie contenga
    -Esperado (por defecto "ELE kernel OK"), cierra QEMU y devuelve 0 si
    apareció, 1 si no. Sin -Prueba abre la ventana de QEMU y muestra el
    puerto serie en esta consola.

.EXAMPLE
    .\kernel\herramientas\construir.ps1
.EXAMPLE
    .\kernel\herramientas\construir.ps1 -Prueba
#>
param(
    [switch]$Prueba,
    [string]$Esperado = "ELE kernel OK",
    [int]$Segundos = 30,
    [string]$Qemu = "C:\Program Files\qemu",
    [int]$Cpus = 2,
    [string]$Memoria = "512M",
    # Con -Prueba: guarda una captura de la pantalla (PNG) al terminar.
    [string]$Captura = "",
    # Con -Prueba: cuando la serie muestre -EsperarAntes, se teclean estas
    # teclas (nombres de `sendkey` de QEMU separados por espacios).
    [string]$EsperarAntes = "",
    [string]$Teclas = ""
)

$ErrorActionPreference = "Stop"
$kernel = Split-Path -Parent $PSScriptRoot
$herramientas = $PSScriptRoot
$ele = Join-Path $kernel "compilador\ele.exe"
$salida = Join-Path $kernel "construccion"
$esp = Join-Path $salida "esp"
$elf = Join-Path $salida "kernel.elf"
$registro = Join-Path $salida "serie.log"

function Fallar([string]$mensaje) {
    Write-Host "ERROR: $mensaje" -ForegroundColor Red
    exit 1
}

foreach ($necesario in @($ele, (Join-Path $herramientas "limine\BOOTX64.EFI"), (Join-Path $Qemu "qemu-system-x86_64.exe"), (Join-Path $Qemu "share\edk2-x86_64-code.fd"))) {
    if (-not (Test-Path $necesario)) { Fallar "no existe $necesario" }
}

# 1. Compilar.
New-Item -ItemType Directory -Force $salida | Out-Null
Write-Host "==> compilando kmain.l (--target kernel)"
Push-Location $kernel
try {
    & $ele build kmain.l --target kernel --lib . -o $elf
    if ($LASTEXITCODE -ne 0) { Fallar "el compilador devolvió $LASTEXITCODE" }
} finally {
    Pop-Location
}
Write-Host ("    kernel.elf: {0} bytes" -f (Get-Item $elf).Length)

# 2. Partición EFI como directorio.
if (Test-Path $esp) { Remove-Item -Recurse -Force $esp }
New-Item -ItemType Directory -Force (Join-Path $esp "EFI\BOOT"), (Join-Path $esp "boot\limine") | Out-Null
Copy-Item (Join-Path $herramientas "limine\BOOTX64.EFI") (Join-Path $esp "EFI\BOOT\BOOTX64.EFI")
Copy-Item (Join-Path $herramientas "limine.conf") (Join-Path $esp "boot\limine\limine.conf")
Copy-Item $elf (Join-Path $esp "boot\kernel.elf")

# 3. QEMU. Celeron 3865U: SSE hasta SSE4.2, sin AVX ni FMA.
$cpu = "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"
$firmware = Join-Path $Qemu "share\edk2-x86_64-code.fd"
$argumentos = @(
    "-M", "q35", "-cpu", $cpu, "-smp", "$Cpus", "-m", $Memoria,
    "-drive", "if=pflash,format=raw,readonly=on,file=`"$firmware`"",
    "-drive", "format=raw,file=fat:rw:`"$esp`"",
    "-no-reboot", "-no-shutdown"
)
$qemuExe = Join-Path $Qemu "qemu-system-x86_64.exe"

if (-not $Prueba) {
    Write-Host "==> QEMU (serie en esta consola; cierre la ventana para salir)"
    & $qemuExe @argumentos -serial stdio
    exit $LASTEXITCODE
}

Write-Host "==> QEMU sin ventana, esperando '$Esperado' (máx. $Segundos s)"
if (Test-Path $registro) { Remove-Item -Force $registro }
$puerto = 45454
$proceso = Start-Process -FilePath $qemuExe -ArgumentList ($argumentos + @("-display", "none", "-serial", "file:`"$registro`"", "-monitor", "tcp:127.0.0.1:${puerto},server,nowait")) -PassThru -WindowStyle Hidden
function Leer-Serie {
    if (-not (Test-Path $registro)) { return "" }
    # QEMU mantiene el archivo abierto: se lee compartido.
    $flujo = [System.IO.File]::Open($registro, "Open", "Read", "ReadWrite")
    try {
        $lector = New-Object System.IO.StreamReader($flujo, [System.Text.Encoding]::UTF8)
        return $lector.ReadToEnd()
    } finally {
        $flujo.Close()
    }
}
function Enviar-Monitor([string[]]$ordenes) {
    $cliente = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $puerto)
    $escritor = New-Object System.IO.StreamWriter($cliente.GetStream())
    $escritor.AutoFlush = $true
    foreach ($orden in $ordenes) {
        $escritor.WriteLine($orden)
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds 500
    $cliente.Close()
}
$limite = (Get-Date).AddSeconds($Segundos)
$visto = $false
$tecleado = -not $Teclas
while ((Get-Date) -lt $limite -and -not $proceso.HasExited) {
    $serie = Leer-Serie
    if (-not $tecleado -and $serie.Contains($EsperarAntes)) {
        Start-Sleep -Milliseconds 300
        Enviar-Monitor (($Teclas -split " " | Where-Object { $_ }) | ForEach-Object { "sendkey $_" })
        $tecleado = $true
    }
    if ($tecleado -and $serie.Contains($Esperado)) {
        $visto = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
if ($Captura -and -not $proceso.HasExited) {
    # Monitor de QEMU: screendump en PPM, convertido a PNG con Python.
    Start-Sleep -Milliseconds 1500
    $ppm = Join-Path $salida "pantalla.ppm"
    if (Test-Path $ppm) { Remove-Item -Force $ppm }
    try {
        Enviar-Monitor @("screendump $($ppm.Replace([char]92, [char]47))")
        Start-Sleep -Milliseconds 1000
        python (Join-Path $herramientas "ppm_a_png.py") $ppm $Captura
        Write-Host "    captura: $Captura"
    } catch {
        Write-Host "    no se pudo capturar la pantalla: $_"
    }
}
if (-not $proceso.HasExited) { Stop-Process -Id $proceso.Id -Force }
Write-Host "---- salida serie ----"
Write-Host (Leer-Serie)
Write-Host "----------------------"
if ($visto) {
    Write-Host "OK: apareció '$Esperado'" -ForegroundColor Green
    exit 0
}
Fallar "no apareció '$Esperado' en $Segundos s"
