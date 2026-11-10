param(
    [ValidateSet('cranelift', 'rustc')]
    [string] $Backend = 'cranelift',
    [string] $Compiler = (Join-Path $PSScriptRoot '../target/debug/l.exe'),
    [switch] $TraceAlloc
)

$ErrorActionPreference = 'Stop'
$compilerPath = (Resolve-Path -LiteralPath $Compiler).Path
$buildDir = Join-Path $PSScriptRoot '../target/compiler-l'
[IO.Directory]::CreateDirectory($buildDir) > $null
$entryFile = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'src/main.l')).Path
$options = @()
if ($TraceAlloc) {
    $options += '--trace-alloc'
}
Push-Location -LiteralPath $buildDir
try {
    $output = & $compilerPath build $entryFile --backend $Backend @options
    if ($LASTEXITCODE -ne 0) {
        throw "Falló la compilación de lexer-l ($LASTEXITCODE)"
    }
    $path = ($output | Where-Object { $_ -like 'Build: *' }).Substring(7)
    (Resolve-Path -LiteralPath $path).Path
} finally {
    Pop-Location
}
