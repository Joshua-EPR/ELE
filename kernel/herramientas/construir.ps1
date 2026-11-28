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
    [string]$Teclas = "",
    # Virtualización por hardware (Windows Hypervisor Platform) en vez de
    # emulación TCG: necesaria para medir rendimiento (hito 9).
    [switch]$Acelerar,
    # Crea construccion\ele.img (GPT + FAT32, para grabar en un USB) y
    # arranca QEMU desde esa imagen en vez del directorio.
    [switch]$Imagen,
    # Sin HPET en la máquina virtual (como algunos equipos reales).
    [switch]$SinHpet,
    # Segundo disco SATA (puerto 1 del AHCI) para el hito 13. "prueba" crea
    # construccion\datos.img con herramientas\crear_disco_prueba.py (512 MiB: cabe el estado de ENCA). Una ruta
    # existente se reutiliza tal cual (segundo arranque del hito 17b).
    [string]$DiscoDatos = "",
    # Carpeta ENCA original: su corpus (18 archivos) se copia al disco de
    # datos (-DiscoDatos prueba) y a la imagen USB (-Imagen) bajo enca/.
    [string]$Enca = "",
    # Segundo corpus (barrido de ranuras, enca=ranuras): el código fuente del
    # compilador de ELE (compiler-l\src) en ele/{entrena,prueba,indice}.bin del
    # disco de datos y de la imagen USB. Ver herramientas\crear_corpus_ele.py.
    [switch]$CorpusEle,
    # Tercer corpus (enca=hablar): carpeta con entrena.bin, prueba.bin e
    # indice.bin del corpus en español (corpus_es\completo o corpus_es\desarrollo;
    # ver crear_corpus_es.py). Se copia a es/ del disco de datos y de la imagen
    # USB. Con -CorpusEs el disco de prueba pasa a 2 GiB (el estado del hablante
    # son ~570 MB por ranura) y la imagen USB a 128 MiB.
    [string]$CorpusEs = "",
    # Cuarto corpus (Fase 4, hito 24, enca=entrenar): carpeta de preparar.ps1 con
    # entrena/valida (.bin, .idx, .tipos). Se copian (NO prueba_sellada) con los
    # prompts de la evaluación a f4/ del disco de datos de prueba (2 GiB: 231 MB de
    # corpus y dos ranuras de ~550 MB). No va en la imagen USB (no cabe): para el
    # portátil se copia por SSH a la partición de datos (ver kernel/docs/bitacora.md).
    [string]$CorpusF4 = "",
    # Carpeta de trabajo (kernel.elf, esp, serie.log, datos.img); por defecto
    # kernel\construccion. Distinta para poder correr dos QEMU a la vez.
    [string]$Carpeta = "",
    # Con -Prueba: segundos que se espera, tras ver -Esperado, antes de matar QEMU
    # (prueba de apagón del hito 24: cortar a mitad de un entrenamiento o de un checkpoint).
    [double]$MatarDespues = 0,
    # Línea de órdenes del kernel (opciones "clave=valor") para la entrada
    # por defecto del menú, p. ej. -Opciones "enca=nuevo". Sin ella, igual
    # que antes (la entrada del menú sin opciones).
    [string]$Opciones = "",
    # Puerto TCP del monitor de QEMU (con -Prueba): cámbielo para que dos QEMU
    # a la vez no choquen.
    [int]$PuertoMonitor = 45454
)

$ErrorActionPreference = "Stop"
$kernel = Split-Path -Parent $PSScriptRoot
$herramientas = $PSScriptRoot
$ele = Join-Path $kernel "compilador\ele.exe"
$salida = Join-Path $kernel "construccion"
if ($Carpeta) { $salida = $Carpeta }
$fuenteEle = Join-Path (Split-Path -Parent $kernel) "compiler-l\src"
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
# limine.conf: con -Prueba sin -Imagen, sin menú (timeout 0). La imagen USB
# conserva siempre el menú (va al portátil). -Opciones se pone como cmdline
# de la primera entrada.
$conf = [System.IO.File]::ReadAllText((Join-Path $herramientas "limine.conf")).Replace("`r`n", "`n")
if ($Prueba -and -not $Imagen) { $conf = $conf -replace "(?m)^timeout: \d+", "timeout: 0" }
if ($Opciones) {
    $marca = "    path: boot():/boot/kernel.elf`n"
    $i = $conf.IndexOf($marca)
    $conf = $conf.Insert($i + $marca.Length, "    cmdline: $Opciones`n")
}
[System.IO.File]::WriteAllText((Join-Path $esp "boot\limine\limine.conf"), $conf, (New-Object System.Text.UTF8Encoding($false)))
Copy-Item $elf (Join-Path $esp "boot\kernel.elf")

$disco = "format=raw,file=fat:rw:`"$esp`""
if ($Imagen) {
    $img = Join-Path $salida "ele.img"
    Write-Host "==> creando imagen USB"
    $extra = @()
    if ($Enca) { $extra += @("--enca", $Enca) }
    if ($CorpusEle) { $extra += @("--ele", $fuenteEle) }
    $mibImagen = 64
    if ($CorpusEs) {
        if (-not (Test-Path (Join-Path $CorpusEs "indice.bin"))) { Fallar "no existe $CorpusEs\indice.bin" }
        $extra += @("--es", $CorpusEs)
        $mibImagen = 128
    }
    python (Join-Path $herramientas "crear_imagen.py") @extra $esp $img $mibImagen
    if ($LASTEXITCODE -ne 0) { Fallar "no se pudo crear la imagen" }
    $disco = "format=raw,file=`"$img`""
}

# 3. QEMU. Celeron 3865U: SSE hasta SSE4.2, sin AVX ni FMA.
$cpu = "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"
$firmware = Join-Path $Qemu "share\edk2-x86_64-code.fd"
$argumentos = @(
    "-M", "q35", "-cpu", $cpu, "-smp", "$Cpus", "-m", $Memoria,
    "-drive", "if=pflash,format=raw,readonly=on,file=`"$firmware`"",
    "-drive", $disco,
    "-no-reboot", "-no-shutdown"
)
if ($Acelerar) { $argumentos += @("-accel", "whpx") }
if ($DiscoDatos) {
    if ($DiscoDatos -eq "prueba") {
        $DiscoDatos = Join-Path $salida "datos.img"
        $extra = @()
        if ($Enca) { $extra += @("--enca", $Enca) }
        if ($CorpusEle) { $extra += @("--ele", $fuenteEle) }
        $mibDatos = 512
        if ($CorpusEs) {
            if (-not (Test-Path (Join-Path $CorpusEs "indice.bin"))) { Fallar "no existe $CorpusEs\indice.bin" }
            $extra += @("--es", $CorpusEs)
            $mibDatos = 2048
        }
        if ($CorpusF4) {
            if (-not (Test-Path (Join-Path $CorpusF4 "entrena.idx"))) { Fallar "no existe $CorpusF4\entrena.idx" }
            $extra += @("--f4", $CorpusF4)
            $mibDatos = 2048
        }
        python (Join-Path $herramientas "crear_disco_prueba.py") $DiscoDatos $mibDatos @extra
        if ($LASTEXITCODE -ne 0) { Fallar "no se pudo crear el disco de prueba" }
    }
    $argumentos += @("-drive", "file=`"$DiscoDatos`",format=raw,if=none,id=datos", "-device", "ide-hd,drive=datos,bus=ide.1")
}
if ($SinHpet) { $argumentos[1] = "q35,hpet=off" }
$qemuExe = Join-Path $Qemu "qemu-system-x86_64.exe"

if (-not $Prueba) {
    Write-Host "==> QEMU (serie en esta consola; cierre la ventana para salir)"
    & $qemuExe @argumentos -serial stdio
    exit $LASTEXITCODE
}

Write-Host "==> QEMU sin ventana, esperando '$Esperado' (máx. $Segundos s)"
if (Test-Path $registro) { Remove-Item -Force $registro }
$puerto = $PuertoMonitor
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
if ($visto -and $MatarDespues -gt 0 -and -not $proceso.HasExited) { Start-Sleep -Milliseconds ([int]($MatarDespues * 1000)) }
if (-not $proceso.HasExited) { Stop-Process -Id $proceso.Id -Force }
Write-Host "---- salida serie ----"
Write-Host (Leer-Serie)
Write-Host "----------------------"
if ($visto) {
    Write-Host "OK: apareció '$Esperado'" -ForegroundColor Green
    exit 0
}
Fallar "no apareció '$Esperado' en $Segundos s"
